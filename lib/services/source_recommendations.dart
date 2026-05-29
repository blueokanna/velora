import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'rss_source.dart';
import '../src/rust/api/book_source.dart' as bs;
import '../state/sources.dart';

class SourceRecommendationsService {
  const SourceRecommendationsService();

  static const _rss = RssSourceService();

  static const cacheTtl = Duration(hours: 6);
  static const _sourceTimeout = Duration(seconds: 8);
  static const maxSourceCacheEntries = 24;
  static const maxCacheEntries = 6;
  static const _sourceCacheKey = 'discover_recommendations_source_cache_v3';
  static const _cacheKey = 'discover_recommendations_cache_v2';

  Future<List<bs.SearchResult>> load(
    Iterable<BookSourceModel> sources, {
    int maxPerSource = 6,
    int maxTotal = 36,
    int maxSources = 10,
    int concurrency = 6,
  }) async {
    final sampled = _sampleSources(
      sources.where((item) => item.enabled),
      maxSources: maxSources,
    );
    final batches = await _loadDetailed(
      sampled,
      maxPerSource: maxPerSource,
      concurrency: concurrency,
      prefs: null,
    );
    return _mergeBatches(batches, maxTotal: maxTotal);
  }

  Future<List<bs.SearchResult>> loadAndCache(
    SharedPreferences prefs,
    Iterable<BookSourceModel> sources, {
    int maxPerSource = 6,
    int maxTotal = 36,
    int maxSources = 10,
    int concurrency = 6,
  }) async {
    final sampled = _sampleSources(
      sources.where((item) => item.enabled),
      maxSources: maxSources,
    );
    final batches = await _loadDetailed(
      sampled,
      maxPerSource: maxPerSource,
      concurrency: concurrency,
      prefs: prefs,
    );
    await _saveSourceCachedMany(prefs, batches);
    return _mergeBatches(batches, maxTotal: maxTotal);
  }

  Future<RecommendationCacheSnapshot?> loadCachedSubset(
    SharedPreferences prefs, {
    required Iterable<BookSourceModel> sources,
    required String collectionSignature,
    int maxPerSource = 6,
    int maxTotal = 36,
    int maxSources = 10,
  }) async {
    final sampled = _sampleSources(
      sources.where((item) => item.enabled),
      maxSources: maxSources,
    );
    if (sampled.isEmpty) return null;
    final sourceCache = _readSourceCache(prefs);
    final cacheIndexByKey = <String, int>{
      for (var index = 0; index < sourceCache.length; index++)
        sourceCache[index].sourceKey: index,
    };
    final touched = <_SourceRecommendationCacheEntry>[];
    final batches = <_SourceRecommendationBatch>[];
    var hasExpired = false;
    var hasMissing = false;
    for (final source in sampled) {
      final sourceKey = _sourceCacheKeyFor(source);
      final index = cacheIndexByKey[sourceKey];
      if (index == null) {
        hasMissing = true;
        continue;
      }
      final entry = sourceCache[index];
      touched.add(entry);
      if (_isExpiredSeconds(entry.cachedAtSeconds)) {
        hasExpired = true;
      }
      batches.add(
        _SourceRecommendationBatch(
          source: source,
          results: entry.items
              .map((item) => _searchResultFromMap(item))
              .take(maxPerSource)
              .toList(growable: false),
        ),
      );
    }
    if (touched.isNotEmpty) {
      final touchedKeys = touched.map((entry) => entry.sourceKey).toSet();
      final reordered = [
        ...touched,
        ...sourceCache.where((entry) => !touchedKeys.contains(entry.sourceKey)),
      ];
      await _persistSourceCache(prefs, reordered);
    }
    final results = _mergeBatches(batches, maxTotal: maxTotal);
    if (results.isEmpty) {
      final aggregate = await loadCached(prefs, signature: collectionSignature);
      if (aggregate != null) return aggregate;
      return null;
    }
    final oldestSeconds = touched.isEmpty
        ? DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000
        : touched
              .map((entry) => entry.cachedAtSeconds)
              .reduce((left, right) => left < right ? left : right);
    return RecommendationCacheSnapshot(
      cachedAt: DateTime.fromMillisecondsSinceEpoch(
        oldestSeconds * 1000,
        isUtc: true,
      ).toLocal(),
      results: results,
      isExpired: hasExpired || hasMissing,
    );
  }

