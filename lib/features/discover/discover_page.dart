import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../src/rust/api/book_source.dart' as bs;
import '../../src/rust/api/storage.dart' as rs;
import '../../state/bookshelf.dart';
import '../../state/sources.dart';

class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  final _controller = TextEditingController();
  List<bs.SearchResult> _results = const [];
  bool _loading = false;
  String? _error;

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _results = const [];
    });
    final sources = ref.read(sourcesProvider).where((s) => s.enabled).toList();
    final all = <bs.SearchResult>[];
    try {
      for (final src in sources) {
        try {
          final list = bs.sourceSearch(
            sourceJson: src.toJsonString(),
            keyword: keyword,
          );
          all.addAll(list);
        } catch (_) {
        }
      }
      setState(() => _results = all);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _addOnlineBook(bs.SearchResult result) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final source = ref.read(sourcesProvider).firstWhere((item) => item.name == result.sourceName);
      final sourceJson = source.toJsonString();
      final detail = bs.sourceBookDetail(sourceJson: sourceJson, bookUrl: result.bookUrl);
      final toc = bs.sourceToc(sourceJson: sourceJson, tocUrl: detail.tocUrl);
      if (toc.isEmpty) throw StateError('目录为空');
      final title = detail.name.trim().isEmpty ? result.name : detail.name;
      final author = detail.author.trim().isEmpty ? result.author : detail.author;
      final entry = rs.BookshelfEntry(
        id: 'online:${result.bookUrl}',
        title: title,
        author: author,
        kind: 'online',
        pathOrUrl: result.bookUrl,
        bookMetaJson: null,
        cover: null,
        lastChapter: 0,
        lastOffset: BigInt.zero,
        updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        sourceName: result.sourceName,
        sourceJson: sourceJson,
        tocUrl: detail.tocUrl,
      );
      await ref.read(bookshelfProvider.notifier).upsert(entry);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${AppLocalizations.of(context).imported}: $title')));
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.discover),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SearchBar(
              controller: _controller,
              hintText: l10n.searchHint,
              leading: const Icon(Icons.search),
              trailing: [
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : _results.isEmpty
                  ? Center(
                      child: Text(l10n.noResults,
                          style: Theme.of(context).textTheme.bodyLarge),
                    )
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final result = _results[index];
                        return ListTile(
                          leading: const Icon(Icons.menu_book_outlined),
                          title: Text(result.name),
                          subtitle: Text('${result.author} · ${result.sourceName}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _addOnlineBook(result),
                        );
                      },
                    ),
    );
  }
}
