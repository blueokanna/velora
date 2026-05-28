import 'dart:convert';

import '../src/rust/api/http_source.dart' as http;

class BookMetadata {
  final String title;
  final String author;
  final String description;
  final String coverUrl;
  final String detailUrl;
  final String sourceName;

  const BookMetadata({
    required this.title,
    required this.author,
    required this.description,
    required this.coverUrl,
    required this.detailUrl,
    required this.sourceName,
  });

  bool get hasDisplayMetadata =>
      title.isNotEmpty || author.isNotEmpty || coverUrl.isNotEmpty;
}

class BookMetadataLookup {
  const BookMetadataLookup();

  Future<BookMetadata?> lookupByUrl(
    String url, {
    String sourceName = '',
  }) async {
    final response = await _safeGet(url);
    if (response == null) return null;
    final metadata = _metadataFromHtml(
      response.body,
      response.url,
      sourceName: sourceName,
    );
    return metadata.hasDisplayMetadata ? metadata : null;
  }

  Future<BookMetadata?> lookupByTitle(
    String title, {
    String author = '',
  }) async {
    final query = _cleanTitle(title);
    if (query.isEmpty) return null;
    for (final provider in _providers) {
      final searchUrl = provider.searchUrl(query);
      final search = await _safeGet(searchUrl);
      if (search == null) continue;

      final direct = _metadataFromHtml(
        search.body,
        search.url,
        sourceName: provider.name,
      );
      if (_matches(direct, query, author) && direct.coverUrl.isNotEmpty) {
        return direct;
      }

      final detailUrl = _findCandidateUrl(search.body, search.url, query);
      if (detailUrl == null) continue;
      final detail = await lookupByUrl(detailUrl, sourceName: provider.name);
      if (detail != null && _matches(detail, query, author)) return detail;
    }
    return null;
  }

  Future<http.HttpResponse?> _safeGet(String url) async {
    try {
      final response = await http.httpGet(
        url: url,
        headers: const [
          ('Accept', 'text/html,application/xhtml+xml,application/json'),
          ('Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8'),
        ],
      );
      if (response.status < 200 || response.status >= 400) return null;
      return response;
    } catch (_) {
      return null;
    }
  }
}

class _MetadataProvider {
  final String name;
  final String Function(String query) searchUrl;

  const _MetadataProvider(this.name, this.searchUrl);
}

final _providers = <_MetadataProvider>[
  _MetadataProvider(
    'Qidian',
    (query) => 'https://www.qidian.com/so/${Uri.encodeComponent(query)}.html',
  ),
  _MetadataProvider(
    'Fanqie Novel',
    (query) =>
        'https://fanqienovel.com/search?keyword=${Uri.encodeQueryComponent(query)}',
  ),
  _MetadataProvider(
    'Qimao',
    (query) =>
        'https://www.qimao.com/search/index/?keyword=${Uri.encodeQueryComponent(query)}',
  ),
  _MetadataProvider(
    'Tadu',
    (query) =>
        'https://www.tadu.com/search?keyword=${Uri.encodeQueryComponent(query)}',
  ),
  _MetadataProvider(
    '17K',
    (query) =>
        'https://search.17k.com/search.xhtml?c.st=0&c.q=${Uri.encodeQueryComponent(query)}',
  ),
  _MetadataProvider(
    'Faloo',
    (query) =>
        'https://b.faloo.com/search.html?k=${Uri.encodeQueryComponent(query)}',
  ),
  _MetadataProvider(
    'GoodNovel',
    (query) => 'https://www.goodnovel.com/search/${Uri.encodeComponent(query)}',
  ),
  _MetadataProvider(
    'Wuxiaworld',
    (query) =>
        'https://www.wuxiaworld.com/search?keywords=${Uri.encodeQueryComponent(query)}',
  ),
  _MetadataProvider(
    'Royal Road',
    (query) =>
        'https://www.royalroad.com/fictions/search?title=${Uri.encodeQueryComponent(query)}',
  ),
];

