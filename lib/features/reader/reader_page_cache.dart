import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../../src/rust/api/book_file.dart' as book_file;
import 'paginator.dart';

class PersistedChapterPages {
  final int basePageIndex;
  final int startOffset;
  final List<int> pageEnds;
  final int nextOffset;
  final bool hasMore;
  final int lastPageIndex;
  final bool usedHotWindow;
  final int restoredFirstPageIndex;
  final int restoredLastPageIndex;
  final int adaptiveWindowSize;
  final int adaptiveRetentionLimit;

  const PersistedChapterPages({
    required this.basePageIndex,
    required this.startOffset,
    required this.pageEnds,
    required this.nextOffset,
    required this.hasMore,
    required this.lastPageIndex,
    required this.usedHotWindow,
    required this.restoredFirstPageIndex,
    required this.restoredLastPageIndex,
    required this.adaptiveWindowSize,
    required this.adaptiveRetentionLimit,
  });

  List<PageSlice> materialize(String text) {
    if (pageEnds.isEmpty) return const [];
    final pages = <PageSlice>[];
    var start = startOffset;
    for (final rawEnd in pageEnds) {
      final end = rawEnd.clamp(start, text.length).toInt();
      if (end <= start) {
        continue;
      }
      pages.add(
        PageSlice(start: start, end: end, text: text.substring(start, end)),
      );
      start = end;
    }
    return pages;
  }
}

class ReaderPageCacheFeedback {
  final int targetPageIndex;
  final int restoredFirstPageIndex;
  final int restoredLastPageIndex;
  final bool usedHotWindow;
  final bool recordRestoreEvent;
  final int bindTotalMicros;
  final int bindSampleCount;
  final int bindMaxMicros;
  final int layoutTotalMicros;
  final int layoutSampleCount;
  final int layoutMaxMicros;
  final int prebindRequestCount;
  final int prebindHitCount;
  final int visiblePreboundBindTotalMicros;
  final int visiblePreboundBindSampleCount;
  final int visiblePreboundBindMaxMicros;
  final int visiblePreboundLayoutTotalMicros;
  final int visiblePreboundLayoutSampleCount;
  final int visiblePreboundLayoutMaxMicros;
  final int backgroundPrebindBindTotalMicros;
  final int backgroundPrebindBindSampleCount;
  final int backgroundPrebindBindMaxMicros;
  final int backgroundPrebindLayoutTotalMicros;
  final int backgroundPrebindLayoutSampleCount;
  final int backgroundPrebindLayoutMaxMicros;

  const ReaderPageCacheFeedback({
    required this.targetPageIndex,
    required this.restoredFirstPageIndex,
    required this.restoredLastPageIndex,
    required this.usedHotWindow,
    required this.recordRestoreEvent,
    required this.bindTotalMicros,
    required this.bindSampleCount,
    required this.bindMaxMicros,
    required this.layoutTotalMicros,
    required this.layoutSampleCount,
    required this.layoutMaxMicros,
    required this.prebindRequestCount,
    required this.prebindHitCount,
    required this.visiblePreboundBindTotalMicros,
    required this.visiblePreboundBindSampleCount,
    required this.visiblePreboundBindMaxMicros,
    required this.visiblePreboundLayoutTotalMicros,
    required this.visiblePreboundLayoutSampleCount,
    required this.visiblePreboundLayoutMaxMicros,
    required this.backgroundPrebindBindTotalMicros,
    required this.backgroundPrebindBindSampleCount,
    required this.backgroundPrebindBindMaxMicros,
    required this.backgroundPrebindLayoutTotalMicros,
    required this.backgroundPrebindLayoutSampleCount,
    required this.backgroundPrebindLayoutMaxMicros,
  });
}

class ReaderPageCacheStore {
  final String _path;

  ReaderPageCacheStore._(this._path);

  static Future<ReaderPageCacheStore> open({required String path}) async {
    return ReaderPageCacheStore._(path);
  }

