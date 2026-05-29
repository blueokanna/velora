import 'dart:io';

import 'package:flutter/services.dart';

import 'paginator.dart';
import 'reader_layout.dart';

class AndroidStaticLayoutStats {
  final int bindSampleCount;
  final int bindTotalMicros;
  final int bindMaxMicros;
  final int layoutSampleCount;
  final int layoutTotalMicros;
  final int layoutMaxMicros;
  final int prebindRequestCount;
  final int prebindHitCount;
  final int visiblePreboundBindSampleCount;
  final int visiblePreboundBindTotalMicros;
  final int visiblePreboundBindMaxMicros;
  final int visiblePreboundLayoutSampleCount;
  final int visiblePreboundLayoutTotalMicros;
  final int visiblePreboundLayoutMaxMicros;
  final int backgroundPrebindBindSampleCount;
  final int backgroundPrebindBindTotalMicros;
  final int backgroundPrebindBindMaxMicros;
  final int backgroundPrebindLayoutSampleCount;
  final int backgroundPrebindLayoutTotalMicros;
  final int backgroundPrebindLayoutMaxMicros;

  const AndroidStaticLayoutStats({
    required this.bindSampleCount,
    required this.bindTotalMicros,
    required this.bindMaxMicros,
    required this.layoutSampleCount,
    required this.layoutTotalMicros,
    required this.layoutMaxMicros,
    required this.prebindRequestCount,
    required this.prebindHitCount,
    required this.visiblePreboundBindSampleCount,
    required this.visiblePreboundBindTotalMicros,
    required this.visiblePreboundBindMaxMicros,
    required this.visiblePreboundLayoutSampleCount,
    required this.visiblePreboundLayoutTotalMicros,
    required this.visiblePreboundLayoutMaxMicros,
    required this.backgroundPrebindBindSampleCount,
    required this.backgroundPrebindBindTotalMicros,
    required this.backgroundPrebindBindMaxMicros,
    required this.backgroundPrebindLayoutSampleCount,
    required this.backgroundPrebindLayoutTotalMicros,
    required this.backgroundPrebindLayoutMaxMicros,
  });

  static const empty = AndroidStaticLayoutStats(
    bindSampleCount: 0,
    bindTotalMicros: 0,
    bindMaxMicros: 0,
    layoutSampleCount: 0,
    layoutTotalMicros: 0,
    layoutMaxMicros: 0,
    prebindRequestCount: 0,
    prebindHitCount: 0,
    visiblePreboundBindSampleCount: 0,
    visiblePreboundBindTotalMicros: 0,
    visiblePreboundBindMaxMicros: 0,
    visiblePreboundLayoutSampleCount: 0,
    visiblePreboundLayoutTotalMicros: 0,
    visiblePreboundLayoutMaxMicros: 0,
    backgroundPrebindBindSampleCount: 0,
    backgroundPrebindBindTotalMicros: 0,
    backgroundPrebindBindMaxMicros: 0,
    backgroundPrebindLayoutSampleCount: 0,
    backgroundPrebindLayoutTotalMicros: 0,
    backgroundPrebindLayoutMaxMicros: 0,
  );

  bool get hasData =>
      bindSampleCount > 0 ||
      layoutSampleCount > 0 ||
      prebindRequestCount > 0 ||
      prebindHitCount > 0;

