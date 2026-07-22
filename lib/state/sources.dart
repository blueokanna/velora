import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:charset/charset.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/settings.dart';

class BookSourceModel {
  final String name;
  final String url;
  final bool enabled;
  final int bookSourceType;
  final String sourceGroup;
  final String sourceIcon;
  final bool enabledExplore;
  final String exploreUrl;
  final String exploreList;
  final String exploreName;
  final String exploreAuthor;
  final String exploreBookUrl;
  final String exploreCover;
  final String searchUrl;
  final String searchList;
  final String searchName;
  final String searchAuthor;
  final String searchBookUrl;
  final String searchCover;
  final String bookInfoName;
  final String bookInfoAuthor;
  final String bookInfoIntro;
  final String bookInfoCover;
  final String bookInfoTocUrl;
  final String tocList;
  final String tocName;
  final String tocUrl;
  final String contentSelector;
  final int ruleVersion;
  final int minTextChars;
  final List<String> denyKeywords;
  final String rssArticles;
  final String rssTitle;
  final String rssPubDate;
  final String rssDescription;
  final String rssImage;
  final String rssLink;
  final String rssContent;

  const BookSourceModel({
    required this.name,
    required this.url,
    this.enabled = true,
    this.bookSourceType = 0,
    this.sourceGroup = '',
    this.sourceIcon = '',
    this.enabledExplore = false,
    this.exploreUrl = '',
    this.exploreList = '',
    this.exploreName = '',
    this.exploreAuthor = '',
    this.exploreBookUrl = '',
    this.exploreCover = '',
    required this.searchUrl,
    required this.searchList,
    required this.searchName,
    required this.searchAuthor,
    required this.searchBookUrl,
    this.searchCover = '',
    required this.bookInfoName,
    required this.bookInfoAuthor,
    required this.bookInfoIntro,
    this.bookInfoCover = '',
    required this.bookInfoTocUrl,
    required this.tocList,
    required this.tocName,
    required this.tocUrl,
    required this.contentSelector,
    this.ruleVersion = 1,
    this.minTextChars = 100,
    this.denyKeywords = const [],
    this.rssArticles = '',
    this.rssTitle = '',
    this.rssPubDate = '',
    this.rssDescription = '',
    this.rssImage = '',
    this.rssLink = '',
    this.rssContent = '',
  });

  bool get isRssSource {
    if (rssArticles.trim().isNotEmpty ||
        rssTitle.trim().isNotEmpty ||
        rssPubDate.trim().isNotEmpty ||
        rssDescription.trim().isNotEmpty ||
        rssImage.trim().isNotEmpty ||
        rssLink.trim().isNotEmpty ||
        rssContent.trim().isNotEmpty) {
      return true;
    }
    return url.trim().isNotEmpty &&
        searchUrl.trim().isEmpty &&
        searchList.trim().isEmpty &&
        searchBookUrl.trim().isEmpty &&
        bookInfoName.trim().isEmpty &&
        bookInfoTocUrl.trim().isEmpty &&
        tocList.trim().isEmpty &&
        contentSelector.trim().isEmpty;
  }

  bool get supportsExploreRecommendations {
    return enabledExplore &&
        exploreUrl.trim().isNotEmpty &&
        exploreList.trim().isNotEmpty &&
        exploreName.trim().isNotEmpty &&
        exploreBookUrl.trim().isNotEmpty;
  }

  List<String> get exploreEntryUrls =>
      _parseExploreEntryUrls(exploreUrl, baseUrl: url);

