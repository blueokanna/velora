import 'dart:convert';

import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/rust/api/http_source.dart' as http;
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

  Future<void> _persist() async {
    await _prefs.setString(
      _key,
      jsonEncode(state.map((e) => e.toJson()).toList()),
    );
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
    await _persist();
  }

  Future<void> remove(String url) async {
    state = state.where((e) => e.url != url).toList();
    await _persist();
  }

  Future<void> toggle(String url, bool enabled) async {
    state = state
        .map((e) => e.url == url ? e.copyWith(enabled: enabled) : e)
        .toList();
    await _persist();
  }

  Future<void> importJson(String json) async {
    await importPayload(json);
  }

  Future<void> importTextOrUrl(String input) async {
    await importPayload(await _readImportPayload(input));
  }

  Future<void> importPayload(String payload) async {
    final decoded = jsonDecode(_extractJsonCandidate(payload));
    if (decoded is List) {
      await _importList(decoded);
    } else if (decoded is Map<String, dynamic>) {
      final nested =
          decoded['data'] ?? decoded['sources'] ?? decoded['bookSources'];
      if (nested is List) {
        await _importList(nested);
      } else {
        await addOrUpdate(BookSourceModel.fromJson(_castMap(decoded)));
      }
    }
  }

  Future<void> _importList(List<dynamic> decoded) async {
    for (final item in decoded) {
      if (item is Map) {
        await addOrUpdate(BookSourceModel.fromJson(_castMap(item)));
      }
    }
  }
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

Future<String> _readImportPayload(String input) async {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return trimmed;
  final onlineImport = _decodeOnlineImportUrl(trimmed);
  if (onlineImport != null) return _readImportPayload(onlineImport);
  final uri = Uri.tryParse(trimmed);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    final response = await http.httpGet(url: trimmed, headers: const []);
    return response.body;
  }
  final firstUrl = RegExp(r"""https?://[^\s"'<>]+""").firstMatch(trimmed);
  if (firstUrl != null &&
      !trimmed.startsWith('{') &&
      !trimmed.startsWith('[')) {
    return _readImportPayload(firstUrl.group(0)!);
  }
  return trimmed;
}

String? _decodeOnlineImportUrl(String input) {
  final uri = Uri.tryParse(input);
  if (uri == null) return null;
  final value =
      uri.queryParameters['src'] ??
      uri.queryParameters['url'] ??
      uri.queryParameters['source'];
  if (value == null || value.trim().isEmpty) return null;
  return Uri.decodeFull(value.trim());
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
