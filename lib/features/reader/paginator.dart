import 'package:flutter/material.dart';

class PageSlice {
  final int start;
  final int end;
  final String text;

  const PageSlice({required this.start, required this.end, required this.text});
}

class PageSliceWindow {
  final List<PageSlice> pages;
  final int nextOffset;
  final bool hasMore;

  const PageSliceWindow({
    required this.pages,
    required this.nextOffset,
    required this.hasMore,
  });
}

class TextPaginator {
  final TextStyle style;
  final double maxWidth;
  final double maxHeight;
  final TextDirection textDirection;

  TextPaginator({
    required this.style,
    required this.maxWidth,
    required this.maxHeight,
    this.textDirection = TextDirection.ltr,
  });

  List<String> paginate(String text) {
    return paginateWindow(text, startOffset: 0, maxPages: 1 << 20)
        .pages
        .map((item) => item.text)
        .toList(growable: false);
  }

  PageSliceWindow paginateWindow(
    String text, {
    required int startOffset,
    required int maxPages,
  }) {
    if (text.isEmpty || maxPages <= 0) {
      return const PageSliceWindow(pages: [], nextOffset: 0, hasMore: false);
    }
    final pages = <PageSlice>[];
    final tp = TextPainter(textDirection: textDirection);
    var start = startOffset.clamp(0, text.length);
    while (start < text.length && pages.length < maxPages) {
      final page = _nextPage(text, start, tp);
      pages.add(page);
      start = page.end;
    }
    return PageSliceWindow(
      pages: pages,
      nextOffset: start,
      hasMore: start < text.length,
    );
  }

  PageSlice _nextPage(String text, int start, TextPainter tp) {
    int lo = 1;
    int hi = text.length - start;
    int best = 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final slice = text.substring(start, start + mid);
      tp.text = TextSpan(text: slice, style: style);
      tp.layout(maxWidth: maxWidth);
      if (tp.size.height <= maxHeight) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    var cut = best;
    final segment = text.substring(start, start + best);
    final lastNewline = segment.lastIndexOf('\n');
    if (lastNewline > best * 0.5) {
      cut = lastNewline + 1;
    } else {
      for (final punctuation in ['。', '！', '？', '.', '!', '?', '”', '」']) {
        final index = segment.lastIndexOf(punctuation);
        if (index > best * 0.6) {
          cut = index + 1;
          break;
        }
      }
    }
    final end = start + cut;
    return PageSlice(start: start, end: end, text: text.substring(start, end));
  }
}