  Future<PersistedChapterPages?> readChapter({
    required String layoutKey,
    required int chapterIndex,
    required int targetPageIndex,
    required String text,
  }) async {
    final selection = book_file.readTxtPageCache(
      path: _path,
      layoutKey: layoutKey,
      chapterIndex: chapterIndex,
      targetPageIndex: targetPageIndex,
      textLength: BigInt.from(text.length),
    );
    if (selection == null) return null;
    final cache = selection.cache;
    final maxLastPageIndex = cache.basePageIndex + cache.pageEnds.length - 1;
    return PersistedChapterPages(
      basePageIndex: cache.basePageIndex,
      startOffset: cache.startOffset.toInt(),
      pageEnds: cache.pageEnds
          .map((item) => item.toInt())
          .toList(growable: false),
      nextOffset: cache.nextOffset.toInt(),
      hasMore: cache.hasMore,
      lastPageIndex: cache.lastPageIndex
          .clamp(cache.basePageIndex, maxLastPageIndex)
          .toInt(),
      usedHotWindow: selection.usedHotWindow,
      restoredFirstPageIndex: selection.restoredFirstPageIndex,
      restoredLastPageIndex: selection.restoredLastPageIndex,
      adaptiveWindowSize: selection.adaptiveWindowSize,
      adaptiveRetentionLimit: selection.adaptiveRetentionLimit,
    );
  }

  Future<void> writeChapter({
    required String layoutKey,
    required int chapterIndex,
    required int basePageIndex,
    required int startOffset,
    required List<PageSlice> pages,
    required int nextOffset,
    required bool hasMore,
    required int lastPageIndex,
  }) async {
    if (pages.isEmpty) return;
    book_file.writeTxtPageCache(
      path: _path,
      layoutKey: layoutKey,
      chapterIndex: chapterIndex,
      basePageIndex: basePageIndex,
      startOffset: BigInt.from(startOffset),
      pageEnds: Uint64List.fromList(
        pages.map((item) => item.end).toList(growable: false),
      ),
      nextOffset: BigInt.from(nextOffset),
      hasMore: hasMore,
      lastPageIndex: lastPageIndex,
    );
  }

  Future<void> reportFeedback({
    required String layoutKey,
    required int chapterIndex,
    required ReaderPageCacheFeedback feedback,
  }) async {
    book_file.reportTxtLayoutFeedback(
      path: _path,
      layoutKey: layoutKey,
      chapterIndex: chapterIndex,
      feedback: book_file.TxtLayoutFeedbackInput(
        targetPageIndex: feedback.targetPageIndex,
        restoredFirstPageIndex: feedback.restoredFirstPageIndex,
        restoredLastPageIndex: feedback.restoredLastPageIndex,
        usedHotWindow: feedback.usedHotWindow,
        recordRestoreEvent: feedback.recordRestoreEvent,
        bindTotalMicros: BigInt.from(feedback.bindTotalMicros),
        bindSampleCount: feedback.bindSampleCount,
        bindMaxMicros: BigInt.from(feedback.bindMaxMicros),
        layoutTotalMicros: BigInt.from(feedback.layoutTotalMicros),
        layoutSampleCount: feedback.layoutSampleCount,
        layoutMaxMicros: BigInt.from(feedback.layoutMaxMicros),
        prebindRequestCount: feedback.prebindRequestCount,
        prebindHitCount: feedback.prebindHitCount,
        visiblePreboundBindTotalMicros: BigInt.from(
          feedback.visiblePreboundBindTotalMicros,
        ),
        visiblePreboundBindSampleCount: feedback.visiblePreboundBindSampleCount,
        visiblePreboundBindMaxMicros: BigInt.from(
          feedback.visiblePreboundBindMaxMicros,
        ),
        visiblePreboundLayoutTotalMicros: BigInt.from(
          feedback.visiblePreboundLayoutTotalMicros,
        ),
        visiblePreboundLayoutSampleCount:
            feedback.visiblePreboundLayoutSampleCount,
        visiblePreboundLayoutMaxMicros: BigInt.from(
          feedback.visiblePreboundLayoutMaxMicros,
        ),
        backgroundPrebindBindTotalMicros: BigInt.from(
          feedback.backgroundPrebindBindTotalMicros,
        ),
        backgroundPrebindBindSampleCount:
            feedback.backgroundPrebindBindSampleCount,
        backgroundPrebindBindMaxMicros: BigInt.from(
          feedback.backgroundPrebindBindMaxMicros,
        ),
        backgroundPrebindLayoutTotalMicros: BigInt.from(
          feedback.backgroundPrebindLayoutTotalMicros,
        ),
        backgroundPrebindLayoutSampleCount:
            feedback.backgroundPrebindLayoutSampleCount,
        backgroundPrebindLayoutMaxMicros: BigInt.from(
          feedback.backgroundPrebindLayoutMaxMicros,
        ),
      ),
    );
  }

  Future<book_file.TxtLayoutTelemetry?> readTelemetry({
    required String layoutKey,
  }) async {
    return book_file.readTxtLayoutTelemetry(path: _path, layoutKey: layoutKey);
  }
}
