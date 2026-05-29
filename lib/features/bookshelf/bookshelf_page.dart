import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

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

enum _BookAction { details, setCoverUrl, setCoverImage, share }

const _clearCoverSentinel = '__velora_clear_cover__';

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
  bool _isHandlingIncomingDocument = false;

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
      _consumePendingOpenDocument();
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
      _consumePendingOpenDocument();
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
    final title = deriveLocalBookTitle(
      metaTitle: meta.title,
      sourceName: picked.files.first.name,
      pathOrUrl: path,
    );
    final entry = _mergeImportedEntry(
      await enrichBookEntryMetadata(
        rs.BookshelfEntry(
          id: 'local://${meta.locator}',
          title: title,
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
    final entry = await _importAndroidDocument(doc);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${AppLocalizations.of(context).imported}: ${entry.title}',
        ),
      ),
    );
  }

  Future<rs.BookshelfEntry> _importAndroidDocument(DocumentFile doc) async {
    final imported = await DocumentFileChannel.importDocument(doc.uri);
    final localPath = imported?.localPath;
    if (imported == null || localPath == null || localPath.isEmpty) {
      throw StateError('无法建立本地阅读缓存');
    }
    final meta = book_file.openBookFile(path: localPath);
    final title = deriveLocalBookTitle(
      metaTitle: meta.title,
      sourceName: imported.name,
      pathOrUrl: localPath,
    );
    final entry = _mergeImportedEntry(
      await enrichBookEntryMetadata(
        rs.BookshelfEntry(
          id: 'local://$localPath',
          title: title,
          author: meta.author,
          kind: meta.format,
          pathOrUrl: localPath,
          bookMetaJson: encodeBookMeta(
            meta,
            sourceSizeBytes: imported.size,
            sourceModifiedAtMillis: imported.lastModifiedMillis,
          ),
          cover: meta.coverDataUrl,
          lastChapter: 0,
          lastOffset: BigInt.zero,
          updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          sourceName: null,
          sourceJson: null,
          tocUrl: null,
        ),
      ),
    );
    await ref.read(bookshelfProvider.notifier).upsert(entry);
    return entry;
  }

  Future<void> _consumePendingOpenDocument() async {
    if (!Platform.isAndroid || _isHandlingIncomingDocument || !mounted) {
      return;
    }
    _isHandlingIncomingDocument = true;
    try {
      final doc = await DocumentFileChannel.consumePendingOpenDocument();
      if (doc == null) return;
      final entry = await _importAndroidDocument(doc);
      if (!mounted) return;
      final location = '/reader?bookId=${Uri.encodeQueryComponent(entry.id)}';
      context.go(location, extra: entry);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${AppLocalizations.of(context).importFailed}: $error'),
        ),
      );
    } finally {
      _isHandlingIncomingDocument = false;
    }
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

  Future<void> _showBookActions(
    rs.BookshelfEntry book,
    BuildContext originContext,
  ) async {
    final l10n = AppLocalizations.of(context);
    final sharePositionOrigin = _sharePositionOrigin(originContext);
    final action = await showModalBottomSheet<_BookAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(l10n.bookDetails),
                onTap: () => Navigator.pop(sheetContext, _BookAction.details),
              ),
              if (isManagedOfflineBook(book))
                ListTile(
                  leading: const Icon(Icons.photo_outlined),
                  title: Text(l10n.setCoverUrl),
                  onTap: () =>
                      Navigator.pop(sheetContext, _BookAction.setCoverUrl),
                ),
              if (isManagedOfflineBook(book))
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: Text(l10n.setCoverImage),
                  onTap: () =>
                      Navigator.pop(sheetContext, _BookAction.setCoverImage),
                ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: Text(l10n.shareBook),
                onTap: () => Navigator.pop(sheetContext, _BookAction.share),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _BookAction.details:
        await _showBookDetails(book, sharePositionOrigin);
      case _BookAction.setCoverUrl:
        await _editCoverUrl(book);
      case _BookAction.setCoverImage:
        await _pickCoverImage(book);
      case _BookAction.share:
        await _shareBook(book, sharePositionOrigin);
    }
  }

  Future<void> _showBookDetails(
    rs.BookshelfEntry book,
    Rect? sharePositionOrigin,
  ) async {
    final l10n = AppLocalizations.of(context);
    final meta = decodeBookMeta(book.bookMetaJson);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.bookDetails,
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        height: 154,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: _BookCover(
                            raw: book.cover,
                            title: book.title,
                            colorScheme: colorScheme,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              book.title,
                              style: Theme.of(
                                sheetContext,
                              ).textTheme.titleMedium,
                            ),
                            if (book.author.trim().isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                book.author,
                                style: Theme.of(sheetContext)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            _DetailField(
                              label: l10n.formatLabel,
                              value: _formatLabel(meta?.format ?? book.kind),
                            ),
                            _DetailField(
                              label: l10n.locationLabel,
                              value: book.pathOrUrl,
                            ),
                            if ((book.sourceName ?? '').trim().isNotEmpty)
                              _DetailField(
                                label: l10n.sourceLink,
                                value: book.sourceName!,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: () async {
                          Navigator.pop(sheetContext);
                          await _shareBook(book, sharePositionOrigin);
                        },
                        icon: const Icon(Icons.share_outlined),
                        label: Text(l10n.shareBook),
                      ),
                      if (isManagedOfflineBook(book))
                        OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.pop(sheetContext);
                            await _editCoverUrl(book);
                          },
                          icon: const Icon(Icons.photo_outlined),
                          label: Text(l10n.setCoverUrl),
                        ),
                      if (isManagedOfflineBook(book))
                        OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.pop(sheetContext);
                            await _pickCoverImage(book);
                          },
                          icon: const Icon(Icons.image_outlined),
                          label: Text(l10n.setCoverImage),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _editCoverUrl(rs.BookshelfEntry book) async {
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        final controller = TextEditingController(
          text: _manualCoverSeed(book.cover),
        );
        String? errorText;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(l10n.setCoverUrl),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: l10n.coverUrlHint,
                  errorText: errorText,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.cancel),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, _clearCoverSentinel),
                  child: Text(l10n.clearCover),
                ),
                FilledButton(
                  onPressed: () {
                    final normalized = _normalizeCoverUrl(controller.text);
                    if (normalized == null) {
                      setDialogState(() {
                        errorText = l10n.invalidCoverUrl;
                      });
                      return;
                    }
                    Navigator.pop(dialogContext, normalized);
                  },
                  child: Text(l10n.save),
                ),
              ],
            );
          },
        );
      },
    );
    if (!mounted || result == null) return;
    final l10n = AppLocalizations.of(context);
    final nextCover = result == _clearCoverSentinel ? null : result;
    await _updateBookCover(book, nextCover);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          nextCover == null ? l10n.coverCleared : l10n.coverUpdated,
        ),
      ),
    );
  }

  Future<void> _shareBook(
    rs.BookshelfEntry book,
    Rect? sharePositionOrigin,
  ) async {
    final l10n = AppLocalizations.of(context);
    try {
      final fileData = await _shareFilesForBook(book);
      if (fileData != null) {
        await Share.shareXFiles(
          fileData.$1,
          subject: book.title,
          text: _shareTextForBook(book),
          sharePositionOrigin: sharePositionOrigin,
          fileNameOverrides: fileData.$2,
        );
      } else {
        await Share.share(
          _shareTextForBook(book),
          subject: book.title,
          sharePositionOrigin: sharePositionOrigin,
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${l10n.shareFailed}: $error')));
    }
  }

  Future<void> _pickCoverImage(rs.BookshelfEntry book) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    final bytes =
        file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null || bytes.isEmpty) return;
    final extension = (file.extension ?? '').toLowerCase();
    final mimeType = switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => 'image/png',
    };
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    await _updateBookCover(book, dataUrl);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).coverImageUpdated)),
    );
  }

  Future<void> _updateBookCover(
    rs.BookshelfEntry book,
    String? nextCover,
  ) async {
    await ref
        .read(bookshelfProvider.notifier)
        .upsert(
          rs.BookshelfEntry(
            id: book.id,
            title: book.title,
            author: book.author,
            kind: book.kind,
            pathOrUrl: book.pathOrUrl,
            bookMetaJson: book.bookMetaJson,
            cover: nextCover,
            lastChapter: book.lastChapter,
            lastOffset: book.lastOffset,
            updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            sourceName: book.sourceName,
            sourceJson: book.sourceJson,
            tocUrl: book.tocUrl,
          ),
        );
  }

  Rect? _sharePositionOrigin(BuildContext originContext) {
    final renderBox = originContext.findRenderObject() as RenderBox?;
    return renderBox == null
        ? null
        : renderBox.localToGlobal(Offset.zero) & renderBox.size;
  }

  Future<(List<XFile>, List<String>?)?> _shareFilesForBook(
    rs.BookshelfEntry book,
  ) async {
    if (!isManagedOfflineBook(book) || Platform.isLinux) {
      return null;
    }
    if (isDocumentUriBook(book)) {
      final source = await describeLocalBook(book);
      final imported = await DocumentFileChannel.importDocument(book.pathOrUrl);
      final localPath = imported?.localPath;
      if (imported == null || localPath == null || localPath.isEmpty) {
        return null;
      }
      final fileName = _shareFileName(book, source?.name ?? imported.name);
      return (
        [XFile(localPath, mimeType: _shareMimeType(book, fileName))],
        [fileName],
      );
    }
    final file = File(book.pathOrUrl);
    if (!await file.exists()) {
      return null;
    }
    return (
      [XFile(file.path, mimeType: _shareMimeType(book, file.path))],
      null,
    );
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
                                              onShowActions: (originContext) =>
                                                  _showBookActions(
                                                    book,
                                                    originContext,
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
  final ValueChanged<BuildContext> onShowActions;
  final VoidCallback onToggleSelected;

  const _BookCard({
    required this.book,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onShowActions,
    required this.onToggleSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final meta = decodeBookMeta(book.bookMetaJson);
    final formatChip = _formatLabel(meta?.format ?? book.kind);

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
                    _BookCover(
                      raw: book.cover,
                      title: book.title,
                      colorScheme: colorScheme,
                    ),
                    if (!selectionMode)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Builder(
                          builder: (menuContext) {
                            return DecoratedBox(
                              decoration: BoxDecoration(
                                color: colorScheme.surface.withValues(
                                  alpha: 0.92,
                                ),
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                visualDensity: VisualDensity.compact,
                                splashRadius: 18,
                                onPressed: () => onShowActions(menuContext),
                                icon: Icon(
                                  Icons.more_horiz,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            );
                          },
                        ),
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
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            formatChip,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        const Spacer(),
                        if (meta != null && meta.chapters.isNotEmpty)
                          Text(
                            '${(book.lastChapter + 1).clamp(1, meta.chapters.length)}/${meta.chapters.length}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                      ],
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

class _BookCover extends StatelessWidget {
  final String? raw;
  final String title;
  final ColorScheme colorScheme;

  const _BookCover({
    required this.raw,
    required this.title,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final value = raw?.trim() ?? '';
    final fallback = _FallbackCover(title: title, colorScheme: colorScheme);
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return Image.network(
        value,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, error, stackTrace) => fallback,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return fallback;
        },
      );
    }
    final coverBytes = _decodeCover(value);
    if (coverBytes == null) return fallback;
    return Image.memory(
      coverBytes,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, error, stackTrace) => fallback,
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

String _manualCoverSeed(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  return '';
}

String? _normalizeCoverUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';
  final uri = Uri.tryParse(value);
  final scheme = uri?.scheme.toLowerCase();
  if (uri == null || uri.host.isEmpty) return null;
  if (scheme != 'http' && scheme != 'https') return null;
  return uri.toString();
}

String _shareTextForBook(rs.BookshelfEntry book) {
  final lines = <String>[book.title];
  if (book.author.trim().isNotEmpty) {
    lines.add(book.author.trim());
  }
  if (book.kind == 'online') {
    lines.add(book.pathOrUrl);
  } else if (!isDocumentUriBook(book)) {
    lines.add(book.pathOrUrl);
  }
  return lines.join('\n');
}

String _shareFileName(rs.BookshelfEntry book, String? sourceName) {
  final fallbackBase = book.title.trim().isEmpty
      ? 'velora_book'
      : book.title.trim();
  final candidate =
      (sourceName?.trim().isNotEmpty == true
              ? sourceName!.trim()
              : fallbackBase)
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  if (candidate.contains('.')) return candidate;
  final format = _formatLabel(book.kind).toLowerCase();
  return '$candidate.$format';
}

String _shareMimeType(rs.BookshelfEntry book, String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.txt')) return 'text/plain';
  if (lower.endsWith('.epub')) return 'application/epub+zip';
  if (lower.endsWith('.mobi')) return 'application/x-mobipocket-ebook';
  if (lower.endsWith('.azw3')) return 'application/vnd.amazon.ebook';
  final format = _formatLabel(book.kind).toLowerCase();
  return switch (format) {
    'txt' => 'text/plain',
    'epub' => 'application/epub+zip',
    'mobi' => 'application/x-mobipocket-ebook',
    'azw3' => 'application/vnd.amazon.ebook',
    _ => 'application/octet-stream',
  };
}

class _DetailField extends StatelessWidget {
  final String label;
  final String value;

  const _DetailField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, maxLines: 3, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
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
