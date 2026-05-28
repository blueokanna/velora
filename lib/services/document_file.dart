import 'dart:io';

import 'package:flutter/services.dart';

class DocumentFile {
  final String uri;
  final String name;
  final int size;
  final int? lastModifiedMillis;

  const DocumentFile({
    required this.uri,
    required this.name,
    required this.size,
    this.lastModifiedMillis,
  });
}

class DocumentFileChannel {
  static const MethodChannel _channel = MethodChannel('velora/document_file');

  static bool get isAndroid => Platform.isAndroid;

  static Future<DocumentFile?> openBookDocument() async {
    final raw = await _channel.invokeMapMethod<String, Object?>('openBookDocument');
    return _decodeDocument(raw);
  }

  static Future<DocumentFile?> describeDocument(String uri) async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      'describeDocument',
      {'uri': uri},
    );
    return _decodeDocument(raw);
  }

  static DocumentFile? _decodeDocument(Map<String, Object?>? raw) {
    if (raw == null) return null;
    final uri = raw['uri'] as String?;
    if (uri == null || uri.isEmpty) return null;
    return DocumentFile(
      uri: uri,
      name: (raw['name'] as String?)?.trim().isNotEmpty == true ? raw['name'] as String : '未命名',
      size: (raw['size'] as num?)?.toInt() ?? 0,
      lastModifiedMillis: (raw['lastModified'] as num?)?.toInt(),
    );
  }

  static Future<Uint8List> readBytes(String uri) async {
    final bytes = await _channel.invokeMethod<Uint8List>('readBytes', {'uri': uri});
    if (bytes == null) {
      throw StateError('无法读取文档内容');
    }
    return bytes;
  }
}