  Future<void> saveSourceCached(
    SharedPreferences prefs, {
    required BookSourceModel source,
    required List<bs.SearchResult> results,
  }) async {
    await _saveSourceCachedMany(prefs, [
      _SourceRecommendationBatch(
        source: source,
        results: results.toList(growable: false),
      ),
    ]);
  }

  Future<List<_SourceRecommendationBatch>> _loadDetailed(
    List<BookSourceModel> sampled, {
    required int maxPerSource,
    required int concurrency,
    required SharedPreferences? prefs,
  }) async {
    final batches = <_SourceRecommendationBatch>[];
    for (var start = 0; start < sampled.length; start += concurrency) {
      final end = math.min(start + concurrency, sampled.length);
      final batch = sampled.sublist(start, end);
      final recommended = await Future.wait(
        batch.map((source) async {
          return _SourceRecommendationBatch(
            source: source,
            results: await _loadSingleSource(
              source,
              maxPerSource: maxPerSource,
              prefs: prefs,
            ),
          );
        }),
      );
      batches.addAll(recommended);
      if (end < sampled.length) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return batches;
  }

  List<bs.SearchResult> _mergeBatches(
    List<_SourceRecommendationBatch> batches, {
    required int maxTotal,
  }) {
    final results = <bs.SearchResult>[];
    final seen = <String>{};
    for (final batch in batches) {
      for (final item in batch.results) {
        final key = item.bookUrl.trim().isEmpty
            ? '${item.sourceName}|${item.name}|${item.author}'
            : item.bookUrl;
        if (!seen.add(key)) continue;
        results.add(item);
        if (results.length >= maxTotal) {
          return results;
        }
      }
    }
    return results;
  }

  Future<RecommendationCacheSnapshot?> loadCached(
    SharedPreferences prefs, {
    required String signature,
  }) async {
    final cache = _readCache(prefs);
    final index = cache.indexWhere((entry) => entry.signature == signature);
    if (index < 0) return null;
    final entry = cache[index];
    if (index > 0) {
      final reordered = [...cache]
        ..removeAt(index)
        ..insert(0, entry);
      await _persistCache(prefs, reordered);
    }
    return _snapshotFromEntry(entry);
  }

  Future<void> saveCached(
    SharedPreferences prefs, {
    required String signature,
    required List<bs.SearchResult> results,
  }) async {
    final cache = _readCache(
      prefs,
    ).where((entry) => entry.signature != signature).toList(growable: true);
    cache.insert(
      0,
      _RecommendationCacheEntry(
        signature: signature,
        cachedAtSeconds: DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
        items: results.map(_searchResultToMap).toList(growable: false),
      ),
    );
    if (cache.length > maxCacheEntries) {
      cache.removeRange(maxCacheEntries, cache.length);
    }
    await _persistCache(prefs, cache);
  }

  Future<List<bs.SearchResult>> _loadSingleSource(
    BookSourceModel source, {
    required int maxPerSource,
    required SharedPreferences? prefs,
  }) async {
    if (source.isRssSource && prefs != null) {
      return _rss.loadItems(prefs, source: source, maxItems: maxPerSource);
    }
    final exploreResults = await _loadExploreRecommendations(
      source,
      maxPerSource: maxPerSource,
    );
    if (exploreResults.isNotEmpty) {
      return exploreResults;
    }
    if (source.searchUrl.trim().isEmpty || source.searchList.trim().isEmpty) {
      return const [];
    }
    for (final keyword in _keywordsForSource(source)) {
      try {
        final results =
            (await bs
                    .sourceSearch(
                      sourceJson: source.toJsonString(),
                      keyword: keyword,
                    )
                    .timeout(_sourceTimeout))
                .where((item) => item.name.trim().isNotEmpty)
                .take(maxPerSource)
                .toList(growable: false);
        if (results.isNotEmpty) return results;
      } catch (_) {}
    }
    return const [];
  }

  Future<List<bs.SearchResult>> _loadExploreRecommendations(
    BookSourceModel source, {
    required int maxPerSource,
  }) async {
    if (!source.supportsExploreRecommendations) {
      return const [];
    }
    for (final entryUrl in source.exploreEntryUrls.take(3)) {
      final exploreSource = source.toExploreSearchSource(entryUrl);
      if (exploreSource == null) continue;
      try {
        final results =
            (await bs
                    .sourceSearch(
                      sourceJson: exploreSource.toJsonString(),
                      keyword: '',
                    )
                    .timeout(_sourceTimeout))
                .where((item) => item.name.trim().isNotEmpty)
                .take(maxPerSource)
                .toList(growable: false);
        if (results.isNotEmpty) {
          return results;
        }
      } catch (_) {}
    }
    return const [];
  }

  Future<void> _saveSourceCachedMany(
    SharedPreferences prefs,
    List<_SourceRecommendationBatch> batches,
  ) async {
    final cache = _readSourceCache(prefs)
        .where(
          (entry) => !batches.any(
            (batch) => _sourceCacheKeyFor(batch.source) == entry.sourceKey,
          ),
        )
        .toList(growable: true);
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    for (final batch in batches.reversed) {
      cache.insert(
        0,
        _SourceRecommendationCacheEntry(
          sourceKey: _sourceCacheKeyFor(batch.source),
          cachedAtSeconds: now,
          items: batch.results.map(_searchResultToMap).toList(growable: false),
        ),
      );
    }
    if (cache.length > maxSourceCacheEntries) {
      cache.removeRange(maxSourceCacheEntries, cache.length);
    }
    await _persistSourceCache(prefs, cache);
  }

  List<String> _keywordsForSource(BookSourceModel source) {
    final domain = Uri.tryParse(source.url)?.host.toLowerCase() ?? '';
    final english =
        domain.contains('wuxiaworld') ||
        domain.contains('royalroad') ||
        domain.contains('goodnovel');
    if (english) {
      return const ['fantasy', 'romance', 'adventure', 'popular', 'action'];
    }
    return const ['玄幻', '都市', '言情', '历史', '科幻', '热门', '推荐'];
  }

  List<BookSourceModel> _sampleSources(
    Iterable<BookSourceModel> sources, {
    required int maxSources,
  }) {
    final list = sources.toList(growable: false);
    if (list.length <= maxSources) return list;
    final step = list.length / maxSources;
    final selected = <BookSourceModel>[];
    final seen = <String>{};
    var cursor = 0.0;
    while (selected.length < maxSources && cursor < list.length) {
      final source = list[cursor.floor()];
      if (seen.add(source.url)) {
        selected.add(source);
      }
      cursor += step;
    }
    for (final source in list.reversed) {
      if (selected.length >= maxSources) break;
      if (seen.add(source.url)) {
        selected.add(source);
      }
    }
    return selected;
  }

  Map<String, String> _searchResultToMap(bs.SearchResult result) => {
    'name': result.name,
    'author': result.author,
    'bookUrl': result.bookUrl,
    'coverUrl': result.coverUrl,
    'sourceName': result.sourceName,
  };

  bs.SearchResult _searchResultFromMap(Map<String, dynamic> raw) {
    return bs.SearchResult(
      name: raw['name']?.toString() ?? '',
      author: raw['author']?.toString() ?? '',
      bookUrl: raw['bookUrl']?.toString() ?? '',
      coverUrl: raw['coverUrl']?.toString() ?? '',
      sourceName: raw['sourceName']?.toString() ?? '',
    );
  }

  RecommendationCacheSnapshot _snapshotFromEntry(
    _RecommendationCacheEntry entry,
  ) {
    final cachedAt = DateTime.fromMillisecondsSinceEpoch(
      entry.cachedAtSeconds * 1000,
      isUtc: true,
    ).toLocal();
    return RecommendationCacheSnapshot(
      cachedAt: cachedAt,
      results: entry.items
          .map((item) => _searchResultFromMap(item))
          .toList(growable: false),
      isExpired: DateTime.now().difference(cachedAt) > cacheTtl,
    );
  }

  String _sourceCacheKeyFor(BookSourceModel source) {
    return [
      source.name,
      source.url,
      source.searchUrl,
      source.searchList,
      source.searchName,
      source.searchAuthor,
      source.searchBookUrl,
      source.searchCover,
      source.bookSourceType.toString(),
      source.enabledExplore.toString(),
      source.exploreUrl,
      source.exploreList,
      source.exploreName,
      source.exploreAuthor,
      source.exploreBookUrl,
      source.exploreCover,
      source.rssArticles,
      source.rssTitle,
      source.rssPubDate,
      source.rssDescription,
      source.rssImage,
      source.rssLink,
      source.rssContent,
    ].join('|');
  }

  bool _isExpiredSeconds(int seconds) {
    final cachedAt = DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
      isUtc: true,
    ).toLocal();
    return DateTime.now().difference(cachedAt) > cacheTtl;
  }

