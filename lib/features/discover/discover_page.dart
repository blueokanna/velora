import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../services/local_books.dart';
import '../../services/rss_source.dart';
import '../../services/source_recommendations.dart';
import '../../src/rust/api/book_source.dart' as bs;
import '../../src/rust/api/storage.dart' as rs;
import '../../state/bookshelf.dart';
import '../../state/settings.dart';
import '../../state/sources.dart';

class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  static const _recommendations = SourceRecommendationsService();
  static const _rss = RssSourceService();
  static const _sourceRequestTimeout = Duration(seconds: 8);

  final _controller = TextEditingController();
  List<bs.SearchResult> _results = const [];
  List<bs.SearchResult> _recommended = const [];
  bool _loading = false;
  bool _refreshingRecommendations = false;
  String? _error;
  String _sourceSignature = '';
  int _requestToken = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (_controller.text.trim().isEmpty && _results.isNotEmpty) {
        setState(() {
          _results = const [];
          _error = null;
        });
      }
    });
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) {
      await _loadRecommendations();
      return;
    }
    final requestToken = ++_requestToken;
    setState(() {
      _loading = true;
      _error = null;
      _results = const [];
    });
    final sources = ref.read(sourcesProvider).where((s) => s.enabled).toList();
    try {
      final all = await _searchSources(
        sources,
        keyword,
        onProgress: (partial) {
          if (!mounted || requestToken != _requestToken) return;
          setState(() => _results = partial);
        },
      );
      if (!mounted || requestToken != _requestToken) return;
      setState(() => _results = all);
    } catch (e) {
      if (!mounted || requestToken != _requestToken) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted && requestToken == _requestToken) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadRecommendations([
    List<BookSourceModel>? seeded,
    bool silent = false,
  ]) async {
    final sources =
        seeded ?? ref.read(sourcesProvider).where((s) => s.enabled).toList();
    final requestToken = ++_requestToken;
    if (sources.isEmpty) {
      if (!mounted || requestToken != _requestToken) return;
      setState(() {
        _recommended = const [];
        _error = null;
      });
      return;
    }
    setState(() {
      _refreshingRecommendations = silent;
      _loading = !silent;
      _error = null;
      if (!silent && _controller.text.trim().isEmpty) {
        _results = const [];
      }
    });
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final recommendations = await _recommendations.loadAndCache(
        prefs,
        sources,
      );
      await _recommendations.saveCached(
        prefs,
        signature: _recommendationSignature(sources),
        results: recommendations,
      );
      if (!mounted || requestToken != _requestToken) return;
      setState(() {
        _recommended = recommendations;
      });
    } catch (e) {
      if (!mounted || requestToken != _requestToken) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted && requestToken == _requestToken) {
        setState(() {
          _loading = false;
          _refreshingRecommendations = false;
        });
      }
    }
  }

  String _recommendationSignature(List<BookSourceModel> sources) {
    return sources
        .where((item) => item.enabled)
        .map(
          (item) => [
            item.name,
            item.url,
            item.searchUrl,
            item.searchList,
            item.enabledExplore.toString(),
            item.exploreUrl,
            item.exploreList,
            item.rssArticles,
            item.rssLink,
            item.rssContent,
          ].join('|'),
        )
        .join('||');
  }

  Future<void> _primeRecommendations(List<BookSourceModel> sources) async {
    final cached = await _recommendations.loadCachedSubset(
      ref.read(sharedPreferencesProvider),
      sources: sources,
      collectionSignature: _sourceSignature,
    );
    if (!mounted || _controller.text.trim().isNotEmpty) return;
    if (cached != null && cached.results.isNotEmpty) {
      setState(() {
        _recommended = cached.results;
        _error = null;
      });
    }
    if (cached == null || cached.results.isEmpty || cached.isExpired) {
      unawaited(
        _loadRecommendations(
          sources,
          cached != null && cached.results.isNotEmpty,
        ),
      );
    }
  }

  Future<List<bs.SearchResult>> _searchSources(
    List<BookSourceModel> sources,
    String keyword, {
    ValueChanged<List<bs.SearchResult>>? onProgress,
  }) async {
    const concurrency = 6;
    final prefs = ref.read(sharedPreferencesProvider);
    final results = <bs.SearchResult>[];
    final seen = <String>{};
    for (var start = 0; start < sources.length; start += concurrency) {
      final end = math.min(start + concurrency, sources.length);
      final batch = sources.sublist(start, end);
      final lists = await Future.wait(
        batch.map((src) async {
          try {
            if (src.isRssSource) {
              return await _rss.loadItems(
                prefs,
                source: src,
                maxItems: 12,
                keyword: keyword,
              );
            }
            return await bs
                .sourceSearch(sourceJson: src.toJsonString(), keyword: keyword)
                .timeout(_sourceRequestTimeout);
          } catch (_) {
            return const <bs.SearchResult>[];
          }
        }),
      );
      for (final list in lists) {
        for (final item in list) {
          final key = item.bookUrl.trim().isEmpty
              ? '${item.sourceName}|${item.name}|${item.author}'
              : item.bookUrl;
          if (seen.add(key)) {
            results.add(item);
          }
        }
      }
      onProgress?.call(List<bs.SearchResult>.unmodifiable(results));
      if (end < sources.length) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return results;
  }

  Future<void> _addOnlineBook(bs.SearchResult result) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final source = ref
          .read(sourcesProvider)
          .firstWhere((item) => item.name == result.sourceName);
      if (RssSourceService.isSyntheticBookUrl(result.bookUrl)) {
        final prefs = ref.read(sharedPreferencesProvider);
        final cached = await _rss.ensureEntry(
          prefs,
          source: source,
          syntheticUrl: result.bookUrl,
          fallbackTitle: result.name,
        );
        final entry = rs.BookshelfEntry(
          id: 'online:${result.bookUrl}',
          title: cached?.title.trim().isNotEmpty == true
              ? cached!.title
              : result.name,
          author: cached?.author.trim().isNotEmpty == true
              ? cached!.author
              : result.author,
          kind: 'online',
          pathOrUrl: result.bookUrl,
          bookMetaJson: null,
          cover: cached?.coverUrl.trim().isNotEmpty == true
              ? cached!.coverUrl
              : result.coverUrl,
          lastChapter: 0,
          lastOffset: BigInt.zero,
          updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          sourceName: result.sourceName,
          sourceJson: source.toJsonString(),
          tocUrl: cached?.link.trim().isNotEmpty == true
              ? cached!.link
              : result.bookUrl,
        );
        await ref.read(bookshelfProvider.notifier).upsert(entry);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${AppLocalizations.of(context).imported}: ${entry.title}',
              ),
            ),
          );
        }
        return;
      }
      final sourceJson = source.toJsonString();
      final detail = await bs.sourceBookDetail(
        sourceJson: sourceJson,
        bookUrl: result.bookUrl,
      );
      final toc = await bs.sourceToc(
        sourceJson: sourceJson,
        tocUrl: detail.tocUrl,
      );
      if (toc.isEmpty) throw StateError('目录为空');
      final title = detail.name.trim().isEmpty ? result.name : detail.name;
      final author = detail.author.trim().isEmpty
          ? result.author
          : detail.author;
      final entry = await enrichBookEntryMetadata(
        rs.BookshelfEntry(
          id: 'online:${result.bookUrl}',
          title: title,
          author: author,
          kind: 'online',
          pathOrUrl: result.bookUrl,
          bookMetaJson: null,
          cover: detail.coverUrl.trim().isEmpty
              ? result.coverUrl
              : detail.coverUrl,
          lastChapter: 0,
          lastOffset: BigInt.zero,
          updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          sourceName: result.sourceName,
          sourceJson: sourceJson,
          tocUrl: detail.tocUrl,
        ),
      );
      await ref.read(bookshelfProvider.notifier).upsert(entry);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${AppLocalizations.of(context).imported}: $title'),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _ensureRecommendations(List<BookSourceModel> sources) {
    final signature = _recommendationSignature(sources);
    if (signature == _sourceSignature) return;
    _sourceSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _controller.text.trim().isNotEmpty) return;
      unawaited(_primeRecommendations(sources));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final sources = ref.watch(sourcesProvider).where((s) => s.enabled).toList();
    _ensureRecommendations(sources);
    final showingSearch = _controller.text.trim().isNotEmpty;
    final items = showingSearch ? _results : _recommended;
    final body = sources.isEmpty
        ? KeyedSubtree(
            key: const ValueKey('discover-no-sources'),
            child: Center(
              child: Text(
                l10n.noSourcesSub,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          )
        : _loading && items.isEmpty
        ? const _DiscoverSkeletonList(key: ValueKey('discover-loading'))
        : _error != null
        ? KeyedSubtree(
            key: const ValueKey('discover-error'),
            child: Center(child: Text(_error!)),
          )
        : items.isEmpty
        ? KeyedSubtree(
            key: ValueKey('discover-empty-$showingSearch'),
            child: Center(
              child: Text(
                showingSearch ? l10n.noResults : l10n.noRecommendations,
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            ),
          )
        : RefreshIndicator(
            key: ValueKey('discover-results-$showingSearch-${items.length}'),
            onRefresh: showingSearch
                ? _search
                : () => _loadRecommendations(sources),
            child: ListView.separated(
              itemCount: items.length + 1,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return ListTile(
                    title: Text(
                      showingSearch ? l10n.searchHint : l10n.recommendedBooks,
                    ),
                    subtitle: showingSearch
                        ? null
                        : Text(l10n.discoverAutoRecommendations),
                  );
                }
                final result = items[index - 1];
                return _AnimatedSearchResultTile(
                  index: index,
                  result: result,
                  onTap: () => _addOnlineBook(result),
                );
              },
            ),
          );
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.discover),
        actions: [
          IconButton(
            onPressed: _loading || _refreshingRecommendations
                ? null
                : () => _loadRecommendations(sources),
            tooltip: l10n.refreshRecommendations,
            icon: _refreshingRecommendations
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SearchBar(
              controller: _controller,
              hintText: l10n.searchHint,
              leading: const Icon(Icons.search),
              trailing: [
                if (_controller.text.trim().isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _controller.clear();
                      _loadRecommendations(sources);
                    },
                  ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _search,
                ),
              ],
              onSubmitted: (_) => _search(),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              reverseDuration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final curved = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                );
                return FadeTransition(
                  opacity: curved,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.025),
                      end: Offset.zero,
                    ).animate(curved),
                    child: child,
                  ),
                );
              },
              child: body,
            ),
          ),
          if (_loading && items.isNotEmpty)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                minHeight: 2.5,
                color: colorScheme.primary,
                backgroundColor: colorScheme.surfaceContainerHighest,
              ),
            ),
        ],
      ),
    );
  }
}

