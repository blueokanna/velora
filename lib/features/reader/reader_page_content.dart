import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'reader_layout.dart';

class ReaderPageContent extends StatelessWidget {
  final String text;
  final TextStyle textStyle;
  final ReaderLayoutSpec layoutSpec;

  const ReaderPageContent({
    super.key,
    required this.text,
    required this.textStyle,
    required this.layoutSpec,
  });

  @override
  Widget build(BuildContext context) {
    if (layoutSpec.isAndroidStaticLayout && Platform.isAndroid) {
      return AndroidView(
        key: ValueKey(layoutSpec.bindingKeyForText(text)),
        viewType: 'velora/reader_page',
        creationParams: layoutSpec.toAndroidParams(text),
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) => CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: _SegmentedPagePainter(
            text: text,
            textStyle: textStyle,
            textDirection: Directionality.of(context),
          ),
        ),
      ),
    );
  }
}

class _SegmentedPagePainter extends CustomPainter {
  final String text;
  final TextStyle textStyle;
  final TextDirection textDirection;

  const _SegmentedPagePainter({
    required this.text,
    required this.textStyle,
    required this.textDirection,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final blocks = text.split('\n');
    final painter = TextPainter(
      textDirection: textDirection,
      strutStyle: StrutStyle.fromTextStyle(textStyle, forceStrutHeight: true),
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: true,
        applyHeightToLastDescent: true,
      ),
    );
    var dy = 0.0;
    for (final raw in blocks) {
      final block = raw.isEmpty ? '\u00a0' : raw;
      painter.text = TextSpan(text: block, style: textStyle);
      painter.layout(maxWidth: size.width);
      if (dy + painter.height > size.height + 0.5) {
        break;
      }
      painter.paint(canvas, Offset(0, dy));
      dy += painter.height;
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentedPagePainter oldDelegate) {
    return oldDelegate.text != text ||
        oldDelegate.textStyle != textStyle ||
        oldDelegate.textDirection != textDirection;
  }
}