  BookSourceModel? toExploreSearchSource(String exploreEntryUrl) {
    if (!supportsExploreRecommendations) return null;
    final resolvedUrl = _resolveExploreEntryUrl(exploreEntryUrl, baseUrl: url);
    if (resolvedUrl.isEmpty) return null;
    return BookSourceModel(
      name: name,
      url: url,
      enabled: enabled,
      bookSourceType: bookSourceType,
      sourceGroup: sourceGroup,
      sourceIcon: sourceIcon,
      enabledExplore: enabledExplore,
      exploreUrl: exploreUrl,
      exploreList: exploreList,
      exploreName: exploreName,
      exploreAuthor: exploreAuthor,
      exploreBookUrl: exploreBookUrl,
      exploreCover: exploreCover,
      searchUrl: resolvedUrl,
      searchList: exploreList,
      searchName: exploreName,
      searchAuthor: exploreAuthor,
      searchBookUrl: exploreBookUrl,
      searchCover: exploreCover,
      bookInfoName: bookInfoName,
      bookInfoAuthor: bookInfoAuthor,
      bookInfoIntro: bookInfoIntro,
      bookInfoCover: bookInfoCover,
      bookInfoTocUrl: bookInfoTocUrl,
      tocList: tocList,
      tocName: tocName,
      tocUrl: tocUrl,
      contentSelector: contentSelector,
      ruleVersion: ruleVersion,
      minTextChars: minTextChars,
      denyKeywords: denyKeywords,
      rssArticles: rssArticles,
      rssTitle: rssTitle,
      rssPubDate: rssPubDate,
      rssDescription: rssDescription,
      rssImage: rssImage,
      rssLink: rssLink,
      rssContent: rssContent,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'enabled': enabled,
    'book_source_type': bookSourceType,
    'source_group': sourceGroup,
    'source_icon': sourceIcon,
    'enabled_explore': enabledExplore,
    'explore_url': exploreUrl,
    'explore_list': exploreList,
    'explore_name': exploreName,
    'explore_author': exploreAuthor,
    'explore_book_url': exploreBookUrl,
    'explore_cover': exploreCover,
    'search_url': searchUrl,
    'search_list': searchList,
    'search_name': searchName,
    'search_author': searchAuthor,
    'search_book_url': searchBookUrl,
    'search_cover': searchCover,
    'book_info_name': bookInfoName,
    'book_info_author': bookInfoAuthor,
    'book_info_intro': bookInfoIntro,
    'book_info_cover': bookInfoCover,
    'book_info_toc_url': bookInfoTocUrl,
    'toc_list': tocList,
    'toc_name': tocName,
    'toc_url': tocUrl,
    'content_selector': contentSelector,
    'rule_version': ruleVersion,
    'validation': {
      'min_text_chars': minTextChars,
      'deny_keywords': denyKeywords,
    },
    'rss_articles': rssArticles,
    'rss_title': rssTitle,
    'rss_pub_date': rssPubDate,
    'rss_description': rssDescription,
    'rss_image': rssImage,
    'rss_link': rssLink,
    'rss_content': rssContent,
  };

  String toJsonString() => jsonEncode(toJson());

  factory BookSourceModel.fromJson(Map<String, dynamic> j) {
    final isRssPayload = _looksLikeRssSource(j);
    final searchRules = _mapField(j, 'ruleSearch');
    final infoRules = _mapField(j, 'ruleBookInfo');
    final tocRules = _mapField(j, 'ruleToc');
    final exploreRules = _mapField(j, 'ruleExplore');
    final contentRules = isRssPayload
        ? const <String, dynamic>{}
        : _mapField(j, 'ruleContent');
    final rssContentRules = isRssPayload
        ? _mapField(j, 'ruleContent')
        : const <String, dynamic>{};
    final validation = _mapField(j, 'validation');
    return BookSourceModel(
      name: _stringField(j, ['name', 'bookSourceName', 'sourceName']),
      url: _stringField(j, ['url', 'bookSourceUrl', 'sourceUrl']),
      enabled: _boolField(j, ['enabled', 'enable'], fallback: true),
      bookSourceType: _intField(j, [
        'book_source_type',
        'bookSourceType',
      ], fallback: 0),
      sourceGroup: _stringField(j, [
        'source_group',
        'bookSourceGroup',
        'sourceGroup',
      ]),
      sourceIcon: _stringField(j, ['source_icon', 'sourceIcon']),
      enabledExplore: _boolField(j, [
        'enabled_explore',
        'enabledExplore',
      ], fallback: false),
      exploreUrl: _stringField(j, ['explore_url', 'exploreUrl']),
      exploreList: _stringField(
        j,
        ['explore_list'],
        exploreRules,
        ['bookList'],
      ),
      exploreName: _stringField(j, ['explore_name'], exploreRules, ['name']),
      exploreAuthor: _stringField(
        j,
        ['explore_author'],
        exploreRules,
        ['author'],
      ),
      exploreBookUrl: _stringField(
        j,
        ['explore_book_url'],
        exploreRules,
        ['bookUrl', 'url'],
      ),
      exploreCover: _stringField(
        j,
        ['explore_cover'],
        exploreRules,
        ['coverUrl', 'cover'],
      ),
      searchUrl: _stringField(j, ['search_url', 'searchUrl']),
      searchList: _stringField(j, ['search_list'], searchRules, ['bookList']),
      searchName: _stringField(j, ['search_name'], searchRules, ['name']),
      searchAuthor: _stringField(j, ['search_author'], searchRules, ['author']),
      searchBookUrl: _stringField(
        j,
        ['search_book_url'],
        searchRules,
        ['bookUrl', 'url'],
      ),
      searchCover: _stringField(
        j,
        ['search_cover', 'coverUrl'],
        searchRules,
        ['coverUrl', 'cover'],
      ),
      bookInfoName: _stringField(j, ['book_info_name'], infoRules, ['name']),
      bookInfoAuthor: _stringField(
        j,
        ['book_info_author'],
        infoRules,
        ['author'],
      ),
      bookInfoIntro: _stringField(j, ['book_info_intro'], infoRules, ['intro']),
      bookInfoCover: _stringField(
        j,
        ['book_info_cover'],
        infoRules,
        ['coverUrl', 'cover'],
      ),
      bookInfoTocUrl: _stringField(
        j,
        ['book_info_toc_url'],
        infoRules,
        ['tocUrl', 'catalogUrl'],
      ),
      tocList: _stringField(j, ['toc_list'], tocRules, ['chapterList']),
      tocName: _stringField(j, ['toc_name'], tocRules, ['chapterName', 'name']),
      tocUrl: _stringField(j, ['toc_url'], tocRules, ['chapterUrl', 'url']),
      contentSelector: _stringField(
        j,
        ['content_selector'],
        contentRules,
        ['content'],
      ),
      ruleVersion: _intField(j, ['rule_version', 'version'], fallback: 1),
      minTextChars: _intField(validation, [
        'min_text_chars',
        'minTextChars',
      ], fallback: 100).clamp(1, 100000),
      denyKeywords: _stringListField(validation, [
        'deny_keywords',
        'denyKeywords',
      ]),
      rssArticles: _stringField(j, ['rss_articles', 'ruleArticles']),
      rssTitle: _stringField(j, ['rss_title', 'ruleTitle']),
      rssPubDate: _stringField(j, ['rss_pub_date', 'rulePubDate']),
      rssDescription: _stringField(j, ['rss_description', 'ruleDescription']),
      rssImage: _stringField(j, ['rss_image', 'ruleImage']),
      rssLink: _stringField(j, ['rss_link', 'ruleLink']),
      rssContent: _stringField(
        j,
        ['rss_content'],
        rssContentRules,
        ['content'],
      ),
    );
  }

  BookSourceModel copyWith({bool? enabled}) => BookSourceModel(
    name: name,
    url: url,
    enabled: enabled ?? this.enabled,
    bookSourceType: bookSourceType,
    sourceGroup: sourceGroup,
    sourceIcon: sourceIcon,
    enabledExplore: enabledExplore,
    exploreUrl: exploreUrl,
    exploreList: exploreList,
    exploreName: exploreName,
    exploreAuthor: exploreAuthor,
    exploreBookUrl: exploreBookUrl,
    exploreCover: exploreCover,
    searchUrl: searchUrl,
    searchList: searchList,
    searchName: searchName,
    searchAuthor: searchAuthor,
    searchBookUrl: searchBookUrl,
    searchCover: searchCover,
    bookInfoName: bookInfoName,
    bookInfoAuthor: bookInfoAuthor,
    bookInfoIntro: bookInfoIntro,
    bookInfoCover: bookInfoCover,
    bookInfoTocUrl: bookInfoTocUrl,
    tocList: tocList,
    tocName: tocName,
    tocUrl: tocUrl,
    contentSelector: contentSelector,
    ruleVersion: ruleVersion,
    minTextChars: minTextChars,
    denyKeywords: denyKeywords,
    rssArticles: rssArticles,
    rssTitle: rssTitle,
    rssPubDate: rssPubDate,
    rssDescription: rssDescription,
    rssImage: rssImage,
    rssLink: rssLink,
    rssContent: rssContent,
  );
}

BookSourceModel? decodeBookSourceModelJson(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return BookSourceModel.fromJson(decoded);
    }
    if (decoded is Map) {
      return BookSourceModel.fromJson(decoded.cast<String, dynamic>());
    }
  } catch (_) {}
  return null;
}

