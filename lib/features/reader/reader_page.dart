import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../app_keys.dart';
import '../../l10n/app_localizations.dart';
import '../../services/document_file.dart';
import '../../services/local_books.dart' as local_books;
import '../../src/rust/api/book_file.dart' as book_file;
import '../../src/rust/api/book_source.dart' as bs;
import '../../src/rust/api/storage.dart' as rs;
import '../../state/bookshelf.dart';
import '../../state/settings.dart';
import '../../theme/app_theme.dart';
import '../../theme/motion.dart';
import '../../widgets/page_turn.dart';
import 'book_meta_codec.dart';
import 'reader_bookmarks.dart';
import 'paginator.dart';

class ReaderPage extends ConsumerStatefulWidget {
  final String bookId;
  final rs.BookshelfEntry? initialBook;

  const ReaderPage({super.key, required this.bookId, this.initialBook});

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderChapter {
  final String title;
  final BigInt start;
  final BigInt end;
  final String? url;

  const _ReaderChapter({
    required this.title,
    required this.start,
    required this.end,
    this.url,
  });

  factory _ReaderChapter.fromBook(book_file.BookChapter chapter) {
    return _ReaderChapter(
      title: chapter.title,
      start: chapter.start,
      end: chapter.end,
    );
  }

  factory _ReaderChapter.fromOnline(bs.TocEntry chapter) {
    return _ReaderChapter(
      title: chapter.title,
      start: BigInt.zero,
      end: BigInt.zero,
      url: chapter.url,
    );
  }
}

class _ReaderPerfBudget {
  final int initialPages;
  final int appendPages;
  final int preloadTrigger;

  const _ReaderPerfBudget({
    required this.initialPages,
    required this.appendPages,
    required this.preloadTrigger,
  });
}

class _ReaderChapterCache {
  final String text;
  final List<PageSlice> pages;
  final int nextOffset;
  final bool hasMore;
  final int lastPageIndex;

