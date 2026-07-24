import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
import '../../services/reader_fonts.dart';
import '../../services/rss_source.dart';
import '../../services/source_adapter.dart';
import '../../src/rust/api/book_file.dart' as book_file;
import '../../src/rust/api/book_source.dart' as bs;
import '../../src/rust/api/storage.dart' as rs;
import '../../state/bookshelf.dart';
import '../../state/settings.dart';
import '../../state/sources.dart';
import '../../theme/app_theme.dart';
import '../../theme/motion.dart';
import '../../widgets/page_turn.dart';
import 'android_static_layout.dart';
import 'book_meta_codec.dart';
import 'reader_bookmarks.dart';
import 'reader_layout.dart';
import 'reader_page_cache.dart';
import 'reader_page_content.dart';
import 'rich_reader_content.dart';
import 'paginator.dart';
import '../settings/reader_font_picker.dart';

class ReaderPage extends ConsumerStatefulWidget {
  final String bookId;
  final rs.BookshelfEntry? initialBook;

  const ReaderPage({super.key, required this.bookId, this.initialBook});

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

@visibleForTesting
Set<String> readerBookIdCandidates(String routedId, String? initialId) => {
  if (routedId.isNotEmpty) routedId,
  ?initialId,
};

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
  final int basePageIndex;
  final int nextOffset;
  final bool hasMore;
  final int lastPageIndex;

  const _ReaderChapterCache({
    required this.text,
    required this.pages,
    required this.basePageIndex,
    required this.nextOffset,
    required this.hasMore,
    required this.lastPageIndex,
  });
}

class _PendingRestoreFeedback {
  final int chapterIndex;
  final int targetPageIndex;
  final int restoredFirstPageIndex;
  final int restoredLastPageIndex;
  final bool usedHotWindow;

  const _PendingRestoreFeedback({
    required this.chapterIndex,
    required this.targetPageIndex,
    required this.restoredFirstPageIndex,
    required this.restoredLastPageIndex,
    required this.usedHotWindow,
  });
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  static const _rss = RssSourceService();
  static const _sourceAdapter = SourceAdapterService();

  rs.BookshelfEntry? _book;
  List<_ReaderChapter> _chapters = const [];
  String _chapterText = '';
  MediaChapterContent? _mediaContent;
  bool _richChapter = false;
  List<PageSlice> _pageSlices = const [];
  int _nextOffset = 0;
  int _chapterIndex = 0;
  int _pageBaseIndex = 0;
  int _pageIndex = 0;
  bool _hasMorePages = false;
  bool _showOverlay = false;
  bool _loadingChapter = true;
  bool _loadingMore = false;
  String? _error;
  final GlobalKey<PageTurnViewState> _viewKey = GlobalKey<PageTurnViewState>();
  final LinkedHashMap<int, _ReaderChapterCache> _chapterCache = LinkedHashMap();
  final Set<int> _prefetchingChapters = <int>{};
  final Set<String> _activeSourceRequests = <String>{};
  final List<_PendingRestoreFeedback> _pendingRestoreFeedback =
      <_PendingRestoreFeedback>[];
  Timer? _saveTimer;
  ReaderPageCacheStore? _pageCacheStore;
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
    _cancelOnlineRequests();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      try {
        final settings = ref.read(settingsProvider);
        await ReaderFonts.prepare(
          ref.read(sharedPreferencesProvider),
          settings.readerFontFamily,
        );
      } catch (_) {
        await ref
            .read(settingsProvider.notifier)
            .update(
              (previous) => previous.copyWith(
                readerFont: ReaderFontPreset.notoSerif,
                readerFontFamily: 'Noto Serif SC',
              ),
            );
      }
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
    final ids = readerBookIdCandidates(widget.bookId, widget.initialBook?.id);
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
    final decodedMeta = decodeBookMetaRecord(syncedBook.bookMetaJson);
    book_file.BookMeta? meta = decodedMeta?.meta;
    final forceTxtReindex =
        !_isDocumentUriBook(syncedBook) &&
        _isTxtBook(syncedBook, meta) &&
        (decodedMeta == null || decodedMeta.schemaVersion < 2);
    if (local_books.isDocumentUriBook(syncedBook)) {
      throw StateError('无法建立本地阅读缓存');
    }
    _updateLoadingProgress(0.24, detail: syncedBook.title);
    if (forceTxtReindex || meta == null) {
      meta = book_file.openBookFile(path: syncedBook.pathOrUrl);
    }
    final resolvedMeta = meta;
    await _persistBookMetaIfNeeded(
      syncedBook,
      resolvedMeta,
      preferredSignature: await _resolveSourceSignature(
        syncedBook,
        decodedMeta?.sourceSignature ?? const BookSourceSignature(),
      ),
    );
    _pageCacheStore = _canUsePersistentPageCache(syncedBook, resolvedMeta)
        ? await ReaderPageCacheStore.open(path: syncedBook.pathOrUrl)
        : null;
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
    _pageCacheStore = null;
    if (RssSourceService.isSyntheticBookUrl(book.pathOrUrl)) {
      await _loadRssBook(book);
      return;
    }
    final sourceJson = book.sourceJson;
    final tocUrl = book.tocUrl;
    if (sourceJson == null ||
        sourceJson.isEmpty ||
        tocUrl == null ||
        tocUrl.isEmpty) {
      throw StateError('在线书籍缺少书源或目录地址');
    }
    final requestId = _sourceAdapter.createRequestId('toc');
    final toc = await _trackOnlineRequest(
      requestId,
      () => _sourceAdapter.toc(sourceJson, tocUrl, requestId: requestId),
    );
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

  Future<void> _loadRssBook(rs.BookshelfEntry book) async {
    final source = decodeBookSourceModelJson(book.sourceJson);
    if (source == null || !source.isRssSource) {
      throw StateError('RSS 书籍缺少可用书源配置');
    }
    final prefs = ref.read(sharedPreferencesProvider);
    final entry = await _rss.ensureEntry(
      prefs,
      source: source,
      syntheticUrl: book.pathOrUrl,
      fallbackUrl: book.tocUrl,
      fallbackTitle: book.title,
    );
    if (entry == null) {
      throw StateError('RSS 条目不存在');
    }
    final chapterUrl = entry.link.trim().isEmpty ? book.tocUrl : entry.link;
    final chapters = [
      _ReaderChapter(
        title: entry.title.trim().isEmpty ? book.title : entry.title,
        start: BigInt.zero,
        end: BigInt.zero,
        url: chapterUrl,
      ),
    ];
    if (!mounted) return;
    setState(() {
      _chapters = chapters;
      _chapterIndex = 0;
    });
    _updateLoadingProgress(0.32, detail: chapters.first.title);
    await _loadChapter(0, initialPageIndex: book.lastOffset.toInt());
  }

