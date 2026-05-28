import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../services/local_books.dart';
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
      final all = await _searchSources(sources, keyword);
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
        .map((item) => '${item.name}|${item.url}|${item.searchUrl}')
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
    String keyword,
  ) async {
    const concurrency = 4;
    final results = <bs.SearchResult>[];
    final seen = <String>{};
    for (var start = 0; start < sources.length; start += concurrency) {
      final end = math.min(start + concurrency, sources.length);
      final batch = sources.sublist(start, end);
      final lists = await Future.wait(
        batch.map((src) async {
          try {
            return await bs.sourceSearch(
              sourceJson: src.toJsonString(),
              keyword: keyword,
            );
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
    final sources = ref.watch(sourcesProvider).where((s) => s.enabled).toList();
    _ensureRecommendations(sources);
    final showingSearch = _controller.text.trim().isNotEmpty;
    final items = showingSearch ? _results : _recommended;
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
                    child: CircularProgressIndicator(strokeWidth: 2),
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
      body: sources.isEmpty
          ? Center(
              child: Text(
                l10n.noSourcesSub,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            )
          : _loading && items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : items.isEmpty
          ? Center(
              child: Text(
                showingSearch ? l10n.noResults : l10n.noRecommendations,
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            )
          : RefreshIndicator(
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
                  return ListTile(
                    leading: _SearchResultCover(url: result.coverUrl),
                    title: Text(result.name),
                    subtitle: Text('${result.author} · ${result.sourceName}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _addOnlineBook(result),
                  );
                },
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
