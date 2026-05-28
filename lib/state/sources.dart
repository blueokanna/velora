import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/legacy.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/settings.dart';

class BookSourceModel {
  final String name;
  final String url;
  final bool enabled;
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

  const BookSourceModel({
    required this.name,
    required this.url,
    this.enabled = true,
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
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'enabled': enabled,
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
  };

  String toJsonString() => jsonEncode(toJson());

  factory BookSourceModel.fromJson(Map<String, dynamic> j) {
    final searchRules = _mapField(j, 'ruleSearch');
    final infoRules = _mapField(j, 'ruleBookInfo');
    final tocRules = _mapField(j, 'ruleToc');
    final contentRules = _mapField(j, 'ruleContent');
    return BookSourceModel(
      name: _stringField(j, ['name', 'bookSourceName', 'sourceName']),
      url: _stringField(j, ['url', 'bookSourceUrl', 'sourceUrl']),
      enabled: _boolField(j, ['enabled', 'enable'], fallback: true),
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
    );
  }

  BookSourceModel copyWith({bool? enabled}) => BookSourceModel(
    name: name,
    url: url,
    enabled: enabled ?? this.enabled,
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
  );
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
    urls.add(match.group(0)!);
  }
  return urls.toList(growable: false);
}

String? decodeSourceImportUrl(String input) {
  final uri = Uri.tryParse(input);
  if (uri == null) return null;
  final value =
      uri.queryParameters['src'] ??
      uri.queryParameters['url'] ??
      uri.queryParameters['source'];
  if (value == null || value.trim().isEmpty) return null;
  return Uri.decodeFull(value.trim());
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
    return utf8.decode(response.bodyBytes).trim();
  } finally {
    client.close();
  }
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