BookMetadata _metadataFromHtml(
  String html,
  String pageUrl, {
  required String sourceName,
}) {
  final fromJsonLd = _metadataFromJsonLd(html, pageUrl, sourceName);
  if (fromJsonLd != null && fromJsonLd.hasDisplayMetadata) return fromJsonLd;

  final title =
      _firstMeta(html, const [
        'og:title',
        'twitter:title',
        'book:title',
        'title',
      ]) ??
      _titleTag(html);
  final author =
      _firstMeta(html, const ['author', 'book:author', 'article:author']) ?? '';
  final description =
      _firstMeta(html, const [
        'description',
        'og:description',
        'twitter:description',
      ]) ??
      '';
  final cover =
      _firstMeta(html, const [
        'og:image',
        'og:image:url',
        'twitter:image',
        'image',
      ]) ??
      _firstImage(html);

  return BookMetadata(
    title: _cleanTitle(title),
    author: _cleanAuthor(author),
    description: _cleanText(description),
    coverUrl: _absoluteUrl(pageUrl, cover),
    detailUrl: pageUrl,
    sourceName: sourceName,
  );
}

BookMetadata? _metadataFromJsonLd(
  String html,
  String pageUrl,
  String sourceName,
) {
  final scripts = RegExp(
    r'''<script\b[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>''',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html);
  for (final script in scripts) {
    final raw = _htmlUnescape(script.group(1) ?? '').trim();
    if (raw.isEmpty) continue;
    try {
      final decoded = jsonDecode(raw);
      final found = _findBookJson(decoded);
      if (found == null) continue;
      final title =
          _jsonString(found['name']) ?? _jsonString(found['headline']) ?? '';
      final author = _jsonAuthor(found['author']);
      final description = _jsonString(found['description']) ?? '';
      final cover = _jsonImage(found['image']);
      return BookMetadata(
        title: _cleanTitle(title),
        author: _cleanAuthor(author),
        description: _cleanText(description),
        coverUrl: _absoluteUrl(pageUrl, cover),
        detailUrl: pageUrl,
        sourceName: sourceName,
      );
    } catch (_) {}
  }
  return null;
}

Map<String, dynamic>? _findBookJson(Object? value) {
  if (value is List) {
    for (final item in value) {
      final found = _findBookJson(item);
      if (found != null) return found;
    }
  }
  if (value is Map) {
    final map = value.map((key, value) => MapEntry(key.toString(), value));
    final type = map['@type'];
    final typeText = type is List ? type.join(' ') : type?.toString() ?? '';
    final lower = typeText.toLowerCase();
    if (lower.contains('book') || lower.contains('novel')) return map;
    for (final key in const [
      '@graph',
      'mainEntity',
      'about',
      'itemListElement',
    ]) {
      final found = _findBookJson(map[key]);
      if (found != null) return found;
    }
  }
  return null;
}

String? _firstMeta(String html, List<String> names) {
  final wanted = names.map((name) => name.toLowerCase()).toSet();
  final tags = RegExp(
    r'''<meta\b([^>]*?)>''',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html);
  for (final tag in tags) {
    final attrs = _attributes(tag.group(1) ?? '');
    final key = (attrs['property'] ?? attrs['name'] ?? attrs['itemprop'] ?? '')
        .toLowerCase();
    if (!wanted.contains(key)) continue;
    final content = attrs['content']?.trim();
    if (content != null && content.isNotEmpty) return _htmlUnescape(content);
  }
  return null;
}

String _titleTag(String html) {
  final match = RegExp(
    r'''<title\b[^>]*>(.*?)</title>''',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html);
  return _htmlUnescape(_stripTags(match?.group(1) ?? ''));
}

String _firstImage(String html) {
  final tags = RegExp(
    r'''<img\b([^>]*?)>''',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html);
  for (final tag in tags.take(30)) {
    final attrs = _attributes(tag.group(1) ?? '');
    final src = attrs['src'] ?? attrs['data-src'] ?? attrs['data-original'];
    if (src == null || src.trim().isEmpty) continue;
    final lower = src.toLowerCase();
    final alt = (attrs['alt'] ?? '').toLowerCase();
    if (lower.contains('cover') ||
        alt.contains('封面') ||
        alt.contains('cover')) {
      return src.trim();
    }
  }
  return '';
}