class _AnimatedSearchResultTile extends StatelessWidget {
  final int index;
  final bs.SearchResult result;
  final VoidCallback onTap;

  const _AnimatedSearchResultTile({
    required this.index,
    required this.result,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final delay = Duration(milliseconds: (index.clamp(0, 8) * 28).toInt());
    return TweenAnimationBuilder<double>(
      key: ValueKey(
        result.bookUrl.isEmpty
            ? '${result.sourceName}-${result.name}-${result.author}'
            : result.bookUrl,
      ),
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 260 + delay.inMilliseconds),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - value)),
            child: child,
          ),
        );
      },
      child: ListTile(
        leading: _SearchResultCover(url: result.coverUrl),
        title: Text(result.name),
        subtitle: Text('${result.author} · ${result.sourceName}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _DiscoverSkeletonList extends StatefulWidget {
  const _DiscoverSkeletonList({super.key});

  @override
  State<_DiscoverSkeletonList> createState() => _DiscoverSkeletonListState();
}

class _DiscoverSkeletonListState extends State<_DiscoverSkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      itemCount: 8,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) =>
          _SkeletonTile(animation: _controller, compact: index == 0),
    );
  }
}

class _SkeletonTile extends StatelessWidget {
  final Animation<double> animation;
  final bool compact;