  const _ReaderChapterCache({
    required this.text,
    required this.pages,
    required this.nextOffset,
    required this.hasMore,
    required this.lastPageIndex,
  });
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  rs.BookshelfEntry? _book;
  List<_ReaderChapter> _chapters = const [];
  List<int>? _bookBytes;
  String _chapterText = '';
  List<PageSlice> _pageSlices = const [];
  int _nextOffset = 0;
  int _chapterIndex = 0;
  int _pageIndex = 0;
  bool _hasMorePages = false;
  bool _showOverlay = false;
  bool _loadingChapter = true;
  bool _loadingMore = false;
  String? _error;
  final GlobalKey<PageTurnViewState> _viewKey = GlobalKey<PageTurnViewState>();
  final LinkedHashMap<int, _ReaderChapterCache> _chapterCache = LinkedHashMap();
  Timer? _saveTimer;
  double _loadingProgress = 0.02;
  String _loadingDetail = '';
  bool _openingComplete = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _updateLoadingProgress(0.06, detail: widget.initialBook?.title ?? '');
      await ref.read(bookshelfProvider.notifier).refresh();
      final entries = ref.read(bookshelfProvider).value ?? const [];
      final book = _resolveBook(entries);
      if (book == null) {
        setState(() {
          _error = '书籍不存在或已被移除';
          _loadingChapter = false;
        });
        return;
      }
      setState(() {
        _book = book;
        _error = null;
        _loadingChapter = true;
      });
      _updateLoadingProgress(0.14, detail: book.title);
      if (book.kind == 'online') {
        await _loadOnlineBook(book);
      } else {
        await _loadLocalBook(book);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loadingChapter = false;
      });
    }
  }

  rs.BookshelfEntry? _resolveBook(List<rs.BookshelfEntry> entries) {
    final ids = <String>{
      if (widget.bookId.isNotEmpty) widget.bookId,
      if (widget.bookId.isNotEmpty) Uri.decodeComponent(widget.bookId),
      if (widget.initialBook != null) widget.initialBook!.id,
    };
    for (final id in ids) {
      final index = entries.indexWhere((book) => book.id == id);
      if (index >= 0) return entries[index];
    }
    final initial = widget.initialBook;
    if (initial != null) {
      final index = entries.indexWhere(
        (book) =>
            book.pathOrUrl == initial.pathOrUrl && book.title == initial.title,
      );
      if (index >= 0) return entries[index];
      return initial;
    }
    return null;
  }

  Future<void> _loadLocalBook(rs.BookshelfEntry book) async {
    final syncedBook = await _refreshLocalBookIfNeeded(book);
    book_file.BookMeta? meta = decodeBookMeta(syncedBook.bookMetaJson);
    if (local_books.isDocumentUriBook(syncedBook)) {
      final bytes =
          _bookBytes ??
          await DocumentFileChannel.readBytes(syncedBook.pathOrUrl);
      _bookBytes = bytes;
      _updateLoadingProgress(0.24, detail: syncedBook.title);
      meta ??= book_file.openBookBytes(
        locator: syncedBook.pathOrUrl,
        title: syncedBook.title,
        bytes: bytes,
      );
    } else {
      _bookBytes = null;
      _updateLoadingProgress(0.24, detail: syncedBook.title);
      meta ??= book_file.openBookFile(path: syncedBook.pathOrUrl);
    }
    final resolvedMeta = meta;
    await _persistBookMetaIfNeeded(syncedBook, resolvedMeta);
    final chapters = resolvedMeta.chapters
        .map(_ReaderChapter.fromBook)
        .toList(growable: false);
    if (chapters.isEmpty) throw StateError('目录为空');
    if (!mounted) return;
    setState(() {
      _book = syncedBook;
      _chapters = chapters;
      _chapterIndex = syncedBook.lastChapter
          .clamp(0, chapters.length - 1)
          .toInt();
    });
    _updateLoadingProgress(0.4, detail: chapters[_chapterIndex].title);
    await _loadChapter(
      _chapterIndex,
      initialPageIndex: syncedBook.lastOffset.toInt(),
    );
  }

  Future<rs.BookshelfEntry> _refreshLocalBookIfNeeded(
    rs.BookshelfEntry book,
  ) async {
    final refreshed = await local_books.refreshLocalBookEntry(book);
    if (refreshed == null) return book;
    await ref.read(bookshelfProvider.notifier).upsert(refreshed);
    return refreshed;
  }

  Future<void> _loadOnlineBook(rs.BookshelfEntry book) async {
    final sourceJson = book.sourceJson;
    final tocUrl = book.tocUrl;
    if (sourceJson == null ||
        sourceJson.isEmpty ||
        tocUrl == null ||
        tocUrl.isEmpty) {
      throw StateError('在线书籍缺少书源或目录地址');
    }
    final toc = await bs.sourceToc(sourceJson: sourceJson, tocUrl: tocUrl);
    final chapters = toc.map(_ReaderChapter.fromOnline).toList(growable: false);
    if (chapters.isEmpty) throw StateError('目录为空');
    if (!mounted) return;
    setState(() {
      _chapters = chapters;
      _chapterIndex = book.lastChapter.clamp(0, chapters.length - 1).toInt();
    });
    _updateLoadingProgress(0.32, detail: chapters[_chapterIndex].title);
    await _loadChapter(
      _chapterIndex,
      initialPageIndex: book.lastOffset.toInt(),
    );
  }

  Future<void> _persistBookMetaIfNeeded(
    rs.BookshelfEntry book,
    book_file.BookMeta meta,
  ) async {
    final signature = decodeBookSourceSignature(book.bookMetaJson);
    final encoded = encodeBookMeta(
      meta,
      sourceSizeBytes: signature.sizeBytes,
      sourceModifiedAtMillis: signature.modifiedAtMillis,
    );
    final nextCover = local_books.resolveStoredBookCover(
      currentCover: book.cover,
      embeddedCover: meta.coverDataUrl,
      onlineCover: null,
    );
    if (book.bookMetaJson == encoded && book.cover == nextCover) return;
    await ref
        .read(bookshelfProvider.notifier)
        .upsert(
          rs.BookshelfEntry(
            id: book.id,
            title: book.title,
            author: book.author,
            kind: book.kind,
            pathOrUrl: book.pathOrUrl,
            bookMetaJson: encoded,
            cover: nextCover,
            lastChapter: book.lastChapter,
            lastOffset: book.lastOffset,
            updatedAt: book.updatedAt,
            sourceName: book.sourceName,
            sourceJson: book.sourceJson,
            tocUrl: book.tocUrl,
          ),
        );
  }

  Future<void> _loadChapter(int index, {int initialPageIndex = 0}) async {
    if (index < 0 || index >= _chapters.length) return;
    final book = _book;
    if (book == null) return;
    _rememberChapterCache(_chapterIndex);
    final cached = _chapterCache[index];
    final targetPageIndex = _resolveRequestedPageIndex(
      initialPageIndex,
      cached,
    );
    setState(() {
      _loadingChapter = true;
      _chapterIndex = index;
      _pageIndex = 0;
      _pageSlices = const [];
      _nextOffset = 0;
      _hasMorePages = false;
    });
    _updateLoadingProgress(
      _openingComplete ? 0.16 : 0.48,
      detail: _chapters[index].title,
    );
    if (cached != null) {
      _chapterText = cached.text;
      _pageSlices = [...cached.pages];
      _nextOffset = cached.nextOffset;
      _hasMorePages = cached.hasMore;
      await _repaginate(
        targetPageIndex: targetPageIndex,
        repaginatingExisting: true,
      );
      return;
    }
    final chapter = _chapters[index];
    final content = await _chapterContent(book, chapter);
    if (!mounted) return;
    _chapterText = '${chapter.title}\n\n$content';
    _updateLoadingProgress(
      _openingComplete ? 0.34 : 0.6,
      detail: chapter.title,
    );
    await _repaginate(targetPageIndex: targetPageIndex);
  }

  Future<String> _chapterContent(
    rs.BookshelfEntry book,
    _ReaderChapter chapter,
  ) async {
    if (book.kind == 'online') {
      final sourceJson = book.sourceJson;
      final url = chapter.url;
      if (sourceJson == null ||
          sourceJson.isEmpty ||
          url == null ||
          url.isEmpty) {
        throw StateError('章节缺少在线地址');
      }
      return bs.sourceChapterContent(sourceJson: sourceJson, chapterUrl: url);
    }
    if (_isDocumentUriBook(book)) {
      final bytes =
          _bookBytes ?? await DocumentFileChannel.readBytes(book.pathOrUrl);
      _bookBytes = bytes;
      return book_file.readBookChapterBytes(
        locator: book.pathOrUrl,
        title: book.title,
        bytes: bytes,
        start: chapter.start,
        end: chapter.end,
      );
    }
    return book_file.readBookChapterFile(
      path: book.pathOrUrl,
      start: chapter.start,
      end: chapter.end,
    );
  }

  bool _isDocumentUriBook(rs.BookshelfEntry book) {
    return local_books.isDocumentUriBook(book);
  }

  Future<void> _repaginate({
    required int targetPageIndex,
    bool repaginatingExisting = false,
  }) async {
    if (!repaginatingExisting) {
      _pageSlices = const [];
      _nextOffset = 0;
      _hasMorePages = _chapterText.isNotEmpty;
    }
    await _ensurePagesFor(
      targetPageIndex,
      onProgress: (ratio) {
        final start = _openingComplete ? 0.34 : 0.6;
        final span = _openingComplete ? 0.58 : 0.36;
        _updateLoadingProgress(
          start + span * ratio,
          detail: _chapters[_chapterIndex].title,
        );
      },
    );
    if (!mounted) return;
    final bounded = _pageSlices.isEmpty
        ? 0
        : targetPageIndex.clamp(0, _pageSlices.length - 1).toInt();
    setState(() {
      _pageIndex = bounded;
      _loadingChapter = false;
      _loadingProgress = 1;
      _openingComplete = true;
    });
    _rememberChapterCache(_chapterIndex);
    _viewKey.currentState?.jumpTo(bounded);
  }

  Future<void> _ensurePagesFor(
    int targetPageIndex, {
    ValueChanged<double>? onProgress,
  }) async {
    if (_chapterText.isEmpty) return;
    final budget = _budget();
    final required = (targetPageIndex + budget.preloadTrigger + 1).clamp(
      budget.initialPages,
      1 << 20,
    );
    while (_pageSlices.length < required && _hasMorePages) {
      final paginator = _buildPaginator(ref.read(settingsProvider));
      final window = paginator.paginateWindow(
        _chapterText,
        startOffset: _nextOffset,
        maxPages: (required - _pageSlices.length).clamp(1, 6),
      );
      _pageSlices = [..._pageSlices, ...window.pages];
      _nextOffset = window.nextOffset;
      _hasMorePages = window.hasMore;
      onProgress?.call(
        required == 0
            ? 1
            : (_pageSlices.length / required).clamp(0, 1).toDouble(),
      );
      if (window.pages.isEmpty) break;
      if (_pageSlices.length < required && _hasMorePages) {
        await SchedulerBinding.instance.endOfFrame;
      }
    }
  }

  Future<bool> _appendMorePages() async {
    if (_loadingMore || !_hasMorePages || _chapterText.isEmpty) return false;
    _loadingMore = true;
    try {
      final budget = _budget();
      final paginator = _buildPaginator(ref.read(settingsProvider));
      final window = paginator.paginateWindow(
        _chapterText,
        startOffset: _nextOffset,
        maxPages: budget.appendPages,
      );
      if (!mounted) return false;
      setState(() {
        _pageSlices = [..._pageSlices, ...window.pages];
        _nextOffset = window.nextOffset;
        _hasMorePages = window.hasMore;
      });
      _rememberChapterCache(_chapterIndex);
      return window.pages.isNotEmpty;
    } finally {
      _loadingMore = false;
    }
  }

  _ReaderPerfBudget _budget() {
    final cores = Platform.numberOfProcessors;
    final initialPages = cores >= 10
        ? 18
        : cores >= 8
        ? 14
        : 10;
    final appendPages = cores >= 10
        ? 10
        : cores >= 8
        ? 8
        : 6;
    return _ReaderPerfBudget(
      initialPages: initialPages,
      appendPages: appendPages,
      preloadTrigger: 4,
    );
  }

  TextPaginator _buildPaginator(AppSettings settings) {
    final padding = settings.pagePadding;
    final size = MediaQuery.sizeOf(context);
    final safePadding = MediaQuery.paddingOf(context);
    return TextPaginator(
      style: _readerTextStyle(context, settings),
      maxWidth: (size.width - padding * 2)
          .clamp(160.0, double.infinity)
          .toDouble(),
      maxHeight: (size.height - padding * 2 - safePadding.vertical - 32)
          .clamp(240.0, double.infinity)
          .toDouble(),
    );
  }

  TextStyle _readerTextStyle(BuildContext context, AppSettings settings) {
    final base = Theme.of(context).textTheme.bodyLarge!;
    return AppTheme.readingTextStyle(
      base.copyWith(
        fontSize: settings.fontScale.value,
        height: settings.lineHeight,
      ),
      settings.readerFont,
    );
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () {
      final book = _book;
      if (book == null) return;
      ref
          .read(bookshelfProvider.notifier)
          .updateProgress(book.id, _chapterIndex, BigInt.from(_pageIndex));
    });
  }

  void _onPageChanged(int page) {
    setState(() => _pageIndex = page);
    _rememberChapterCache(_chapterIndex);
    _scheduleSave();
    final budget = _budget();
    if (_pageSlices.length - page <= budget.preloadTrigger) {
      unawaited(_appendMorePages());
    }
  }

  Future<void> _gotoChapter(int index, {int initialPageIndex = 0}) async {
    if (index < 0 || index >= _chapters.length) return;
    await _loadChapter(index, initialPageIndex: initialPageIndex);
  }

  void _updateLoadingProgress(double value, {String? detail}) {
    if (!mounted) return;
    setState(() {
      _loadingProgress = value.clamp(0.02, 1).toDouble();
      if (detail != null) {
        _loadingDetail = detail;
      }
    });
  }

  int _resolveRequestedPageIndex(
    int requestedPageIndex,
    _ReaderChapterCache? cached,
  ) {
    if (cached == null || requestedPageIndex < (1 << 20)) {
      return requestedPageIndex;
    }
    if (cached.pages.isEmpty) {
      return 0;
    }
    if (!cached.hasMore) {
      return cached.pages.length - 1;
    }
    return cached.lastPageIndex;
  }

  void _rememberChapterCache(int chapterIndex) {
    if (_chapterText.isEmpty ||
        _pageSlices.isEmpty ||
        chapterIndex < 0 ||
        chapterIndex >= _chapters.length) {
      return;
    }
    _chapterCache.remove(chapterIndex);
    _chapterCache[chapterIndex] = _ReaderChapterCache(
      text: _chapterText,
      pages: List<PageSlice>.unmodifiable(_pageSlices),
      nextOffset: _nextOffset,
      hasMore: _hasMorePages,
      lastPageIndex: _pageIndex.clamp(0, _pageSlices.length - 1).toInt(),
    );
    while (_chapterCache.length > 3) {
      _chapterCache.remove(_chapterCache.keys.first);
    }
  }

  Future<void> _handleReachEnd() async {
    if (_hasMorePages) {
      final appended = await _appendMorePages();
      if (appended && mounted) {
        _viewKey.currentState?.next();
      }
      return;
    }
    if (_chapterIndex < _chapters.length - 1) {
      await _gotoChapter(_chapterIndex + 1);
    }
  }

  Future<void> _handleReachStart() async {
    if (_chapterIndex <= 0) return;
    final previousIndex = _chapterIndex - 1;
    final cached = _chapterCache[previousIndex];
    final targetPage = cached == null
        ? (1 << 20)
        : _resolveRequestedPageIndex(1 << 20, cached);
    await _gotoChapter(previousIndex, initialPageIndex: targetPage);
  }

  Future<void> _showBookmarks(BuildContext context) async {
    final book = _book;
    if (book == null) return;
    final store = ref.read(readerBookmarksStoreProvider);
    var bookmarks = store.list(book.id);
    final currentId = '$book.id::$_chapterIndex::$_pageIndex';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final hasCurrent = bookmarks.any((item) => item.id == currentId);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        AppLocalizations.of(context).bookmarks,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: () async {
                          if (hasCurrent) {
                            bookmarks = await store.remove(currentId, book.id);
                          } else {
                            bookmarks = await store.add(
                              bookId: book.id,
                              bookTitle: book.title,
                              chapterIndex: _chapterIndex,
                              chapterTitle: _chapters[_chapterIndex].title,
                              pageIndex: _pageIndex,
                              preview: _pageSlices[_pageIndex].text
                                  .replaceAll('\n', ' ')
                                  .trim(),
                            );
                          }
                          setModalState(() {});
                        },
                        icon: Icon(
                          hasCurrent
                              ? Icons.bookmark_remove_outlined
                              : Icons.bookmark_add_outlined,
                        ),
                        label: Text(
                          hasCurrent
                              ? AppLocalizations.of(context).removeBookmark
                              : AppLocalizations.of(context).addBookmark,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (bookmarks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(AppLocalizations.of(context).noBookmarks),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: bookmarks.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final bookmark = bookmarks[index];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              bookmark.chapterTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              bookmark.preview,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                bookmarks = await store.remove(
                                  bookmark.id,
                                  book.id,
                                );
                                setModalState(() {});
                              },
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _gotoChapter(
                                bookmark.chapterIndex,
                                initialPageIndex: bookmark.pageIndex,
                              );
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showToc(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.95,
        builder: (context, controller) => Scrollbar(
          controller: controller,
          thumbVisibility: true,
          interactive: true,
          child: ListView.builder(
            controller: controller,
            itemCount: _chapters.length,
            itemBuilder: (context, index) {
              final chapter = _chapters[index];
              return ListTile(
                leading: Icon(
                  index == _chapterIndex
                      ? Icons.my_location
                      : Icons.notes_outlined,
                ),
                title: Text(
                  chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: index == _chapterIndex,
                onTap: () {
                  Navigator.pop(context);
                  _gotoChapter(index);
                },
              );
            },
          ),
        ),
      ),
    );
  }

  void _showReaderSettings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Consumer(
        builder: (context, ref, child) {
          final settings = ref.watch(settingsProvider);
          final l10n = AppLocalizations.of(context);
          final mediaQuery = MediaQuery.of(context);
          return AnimatedPadding(
            duration: M3Motion.short4,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: mediaQuery.size.height * 0.82,
              ),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  24 + mediaQuery.padding.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.readerSettings,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    Text(l10n.readerFont),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: ReaderFontPreset.values
                          .map(
                            (preset) => ChoiceChip(
                              label: Text(_fontLabel(preset)),
                              selected: settings.readerFont == preset,
                              onSelected: (_) {
                                ref
                                    .read(settingsProvider.notifier)
                                    .update(
                                      (previous) =>
                                          previous.copyWith(readerFont: preset),
                                    );
                                unawaited(
                                  _repaginate(targetPageIndex: _pageIndex),
                                );
                              },
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 16),
                    Text(l10n.fontSize),
                    Slider(
                      min: 14,
                      max: 28,
                      divisions: 14,
                      value: settings.fontScale.value,
                      label: '${settings.fontScale.value.toInt()}',
                      onChanged: (value) {
                        final scale = value <= 17
                            ? ReaderFontScale.small
                            : value <= 19
                            ? ReaderFontScale.normal
                            : value <= 21
                            ? ReaderFontScale.large
                            : ReaderFontScale.xLarge;
                        ref
                            .read(settingsProvider.notifier)
                            .update(
                              (previous) => previous.copyWith(fontScale: scale),
                            );
                        unawaited(_repaginate(targetPageIndex: _pageIndex));
                      },
                    ),
                    Text(l10n.lineHeight),
                    Slider(
                      min: 1.2,
                      max: 2.4,
                      divisions: 12,
                      value: settings.lineHeight,
                      label: settings.lineHeight.toStringAsFixed(2),
                      onChanged: (value) {
                        ref
                            .read(settingsProvider.notifier)
                            .update(
                              (previous) =>
                                  previous.copyWith(lineHeight: value),
                            );
                        unawaited(_repaginate(targetPageIndex: _pageIndex));
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.keepScreenOn),
                      value: settings.keepScreenOn,
                      onChanged: (value) {
                        ref
                            .read(settingsProvider.notifier)
                            .update(
                              (previous) =>
                                  previous.copyWith(keepScreenOn: value),
                            );
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(l10n.pageTurnEffect),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: PageTurnEffect.values
                          .map(
                            (effect) => ChoiceChip(
                              label: Text(_effectLabel(context, effect)),
                              selected: settings.pageTurnEffect == effect,
                              onSelected: (_) => ref
                                  .read(settingsProvider.notifier)
                                  .update(
                                    (previous) => previous.copyWith(
                                      pageTurnEffect: effect,
                                    ),
                                  ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _effectLabel(BuildContext context, PageTurnEffect effect) {
    final l10n = AppLocalizations.of(context);
    return switch (effect) {
      PageTurnEffect.slide => l10n.effectSlide,
      PageTurnEffect.cover => l10n.effectCover,
      PageTurnEffect.curl => l10n.effectCurl,
      PageTurnEffect.fade => l10n.effectFade,
      PageTurnEffect.scroll => l10n.effectScroll,
    };
  }

  String _fontLabel(ReaderFontPreset preset) {
    return switch (preset) {
      ReaderFontPreset.notoSerif => 'Noto Serif SC',
      ReaderFontPreset.notoSans => 'Noto Sans SC',
      ReaderFontPreset.literata => 'Literata',
      ReaderFontPreset.merriweather => 'Merriweather',
      ReaderFontPreset.lora => 'Lora',
    };
  }

  String _pageCountLabel() {
    final total = _pageSlices.length;
    final suffix = _hasMorePages ? '+' : '';
    return '${_pageIndex + 1} / $total$suffix';
  }

  void _openAppSettings() {
    setState(() => _showOverlay = false);
    context.go('/settings');
  }

  Future<void> _shareCurrentBook(BuildContext originContext) async {
    final book = _book;
    if (book == null) return;
    final l10n = AppLocalizations.of(context);
    final sharePositionOrigin = _sharePositionOrigin(originContext);
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

  Rect? _sharePositionOrigin(BuildContext originContext) {
    final renderBox = originContext.findRenderObject() as RenderBox?;
    return renderBox == null
        ? null
        : renderBox.localToGlobal(Offset.zero) & renderBox.size;
  }

  Future<(List<XFile>, List<String>?)?> _shareFilesForBook(
    rs.BookshelfEntry book,
  ) async {
    if (!local_books.isManagedOfflineBook(book) || Platform.isLinux) {
      return null;
    }
    if (local_books.isDocumentUriBook(book)) {
      final source = await local_books.describeLocalBook(book);
      final fileName = _shareFileName(book, source?.name);
      return (
        [
          XFile.fromData(
            await DocumentFileChannel.readBytes(book.pathOrUrl),
            mimeType: _shareMimeType(book, fileName),
          ),
        ],
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

  String _shareTextForBook(rs.BookshelfEntry book) {
    final lines = <String>[book.title];
    if (book.author.trim().isNotEmpty) {
      lines.add(book.author.trim());
    }
    if (book.kind == 'online') {
      lines.add(book.pathOrUrl);
    } else if (!local_books.isDocumentUriBook(book)) {
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
    final format = book.kind.replaceAll('_uri', '').trim().toLowerCase();
    return '$candidate.${format.isEmpty ? 'book' : format}';
  }

  String _shareMimeType(rs.BookshelfEntry book, String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.epub')) return 'application/epub+zip';
    if (lower.endsWith('.mobi')) return 'application/x-mobipocket-ebook';
    if (lower.endsWith('.azw3')) return 'application/vnd.amazon.ebook';
    final format = book.kind.replaceAll('_uri', '').trim().toLowerCase();
    return switch (format) {
      'txt' => 'text/plain',
      'epub' => 'application/epub+zip',
      'mobi' => 'application/x-mobipocket-ebook',
      'azw3' => 'application/vnd.amazon.ebook',
      _ => 'application/octet-stream',
    };
  }

  void _leaveReader() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      context.go('/bookshelf');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;

    if (_error != null) {
      return PopScope(
        canPop: Navigator.of(context).canPop(),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) context.go('/bookshelf');
        },
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _leaveReader,
            ),
          ),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _leaveReader,
                    icon: const Icon(Icons.arrow_back),
                    label: Text(AppLocalizations.of(context).backToBookshelf),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (_book == null ||
        _chapters.isEmpty ||
        _loadingChapter ||
        _pageSlices.isEmpty) {
      return PopScope(
        canPop: Navigator.of(context).canPop(),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) context.go('/bookshelf');
        },
        child: _ReaderLoadingScaffold(
          heroTag: _openingComplete
              ? null
              : (_book?.id ?? widget.initialBook?.id ?? widget.bookId),
          title: _book?.title ?? widget.initialBook?.title ?? '',
          author: _book?.author ?? widget.initialBook?.author ?? '',
          detail: _loadingDetail,
          label: _openingComplete
              ? AppLocalizations.of(context).loadingChapterLabel
              : AppLocalizations.of(context).openingBook,
          progress: _loadingProgress,
        ),
      );
    }

    final effect = switch (settings.pageTurnEffect) {
      PageTurnEffect.slide => PageTurnEffectType.slide,
      PageTurnEffect.cover => PageTurnEffectType.cover,
      PageTurnEffect.curl => PageTurnEffectType.curl,
      PageTurnEffect.fade => PageTurnEffectType.fade,
      PageTurnEffect.scroll => PageTurnEffectType.scroll,
    };

    final reader = PageTurnView(
      key: _viewKey,
      pageCount: _pageSlices.length,
      initialPage: _pageIndex,
      effect: effect,
      onPageChanged: _onPageChanged,
      onReachEnd: () => unawaited(_handleReachEnd()),
      onReachStart: () => unawaited(_handleReachStart()),
      pageBuilder: (context, index) => _ReaderPageView(
        text: _pageSlices[index].text,
        textStyle: _readerTextStyle(context, settings),
        padding: settings.pagePadding,
        backgroundColor: colorScheme.surface,
        footer: _ReaderFooter(
          chapterTitle: _chapters[_chapterIndex].title,
          pageLabel: _pageCountLabel(),
        ),
      ),
    );

    return PopScope(
      canPop: Navigator.of(context).canPop(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/bookshelf');
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        body: Stack(
          children: [
            ReaderTapRegion(
              onTapCenter: () => setState(() => _showOverlay = !_showOverlay),
              child: KeyedSubtree(key: AppKeys.readerViewport, child: reader),
            ),
            AnimatedSwitcher(
              duration: M3Motion.medium2,
              switchInCurve: M3Motion.emphasizedDecelerate,
              switchOutCurve: M3Motion.emphasizedAccelerate,
              child: _showOverlay
                  ? _ReaderOverlay(
                      key: AppKeys.readerOverlay,
                      title: _book!.title,
                      chapterIndex: _chapterIndex,
                      chapterCount: _chapters.length,
                      pageIndex: _pageIndex,
                      pageCount: _pageSlices.length,
                      hasMorePages: _hasMorePages,
                      onBack: _leaveReader,
                      onPrevChapter: () => _gotoChapter(_chapterIndex - 1),
                      onNextChapter: () => _gotoChapter(_chapterIndex + 1),
                      onShowToc: () => _showToc(context),
                      onShowBookmarks: () => _showBookmarks(context),
                      onShare: (shareContext) =>
                          _shareCurrentBook(shareContext),
                      onClose: () => setState(() => _showOverlay = false),
                      onShowReaderSettings: () => _showReaderSettings(context),
                      onOpenAppSettings: _openAppSettings,
                      onJumpToPage: (page) =>
                          _viewKey.currentState?.jumpTo(page),
                    )
                  : const SizedBox.shrink(),
            ),
            if (_loadingMore)
              Positioned(
                right: 16,
                bottom: 112,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainer.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReaderPageView extends StatelessWidget {
  final String text;
  final TextStyle textStyle;
  final double padding;
  final Color backgroundColor;
  final Widget footer;

  const _ReaderPageView({
    required this.text,
    required this.textStyle,
    required this.padding,
    required this.backgroundColor,
    required this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: AppKeys.readerPageBody,
      color: backgroundColor,
      padding: EdgeInsets.fromLTRB(
        padding,
        padding + MediaQuery.paddingOf(context).top,
        padding,
        padding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: Text(text, style: textStyle)),
          footer,
        ],
      ),
    );
  }
}

class _ReaderFooter extends StatelessWidget {
  final String chapterTitle;
  final String pageLabel;

  const _ReaderFooter({required this.chapterTitle, required this.pageLabel});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              chapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            pageLabel,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReaderOverlay extends StatelessWidget {
  final String title;
  final int chapterIndex;
  final int chapterCount;
  final int pageIndex;
  final int pageCount;
  final bool hasMorePages;
  final VoidCallback onBack;
  final VoidCallback onPrevChapter;
  final VoidCallback onNextChapter;
  final VoidCallback onShowToc;
  final VoidCallback onShowBookmarks;
  final ValueChanged<BuildContext> onShare;
  final VoidCallback onShowReaderSettings;
  final VoidCallback onOpenAppSettings;
  final VoidCallback onClose;
  final ValueChanged<int> onJumpToPage;

  const _ReaderOverlay({
    super.key,
    required this.title,
    required this.chapterIndex,
    required this.chapterCount,
    required this.pageIndex,
    required this.pageCount,
    required this.hasMorePages,
    required this.onBack,
    required this.onPrevChapter,
    required this.onNextChapter,
    required this.onShowToc,
    required this.onShowBookmarks,
    required this.onShare,
    required this.onShowReaderSettings,
    required this.onOpenAppSettings,
    required this.onClose,
    required this.onJumpToPage,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final maxPage = (pageCount - 1).clamp(0, 1 << 20).toDouble();
    final value = pageIndex.toDouble().clamp(0, maxPage).toDouble();
    final chapterLabel = '${chapterIndex + 1} / $chapterCount';
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Material(
            color: colorScheme.surfaceContainer.withValues(alpha: 0.96),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: onBack,
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          chapterLabel,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.close), onPressed: onClose),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Material(
            color: colorScheme.surfaceContainer.withValues(alpha: 0.96),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      TextButton(
                        onPressed: onPrevChapter,
                        child: Text(l10n.prevChapter),
                      ),
                      Expanded(
                        child: Slider(
                          min: 0,
                          max: maxPage,
                          value: value,
                          onChanged: pageCount <= 1
                              ? null
                              : (next) => onJumpToPage(next.round()),
                        ),
                      ),
                      Text(
                        hasMorePages
                            ? '${pageIndex + 1} / $pageCount+'
                            : '${pageIndex + 1} / $pageCount',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: onNextChapter,
                        child: Text(l10n.nextChapter),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        IconButton.filledTonal(
                          key: AppKeys.readerOverlayToc,
                          icon: const Icon(Icons.list),
                          onPressed: onShowToc,
                          tooltip: l10n.tableOfContents,
                        ),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.bookmarks_outlined),
                          onPressed: onShowBookmarks,
                          tooltip: l10n.bookmarks,
                        ),
                        Builder(
                          builder: (shareContext) {
                            return IconButton.filledTonal(
                              icon: const Icon(Icons.share_outlined),
                              onPressed: () => onShare(shareContext),
                              tooltip: l10n.shareBook,
                            );
                          },
                        ),
                        IconButton.filledTonal(
                          key: AppKeys.readerOverlayReaderSettings,
                          icon: const Icon(Icons.tune),
                          onPressed: onShowReaderSettings,
                          tooltip: l10n.readerSettings,
                        ),
                        IconButton.filledTonal(
                          key: AppKeys.readerOverlaySettings,
                          icon: const Icon(Icons.settings_outlined),
                          onPressed: onOpenAppSettings,
                          tooltip: l10n.settings,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReaderLoadingScaffold extends StatefulWidget {
  final Object? heroTag;
  final String title;
  final String author;
  final String label;
  final String detail;
  final double progress;

  const _ReaderLoadingScaffold({
    required this.heroTag,
    required this.title,
    required this.author,
    required this.label,
    required this.detail,
    required this.progress,
  });

  @override
  State<_ReaderLoadingScaffold> createState() => _ReaderLoadingScaffoldState();
}

class _ReaderLoadingScaffoldState extends State<_ReaderLoadingScaffold>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: M3Motion.extraLong2,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final progress = widget.progress.clamp(0.02, 1).toDouble();
    final progressLabel = '${(progress * 100).round()}%';
    final preview = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: AspectRatio(
        aspectRatio: 0.72,
        child: Card(
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        colorScheme.primaryContainer,
                        colorScheme.tertiaryContainer,
                      ],
                    ),
                  ),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        widget.title.isEmpty ? 'Velora' : widget.title,
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title.isEmpty ? 'Velora' : widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.author.isEmpty ? widget.label : widget.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      key: AppKeys.readerLoading,
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            children: [
              const Spacer(),
              if (widget.heroTag != null && '${widget.heroTag}'.isNotEmpty)
                Hero(
                  tag: widget.heroTag!,
                  createRectTween: (begin, end) =>
                      MaterialRectCenterArcTween(begin: begin, end: end),
                  child: preview,
                )
              else
                preview,
              const SizedBox(height: 28),
              Text(widget.label, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                widget.detail.isEmpty ? widget.title : widget.detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress),
                duration: M3Motion.short4,
                curve: M3Motion.standardDecelerate,
                builder: (context, value, child) => Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.label,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        Text(
                          progressLabel,
                          key: AppKeys.readerLoadingPercent,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: colorScheme.primary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        key: AppKeys.readerLoadingProgress,
                        minHeight: 8,
                        value: value,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Expanded(
                flex: 2,
                child: FadeTransition(
                  opacity: Tween<double>(begin: 0.4, end: 1).animate(
                    CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
                  ),
                  child: Column(
                    children: [
                      _ReaderSkeletonLine(
                        widthFactor: 1,
                        color: colorScheme.surfaceContainerHigh,
                      ),
                      const SizedBox(height: 14),
                      _ReaderSkeletonLine(
                        widthFactor: 0.92,
                        color: colorScheme.surfaceContainerHigh,
                      ),
                      const SizedBox(height: 14),
                      _ReaderSkeletonLine(
                        widthFactor: 0.98,
                        color: colorScheme.surfaceContainerHigh,
                      ),
                      const SizedBox(height: 14),
                      _ReaderSkeletonLine(
                        widthFactor: 0.86,
                        color: colorScheme.surfaceContainerHigh,
                      ),
                      const SizedBox(height: 14),
                      _ReaderSkeletonLine(
                        widthFactor: 0.94,
                        color: colorScheme.surfaceContainerHigh,
                      ),
                      const SizedBox(height: 14),
                      _ReaderSkeletonLine(
                        widthFactor: 0.78,
                        color: colorScheme.surfaceContainerHigh,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReaderSkeletonLine extends StatelessWidget {
  final double widthFactor;
  final Color color;

  const _ReaderSkeletonLine({required this.widthFactor, required this.color});

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(999),
        ),
        child: const SizedBox(height: 20),
      ),
    );
  }
}