String? _findCandidateUrl(String html, String pageUrl, String title) {
  final normalizedTitle = _normalizeForMatch(title);
  var bestScore = 0;
  String? bestUrl;
  final links = RegExp(
    r'''<a\b([^>]*href\s*=\s*(?:"[^"]+"|'[^']+'|[^\s>]+)[^>]*)>(.*?)</a>''',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html);
  for (final link in links.take(240)) {
    final attrs = _attributes(link.group(1) ?? '');
    final href = attrs['href'];
    if (href == null ||
        href.startsWith('#') ||
        href.startsWith('javascript:')) {
      continue;
    }
    final url = _absoluteUrl(pageUrl, href);
    final label = _normalizeForMatch(_stripTags(link.group(2) ?? ''));
    final lowerUrl = url.toLowerCase();
    var score = 0;
    if (label.contains(normalizedTitle) || normalizedTitle.contains(label)) {
      score += 5;
    }
    if (RegExp(
      r'''/(book|info|novel|fiction|story|shuku|reader|detail)[/-]''',
    ).hasMatch(lowerUrl)) {
      score += 2;
    }
    if (lowerUrl.contains(Uri.encodeComponent(title).toLowerCase())) {
      score += 1;
    }
    if (score > bestScore) {
      bestScore = score;
      bestUrl = url;
    }
  }
  return bestScore >= 4 ? bestUrl : null;
}

Map<String, String> _attributes(String raw) {
  final result = <String, String>{};
  final matches = RegExp(
    r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''',
  ).allMatches(raw);
  for (final match in matches) {
    result[match.group(1)!.toLowerCase()] = _htmlUnescape(
      match.group(2) ?? match.group(3) ?? match.group(4) ?? '',
    );
  }
  return result;
}

bool _matches(BookMetadata metadata, String title, String author) {
  final expectedTitle = _normalizeForMatch(title);
  final actualTitle = _normalizeForMatch(metadata.title);
  final titleMatches =
      actualTitle.isEmpty ||
      actualTitle.contains(expectedTitle) ||
      expectedTitle.contains(actualTitle);
  if (!titleMatches) return false;
  final expectedAuthor = _normalizeForMatch(author);
  if (expectedAuthor.isEmpty || metadata.author.isEmpty) return true;
  return _normalizeForMatch(metadata.author).contains(expectedAuthor) ||
      expectedAuthor.contains(_normalizeForMatch(metadata.author));
}

String _jsonAuthor(Object? value) {
  if (value is String) return value;
  if (value is Map) return _jsonString(value['name']) ?? '';
  if (value is List) {
    return value.map(_jsonAuthor).where((item) => item.isNotEmpty).join(', ');
  }
  return '';
}

String _jsonImage(Object? value) {
  if (value is String) return value;
  if (value is Map) {
    return _jsonString(value['url']) ??
        _jsonString(value['contentUrl']) ??
        _jsonString(value['@id']) ??
        '';
  }
  if (value is List) {
    for (final item in value) {
      final image = _jsonImage(item);
      if (image.isNotEmpty) return image;
    }
  }
  return '';
}

String? _jsonString(Object? value) => value is String ? value.trim() : null;

String _absoluteUrl(String base, String? value) {
  final raw = (value ?? '').trim();
  if (raw.isEmpty || raw.startsWith('data:')) return raw;
  final uri = Uri.tryParse(raw);
  if (uri != null && uri.hasScheme) return raw;
  final baseUri = Uri.tryParse(base);
  if (baseUri == null) return raw;
  if (raw.startsWith('//')) return '${baseUri.scheme}:$raw';
  return baseUri.resolve(raw).toString();
}

String _cleanTitle(String value) {
  var text = _cleanText(value);
  for (final separator in const [' - ', '_', ' | ', '，', ',', '：', ':']) {
    final index = text.indexOf(separator);
    if (index > 1) {
      final head = text.substring(0, index).trim();
      if (head.runes.length >= 2) return head;
    }
  }
  return text;
}

String _cleanAuthor(String value) => _cleanText(value)
    .replaceFirst(RegExp(r'''^(作者|Author)[:：\s]*''', caseSensitive: false), '')
    .trim();

String _cleanText(String value) =>
    _htmlUnescape(_stripTags(value)).replaceAll(RegExp(r'''\s+'''), ' ').trim();

String _stripTags(String value) =>
    value.replaceAll(RegExp(r'''<[^>]+>'''), ' ');

String _normalizeForMatch(String value) => _cleanText(
  value,
).toLowerCase().replaceAll(RegExp(r'''[\s\p{P}\p{S}_]+''', unicode: true), '');

String _htmlUnescape(String value) => value
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ');