  const _SkeletonTile({required this.animation, required this.compact});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final alpha = 0.34 + animation.value * 0.28;
        final base = colorScheme.surfaceContainerHighest.withValues(
          alpha: alpha,
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            compact ? 12 : 10,
            16,
            compact ? 12 : 10,
          ),
          child: Row(
            children: [
              _SkeletonBlock(
                width: compact ? 36 : 42,
                height: compact ? 36 : 56,
                radius: compact ? 18 : 8,
                color: base,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SkeletonBlock(
                      width: double.infinity,
                      height: compact ? 16 : 18,
                      radius: 999,
                      color: base,
                    ),
                    const SizedBox(height: 10),
                    FractionallySizedBox(
                      widthFactor: compact ? 0.46 : 0.68,
                      child: _SkeletonBlock(
                        width: double.infinity,
                        height: 14,
                        radius: 999,
                        color: base,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  final Color color;

  const _SkeletonBlock({
    required this.width,
    required this.height,
    required this.radius,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

class _SearchResultCover extends StatelessWidget {
  final String url;

  const _SearchResultCover({required this.url});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final value = url.trim();
    final fallback = Container(
      width: 42,
      height: 56,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        Icons.menu_book_outlined,
        color: colorScheme.onSurfaceVariant,
      ),
    );
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      return fallback;
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        value,
        width: 42,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, error, stackTrace) => fallback,
      ),
    );
  }
}