enum SourceImportStage {
  preparing,
  fetching,
  parsing,
  merging,
  saving,
  completed,
  cancelled,
}

class SourceImportProgress {
  final SourceImportStage stage;
  final int processed;
  final int? total;
  final int imported;
  final String? label;

  const SourceImportProgress({
    required this.stage,
    this.processed = 0,
    this.total,
    this.imported = 0,
    this.label,
  });

  double? get value {
    final total = this.total;
    if (total == null || total <= 0) return null;
    return (processed / total).clamp(0, 1).toDouble();
  }
}

typedef SourceImportProgressCallback =
    void Function(SourceImportProgress progress);

class SourceImportController {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void throwIfCancelled() {
    if (_cancelled) throw const SourceImportCancelled();
  }
}

class SourceImportCancelled implements Exception {
  const SourceImportCancelled();

  @override
  String toString() => 'SourceImportCancelled';
}

class SourcesNotifier extends StateNotifier<List<BookSourceModel>> {
  SourcesNotifier(this._prefs) : super(_load(_prefs));
  final SharedPreferences _prefs;
  static const _key = 'book_sources';

  static List<BookSourceModel> _load(SharedPreferences p) {
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .cast<Map<String, dynamic>>()
        .map(BookSourceModel.fromJson)
        .toList();
  }

