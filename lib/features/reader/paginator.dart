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
    return paginateWindow(
      text,
      startOffset: 0,
      maxPages: 1 << 20,
    ).pages.map((item) => item.text).toList(growable: false);
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
    final tp = TextPainter(
      textDirection: textDirection,
      strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: true,
        applyHeightToLastDescent: true,
      ),
    );
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
    final remaining = text.length - start;
    final estimate = _estimatedCharsPerPage().clamp(1, remaining).toInt();
    var best = 1;
    var lowFit = 0;
    var highFail = remaining + 1;
    if (_fits(text, start, estimate, tp)) {
      lowFit = estimate;
      var probe = estimate;
      while (probe < remaining) {
        final next = (probe * 13 ~/ 8 + 32).clamp(probe + 1, remaining).toInt();
        if (_fits(text, start, next, tp)) {
          lowFit = next;
          probe = next;
        } else {
          highFail = next;
          break;
        }
      }
      if (lowFit == remaining) {
        best = remaining;
      }
    } else {
      highFail = estimate;
      var probe = estimate;
      while (probe > 1) {
        final next = (probe ~/ 2).clamp(1, probe - 1).toInt();
        if (_fits(text, start, next, tp)) {
          lowFit = next;
          break;
        }
        highFail = next;
        probe = next;
      }
    }
    if (best != remaining) {
      var lo = lowFit + 1;
      var hi = highFail - 1;
      best = lowFit == 0 ? 1 : lowFit;
      while (lo <= hi) {
        final mid = (lo + hi) ~/ 2;
        if (_fits(text, start, mid, tp)) {
          best = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
    }
    var cut = best.clamp(1, remaining).toInt();
    final segment = text.substring(start, start + cut);
    final lastNewline = segment.lastIndexOf('\n');
    if (lastNewline > cut * 0.5) {
      cut = lastNewline + 1;
    } else {
      for (final punctuation in ['。', '！', '？', '.', '!', '?', '”', '」']) {
        final index = segment.lastIndexOf(punctuation);
        if (index > cut * 0.6) {
          cut = index + 1;
          break;
        }
      }
    }
    final end = start + cut;
    return PageSlice(start: start, end: end, text: text.substring(start, end));
  }

  bool _fits(String text, int start, int length, TextPainter tp) {
    final bounded = length.clamp(1, text.length - start).toInt();
    tp.text = TextSpan(
      text: text.substring(start, start + bounded),
      style: style,
    );
    tp.layout(maxWidth: maxWidth);
    return tp.size.height <= maxHeight;
  }

  int _estimatedCharsPerPage() {
    final fontSize = (style.fontSize ?? 18).clamp(10.0, 40.0).toDouble();
    final height = (style.height ?? 1.5).clamp(1.0, 3.0).toDouble();
    final charsPerLine = (maxWidth / (fontSize * 0.56))
        .floor()
        .clamp(8, 240)
        .toInt();
    final lines = (maxHeight / (fontSize * height))
        .floor()
        .clamp(4, 160)
        .toInt();
    return (charsPerLine * lines * 0.92).round().clamp(16, 12000).toInt();
  }
}