  factory AndroidStaticLayoutStats.fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) return empty;
    int readInt(String key) => (raw[key] as num?)?.toInt() ?? 0;
    return AndroidStaticLayoutStats(
      bindSampleCount: readInt('bindSampleCount'),
      bindTotalMicros: readInt('bindTotalMicros'),
      bindMaxMicros: readInt('bindMaxMicros'),
      layoutSampleCount: readInt('layoutSampleCount'),
      layoutTotalMicros: readInt('layoutTotalMicros'),
      layoutMaxMicros: readInt('layoutMaxMicros'),
      prebindRequestCount: readInt('prebindRequestCount'),
      prebindHitCount: readInt('prebindHitCount'),
      visiblePreboundBindSampleCount: readInt('visiblePreboundBindSampleCount'),
      visiblePreboundBindTotalMicros: readInt('visiblePreboundBindTotalMicros'),
      visiblePreboundBindMaxMicros: readInt('visiblePreboundBindMaxMicros'),
      visiblePreboundLayoutSampleCount: readInt(
        'visiblePreboundLayoutSampleCount',
      ),
      visiblePreboundLayoutTotalMicros: readInt(
        'visiblePreboundLayoutTotalMicros',
      ),
      visiblePreboundLayoutMaxMicros: readInt('visiblePreboundLayoutMaxMicros'),
      backgroundPrebindBindSampleCount: readInt(
        'backgroundPrebindBindSampleCount',
      ),
      backgroundPrebindBindTotalMicros: readInt(
        'backgroundPrebindBindTotalMicros',
      ),
      backgroundPrebindBindMaxMicros: readInt('backgroundPrebindBindMaxMicros'),
      backgroundPrebindLayoutSampleCount: readInt(
        'backgroundPrebindLayoutSampleCount',
      ),
      backgroundPrebindLayoutTotalMicros: readInt(
        'backgroundPrebindLayoutTotalMicros',
      ),
      backgroundPrebindLayoutMaxMicros: readInt(
        'backgroundPrebindLayoutMaxMicros',
      ),
    );
  }
}

class AndroidStaticLayoutPaginator {
  static const MethodChannel _channel = MethodChannel('velora/reader_layout');

  static Future<AndroidStaticLayoutStats> drainStats() async {
    if (!Platform.isAndroid) {
      return AndroidStaticLayoutStats.empty;
    }
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'drainStaticLayoutStats',
    );
    return AndroidStaticLayoutStats.fromMap(raw);
  }

  static Future<void> prebindPages({
    required List<String> texts,
    required ReaderLayoutSpec layout,
  }) async {
    if (!Platform.isAndroid || texts.isEmpty) {
      return;
    }
    final payload = texts
        .where((item) => item.isNotEmpty)
        .map((item) => layout.toAndroidParams(item))
        .toList(growable: false);
    if (payload.isEmpty) {
      return;
    }
    await _channel.invokeMethod<void>('prebindStaticLayoutPages', {
      'pages': payload,
    });
  }

  static Future<PageSliceWindow> paginateWindow({
    required String text,
    required int startOffset,
    required int maxPages,
    required ReaderLayoutSpec layout,
  }) async {
    if (!Platform.isAndroid) {
      throw StateError('Android StaticLayout 仅支持 Android');
    }
    final raw = await _channel
        .invokeMapMethod<String, Object?>('paginateStaticLayout', {
          'text': text,
          'startOffset': startOffset,
          'maxPages': maxPages,
          'width': layout.maxWidth,
          'height': layout.maxHeight,
          'fontSize': layout.fontSize,
          'lineHeight': layout.lineHeight,
          'fontFamilyKey': layout.fontFamilyKey,
          'textDirection': layout.textDirection.name,
        });
    if (raw == null) {
      return const PageSliceWindow(pages: [], nextOffset: 0, hasMore: false);
    }
    final pageMaps = (raw['pages'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<dynamic, dynamic>>();
    final pages = pageMaps
        .map((item) {
          final start = (item['start'] as num?)?.toInt() ?? 0;
          final end = (item['end'] as num?)?.toInt() ?? start;
          final boundedStart = start.clamp(0, text.length).toInt();
          final boundedEnd = end.clamp(boundedStart, text.length).toInt();
          return PageSlice(
            start: boundedStart,
            end: boundedEnd,
            text: text.substring(boundedStart, boundedEnd),
          );
        })
        .toList(growable: false);
    return PageSliceWindow(
      pages: pages,
      nextOffset: ((raw['nextOffset'] as num?)?.toInt() ?? 0)
          .clamp(0, text.length)
          .toInt(),
      hasMore: raw['hasMore'] == true,
    );
  }
}