  Future<void> _persist([List<BookSourceModel>? snapshot]) async {
    await _prefs.setString(_key, await _serializeSources(snapshot ?? state));
  }

  Future<void> addOrUpdate(BookSourceModel src) async {
    final exists = state.indexWhere((e) => e.url == src.url);
    final next = List<BookSourceModel>.from(state);
    if (exists >= 0) {
      next[exists] = src;
    } else {
      next.add(src);
    }
    state = next;
    await _persist(next);
  }

  Future<void> remove(String url) async {
    state = state.where((e) => e.url != url).toList();
    await _persist(state);
  }

  Future<void> toggle(String url, bool enabled) async {
    state = state
        .map((e) => e.url == url ? e.copyWith(enabled: enabled) : e)
        .toList();
    await _persist(state);
  }

  Future<int> importJson(
    String json, {
    SourceImportProgressCallback? onProgress,
    SourceImportController? controller,
  }) async {
    return importPayload(json, onProgress: onProgress, controller: controller);
  }

  Future<int> importTextOrUrl(
    String input, {
    SourceImportProgressCallback? onProgress,
    SourceImportController? controller,
  }) async {
    final activeController = controller ?? SourceImportController();
    _reportImportProgress(
      onProgress,
      const SourceImportProgress(stage: SourceImportStage.preparing),
    );
    final payloads = await _readImportPayloads(
      input,
      onProgress: onProgress,
      controller: activeController,
    );
    final importedSources = <BookSourceModel>[];
    for (final payload in payloads) {
      activeController.throwIfCancelled();
      importedSources.addAll(
        await _decodeImportModels(
          payload,
          onProgress: onProgress,
          controller: activeController,
        ),
      );
      if (payloads.length > 1) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    final imported = await _upsertImportedSources(
      importedSources,
      onProgress: onProgress,
      controller: activeController,
    );
    _reportImportProgress(
      onProgress,
      SourceImportProgress(
        stage: SourceImportStage.completed,
        processed: importedSources.length,
        total: importedSources.length,
        imported: imported,
      ),
    );
    return imported;
  }

  Future<int> importPayload(
    String payload, {
    SourceImportProgressCallback? onProgress,
    SourceImportController? controller,
  }) async {
    final activeController = controller ?? SourceImportController();
    _reportImportProgress(
      onProgress,
      const SourceImportProgress(stage: SourceImportStage.preparing),
    );
    final importedSources = await _decodeImportModels(
      payload,
      onProgress: onProgress,
      controller: activeController,
    );
    final imported = await _upsertImportedSources(
      importedSources,
      onProgress: onProgress,
      controller: activeController,
    );
    _reportImportProgress(
      onProgress,
      SourceImportProgress(
        stage: SourceImportStage.completed,
        processed: importedSources.length,
        total: importedSources.length,
        imported: imported,
      ),
    );
    return imported;
  }

  Future<int> _upsertImportedSources(
    List<BookSourceModel> importedSources, {
    SourceImportProgressCallback? onProgress,
    SourceImportController? controller,
  }) async {
    var imported = 0;
    if (importedSources.isEmpty) return imported;
    _reportImportProgress(
      onProgress,
      SourceImportProgress(
        stage: SourceImportStage.merging,
        processed: 0,
        total: importedSources.length,
      ),
    );
    final merged = <String, BookSourceModel>{
      for (final source in state) source.url: source,
    };
    for (var index = 0; index < importedSources.length; index++) {
      controller?.throwIfCancelled();
      final source = importedSources[index];
      if (source.url.trim().isEmpty) continue;
      if (!merged.containsKey(source.url)) {
        imported += 1;
      }
      merged[source.url] = source;
      if ((index + 1) % 64 == 0 || index + 1 == importedSources.length) {
        _reportImportProgress(
          onProgress,
          SourceImportProgress(
            stage: SourceImportStage.merging,
            processed: index + 1,
            total: importedSources.length,
            imported: imported,
          ),
        );
      }
      if ((index + 1) % 128 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    final next = merged.values.toList(growable: false);
    _reportImportProgress(
      onProgress,
      SourceImportProgress(
        stage: SourceImportStage.saving,
        processed: importedSources.length,
        total: importedSources.length,
        imported: imported,
      ),
    );
    controller?.throwIfCancelled();
    state = next;
    await _persist(next);
    return imported;
  }
}

void _reportImportProgress(
  SourceImportProgressCallback? onProgress,
  SourceImportProgress progress,
) {
  onProgress?.call(progress);
}

Future<String> _serializeSources(List<BookSourceModel> snapshot) {
  final raw = snapshot.map((item) => item.toJson()).toList(growable: false);
  return Isolate.run(() => jsonEncode(raw));
}

Future<List<BookSourceModel>> _decodeImportModels(
  String payload, {
  SourceImportProgressCallback? onProgress,
  SourceImportController? controller,
}) async {
  controller?.throwIfCancelled();
  final rawSources = await Isolate.run(() => _decodeImportPayloadMaps(payload));
  final models = <BookSourceModel>[];
  _reportImportProgress(
    onProgress,
    SourceImportProgress(
      stage: SourceImportStage.parsing,
      processed: 0,
      total: rawSources.length,
    ),
  );
  for (var index = 0; index < rawSources.length; index++) {
    controller?.throwIfCancelled();
    models.add(BookSourceModel.fromJson(rawSources[index]));
    if ((index + 1) % 64 == 0 || index + 1 == rawSources.length) {
      _reportImportProgress(
        onProgress,
        SourceImportProgress(
          stage: SourceImportStage.parsing,
          processed: index + 1,
          total: rawSources.length,
        ),
      );
    }
    if ((index + 1) % 128 == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  return models;
}

List<Map<String, dynamic>> _decodeImportPayloadMaps(String payload) {
  final decoded = jsonDecode(_extractJsonCandidate(payload));
  if (decoded is List) {
    return decoded.whereType<Map>().map(_castMap).toList(growable: false);
  }
  if (decoded is! Map) return const [];
  final map = _castMap(decoded);
  final nested = map['data'] ?? map['sources'] ?? map['bookSources'];
  if (nested is List) {
    return nested.whereType<Map>().map(_castMap).toList(growable: false);
  }
  return [map];
}

Map<String, dynamic> _castMap(Map<dynamic, dynamic> raw) =>
    raw.map((key, value) => MapEntry(key.toString(), value));

Map<String, dynamic> _mapField(Map<String, dynamic> raw, String key) {
  final value = raw[key];
  if (value is Map) return _castMap(value);
  return const {};
}

String _stringField(
  Map<String, dynamic> raw,
  List<String> keys, [
  Map<String, dynamic> nested = const {},
  List<String> nestedKeys = const [],
]) {
  for (final key in keys) {
    final value = raw[key];
    if (value != null) return value.toString().trim();
  }
  for (final key in nestedKeys) {
    final value = nested[key];
    if (value != null) return value.toString().trim();
  }
  return '';
}

bool _boolField(
  Map<String, dynamic> raw,
  List<String> keys, {
  required bool fallback,
}) {
  for (final key in keys) {
    final value = raw[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
  }
  return fallback;
}

int _intField(
  Map<String, dynamic> raw,
  List<String> keys, {
  required int fallback,
}) {
  for (final key in keys) {
    final value = raw[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
  }
  return fallback;
}

List<String> _stringListField(Map<String, dynamic> raw, List<String> keys) {
  for (final key in keys) {
    final value = raw[key];
    if (value is List) {
      return List<String>.unmodifiable(
        value
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty),
      );
    }
    if (value is String && value.trim().isNotEmpty) {
      return List<String>.unmodifiable(
        value
            .split(RegExp(r'[,，\n]'))
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty),
      );
    }
  }
  return const [];
}

bool _looksLikeRssSource(Map<String, dynamic> raw) {
  if (raw.containsKey('ruleArticles') ||
      raw.containsKey('ruleTitle') ||
      raw.containsKey('rulePubDate') ||
      raw.containsKey('ruleDescription') ||
      raw.containsKey('ruleImage') ||
      raw.containsKey('ruleLink')) {
    return true;
  }
  return raw.containsKey('sourceUrl') &&
      !raw.containsKey('ruleSearch') &&
      !raw.containsKey('ruleBookInfo') &&
      !raw.containsKey('ruleToc');
}

List<String> _parseExploreEntryUrls(String raw, {required String baseUrl}) {
  final jsonEntries = _parseExploreEntryUrlsFromJson(raw, baseUrl: baseUrl);
  if (jsonEntries.isNotEmpty) {
    return jsonEntries;
  }
  final entries = <String>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split('::');
    final urlPart = parts.length >= 2 ? parts.sublist(1).join('::') : trimmed;
    final resolved = _resolveExploreEntryUrl(urlPart, baseUrl: baseUrl);
    if (resolved.isNotEmpty && !entries.contains(resolved)) {
      entries.add(resolved);
    }
  }
  return entries;
}

List<String> _parseExploreEntryUrlsFromJson(
  String raw, {
  required String baseUrl,
}) {
  final trimmed = raw.trim();
  if (!(trimmed.startsWith('[') || trimmed.startsWith('{'))) {
    return const [];
  }
  try {
    final decoded = jsonDecode(trimmed);
    final entries = <String>[];

    void collectFrom(dynamic value) {
      if (value is List) {
        for (final item in value) {
          collectFrom(item);
        }
        return;
      }
      if (value is! Map) {
        return;
      }
      final map = _castMap(value.cast<dynamic, dynamic>());
      final nested =
          map['data'] ??
          map['items'] ??
          map['tabs'] ??
          map['children'] ??
          map['list'];
      if (nested is List) {
        collectFrom(nested);
      }
      final rawUrl = [map['url'], map['exploreUrl'], map['link'], map['path']]
          .firstWhere(
            (candidate) =>
                candidate != null && candidate.toString().trim().isNotEmpty,
            orElse: () => null,
          );
      if (rawUrl == null) {
        return;
      }
      final resolved = _resolveExploreEntryUrl(
        rawUrl.toString(),
        baseUrl: baseUrl,
      );
      if (resolved.isNotEmpty && !entries.contains(resolved)) {
        entries.add(resolved);
      }
    }

    collectFrom(decoded);
    return entries;
  } catch (_) {
    return const [];
  }
}

String _resolveExploreEntryUrl(String raw, {required String baseUrl}) {
  var value = raw.trim();
  if (value.isEmpty) return '';
  for (final placeholder in const [
    '{{page}}',
    '{page}',
    '{{pageNo}}',
    '{pageNo}',
  ]) {
    value = value.replaceAll(placeholder, '1');
  }
  final base = Uri.tryParse(baseUrl);
  if (base != null) {
    final joined = base.resolve(value).toString();
    if (joined.isNotEmpty) {
      return joined;
    }
  }
  return value;
}

Future<List<String>> _readImportPayloads(
  String input, {
  SourceImportProgressCallback? onProgress,
  SourceImportController? controller,
}) async {
  controller?.throwIfCancelled();
  final trimmed = input.trim();
  if (trimmed.isEmpty) return const [];
  final urls = extractSourceImportUrls(trimmed);
  if (urls.isNotEmpty) {
    final payloads = <String>[];
    Object? lastError;
    for (var index = 0; index < urls.length; index++) {
      controller?.throwIfCancelled();
      final url = urls[index];
      _reportImportProgress(
        onProgress,
        SourceImportProgress(
          stage: SourceImportStage.fetching,
          processed: index,
          total: urls.length,
          label: url,
        ),
      );
      try {
        payloads.addAll(
          await _fetchImportPayloads(url, controller: controller),
        );
        _reportImportProgress(
          onProgress,
          SourceImportProgress(
            stage: SourceImportStage.fetching,
            processed: index + 1,
            total: urls.length,
            label: url,
          ),
        );
      } catch (error) {
        lastError = error;
      }
    }
    if (payloads.isNotEmpty) return payloads;
    if (lastError != null) {
      throw StateError('$lastError');
    }
  }
  return [trimmed];
}

List<String> buildImportFetchCandidates(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return [url];
  final candidates = <String>{uri.toString()};
  final yckceoContentProbe = _toYckceoContentPage(uri);
  if (yckceoContentProbe != null) {
    candidates.add(yckceoContentProbe);
  }
  if (uri.scheme == 'https') {
    candidates.add(uri.replace(scheme: 'http').toString());
    if (yckceoContentProbe != null) {
      candidates.add(
        Uri.parse(yckceoContentProbe).replace(scheme: 'http').toString(),
      );
    }
  }
  if (uri.host.startsWith('www.')) {
    final bareHost = uri.host.substring(4);
    candidates.add(uri.replace(host: bareHost).toString());
    if (uri.scheme == 'https') {
      candidates.add(uri.replace(scheme: 'http', host: bareHost).toString());
    }
    if (yckceoContentProbe != null) {
      final contentUri = Uri.parse(yckceoContentProbe);
      candidates.add(contentUri.replace(host: bareHost).toString());
      if (contentUri.scheme == 'https') {
        candidates.add(
          contentUri.replace(scheme: 'http', host: bareHost).toString(),
        );
      }
    }
  }
  return candidates.toList(growable: false);
}

String? _toYckceoContentPage(Uri uri) {
  final match = RegExp(
    r'^/yuedu/shuyuans/json/id/(\d+)\.json$',
    caseSensitive: false,
  ).firstMatch(uri.path);
  if (match == null) return null;
  final id = match.group(1)!;
  return uri.replace(path: '/yuedu/shuyuans/content/id/$id.html').toString();
}

List<String> extractSourceImportUrls(String input) {
  final urls = <String>{};
  final onlineImport = decodeSourceImportUrl(input);
  if (onlineImport != null) {
    urls.add(onlineImport);
  }
  final onlineImportLinks = RegExp(
    r'''yuedu://[^\s"'<>]+''',
    caseSensitive: false,
  ).allMatches(input);
  for (final match in onlineImportLinks) {
    final decoded = decodeSourceImportUrl(match.group(0)!);
    if (decoded != null) {
      urls.add(decoded);
    }
  }
  final contentLinks = RegExp(
    r'''https?://www\.yckceo\.com/yuedu/shuyuans/content/id/(\d+)\.html''',
    caseSensitive: false,
  ).allMatches(input);
  for (final match in contentLinks) {
    final id = match.group(1)!;
    urls.add('https://www.yckceo.com/yuedu/shuyuans/json/id/$id.json');
  }
  final rawUrls = RegExp(r"""https?://[^\s"'<>]+""").allMatches(input);
  for (final match in rawUrls) {
    final normalized = normalizeSourceImportUrl(match.group(0)!);
    if (normalized != null) {
      urls.add(normalized);
    }
  }
  return urls.toList(growable: false);
}

String? normalizeSourceImportUrl(String? input) {
  if (input == null) return null;
  var value = input.trim();
  if (value.isEmpty) return null;
  value = value.replaceAll('&amp;', '&');
  while (value.isNotEmpty && '),;]}'.contains(value[value.length - 1])) {
    value = value.substring(0, value.length - 1).trimRight();
  }
  return value.isEmpty ? null : value;
}

String? decodeSourceImportUrl(String input) {
  try {
    final uri = Uri.tryParse(input);
    if (uri == null) return null;
    final value =
        uri.queryParameters['src'] ??
        uri.queryParameters['url'] ??
        uri.queryParameters['source'];
    if (value == null || value.trim().isEmpty) return null;
    return normalizeSourceImportUrl(Uri.decodeFull(value.trim()));
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

Future<List<String>> _fetchImportPayloads(
  String url, {
  SourceImportController? controller,
}) async {
  Object? lastError;
  for (final candidate in buildImportFetchCandidates(url)) {
    controller?.throwIfCancelled();
    try {
      final body = await _requestImportBody(candidate);
      if (body.isEmpty) continue;
      if (body.startsWith('{') || body.startsWith('[')) return [body];
      final embeddedUrls = extractSourceImportUrls(body);
      if (embeddedUrls.isNotEmpty) {
        final payloads = <String>[];
        for (final item in embeddedUrls) {
          controller?.throwIfCancelled();
          if (item == candidate || item == url) continue;
          payloads.addAll(
            await _fetchImportPayloads(item, controller: controller),
          );
        }
        if (payloads.isNotEmpty) return payloads;
      }
      final candidateJson = _extractJsonCandidate(body);
      if (candidateJson.trim().startsWith('{') ||
          candidateJson.trim().startsWith('[')) {
        return [candidateJson];
      }
    } on SocketException catch (error) {
      lastError = error;
    } on TimeoutException catch (error) {
      lastError = error;
    } on http.ClientException catch (error) {
      lastError = error;
    } on StateError catch (error) {
      lastError = error;
    }
  }
  if (lastError != null) {
    throw StateError('导入请求失败: $url ($lastError)');
  }
  return const [];
}

Future<String> _requestImportBody(String url) async {
  final uri = Uri.parse(url);
  final client = RetryClient(
    http.Client(),
    retries: 2,
    whenError: (error, _) =>
        error is SocketException || error is TimeoutException,
  );
  try {
    final response = await client
        .get(
          uri,
          headers: {
            'Accept': 'application/json,text/plain,text/html,*/*',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
            'Referer': '${uri.scheme}://${uri.host}/',
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36 Velora/1.0',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw StateError('HTTP ${response.statusCode}');
    }
    return decodeImportResponseBody(
      response.bodyBytes,
      contentType: response.headers['content-type'],
    ).trim();
  } finally {
    client.close();
  }
}

String decodeImportResponseBody(List<int> bodyBytes, {String? contentType}) {
  if (bodyBytes.isEmpty) {
    return '';
  }
  final decodedUtf8 = _tryDecodeDartEncoding(utf8, bodyBytes);
  if (decodedUtf8 != null &&
      (_looksLikeImportPayload(decodedUtf8) ||
          _looksLikeImportHtml(decodedUtf8))) {
    return decodedUtf8.trim();
  }
  final candidates = <Encoding>[];
  final seen = <String>{};
  void push(Encoding? encoding) {
    if (encoding == null) return;
    final key = encoding.name.toLowerCase();
    if (seen.add(key)) {
      candidates.add(encoding);
    }
  }

  final declaredCharset = _extractDeclaredCharset(contentType);
  push(declaredCharset == null ? null : Charset.getByName(declaredCharset));
  push(utf8);
  if (_hasUtf16Bom(bodyBytes)) {
    push(Charset.getByName('utf-16'));
  }
  push(Charset.getByName('gb18030'));
  push(Charset.getByName('gbk'));
  push(Charset.getByName('gb2312'));
  push(latin1);
  push(
    Charset.detect(
      bodyBytes,
      defaultEncoding: utf8,
      orders: [utf8, Charset.getByName('gbk') ?? utf8],
    ),
  );

  String? bestText;
  var bestScore = -1 << 30;
  for (final encoding in candidates) {
    final decoded = _tryDecodeCharsetEncoding(encoding, bodyBytes);
    if (decoded == null) {
      continue;
    }
    final score = _scoreDecodedImportText(decoded, encoding.name);
    if (score > bestScore) {
      bestScore = score;
      bestText = decoded;
    }
  }
  return (bestText ?? utf8.decode(bodyBytes, allowMalformed: true)).trim();
}

String? _tryDecodeDartEncoding(Encoding encoding, List<int> bodyBytes) {
  try {
    return encoding.decode(bodyBytes);
  } on FormatException catch (_) {
    return null;
  }
}

String? _tryDecodeCharsetEncoding(Encoding encoding, List<int> bodyBytes) {
  try {
    return encoding.decode(bodyBytes);
  } on FormatException catch (_) {
    return null;
  } on ArgumentError catch (_) {
    return null;
  }
}

String? _extractDeclaredCharset(String? contentType) {
  if (contentType == null || contentType.isEmpty) {
    return null;
  }
  final match = RegExp(
    "charset\\s*=\\s*['\\\"]?([^;'\\\"]+)",
    caseSensitive: false,
  ).firstMatch(contentType);
  if (match == null) {
    return null;
  }
  return match.group(1)?.trim();
}

int _scoreDecodedImportText(String text, String encodingName) {
  var score = 0;
  final trimmed = text.trimLeft();
  if (_looksLikeImportPayload(text)) {
    score += 6000;
  } else if (_looksLikeImportHtml(text)) {
    score += 2400;
  } else if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    score += 1200;
  }
  final replacementCount = '�'.allMatches(text).length;
  final cjkCount = RegExp(r'[\u2E80-\u9FFF]').allMatches(text).length;
  final suspiciousLatin = RegExp(r'[\u00C0-\u024F]').allMatches(text).length;
  score -= replacementCount * 160;
  score += cjkCount * 10;
  if (cjkCount == 0 && suspiciousLatin > 24) {
    score -= suspiciousLatin * 12;
  }
  if (encodingName.toLowerCase().contains('1252') && cjkCount > 0) {
    score -= 600;
  }
  score += text.length.clamp(0, 2000);
  return score;
}

bool _hasUtf16Bom(List<int> bodyBytes) {
  return bodyBytes.length >= 2 &&
      ((bodyBytes[0] == 0xFF && bodyBytes[1] == 0xFE) ||
          (bodyBytes[0] == 0xFE && bodyBytes[1] == 0xFF));
}

bool _looksLikeImportPayload(String text) {
  final candidate = _extractJsonCandidate(text).trim();
  if (!(candidate.startsWith('{') || candidate.startsWith('['))) {
    return false;
  }
  try {
    final decoded = jsonDecode(candidate);
    if (decoded is List) {
      return decoded.isNotEmpty;
    }
    if (decoded is Map) {
      return decoded.isNotEmpty;
    }
  } catch (_) {
    return false;
  }
  return false;
}

bool _looksLikeImportHtml(String text) {
  final lower = text.toLowerCase();
  return lower.contains('<html') ||
      lower.contains('yuedu://booksource/importonline') ||
      lower.contains('/yuedu/shuyuans/json/id/') ||
      lower.contains('<script');
}

String _extractJsonCandidate(String payload) {
  final trimmed = payload.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) return trimmed;
  final array = _balancedJson(trimmed, '[', ']');
  if (array != null) return array;
  final object = _balancedJson(trimmed, '{', '}');
  if (object != null) return object;
  return trimmed;
}

String? _balancedJson(String text, String open, String close) {
  final start = text.indexOf(open);
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final char = text[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (char == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (char == open) depth++;
    if (char == close) depth--;
    if (depth == 0) return text.substring(start, i + 1);
  }
  return null;
}

final sourcesProvider =
    StateNotifierProvider<SourcesNotifier, List<BookSourceModel>>((ref) {
      return SourcesNotifier(ref.watch(sharedPreferencesProvider));
    });
