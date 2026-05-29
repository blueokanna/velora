import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import '../src/rust/api/book_source.dart' as bs;
import '../state/sources.dart';

const _rssSyntheticUrlPrefix = 'velora-rss://entry/';

class RssSourceService {
  const RssSourceService();

  static const _cacheKey = 'rss_source_entry_cache_v1';
  static const _maxCacheEntries = 64;

  static bool isSyntheticBookUrl(String value) {
    return value.startsWith(_rssSyntheticUrlPrefix);
  }

  Future<List<bs.SearchResult>> loadItems(
    SharedPreferences prefs, {
    required BookSourceModel source,
    int maxItems = 12,
    String? keyword,
  }) async {
    if (!source.isRssSource) return const [];
    final entries = await _fetchEntries(source);
    final normalizedKeyword = keyword?.trim().toLowerCase() ?? '';
    final filtered = normalizedKeyword.isEmpty
        ? entries
        : entries
              .where((entry) => entry.matches(normalizedKeyword))
              .toList(growable: false);
    await _saveEntries(prefs, filtered);
    return filtered
        .take(maxItems)
        .map((entry) => entry.toSearchResult())
        .toList(growable: false);
  }

  Future<RssCachedEntry?> loadCachedEntry(
    SharedPreferences prefs,
    String syntheticUrl,
  ) async {
    final cache = _readEntries(prefs);
    final index = cache.indexWhere(
      (entry) => entry.syntheticUrl == syntheticUrl,
    );
    if (index < 0) return null;
    final entry = cache[index];
    if (index > 0) {
      final reordered = [...cache]
        ..removeAt(index)
        ..insert(0, entry);
      await _persistEntries(prefs, reordered);
    }
    return entry;
  }

  Future<RssCachedEntry?> ensureEntry(
    SharedPreferences prefs, {
    required BookSourceModel source,
    required String syntheticUrl,
    String? fallbackUrl,
    String? fallbackTitle,
  }) async {
    final cached = await loadCachedEntry(prefs, syntheticUrl);
    if (cached != null) return cached;
    final fetched = await loadItems(prefs, source: source, maxItems: 48);
    for (final item in fetched) {
      if (item.bookUrl == syntheticUrl) {
        return loadCachedEntry(prefs, syntheticUrl);
      }
    }
    final fallbackLink = fallbackUrl?.trim() ?? '';
    final fallbackName = fallbackTitle?.trim() ?? '';
    if (fallbackLink.isEmpty && fallbackName.isEmpty) return null;
    final entry = RssCachedEntry(
      syntheticUrl: syntheticUrl,
      sourceName: source.name,
      sourceUrl: source.url,
      title: fallbackName.isEmpty ? source.name : fallbackName,
      author: '',
      link: fallbackLink,
      coverUrl: '',
      description: '',
      content: '',
      publishedAt: '',
    );
    await _upsertEntry(prefs, entry);
    return entry;
  }

  Future<String> loadReadableContent(
    SharedPreferences prefs, {
    required BookSourceModel source,
    required String syntheticUrl,
    String? fallbackUrl,
    String? fallbackTitle,
  }) async {
    final entry = await ensureEntry(
      prefs,
      source: source,
      syntheticUrl: syntheticUrl,
      fallbackUrl: fallbackUrl,
      fallbackTitle: fallbackTitle,
    );
    if (entry == null) {
      throw StateError('RSS 条目不存在或已过期');
    }
    if (entry.content.trim().isNotEmpty) {
      return entry.content.trim();
    }
    if (source.contentSelector.trim().isNotEmpty &&
        entry.link.trim().isNotEmpty) {
      final content = await bs.sourceChapterContent(
        sourceJson: source.toJsonString(),
        chapterUrl: entry.link,
      );
      final normalized = content.trim();
      if (normalized.isNotEmpty) {
        await _upsertEntry(prefs, entry.copyWith(content: normalized));
        return normalized;
      }
    }
    if (entry.description.trim().isNotEmpty) {
      return entry.description.trim();
    }
    if (entry.link.trim().isNotEmpty) {
      return entry.link.trim();
    }
    throw StateError('RSS 条目缺少可读内容');
  }