  Future<BookSourceSignature> _persistBookMetaIfNeeded(
    rs.BookshelfEntry book,
    book_file.BookMeta meta, {
    BookSourceSignature? preferredSignature,
  }) async {
    final signature =
        preferredSignature ?? decodeBookSourceSignature(book.bookMetaJson);
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
    if (book.bookMetaJson == encoded && book.cover == nextCover) {
      return signature;
    }
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
    return signature;
  }

  Future<BookSourceSignature> _resolveSourceSignature(
    rs.BookshelfEntry book,
    BookSourceSignature current,
  ) async {
    if (book.kind == 'online' || _isDocumentUriBook(book)) {
      return current;
    }
    if (current.sizeBytes != null && current.modifiedAtMillis != null) {
      return current;
    }
    try {
      final stat = await File(book.pathOrUrl).stat();
      return BookSourceSignature(
        sizeBytes: stat.size,
        modifiedAtMillis: stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      return current;
    }
  }

  bool _canUsePersistentPageCache(
    rs.BookshelfEntry book,
    book_file.BookMeta? meta,
  ) {
    return !_isDocumentUriBook(book) && _isTxtBook(book, meta);
  }

  Future<void> _loadChapter(int index, {int initialPageIndex = 0}) async {
    if (index < 0 || index >= _chapters.length) return;
    final book = _book;
    if (book == null) return;
    _rememberChapterCache(_chapterIndex);
    final richBook = _isRichBook(book);
    final cached = richBook ? null : _chapterCache[index];
    final targetPageIndex = _resolveRequestedPageIndex(
      initialPageIndex,
      cached,
    );
    setState(() {
      _loadingChapter = true;
      _chapterIndex = index;
      _pageBaseIndex = 0;
      _pageIndex = 0;
      _pageSlices = const [];
      _nextOffset = 0;
      _hasMorePages = false;
      _mediaContent = null;
      _richChapter = false;
    });
    _updateLoadingProgress(
      _openingComplete ? 0.16 : 0.48,
      detail: _chapters[index].title,
    );
    if (cached != null) {
      _chapterText = cached.text;
      _pageSlices = [...cached.pages];
      _pageBaseIndex = cached.basePageIndex;
      _nextOffset = cached.nextOffset;
      _hasMorePages = cached.hasMore;
      await _repaginate(
        targetPageIndex: targetPageIndex,
        repaginatingExisting: true,
      );
      return;
    }
    final chapter = _chapters[index];
    if (_isAudioBook(book)) {
      _chapterText = chapter.title;
      _mediaContent = MediaChapterContent(audioUrl: book.pathOrUrl);
      _finishRichChapter();
      return;
    }
    final content = await _chapterContent(book, chapter);
    if (!mounted) return;
    if (_isMarkdownBook(book)) {
      _chapterText = content;
      _finishRichChapter();
      return;
    }
    final media =
        MediaChapterContent.decode(content) ??
        _mediaFromSourceType(book, content);
    if (_isComicBook(book) || media != null) {
      _chapterText = content;
      _mediaContent = media ?? MediaChapterContent(images: [content]);
      _finishRichChapter();
      return;
    }
    _chapterText = '${chapter.title}\n\n$content';
    _updateLoadingProgress(
      _openingComplete ? 0.34 : 0.6,
      detail: chapter.title,
    );
    await _repaginate(targetPageIndex: targetPageIndex);
  }

  void _finishRichChapter() {
    final length = _chapterText.length;
    setState(() {
      _richChapter = true;
      _pageSlices = [PageSlice(start: 0, end: length, text: _chapterText)];
      _pageBaseIndex = 0;
      _pageIndex = 0;
      _nextOffset = length;
      _hasMorePages = false;
      _loadingChapter = false;
      _loadingProgress = 1;
      _openingComplete = true;
    });
    _scheduleSave();
  }

  MediaChapterContent? _mediaFromSourceType(
    rs.BookshelfEntry book,
    String content,
  ) {
    if (book.kind != 'online') return null;
    final source = decodeBookSourceModelJson(book.sourceJson);
    if (source == null || !const [1, 2].contains(source.bookSourceType)) {
      return null;
    }
    final urls = RegExp(r'https?://[^\s<>"]+', caseSensitive: false)
        .allMatches(content)
        .map((match) => match.group(0)!)
        .toList(growable: false);
    if (source.bookSourceType == 1) {
      return MediaChapterContent(audioUrl: urls.firstOrNull ?? content.trim());
    }
    return MediaChapterContent(images: urls.isEmpty ? [content.trim()] : urls);
  }

  Future<String> _chapterContent(
    rs.BookshelfEntry book,
    _ReaderChapter chapter,
  ) async {
    if (book.kind == 'online') {
      if (RssSourceService.isSyntheticBookUrl(book.pathOrUrl)) {
        final source = decodeBookSourceModelJson(book.sourceJson);
        if (source == null || !source.isRssSource) {
          throw StateError('RSS 章节缺少可用书源配置');
        }
        return _rss.loadReadableContent(
          ref.read(sharedPreferencesProvider),
          source: source,
          syntheticUrl: book.pathOrUrl,
          fallbackUrl: chapter.url ?? book.tocUrl,
          fallbackTitle: chapter.title,
        );
      }
      final sourceJson = book.sourceJson;
      final url = chapter.url;
      if (sourceJson == null ||
          sourceJson.isEmpty ||
          url == null ||
          url.isEmpty) {
        throw StateError('章节缺少在线地址');
      }
      final requestId = _sourceAdapter.createRequestId('content');
      return _trackOnlineRequest(
        requestId,
        () => _sourceAdapter.chapterContent(
          sourceJson,
          url,
          requestId: requestId,
        ),
      );
    }
    if (_isDocumentUriBook(book)) {
      throw StateError('无法建立本地阅读缓存');
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

  bool _isTxtBook(rs.BookshelfEntry book, book_file.BookMeta? meta) {
    final format = ((meta?.format ?? book.kind).replaceAll(
      '_uri',
      '',
    )).trim().toLowerCase();
    return format == 'txt';
  }

  String _bookFormat(rs.BookshelfEntry book) =>
      book.kind.replaceAll('_uri', '').trim().toLowerCase();

  bool _isMarkdownBook(rs.BookshelfEntry book) =>
      const {'md', 'markdown'}.contains(_bookFormat(book));

  bool _isComicBook(rs.BookshelfEntry book) =>
      const {'cbz', 'zip'}.contains(_bookFormat(book));

  bool _isAudioBook(rs.BookshelfEntry book) => const {
    'mp3',
    'm4a',
    'aac',
    'ogg',
    'opus',
    'wav',
    'flac',
  }.contains(_bookFormat(book));

  bool _isRichBook(rs.BookshelfEntry book) =>
      _isMarkdownBook(book) || _isComicBook(book) || _isAudioBook(book);

  Future<void> _repaginate({
    required int targetPageIndex,
    bool repaginatingExisting = false,
  }) async {
    final settings = ref.read(settingsProvider);
    if (!repaginatingExisting) {
      _pageSlices = const [];
      _pageBaseIndex = 0;
      _nextOffset = 0;
      _hasMorePages = _chapterText.isNotEmpty;
      await _restorePersistedPageCache(
        settings,
        targetPageIndex: targetPageIndex,
      );
    }
    await _ensurePagesFor(
      targetPageIndex,
      settings: settings,
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
        : (targetPageIndex - _pageBaseIndex)
              .clamp(0, _pageSlices.length - 1)
              .toInt();
    setState(() {
      _pageIndex = bounded;
      _loadingChapter = false;
      _loadingProgress = 1;
      _openingComplete = true;
    });
    _rememberChapterCache(_chapterIndex);
    unawaited(_persistCurrentPageCache());
    unawaited(_prefetchAround(_chapterIndex));
    unawaited(_prebindNativeNeighborPages(bounded));
    _viewKey.currentState?.jumpTo(bounded);
  }

  Future<void> _ensurePagesFor(
    int targetPageIndex, {
    ValueChanged<double>? onProgress,
    AppSettings? settings,
  }) async {
    if (_chapterText.isEmpty) return;
    final budget = _budget();
    final AppSettings effectiveSettings =
        settings ?? ref.read(settingsProvider);
    final required = (targetPageIndex + budget.preloadTrigger + 1).clamp(
      budget.initialPages,
      1 << 20,
    );
    while (_pageBaseIndex + _pageSlices.length < required && _hasMorePages) {
      final window = await _paginateWindow(
        _chapterText,
        settings: effectiveSettings,
        startOffset: _nextOffset,
        maxPages: (required - (_pageBaseIndex + _pageSlices.length)).clamp(
          1,
          6,
        ),
      );
      _pageSlices = [..._pageSlices, ...window.pages];
      _nextOffset = window.nextOffset;
      _hasMorePages = window.hasMore;
      onProgress?.call(
        required == 0
            ? 1
            : ((_pageBaseIndex + _pageSlices.length) / required)
                  .clamp(0, 1)
                  .toDouble(),
      );
      if (window.pages.isEmpty) break;
      if (_pageBaseIndex + _pageSlices.length < required && _hasMorePages) {
        await SchedulerBinding.instance.endOfFrame;
      }
    }
  }

  Future<bool> _appendMorePages() async {
    if (_loadingMore || !_hasMorePages || _chapterText.isEmpty) return false;
    _loadingMore = true;
    try {
      final budget = _budget();
      final settings = ref.read(settingsProvider);
      final window = await _paginateWindow(
        _chapterText,
        settings: settings,
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
      unawaited(_persistCurrentPageCache());
      unawaited(_prebindNativeNeighborPages(_pageIndex));
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

  TextPaginator _buildPaginator(
    AppSettings settings, {
    ReaderLayoutSpec? layoutSpec,
  }) {
    final spec = layoutSpec ?? _buildLayoutSpec(settings);
    return TextPaginator(
      style: _readerTextStyle(context, settings),
      maxWidth: spec.maxWidth,
      maxHeight: spec.maxHeight,
    );
  }

  ReaderLayoutSpec _buildLayoutSpec(AppSettings settings) {
    final padding = settings.pagePadding;
    final size = MediaQuery.sizeOf(context);
    final safePadding = MediaQuery.paddingOf(context);
    final style = _readerTextStyle(context, settings);
    final colorScheme = Theme.of(context).colorScheme;
    return ReaderLayoutSpec(
      // Android platform views detach and reattach when they move between the
      // two layers of a page-turn animation, which exposes a blank frame. Keep
      // animated text in Flutter's scene so pagination and painting are stable.
      rendererKind: ReaderRendererKind.flutterSegments,
      maxWidth: (size.width - padding * 2)
          .clamp(160.0, double.infinity)
          .toDouble(),
      maxHeight: (size.height - padding * 2 - safePadding.vertical - 32)
          .clamp(240.0, double.infinity)
          .toDouble(),
      fontSize: style.fontSize ?? settings.fontScale.value,
      lineHeight: style.height ?? settings.lineHeight,
      fontFamilyKey: settings.readerFontFamily,
      textColor: style.color ?? colorScheme.onSurface,
      backgroundColor: colorScheme.surface,
    );
  }

  Future<PageSliceWindow> _paginateWindow(
    String text, {
    required AppSettings settings,
    required int startOffset,
    required int maxPages,
  }) async {
    final layoutSpec = _buildLayoutSpec(settings);
    if (layoutSpec.isAndroidStaticLayout) {
      try {
        return await AndroidStaticLayoutPaginator.paginateWindow(
          text: text,
          startOffset: startOffset,
          maxPages: maxPages,
          layout: layoutSpec,
        );
      } catch (_) {}
    }
    final paginator = _buildPaginator(settings, layoutSpec: layoutSpec);
    return paginator.paginateWindow(
      text,
      startOffset: startOffset,
      maxPages: maxPages,
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
      fontFamily: settings.readerFontFamily,
    );
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () async {
      final book = _book;
      if (book == null) return;
      await ref
          .read(bookshelfProvider.notifier)
          .updateProgress(
            book.id,
            _chapterIndex,
            BigInt.from(_absolutePageIndex()),
          );
      await _persistCurrentPageCache();
    });
  }

  void _onPageChanged(int page) {
    setState(() => _pageIndex = page);
    _rememberChapterCache(_chapterIndex);
    _scheduleSave();
    unawaited(_prebindNativeNeighborPages(page));
    final budget = _budget();
    if (_pageSlices.length - page <= budget.preloadTrigger) {
      unawaited(_appendMorePages());
    }
  }

  Future<void> _gotoChapter(int index, {int initialPageIndex = 0}) async {
    if (index < 0 || index >= _chapters.length) return;
    _cancelOnlineRequests();
    try {
      await _loadChapter(index, initialPageIndex: initialPageIndex);
    } on SourceRequestFailure catch (error) {
      if (!error.isCancelled) rethrow;
    }
  }

  Future<T> _trackOnlineRequest<T>(
    String requestId,
    Future<T> Function() request,
  ) async {
    _activeSourceRequests.add(requestId);
    try {
      return await request();
    } finally {
      _activeSourceRequests.remove(requestId);
    }
  }

  void _cancelOnlineRequests() {
    for (final requestId in _activeSourceRequests.toList(growable: false)) {
      _sourceAdapter.cancel(requestId);
    }
    _activeSourceRequests.clear();
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
    return cached.lastPageIndex;
  }

  void _rememberChapterCache(int chapterIndex) {
    if (_richChapter) return;
    final book = _book;
    if (book != null && _isRichBook(book)) return;
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
      basePageIndex: _pageBaseIndex,
      nextOffset: _nextOffset,
      hasMore: _hasMorePages,
      lastPageIndex: _absolutePageIndex(),
    );
    while (_chapterCache.length > 3) {
      _chapterCache.remove(_chapterCache.keys.first);
    }
  }

  Future<void> _prefetchAround(int chapterIndex) async {
    final book = _book;
    if (book != null && _isRichBook(book)) return;
    await _prefetchChapter(chapterIndex + 1);
  }

  Future<void> _prefetchChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    if (_chapterCache.containsKey(index) ||
        _prefetchingChapters.contains(index)) {
      return;
    }
    final book = _book;
    if (book == null) return;
    _prefetchingChapters.add(index);
    try {
      final chapter = _chapters[index];
      final content = await _chapterContent(book, chapter);
      if (!mounted || index == _chapterIndex) return;
      final text = '${chapter.title}\n\n$content';
      final budget = _budget();
      final settings = ref.read(settingsProvider);
      final window = await _paginateWindow(
        text,
        settings: settings,
        startOffset: 0,
        maxPages: budget.initialPages,
      );
      if (!mounted || index == _chapterIndex || window.pages.isEmpty) return;
      _chapterCache.remove(index);
      _chapterCache[index] = _ReaderChapterCache(
        text: text,
        pages: List<PageSlice>.unmodifiable(window.pages),
        basePageIndex: 0,
        nextOffset: window.nextOffset,
        hasMore: window.hasMore,
        lastPageIndex: 0,
      );
      while (_chapterCache.length > 4) {
        _chapterCache.remove(_chapterCache.keys.first);
      }
      await _persistPageCacheFor(
        chapterIndex: index,
        chapterText: text,
        basePageIndex: 0,
        pages: window.pages,
        nextOffset: window.nextOffset,
        hasMore: window.hasMore,
        lastPageIndex: 0,
      );
    } catch (_) {
    } finally {
      _prefetchingChapters.remove(index);
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
    if (_pageBaseIndex > 0) {
      await _restoreWindowAround((_pageBaseIndex - 1).clamp(0, 1 << 20));
      return;
    }
    if (_chapterIndex <= 0) return;
    final previousIndex = _chapterIndex - 1;
    final cached = _chapterCache[previousIndex];
    final targetPage = cached == null
        ? (1 << 20)
        : _resolveRequestedPageIndex(1 << 20, cached);
    await _gotoChapter(previousIndex, initialPageIndex: targetPage);
  }

  int _absolutePageIndex() {
    return _pageBaseIndex + _pageIndex;
  }

  Future<void> _restoreWindowAround(int targetPageIndex) async {
    if (_chapterText.isEmpty) return;
    final settings = ref.read(settingsProvider);
    _rememberChapterCache(_chapterIndex);
    setState(() {
      _loadingMore = true;
      _pageSlices = const [];
      _pageBaseIndex = 0;
      _nextOffset = 0;
      _hasMorePages = _chapterText.isNotEmpty;
    });
    try {
      await _restorePersistedPageCache(
        settings,
        targetPageIndex: targetPageIndex,
      );
      await _ensurePagesFor(targetPageIndex, settings: settings);
      if (!mounted || _pageSlices.isEmpty) return;
      final bounded = (targetPageIndex - _pageBaseIndex)
          .clamp(0, _pageSlices.length - 1)
          .toInt();
      setState(() {
        _pageIndex = bounded;
      });
      _rememberChapterCache(_chapterIndex);
      unawaited(_persistCurrentPageCache());
      unawaited(_prebindNativeNeighborPages(bounded));
      _viewKey.currentState?.jumpTo(bounded);
    } finally {
      if (mounted) {
        setState(() {
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _prebindNativeNeighborPages(int localPageIndex) async {
    final settings = ref.read(settingsProvider);
    final layoutSpec = _buildLayoutSpec(settings);
    if (!layoutSpec.isAndroidStaticLayout || _pageSlices.isEmpty) {
      return;
    }
    final texts = <String>[];
    for (final offset in const [-1, 0, 1]) {
      final index = localPageIndex + offset;
      if (index < 0 || index >= _pageSlices.length) {
        continue;
      }
      texts.add(_pageSlices[index].text);
    }
    await AndroidStaticLayoutPaginator.prebindPages(
      texts: texts,
      layout: layoutSpec,
    );
  }

  Future<void> _showBookmarks(BuildContext context) async {
    final book = _book;
    if (book == null) return;
    final store = ref.read(readerBookmarksStoreProvider);
    var bookmarks = store.list(book.id);
    final currentAbsolutePageIndex = _absolutePageIndex();
    final currentId = '$book.id::$_chapterIndex::$currentAbsolutePageIndex';
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
                              pageIndex: currentAbsolutePageIndex,
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

  Future<void> _showDiagnostics(BuildContext context) async {
    final store = _pageCacheStore;
    if (store == null) return;
    await _persistCurrentPageCache();
    final telemetry = await store.readTelemetry(
      layoutKey: _buildLayoutSpec(ref.read(settingsProvider)).cacheKey,
    );
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _ReaderDiagnosticsSheet(
        telemetry: telemetry,
        chapterIndex: _chapterIndex,
        absolutePageIndex: _absolutePageIndex(),
        visiblePageCount: _pageSlices.length,
        pageBaseIndex: _pageBaseIndex,
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
          final notifier = ref.read(settingsProvider.notifier);
          final l10n = AppLocalizations.of(context);
          final mediaQuery = MediaQuery.of(context);
          var previewFontSize = settings.fontScale.value;
          var previewLineHeight = settings.lineHeight;
          return AnimatedPadding(
            duration: M3Motion.short4,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: mediaQuery.size.height * 0.82,
              ),
              child: StatefulBuilder(
                builder: (context, setSheetState) => SingleChildScrollView(
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
                                label: Text(
                                  _fontLabel(preset),
                                  style: AppTheme.readingTextStyle(
                                    Theme.of(context).textTheme.titleSmall ??
                                        const TextStyle(fontSize: 14),
                                    preset,
                                  ),
                                ),
                                selected:
                                    settings.readerFontFamily ==
                                    _fontLabel(preset),
                                onSelected: (_) {
                                  notifier.update(
                                    (previous) => previous.copyWith(
                                      readerFont: preset,
                                      readerFontFamily: _fontLabel(preset),
                                    ),
                                  );
                                  unawaited(_refreshReaderLayout());
                                },
                              ),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.pop(context);
                            await showReaderFontPicker(
                              this.context,
                              onChanged: _refreshReaderLayout,
                            );
                          },
                          icon: const Icon(Icons.manage_search),
                          label: const Text(
                            '全部 Google Fonts / 导入本地字体',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(l10n.fontSize),
                      Slider(
                        min: 14,
                        max: 28,
                        divisions: 14,
                        value: previewFontSize,
                        label: '${previewFontSize.toInt()}',
                        onChanged: (value) {
                          setSheetState(() => previewFontSize = value);
                        },
                        onChangeEnd: (value) {
                          final scale = value <= 17
                              ? ReaderFontScale.small
                              : value <= 19
                              ? ReaderFontScale.normal
                              : value <= 21
                              ? ReaderFontScale.large
                              : ReaderFontScale.xLarge;
                          if (scale == settings.fontScale) {
                            return;
                          }
                          notifier.update(
                            (previous) => previous.copyWith(fontScale: scale),
                          );
                          unawaited(_refreshReaderLayout());
                        },
                      ),
                      Text(l10n.lineHeight),
                      Slider(
                        min: 1.2,
                        max: 2.4,
                        divisions: 12,
                        value: previewLineHeight,
                        label: previewLineHeight.toStringAsFixed(2),
                        onChanged: (value) {
                          setSheetState(() => previewLineHeight = value);
                        },
                        onChangeEnd: (value) {
                          if ((value - settings.lineHeight).abs() < 0.001) {
                            return;
                          }
                          notifier.update(
                            (previous) => previous.copyWith(lineHeight: value),
                          );
                          unawaited(_refreshReaderLayout());
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.keepScreenOn),
                        value: settings.keepScreenOn,
                        onChanged: (value) {
                          notifier.update(
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
                                onSelected: (_) => notifier.update(
                                  (previous) =>
                                      previous.copyWith(pageTurnEffect: effect),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _refreshReaderLayout() async {
    if (_richChapter) {
      if (mounted) setState(() {});
      return;
    }
    await _repaginate(targetPageIndex: _pageIndex);
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

  String _pageCountLabel([int? localPageIndex]) {
    final current = _pageBaseIndex + (localPageIndex ?? _pageIndex) + 1;
    final total = _pageBaseIndex + _pageSlices.length;
    final suffix = (_hasMorePages || _pageBaseIndex > 0) ? '+' : '';
    return '$current / $total$suffix';
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
    if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
      return 'text/markdown';
    }
    if (lower.endsWith('.cbz') || lower.endsWith('.zip')) {
      return 'application/vnd.comicbook+zip';
    }
    for (final audio in const [
      'mp3',
      'm4a',
      'aac',
      'ogg',
      'opus',
      'wav',
      'flac',
    ]) {
      if (lower.endsWith('.$audio')) return 'audio/$audio';
    }
    final format = book.kind.replaceAll('_uri', '').trim().toLowerCase();
    return switch (format) {
      'txt' => 'text/plain',
      'epub' => 'application/epub+zip',
      'mobi' => 'application/x-mobipocket-ebook',
      'azw3' => 'application/vnd.amazon.ebook',
      'md' || 'markdown' => 'text/markdown',
      'cbz' || 'zip' => 'application/vnd.comicbook+zip',
      'mp3' ||
      'm4a' ||
      'aac' ||
      'ogg' ||
      'opus' ||
      'wav' ||
      'flac' => 'audio/$format',
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
    final layoutSpec = _buildLayoutSpec(settings);
    final readerTextStyle = _readerTextStyle(context, settings);

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

    final Widget reader;
    if (_richChapter && _isMarkdownBook(_book!)) {
      reader = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => setState(() => _showOverlay = !_showOverlay),
        child: MarkdownReaderContent(
          data: _chapterText,
          textStyle: readerTextStyle,
          documentPath: _book!.pathOrUrl,
          padding: EdgeInsets.fromLTRB(
            settings.pagePadding,
            settings.pagePadding + MediaQuery.paddingOf(context).top,
            settings.pagePadding,
            settings.pagePadding + MediaQuery.paddingOf(context).bottom,
          ),
        ),
      );
    } else if (_richChapter && _mediaContent != null) {
      final media = _mediaContent!;
      final localAudioPath = _isAudioBook(_book!) ? _book!.pathOrUrl : null;
      reader = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => setState(() => _showOverlay = !_showOverlay),
        child: ComicReaderContent(
          images: media.images,
          audioUrl: localAudioPath == null ? media.audioUrl : null,
          localAudioPath: localAudioPath,
          onPrevious: _chapterIndex > 0
              ? () => _gotoChapter(_chapterIndex - 1)
              : null,
          onNext: _chapterIndex < _chapters.length - 1
              ? () => _gotoChapter(_chapterIndex + 1)
              : null,
          chapterLabel: '${_chapterIndex + 1} / ${_chapters.length}',
          padding: EdgeInsets.fromLTRB(
            settings.pagePadding,
            settings.pagePadding + MediaQuery.paddingOf(context).top,
            settings.pagePadding,
            settings.pagePadding,
          ),
        ),
      );
    } else {
      reader = PageTurnView(
        key: _viewKey,
        pageCount: _pageSlices.length,
        initialPage: _pageIndex,
        effect: effect,
        contentRevision: (
          _pageSlices,
          _chapterIndex,
          layoutSpec.cacheKey,
          layoutSpec.textColor.toARGB32(),
          layoutSpec.backgroundColor.toARGB32(),
          _pageBaseIndex,
          _hasMorePages,
        ),
        onTapCenter: () => setState(() => _showOverlay = !_showOverlay),
        onPageChanged: _onPageChanged,
        onReachEnd: () => unawaited(_handleReachEnd()),
        onReachStart: () => unawaited(_handleReachStart()),
        pageBuilder: (context, index) => _ReaderPageView(
          text: _pageSlices[index].text,
          textStyle: readerTextStyle,
          layoutSpec: layoutSpec,
          padding: settings.pagePadding,
          backgroundColor: colorScheme.surface,
          footer: _ReaderFooter(
            chapterTitle: _chapters[_chapterIndex].title,
            pageLabel: _pageCountLabel(index),
          ),
        ),
      );
    }

    return PopScope(
      canPop: Navigator.of(context).canPop(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/bookshelf');
      },
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        body: Stack(
          children: [
            KeyedSubtree(key: AppKeys.readerViewport, child: reader),
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
                      onShowDiagnostics: _pageCacheStore == null
                          ? null
                          : () => _showDiagnostics(context),
                      onShare: (shareContext) =>
                          _shareCurrentBook(shareContext),
                      onOpenAppSettings: () => context.push('/settings'),
                      onClose: () => setState(() => _showOverlay = false),
                      onShowReaderSettings: () => _showReaderSettings(context),
                      isNightMode:
                          Theme.of(context).brightness == Brightness.dark,
                      onToggleNightMode: () {
                        final isDark =
                            Theme.of(context).brightness == Brightness.dark;
                        unawaited(
                          ref
                              .read(settingsProvider.notifier)
                              .update(
                                (previous) => previous.copyWith(
                                  themeMode: isDark
                                      ? ThemeMode.light
                                      : ThemeMode.dark,
                                ),
                              ),
                        );
                      },
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
  final ReaderLayoutSpec layoutSpec;
  final double padding;
  final Color backgroundColor;
  final Widget footer;

  const _ReaderPageView({
    required this.text,
    required this.textStyle,
    required this.layoutSpec,
    required this.padding,
    required this.backgroundColor,
    required this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
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
            Expanded(
              child: ReaderPageContent(
                text: text,
                textStyle: textStyle,
                layoutSpec: layoutSpec,
              ),
            ),
            footer,
          ],
        ),
      ),
    );
  }
}

extension on _ReaderPageState {
  Future<void> _restorePersistedPageCache(
    AppSettings settings, {
    required int targetPageIndex,
  }) async {
    final store = _pageCacheStore;
    if (store == null || _chapterText.isEmpty) return;
    final persisted = await store.readChapter(
      layoutKey: _buildLayoutSpec(settings).cacheKey,
      chapterIndex: _chapterIndex,
      targetPageIndex: targetPageIndex,
      text: _chapterText,
    );
    if (persisted == null) return;
    final pages = persisted.materialize(_chapterText);
    if (pages.isEmpty) return;
    _pageSlices = pages;
    _pageBaseIndex = persisted.basePageIndex;
    _nextOffset = persisted.nextOffset;
    _hasMorePages = persisted.hasMore;
    _pageIndex = (persisted.lastPageIndex - persisted.basePageIndex)
        .clamp(0, pages.length - 1)
        .toInt();
    _pendingRestoreFeedback.add(
      _PendingRestoreFeedback(
        chapterIndex: _chapterIndex,
        targetPageIndex: targetPageIndex,
        restoredFirstPageIndex: persisted.restoredFirstPageIndex,
        restoredLastPageIndex: persisted.restoredLastPageIndex,
        usedHotWindow: persisted.usedHotWindow,
      ),
    );
  }

  Future<void> _persistCurrentPageCache() {
    return _persistPageCacheFor(
      chapterIndex: _chapterIndex,
      chapterText: _chapterText,
      basePageIndex: _pageBaseIndex,
      pages: _pageSlices,
      nextOffset: _nextOffset,
      hasMore: _hasMorePages,
      lastPageIndex: _absolutePageIndex(),
    );
  }

  Future<void> _persistPageCacheFor({
    required int chapterIndex,
    required String chapterText,
    required int basePageIndex,
    required List<PageSlice> pages,
    required int nextOffset,
    required bool hasMore,
    required int lastPageIndex,
  }) async {
    final store = _pageCacheStore;
    if (store == null || chapterText.isEmpty || pages.isEmpty || !mounted) {
      return;
    }
    final layoutKey = _buildLayoutSpec(ref.read(settingsProvider)).cacheKey;
    final feedbacks = await _collectPersistFeedback(
      chapterIndex: chapterIndex,
      basePageIndex: basePageIndex,
      pages: pages,
    );
    await store.writeChapter(
      layoutKey: layoutKey,
      chapterIndex: chapterIndex,
      basePageIndex: basePageIndex,
      startOffset: pages.first.start,
      pages: pages,
      nextOffset: nextOffset,
      hasMore: hasMore,
      lastPageIndex: lastPageIndex,
    );
    for (final feedback in feedbacks) {
      await store.reportFeedback(
        layoutKey: layoutKey,
        chapterIndex: chapterIndex,
        feedback: feedback,
      );
    }
  }

  Future<List<ReaderPageCacheFeedback>> _collectPersistFeedback({
    required int chapterIndex,
    required int basePageIndex,
    required List<PageSlice> pages,
  }) async {
    final restoreFeedbacks = _pendingRestoreFeedback
        .where((item) => item.chapterIndex == chapterIndex)
        .toList(growable: false);
    _pendingRestoreFeedback.removeWhere(
      (item) => item.chapterIndex == chapterIndex,
    );
    final layoutSpec = _buildLayoutSpec(ref.read(settingsProvider));
    final nativeStats =
        chapterIndex == _chapterIndex && layoutSpec.isAndroidStaticLayout
        ? await AndroidStaticLayoutPaginator.drainStats()
        : AndroidStaticLayoutStats.empty;
    if (restoreFeedbacks.isEmpty && !nativeStats.hasData) {
      return const [];
    }
    final currentAbsolutePage = chapterIndex == _chapterIndex
        ? _absolutePageIndex()
        : basePageIndex;
    final currentLastPageIndex = basePageIndex + pages.length - 1;
    if (restoreFeedbacks.isEmpty) {
      return [
        ReaderPageCacheFeedback(
          targetPageIndex: currentAbsolutePage,
          restoredFirstPageIndex: basePageIndex,
          restoredLastPageIndex: currentLastPageIndex,
          usedHotWindow: basePageIndex > 0,
          recordRestoreEvent: false,
          bindTotalMicros: nativeStats.bindTotalMicros,
          bindSampleCount: nativeStats.bindSampleCount,
          bindMaxMicros: nativeStats.bindMaxMicros,
          layoutTotalMicros: nativeStats.layoutTotalMicros,
          layoutSampleCount: nativeStats.layoutSampleCount,
          layoutMaxMicros: nativeStats.layoutMaxMicros,
          prebindRequestCount: nativeStats.prebindRequestCount,
          prebindHitCount: nativeStats.prebindHitCount,
          visiblePreboundBindTotalMicros:
              nativeStats.visiblePreboundBindTotalMicros,
          visiblePreboundBindSampleCount:
              nativeStats.visiblePreboundBindSampleCount,
          visiblePreboundBindMaxMicros:
              nativeStats.visiblePreboundBindMaxMicros,
          visiblePreboundLayoutTotalMicros:
              nativeStats.visiblePreboundLayoutTotalMicros,
          visiblePreboundLayoutSampleCount:
              nativeStats.visiblePreboundLayoutSampleCount,
          visiblePreboundLayoutMaxMicros:
              nativeStats.visiblePreboundLayoutMaxMicros,
          backgroundPrebindBindTotalMicros:
              nativeStats.backgroundPrebindBindTotalMicros,
          backgroundPrebindBindSampleCount:
              nativeStats.backgroundPrebindBindSampleCount,
          backgroundPrebindBindMaxMicros:
              nativeStats.backgroundPrebindBindMaxMicros,
          backgroundPrebindLayoutTotalMicros:
              nativeStats.backgroundPrebindLayoutTotalMicros,
          backgroundPrebindLayoutSampleCount:
              nativeStats.backgroundPrebindLayoutSampleCount,
          backgroundPrebindLayoutMaxMicros:
              nativeStats.backgroundPrebindLayoutMaxMicros,
        ),
      ];
    }
    final feedbacks = <ReaderPageCacheFeedback>[];
    for (var index = 0; index < restoreFeedbacks.length; index++) {
      final restoreFeedback = restoreFeedbacks[index];
      final attachNativeStats = index == restoreFeedbacks.length - 1
          ? nativeStats
          : AndroidStaticLayoutStats.empty;
      feedbacks.add(
        ReaderPageCacheFeedback(
          targetPageIndex: restoreFeedback.targetPageIndex,
          restoredFirstPageIndex: restoreFeedback.restoredFirstPageIndex,
          restoredLastPageIndex: restoreFeedback.restoredLastPageIndex,
          usedHotWindow: restoreFeedback.usedHotWindow,
          recordRestoreEvent: true,
          bindTotalMicros: attachNativeStats.bindTotalMicros,
          bindSampleCount: attachNativeStats.bindSampleCount,
          bindMaxMicros: attachNativeStats.bindMaxMicros,
          layoutTotalMicros: attachNativeStats.layoutTotalMicros,
          layoutSampleCount: attachNativeStats.layoutSampleCount,
          layoutMaxMicros: attachNativeStats.layoutMaxMicros,
          prebindRequestCount: attachNativeStats.prebindRequestCount,
          prebindHitCount: attachNativeStats.prebindHitCount,
          visiblePreboundBindTotalMicros:
              attachNativeStats.visiblePreboundBindTotalMicros,
          visiblePreboundBindSampleCount:
              attachNativeStats.visiblePreboundBindSampleCount,
          visiblePreboundBindMaxMicros:
              attachNativeStats.visiblePreboundBindMaxMicros,
          visiblePreboundLayoutTotalMicros:
              attachNativeStats.visiblePreboundLayoutTotalMicros,
          visiblePreboundLayoutSampleCount:
              attachNativeStats.visiblePreboundLayoutSampleCount,
          visiblePreboundLayoutMaxMicros:
              attachNativeStats.visiblePreboundLayoutMaxMicros,
          backgroundPrebindBindTotalMicros:
              attachNativeStats.backgroundPrebindBindTotalMicros,
          backgroundPrebindBindSampleCount:
              attachNativeStats.backgroundPrebindBindSampleCount,
          backgroundPrebindBindMaxMicros:
              attachNativeStats.backgroundPrebindBindMaxMicros,
          backgroundPrebindLayoutTotalMicros:
              attachNativeStats.backgroundPrebindLayoutTotalMicros,
          backgroundPrebindLayoutSampleCount:
              attachNativeStats.backgroundPrebindLayoutSampleCount,
          backgroundPrebindLayoutMaxMicros:
              attachNativeStats.backgroundPrebindLayoutMaxMicros,
        ),
      );
    }
    return feedbacks;
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
  final VoidCallback? onShowDiagnostics;
  final ValueChanged<BuildContext> onShare;
  final VoidCallback onOpenAppSettings;
  final VoidCallback onShowReaderSettings;
  final bool isNightMode;
  final VoidCallback onToggleNightMode;
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
    this.onShowDiagnostics,
    required this.onShare,
    required this.onOpenAppSettings,
    required this.onShowReaderSettings,
    required this.isNightMode,
    required this.onToggleNightMode,
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
                  if (onShowDiagnostics != null)
                    IconButton(
                      icon: const Icon(Icons.analytics_outlined),
                      onPressed: onShowDiagnostics,
                      tooltip: '阅读诊断',
                    ),
                  Builder(
                    builder: (shareContext) => IconButton(
                      key: AppKeys.readerOverlayShare,
                      icon: const Icon(Icons.share_outlined),
                      onPressed: () => onShare(shareContext),
                      tooltip: l10n.shareBook,
                    ),
                  ),
                  IconButton(
                    key: AppKeys.readerOverlaySettings,
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: onOpenAppSettings,
                    tooltip: l10n.settings,
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
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ReaderOverlayAction(
                          key: AppKeys.readerOverlayToc,
                          icon: Icons.menu_book_outlined,
                          label: l10n.tableOfContents,
                          onTap: onShowToc,
                        ),
                        _ReaderOverlayAction(
                          key: AppKeys.readerOverlayBookmarks,
                          icon: Icons.bookmarks_outlined,
                          label: l10n.bookmarks,
                          onTap: onShowBookmarks,
                        ),
                        _ReaderOverlayAction(
                          key: AppKeys.readerOverlayNightMode,
                          icon: isNightMode
                              ? Icons.dark_mode
                              : Icons.dark_mode_outlined,
                          label: l10n.nightMode,
                          tooltip: isNightMode
                              ? l10n.themeLight
                              : l10n.themeDark,
                          selected: isNightMode,
                          onTap: onToggleNightMode,
                        ),
                        _ReaderOverlayAction(
                          key: AppKeys.readerOverlayReaderSettings,
                          icon: Icons.tune,
                          label: l10n.settings,
                          tooltip: l10n.readerSettings,
                          onTap: onShowReaderSettings,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReaderOverlayAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? tooltip;
  final bool selected;
  final VoidCallback onTap;

  const _ReaderOverlayAction({
    super.key,
    required this.icon,
    required this.label,
    this.tooltip,
    this.selected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurfaceVariant;
    return Expanded(
      child: Tooltip(
        message: tooltip ?? label,
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 68),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: M3Motion.short4,
                      curve: M3Motion.emphasizedDecelerate,
                      width: 48,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? colorScheme.secondaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(icon, size: 22, color: foreground),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderDiagnosticsSheet extends StatelessWidget {
  final book_file.TxtLayoutTelemetry? telemetry;
  final int chapterIndex;
  final int absolutePageIndex;
  final int visiblePageCount;
  final int pageBaseIndex;

  const _ReaderDiagnosticsSheet({
    required this.telemetry,
    required this.chapterIndex,
    required this.absolutePageIndex,
    required this.visiblePageCount,
    required this.pageBaseIndex,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final data = telemetry;
    final content = data == null
        ? const [
            _ReaderDiagnosticsRow(label: 'sidecar telemetry', value: '暂无数据'),
          ]
        : [
            _ReaderDiagnosticsRow(
              label: '热门窗口命中率',
              value: _ratioLabel(data.hotHitCount, data.hotReadCount),
            ),
            _ReaderDiagnosticsRow(
              label: '平均补页跨度',
              value: '${data.averageJumpGapPages} 页',
            ),
            _ReaderDiagnosticsRow(
              label: '最大补页跨度',
              value: '${data.maxJumpGapPages} 页',
            ),
            _ReaderDiagnosticsRow(
              label: '预绑定命中率',
              value: _ratioLabel(
                data.prebindHitCount,
                data.prebindRequestCount,
              ),
            ),
            _ReaderDiagnosticsRow(
              label: '窗口大小 / 保留数',
              value:
                  '${data.adaptiveWindowSize} / ${data.adaptiveRetentionLimit}',
            ),
            _ReaderDiagnosticsRow(
              label: '可见页 bind 均值 / 峰值',
              value:
                  '${_microsToMs(data.averageBindMicros)} / ${_microsToMs(data.maxBindMicros)}',
            ),
            _ReaderDiagnosticsRow(
              label: '可见页 layout 均值 / 峰值',
              value:
                  '${_microsToMs(data.averageLayoutMicros)} / ${_microsToMs(data.maxLayoutMicros)}',
            ),
            _ReaderDiagnosticsRow(
              label: '命中预绑定可见页 bind 均值 / 峰值',
              value:
                  '${_microsToMs(data.averageVisiblePreboundBindMicros)} / ${_microsToMs(data.maxVisiblePreboundBindMicros)}',
            ),
            _ReaderDiagnosticsRow(
              label: '命中预绑定可见页 layout 均值 / 峰值',
              value:
                  '${_microsToMs(data.averageVisiblePreboundLayoutMicros)} / ${_microsToMs(data.maxVisiblePreboundLayoutMicros)}',
            ),
            _ReaderDiagnosticsRow(
              label: '后台预绑定 bind 均值 / 峰值',
              value:
                  '${_microsToMs(data.averageBackgroundPrebindBindMicros)} / ${_microsToMs(data.maxBackgroundPrebindBindMicros)}',
            ),
            _ReaderDiagnosticsRow(
              label: '后台预绑定 layout 均值 / 峰值',
              value:
                  '${_microsToMs(data.averageBackgroundPrebindLayoutMicros)} / ${_microsToMs(data.maxBackgroundPrebindLayoutMicros)}',
            ),
          ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('阅读诊断', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('当前章节 ${chapterIndex + 1}'),
                    Text('当前绝对页号 ${absolutePageIndex + 1}'),
                    Text('窗口起始页号 ${pageBaseIndex + 1}'),
                    Text('当前窗口页数 $visiblePageCount'),
                    if (kDebugMode)
                      Text(
                        '该面板显示 sidecar 持久化后的统计，不是瞬时内存快照。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: content.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) => content[index],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _ratioLabel(BigInt hit, BigInt total) {
    if (total == BigInt.zero) {
      return '0 / 0';
    }
    final ratio = hit.toDouble() / total.toDouble();
    return '${hit.toString()} / ${total.toString()} (${(ratio * 100).toStringAsFixed(1)}%)';
  }

  String _microsToMs(BigInt micros) {
    final value = micros.toDouble() / 1000;
    return '${value.toStringAsFixed(value >= 10 ? 1 : 2)} ms';
  }
}

class _ReaderDiagnosticsRow extends StatelessWidget {
  final String label;
  final String value;

  const _ReaderDiagnosticsRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: colorScheme.primary),
            ),
          ],
        ),
      ),
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
