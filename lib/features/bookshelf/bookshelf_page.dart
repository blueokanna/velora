import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app_keys.dart';
import '../../l10n/app_localizations.dart';
import '../../services/document_file.dart';
import '../../services/local_books.dart';
import '../../src/rust/api/book_file.dart' as book_file;
import '../../src/rust/api/storage.dart' as rs;
import '../../state/bookshelf.dart';
import '../../theme/motion.dart';
import '../../widgets/responsive.dart';
import '../reader/book_meta_codec.dart';

class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends ConsumerState<BookshelfPage>
    with WidgetsBindingObserver {
  late final TextEditingController _searchController;
  String _searchQuery = '';
  String? _formatFilter;
  final Set<String> _selectedIds = <String>{};
  bool _isImporting = false;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchController = TextEditingController()
      ..addListener(() {
        final next = _searchController.text.trim();
        if (next == _searchQuery) return;
        setState(() {
          _searchQuery = next;
        });
      });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncLocalBooks();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncLocalBooks();
    }
  }

  bool get _selectionMode => _selectedIds.isNotEmpty;

  Future<void> _importBook() async {
    if (_isImporting) return;
    setState(() {
      _isImporting = true;
    });

    try {
      if (Platform.isAndroid) {
        await _importAndroidBook();
      } else {
        await _importDesktopBook();
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${AppLocalizations.of(context).importFailed}: $error'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
        });
      }
    }
  }

  Future<void> _importDesktopBook() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub', 'mobi', 'azw3'],
    );
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.first.path;
    if (path == null) return;
    final stat = await File(path).stat();
    final meta = book_file.openBookFile(path: path);
    final entry = _mergeImportedEntry(
      rs.BookshelfEntry(
        id: 'local://${meta.locator}',
        title: meta.title,
        author: meta.author,
        kind: meta.format,
        pathOrUrl: meta.locator,
        bookMetaJson: encodeBookMeta(
          meta,
          sourceSizeBytes: stat.size,
          sourceModifiedAtMillis: stat.modified.millisecondsSinceEpoch,
        ),
        cover: meta.coverDataUrl,
        lastChapter: 0,
        lastOffset: BigInt.zero,
        updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        sourceName: null,
        sourceJson: null,
        tocUrl: null,
      ),
    );
    await ref.read(bookshelfProvider.notifier).upsert(entry);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${AppLocalizations.of(context).imported}: ${entry.title}',
        ),
      ),
    );
  }

  Future<void> _importAndroidBook() async {
    final doc = await DocumentFileChannel.openBookDocument();
    if (doc == null) return;
    final bytes = await DocumentFileChannel.readBytes(doc.uri);
    final meta = book_file.openBookBytes(
      locator: doc.uri,
      title: doc.name,
      bytes: bytes,
    );
    final entry = _mergeImportedEntry(
      rs.BookshelfEntry(
        id: 'local-uri:${doc.uri}',
        title: meta.title,
        author: meta.author,
        kind: '${meta.format}_uri',
        pathOrUrl: doc.uri,
        bookMetaJson: encodeBookMeta(
          meta,
          sourceSizeBytes: doc.size,
          sourceModifiedAtMillis: doc.lastModifiedMillis,
        ),
        cover: meta.coverDataUrl,
        lastChapter: 0,
        lastOffset: BigInt.zero,
        updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        sourceName: null,
        sourceJson: null,
        tocUrl: null,
      ),
    );
    await ref.read(bookshelfProvider.notifier).upsert(entry);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${AppLocalizations.of(context).imported}: ${entry.title}',
        ),
      ),
    );
  }

  rs.BookshelfEntry _mergeImportedEntry(rs.BookshelfEntry entry) {
    final current = ref.read(bookshelfProvider).asData?.value ?? const [];
    rs.BookshelfEntry? existing;
    for (final item in current) {
      if (item.id == entry.id || item.pathOrUrl == entry.pathOrUrl) {
        existing = item;
        break;
      }
    }
    if (existing == null) return entry;
    return rs.BookshelfEntry(
      id: existing.id,
      title: entry.title,
      author: entry.author,
      kind: entry.kind,
      pathOrUrl: entry.pathOrUrl,
      bookMetaJson: entry.bookMetaJson,
      cover: entry.cover,
      lastChapter: existing.lastChapter,
      lastOffset: existing.lastOffset,
      updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      sourceName: existing.sourceName,
      sourceJson: existing.sourceJson,
      tocUrl: existing.tocUrl,
    );
  }

  Future<void> _syncLocalBooks({bool force = false}) async {
    if (_isSyncing) return;
    setState(() {
      _isSyncing = true;
    });
    try {
      await ref.read(bookshelfProvider.notifier).refresh();
      final books = ref.read(bookshelfProvider).asData?.value ?? const [];
      final updates = <rs.BookshelfEntry>[];
      for (final book in books.where(isManagedOfflineBook)) {
        try {
          final refreshed = await refreshLocalBookEntry(book, force: force);
          if (refreshed != null) {
            updates.add(refreshed);
          }
        } catch (_) {}
      }
      if (updates.isNotEmpty) {
        await ref.read(bookshelfProvider.notifier).upsertMany(updates);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${AppLocalizations.of(context).booksUpdated} ${updates.length}',
              ),
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
        });
      }
    }
  }

  Future<void> _deleteSelected() async {
    final ids = _selectedIds.toList(growable: false);
    if (ids.isEmpty) return;
    await ref.read(bookshelfProvider.notifier).removeMany(ids);
    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
    });
  }

  void _toggleSelection(String bookId) {
    setState(() {
      if (_selectedIds.contains(bookId)) {
        _selectedIds.remove(bookId);
      } else {
        _selectedIds.add(bookId);
      }
    });
  }

  void _selectAll(Iterable<rs.BookshelfEntry> books) {
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(books.map((book) => book.id));
    });
  }

  List<String> _formatOptions(List<rs.BookshelfEntry> items) {
    final options =
        items
            .map(
              (book) => _formatLabel(
                decodeBookMeta(book.bookMetaJson)?.format ?? book.kind,
              ),
            )
            .toSet()
            .toList(growable: false)
          ..sort();
    return options;
  }

  List<rs.BookshelfEntry> _filterBooks(List<rs.BookshelfEntry> items) {
    final query = _searchQuery.trim().toLowerCase();
    return items
        .where((book) {
          final meta = decodeBookMeta(book.bookMetaJson);
          final haystack = <String>[
            book.title,
            book.author,
            book.kind,
            book.pathOrUrl,
            if (meta != null) meta.format,
          ].join('\n').toLowerCase();
          final matchesQuery = query.isEmpty || haystack.contains(query);
          final format = _formatLabel(meta?.format ?? book.kind);
          final matchesFormat =
              _formatFilter == null || _formatFilter == format;
          return matchesQuery && matchesFormat;
        })
        .toList(growable: false);
  }

  Map<String, List<rs.BookshelfEntry>> _groupBooks(
    List<rs.BookshelfEntry> items,
  ) {
    final grouped = <String, List<rs.BookshelfEntry>>{};
    for (final book in items) {
      final label = _formatLabel(
        decodeBookMeta(book.bookMetaJson)?.format ?? book.kind,
      );
      grouped.putIfAbsent(label, () => <rs.BookshelfEntry>[]).add(book);
    }
    return Map.fromEntries(
      grouped.entries.toList(growable: false)
        ..sort((left, right) => left.key.compareTo(right.key)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shelfAsync = ref.watch(bookshelfProvider);
    final allItems = shelfAsync.asData?.value ?? const <rs.BookshelfEntry>[];
    final filteredForActions = _filterBooks(allItems);
    final size = windowSizeOf(context);
    final crossAxis = switch (size) {
      WindowSizeClass.compact => 3,
      WindowSizeClass.medium => 4,
      WindowSizeClass.expanded => 5,
      WindowSizeClass.large => 6,
      WindowSizeClass.extraLarge => 8,
    };

    return Scaffold(
      key: AppKeys.bookshelfPage,
      appBar: AppBar(
        title: Text(
          _selectionMode
              ? '${_selectedIds.length} ${l10n.selectedItems}'
              : l10n.bookshelf,
        ),
        actions: [
          if (_selectionMode)
            IconButton(
              tooltip: l10n.selectAll,
              onPressed: () => _selectAll(filteredForActions),
              icon: const Icon(Icons.select_all),
            ),
          if (_selectionMode)
            IconButton(
              tooltip: l10n.clearSelection,
              onPressed: () {
                setState(() {
                  _selectedIds.clear();
                });
              },
              icon: const Icon(Icons.close),
            ),
          if (_selectionMode)
            IconButton(
              tooltip: l10n.deleteSelected,
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete_outline),
            ),
          if (!_selectionMode)
            IconButton(
              tooltip: l10n.syncLibrary,
              onPressed: _isSyncing ? null : () => _syncLocalBooks(force: true),
              icon: _isSyncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
            ),
        ],
      ),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _isImporting ? null : _importBook,
              icon: _isImporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: Text(l10n.importBook),
            ),
      body: shelfAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (items) {
          if (items.isEmpty) {
            return const _EmptyShelf();
          }
          final filteredItems = _filterBooks(items);
          final grouped = _groupBooks(filteredItems);
          final formats = _formatOptions(items);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  key: AppKeys.bookshelfSearch,
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: l10n.searchHint,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isEmpty
                        ? null
                        : IconButton(
                            onPressed: _searchController.clear,
                            icon: const Icon(Icons.close),
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
              ),
              SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        l10n.formatFilter,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    ChoiceChip(
                      label: Text(l10n.allFormats),
                      selected: _formatFilter == null,
                      onSelected: (_) {
                        setState(() {
                          _formatFilter = null;
                        });
                      },
                    ),
                    const SizedBox(width: 8),
                    ...formats.map(
                      (format) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(format),
                          selected: _formatFilter == format,
                          onSelected: (_) {
                            setState(() {
                              _formatFilter = _formatFilter == format
                                  ? null
                                  : format;
                            });
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: M3Motion.medium2,
                  switchInCurve: M3Motion.emphasizedDecelerate,
                  child: filteredItems.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              l10n.noResults,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        )
                      : ListView(
                          key: ValueKey(
                            '${filteredItems.length}_${_searchQuery}_${_formatFilter ?? 'all'}_${_selectedIds.length}',
                          ),
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                          children: grouped.entries
                              .map((section) {
                                final books = section.value;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 18),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        child: Text(
                                          '${section.key} · ${books.length}',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                      ),
                                      GridView.builder(
                                        shrinkWrap: true,
                                        physics:
                                            const NeverScrollableScrollPhysics(),
                                        gridDelegate:
                                            SliverGridDelegateWithFixedCrossAxisCount(
                                              crossAxisCount: crossAxis,
                                              mainAxisSpacing: 16,
                                              crossAxisSpacing: 16,
                                              childAspectRatio: 0.58,
                                            ),
                                        itemCount: books.length,
                                        itemBuilder: (context, index) {
                                          final book = books[index];
                                          return KeyedSubtree(
                                            key:
                                                section.key ==
                                                        grouped.keys.first &&
                                                    index == 0
                                                ? AppKeys.bookshelfGrid
                                                : null,
                                            child: _BookCard(
                                              book: book,
                                              selected: _selectedIds.contains(
                                                book.id,
                                              ),
                                              selectionMode: _selectionMode,
                                              onTap: () => context.push(
                                                '/reader?bookId=${Uri.encodeQueryComponent(book.id)}',
                                                extra: book,
                                              ),
                                              onToggleSelected: () =>
                                                  _toggleSelection(book.id),
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              })
                              .toList(growable: false),
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  final rs.BookshelfEntry book;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onToggleSelected;

  const _BookCard({
    required this.book,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onToggleSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final meta = decodeBookMeta(book.bookMetaJson);
    final coverBytes = _decodeCover(book.cover);
    final chips = <String>[
      _formatLabel(meta?.format ?? book.kind),
      if (meta != null && meta.sizeBytes > BigInt.zero)
        _formatBytes(meta.sizeBytes),
      if (meta != null && meta.chapters.isNotEmpty)
        '${(book.lastChapter + 1).clamp(1, meta.chapters.length)}/${meta.chapters.length}',
    ];

    return Hero(
      tag: book.id,
      createRectTween: (begin, end) =>
          MaterialRectCenterArcTween(begin: begin, end: end),
      child: Card(
        key: AppKeys.bookshelfBook(book.id),
        clipBehavior: Clip.antiAlias,
        elevation: selected ? 3 : 1,
        child: InkWell(
          onTap: selectionMode ? onToggleSelected : onTap,
          onLongPress: onToggleSelected,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (coverBytes != null)
                      Image.memory(
                        coverBytes,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, error, stackTrace) => _FallbackCover(
                          title: book.title,
                          colorScheme: colorScheme,
                        ),
                      )
                    else
                      _FallbackCover(
                        title: book.title,
                        colorScheme: colorScheme,
                      ),
                    if (selectionMode || selected)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colorScheme.surface.withValues(alpha: 0.92),
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              selected
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color: selected
                                  ? colorScheme.primary
                                  : colorScheme.onSurfaceVariant,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (book.author.isNotEmpty)
                      Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: chips
                          .map(
                            (chip) => Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                chip,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FallbackCover extends StatelessWidget {
  final String title;
  final ColorScheme colorScheme;

  const _FallbackCover({required this.title, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colorScheme.primaryContainer, colorScheme.tertiaryContainer],
        ),
      ),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          title,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_outlined,
              size: 96,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.emptyShelfTitle,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.emptyShelfSubtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

String _formatLabel(String raw) {
  final normalized = raw.replaceAll('_uri', '').trim();
  if (normalized.isEmpty) return 'BOOK';
  return normalized.toUpperCase();
}

String _formatBytes(BigInt bytes) {
  final value = bytes.toDouble();
  const units = ['B', 'KB', 'MB', 'GB'];
  var unitIndex = 0;
  var size = value;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }
  final digits = size >= 100
      ? 0
      : size >= 10
      ? 1
      : 2;
  return '${size.toStringAsFixed(digits)} ${units[unitIndex]}';
}

Uint8List? _decodeCover(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final comma = raw.indexOf(',');
  if (comma < 0 || comma == raw.length - 1) return null;
  try {
    return base64Decode(raw.substring(comma + 1));
  } catch (_) {
    return null;
  }
}