  Future<List<RssCachedEntry>> _fetchEntries(BookSourceModel source) async {
    final response = await http
        .get(
          Uri.parse(source.url),
          headers: const {
            'Accept':
                'application/rss+xml,application/atom+xml,application/xml,text/xml,application/json,text/plain,*/*',
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36 Velora/1.0',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw StateError('RSS 请求失败: HTTP ${response.statusCode}');
    }
    final body = decodeImportResponseBody(
      response.bodyBytes,
      contentType: response.headers['content-type'],
    ).trim();
    if (body.isEmpty) return const [];
    if (body.startsWith('{') || body.startsWith('[')) {
      return _parseJsonEntries(source, body);
    }
    return _parseXmlEntries(source, body);
  }

  List<RssCachedEntry> _parseJsonEntries(BookSourceModel source, String body) {
    final decoded = jsonDecode(body);
    final nodes = _selectJsonNodes(decoded, source.rssArticles);
    final entries = <RssCachedEntry>[];
    for (final node in nodes) {
      final title = _jsonScalar(
        node,
        source.rssTitle,
        fallbackKeys: const ['title', 'name'],
      );
      final link = _absoluteUrl(
        source.url,
        _jsonScalar(node, source.rssLink, fallbackKeys: const ['link', 'url']),
      );
      final description = _cleanFeedText(
        _jsonScalar(
          node,
          source.rssDescription,
          fallbackKeys: const ['description', 'summary', 'desc'],
        ),
      );
      final content = _cleanFeedText(
        _jsonScalar(
          node,
          source.rssContent,
          fallbackKeys: const ['content', 'body'],
        ),
      );
      final cover = _absoluteUrl(
        source.url,
        _jsonScalar(
          node,
          source.rssImage,
          fallbackKeys: const ['image', 'pic', 'cover'],
        ),
      );
      final author = _jsonScalar(
        node,
        '',
        fallbackKeys: const ['author', 'creator'],
      );
      final publishedAt = _jsonScalar(
        node,
        source.rssPubDate,
        fallbackKeys: const ['pubDate', 'date', 'time'],
      );
      if (title.trim().isEmpty && link.trim().isEmpty) {
        continue;
      }
      entries.add(
        RssCachedEntry(
          syntheticUrl: _syntheticUrl(source.url, link, title),
          sourceName: source.name,
          sourceUrl: source.url,
          title: title.trim().isEmpty ? source.name : title.trim(),
          author: author.trim(),
          link: link,
          coverUrl: cover,
          description: description,
          content: content,
          publishedAt: publishedAt.trim(),
        ),
      );
    }
    return entries;
  }

  List<RssCachedEntry> _parseXmlEntries(BookSourceModel source, String body) {
    final document = XmlDocument.parse(body);
    final items = document.descendants
        .whereType<XmlElement>()
        .where((element) {
          final name = _localName(element.name.qualified).toLowerCase();
          return name == 'item' || name == 'entry';
        })
        .toList(growable: false);
    final entries = <RssCachedEntry>[];
    for (final item in items) {
      final title = _firstElementText(item, const ['title']);
      final link = _resolveFeedLink(source.url, item);
      final description = _cleanFeedText(
        _firstElementText(item, const ['description', 'summary']),
      );
      final content = _cleanFeedText(
        _firstElementText(item, const ['encoded', 'content']),
      );
      final author = _resolveFeedAuthor(item);
      final publishedAt = _firstElementText(item, const [
        'pubDate',
        'updated',
        'published',
      ]);
      final cover = _resolveFeedImage(source.url, item);
      if (title.trim().isEmpty && link.trim().isEmpty) {
        continue;
      }
      entries.add(
        RssCachedEntry(
          syntheticUrl: _syntheticUrl(source.url, link, title),
          sourceName: source.name,
          sourceUrl: source.url,
          title: title.trim().isEmpty ? source.name : title.trim(),
          author: author.trim(),
          link: link,
          coverUrl: cover,
          description: description,
          content: content,
          publishedAt: publishedAt.trim(),
        ),
      );
    }
    return entries;
  }

  Future<void> _saveEntries(
    SharedPreferences prefs,
    List<RssCachedEntry> entries,
  ) async {
    var cache = _readEntries(prefs);
    for (final entry in entries.reversed) {
      cache = cache
          .where((item) => item.syntheticUrl != entry.syntheticUrl)
          .toList(growable: true);
      cache.insert(0, entry);
    }
    if (cache.length > _maxCacheEntries) {
      cache = cache.sublist(0, _maxCacheEntries);
    }
    await _persistEntries(prefs, cache);
  }

  Future<void> _upsertEntry(
    SharedPreferences prefs,
    RssCachedEntry entry,
  ) async {
    await _saveEntries(prefs, [entry]);
  }

  List<RssCachedEntry> _readEntries(SharedPreferences prefs) {
    final raw = prefs.getString(_cacheKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => RssCachedEntry.fromJson(item.cast<String, dynamic>()))
          .where((item) => item.syntheticUrl.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistEntries(
    SharedPreferences prefs,
    List<RssCachedEntry> entries,
  ) async {
    await prefs.setString(
      _cacheKey,
      jsonEncode(
        entries.map((entry) => entry.toJson()).toList(growable: false),
      ),
    );
  }
}

class RssCachedEntry {
  final String syntheticUrl;
  final String sourceName;
  final String sourceUrl;
  final String title;
  final String author;
  final String link;
  final String coverUrl;
  final String description;
  final String content;
  final String publishedAt;

  const RssCachedEntry({
    required this.syntheticUrl,
    required this.sourceName,
    required this.sourceUrl,
    required this.title,
    required this.author,
    required this.link,
    required this.coverUrl,
    required this.description,
    required this.content,
    required this.publishedAt,
  });

  bool matches(String keyword) {
    return title.toLowerCase().contains(keyword) ||
        author.toLowerCase().contains(keyword) ||
        description.toLowerCase().contains(keyword) ||
        content.toLowerCase().contains(keyword);
  }

  bs.SearchResult toSearchResult() {
    return bs.SearchResult(
      name: title,
      author: author.isEmpty
          ? (publishedAt.isEmpty ? sourceName : publishedAt)
          : author,
      bookUrl: syntheticUrl,
      coverUrl: coverUrl,
      sourceName: sourceName,
    );
  }

  RssCachedEntry copyWith({String? content}) {
    return RssCachedEntry(
      syntheticUrl: syntheticUrl,
      sourceName: sourceName,
      sourceUrl: sourceUrl,
      title: title,
      author: author,
      link: link,
      coverUrl: coverUrl,
      description: description,
      content: content ?? this.content,
      publishedAt: publishedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'syntheticUrl': syntheticUrl,
    'sourceName': sourceName,
    'sourceUrl': sourceUrl,
    'title': title,
    'author': author,
    'link': link,
    'coverUrl': coverUrl,
    'description': description,
    'content': content,
    'publishedAt': publishedAt,
  };

  factory RssCachedEntry.fromJson(Map<String, dynamic> raw) {
    return RssCachedEntry(
      syntheticUrl: raw['syntheticUrl']?.toString() ?? '',
      sourceName: raw['sourceName']?.toString() ?? '',
      sourceUrl: raw['sourceUrl']?.toString() ?? '',
      title: raw['title']?.toString() ?? '',
      author: raw['author']?.toString() ?? '',
      link: raw['link']?.toString() ?? '',
      coverUrl: raw['coverUrl']?.toString() ?? '',
      description: raw['description']?.toString() ?? '',
      content: raw['content']?.toString() ?? '',
      publishedAt: raw['publishedAt']?.toString() ?? '',
    );
  }
}

List<dynamic> _selectJsonNodes(dynamic root, String rule) {
  if (rule.trim().isEmpty) {
    if (root is List) return root;
    if (root is Map) {
      for (final key in const ['list', 'items', 'data', 'articles']) {
        final value = root[key];
        if (value is List) return value;
      }
    }
    return root == null ? const [] : [root];
  }
  dynamic current = root;
  final normalized = _normalizeJsonRule(rule);
  for (final segment in normalized) {
    if (current is Map) {
      current = current[segment];
      continue;
    }
    return const [];
  }
  if (current is List) return current;
  return current == null ? const [] : [current];
}

String _jsonScalar(
  dynamic node,
  String rule, {
  List<String> fallbackKeys = const [],
}) {
  final trimmed = rule.trim();
  if (trimmed == '<js>result</js>' || trimmed == 'result') {
    return _jsonStringValue(node);
  }
  if (trimmed.isEmpty) {
    return _jsonFallback(node, fallbackKeys);
  }
  dynamic current = node;
  for (final segment in _normalizeJsonRule(trimmed)) {
    if (current is Map) {
      current = current[segment];
      continue;
    }
    return _jsonFallback(node, fallbackKeys);
  }
  final resolved = _jsonStringValue(current);
  return resolved.isEmpty ? _jsonFallback(node, fallbackKeys) : resolved;
}

List<String> _normalizeJsonRule(String rule) {
  var normalized = rule.trim();
  if (normalized.startsWith(r'$.')) {
    normalized = normalized.substring(2);
  } else if (normalized.startsWith(r'$')) {
    normalized = normalized.substring(1);
  }
  if (normalized.startsWith('.')) {
    normalized = normalized.substring(1);
  }
  normalized = normalized.replaceAll('[*]', '');
  return normalized
      .split('.')
      .where((segment) => segment.trim().isNotEmpty)
      .toList(growable: false);
}

String _jsonFallback(dynamic node, List<String> fallbackKeys) {
  if (node is Map) {
    for (final key in fallbackKeys) {
      final value = node[key];
      final resolved = _jsonStringValue(value);
      if (resolved.isNotEmpty) return resolved;
    }
  }
  return _jsonStringValue(node);
}

String _jsonStringValue(dynamic value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  if (value is num || value is bool) return value.toString();
  if (value is List) {
    return value
        .map(_jsonStringValue)
        .where((item) => item.isNotEmpty)
        .join('\n')
        .trim();
  }
  if (value is Map) {
    return jsonEncode(value);
  }
  return value.toString().trim();
}

String _localName(String name) {
  final index = name.indexOf(':');
  return index >= 0 ? name.substring(index + 1) : name;
}

String _firstElementText(XmlElement parent, List<String> localNames) {
  final names = localNames.map((item) => item.toLowerCase()).toSet();
  for (final child in parent.children.whereType<XmlElement>()) {
    final local = _localName(child.name.qualified).toLowerCase();
    if (!names.contains(local)) continue;
    final text = child.innerText.trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

String _resolveFeedAuthor(XmlElement item) {
  final author = _firstElementText(item, const ['author', 'creator']);
  if (author.isNotEmpty) return author;
  for (final child in item.children.whereType<XmlElement>()) {
    if (_localName(child.name.qualified).toLowerCase() != 'author') continue;
    final nested = _firstElementText(child, const ['name']);
    if (nested.isNotEmpty) return nested;
  }
  return '';
}

String _resolveFeedLink(String baseUrl, XmlElement item) {
  for (final child in item.children.whereType<XmlElement>()) {
    if (_localName(child.name.qualified).toLowerCase() != 'link') continue;
    final href = child.getAttribute('href')?.trim() ?? '';
    if (href.isNotEmpty) return _absoluteUrl(baseUrl, href);
    final text = child.innerText.trim();
    if (text.isNotEmpty) return _absoluteUrl(baseUrl, text);
  }
  return '';
}

String _resolveFeedImage(String baseUrl, XmlElement item) {
  for (final child in item.children.whereType<XmlElement>()) {
    final local = _localName(child.name.qualified).toLowerCase();
    if (local == 'enclosure') {
      final type = child.getAttribute('type')?.toLowerCase() ?? '';
      if (type.startsWith('image/')) {
        final url = child.getAttribute('url')?.trim() ?? '';
        if (url.isNotEmpty) return _absoluteUrl(baseUrl, url);
      }
    }
    if (local == 'thumbnail' || local == 'content' || local == 'image') {
      final url =
          child.getAttribute('url')?.trim() ??
          child.getAttribute('href')?.trim() ??
          child.innerText.trim();
      if (url.isNotEmpty) return _absoluteUrl(baseUrl, url);
    }
  }
  return '';
}

String _syntheticUrl(String sourceUrl, String link, String title) {
  final raw = link.trim().isEmpty ? '$sourceUrl|$title' : '$sourceUrl|$link';
  return '$_rssSyntheticUrlPrefix${base64Url.encode(utf8.encode(raw))}';
}

String _absoluteUrl(String baseUrl, String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final base = Uri.tryParse(baseUrl);
  if (base == null) return trimmed;
  return base.resolve(trimmed).toString();
}

String _cleanFeedText(String raw) {
  if (raw.trim().isEmpty) return '';
  var text = raw
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  for (final entry in const {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
  }.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