  List<_RecommendationCacheEntry> _readCache(SharedPreferences prefs) {
    final raw =
        prefs.getString(_cacheKey) ??
        prefs.getString('discover_recommendations_cache_v1');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const [];
      final map = decoded.cast<String, dynamic>();
      final entries = map['entries'];
      if (entries is List) {
        return entries
            .whereType<Map>()
            .map(
              (entry) => _RecommendationCacheEntry.fromJson(
                entry.cast<String, dynamic>(),
              ),
            )
            .where((entry) => entry.signature.isNotEmpty)
            .toList(growable: false);
      }
      final migrated = _RecommendationCacheEntry.fromLegacyJson(map);
      return migrated == null ? const [] : [migrated];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistCache(
    SharedPreferences prefs,
    List<_RecommendationCacheEntry> cache,
  ) async {
    await prefs.setString(
      _cacheKey,
      jsonEncode({
        'entries': cache.map((entry) => entry.toJson()).toList(growable: false),
      }),
    );
  }

  List<_SourceRecommendationCacheEntry> _readSourceCache(
    SharedPreferences prefs,
  ) {
    final raw = prefs.getString(_sourceCacheKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const [];
      final map = decoded.cast<String, dynamic>();
      final entries = map['entries'];
      if (entries is! List) return const [];
      return entries
          .whereType<Map>()
          .map(
            (entry) => _SourceRecommendationCacheEntry.fromJson(
              entry.cast<String, dynamic>(),
            ),
          )
          .where((entry) => entry.sourceKey.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistSourceCache(
    SharedPreferences prefs,
    List<_SourceRecommendationCacheEntry> cache,
  ) async {
    await prefs.setString(
      _sourceCacheKey,
      jsonEncode({
        'entries': cache.map((entry) => entry.toJson()).toList(growable: false),
      }),
    );
  }
}

class RecommendationCacheSnapshot {
  final DateTime cachedAt;
  final List<bs.SearchResult> results;
  final bool isExpired;

  const RecommendationCacheSnapshot({
    required this.cachedAt,
    required this.results,
    required this.isExpired,
  });
}

class _SourceRecommendationBatch {
  final BookSourceModel source;
  final List<bs.SearchResult> results;

  const _SourceRecommendationBatch({
    required this.source,
    required this.results,
  });
}

class _RecommendationCacheEntry {
  final String signature;
  final int cachedAtSeconds;
  final List<Map<String, String>> items;

  const _RecommendationCacheEntry({
    required this.signature,
    required this.cachedAtSeconds,
    required this.items,
  });

  factory _RecommendationCacheEntry.fromJson(Map<String, dynamic> raw) {
    return _RecommendationCacheEntry(
      signature: raw['signature']?.toString() ?? '',
      cachedAtSeconds: raw['cachedAt'] as int? ?? 0,
      items: (raw['items'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (item) => item.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ),
          )
          .toList(growable: false),
    );
  }

  static _RecommendationCacheEntry? fromLegacyJson(Map<String, dynamic> raw) {
    final signature = raw['signature']?.toString() ?? '';
    final cachedAt = raw['cachedAt'] as int?;
    final items = raw['items'];
    if (signature.isEmpty || cachedAt == null || items is! List) return null;
    return _RecommendationCacheEntry(
      signature: signature,
      cachedAtSeconds: cachedAt,
      items: items
          .whereType<Map>()
          .map(
            (item) => item.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ),
          )
          .toList(growable: false),
    );
  }

  Map<String, Object> toJson() => {
    'signature': signature,
    'cachedAt': cachedAtSeconds,
    'items': items,
  };
}

class _SourceRecommendationCacheEntry {
  final String sourceKey;
  final int cachedAtSeconds;
  final List<Map<String, String>> items;

  const _SourceRecommendationCacheEntry({
    required this.sourceKey,
    required this.cachedAtSeconds,
    required this.items,
  });

  factory _SourceRecommendationCacheEntry.fromJson(Map<String, dynamic> raw) {
    return _SourceRecommendationCacheEntry(
      sourceKey: raw['sourceKey']?.toString() ?? '',
      cachedAtSeconds: raw['cachedAt'] as int? ?? 0,
      items: (raw['items'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (item) => item.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ),
          )
          .toList(growable: false),
    );
  }

  Map<String, Object> toJson() => {
    'sourceKey': sourceKey,
    'cachedAt': cachedAtSeconds,
    'items': items,
  };
}
