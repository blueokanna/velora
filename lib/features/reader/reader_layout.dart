import 'dart:io';

import 'package:flutter/material.dart';

enum ReaderRendererKind { flutterSegments, androidStaticLayout }

class ReaderLayoutSpec {
  final ReaderRendererKind rendererKind;
  final double maxWidth;
  final double maxHeight;
  final double fontSize;
  final double lineHeight;
  final String fontFamilyKey;
  final Color textColor;
  final Color backgroundColor;
  final TextDirection textDirection;

  const ReaderLayoutSpec({
    required this.rendererKind,
    required this.maxWidth,
    required this.maxHeight,
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamilyKey,
    required this.textColor,
    required this.backgroundColor,
    this.textDirection = TextDirection.ltr,
  });

  bool get isAndroidStaticLayout =>
      rendererKind == ReaderRendererKind.androidStaticLayout &&
      Platform.isAndroid;

  String get cacheKey => [
    rendererKind.name,
    maxWidth.round(),
    maxHeight.round(),
    fontSize.toStringAsFixed(2),
    lineHeight.toStringAsFixed(3),
    fontFamilyKey,
    textDirection.name,
  ].join('|');

  String bindingKeyForText(String text) {
    return '$cacheKey|${textColor.toARGB32()}|${backgroundColor.toARGB32()}|${text.length}|${text.hashCode}';
  }

  Map<String, Object?> toAndroidParams(String text) {
    return {
      'bindingKey': bindingKeyForText(text),
      'text': text,
      'width': maxWidth,
      'height': maxHeight,
      'fontSize': fontSize,
      'lineHeight': lineHeight,
      'fontFamilyKey': fontFamilyKey,
      'textColor': textColor.toARGB32(),
      'backgroundColor': backgroundColor.toARGB32(),
      'textDirection': textDirection.name,
    };
  }
}
