import 'dart:convert';

import '../../src/rust/api/book_file.dart' as book_file;

class BookSourceSignature {
  final int? sizeBytes;
  final int? modifiedAtMillis;

  const BookSourceSignature({this.sizeBytes, this.modifiedAtMillis});
}

class DecodedBookMeta {
  final book_file.BookMeta meta;
  final BookSourceSignature sourceSignature;

  const DecodedBookMeta({required this.meta, required this.sourceSignature});
}

String encodeBookMeta(
  book_file.BookMeta meta, {
  int? sourceSizeBytes,
  int? sourceModifiedAtMillis,
}) {
  return jsonEncode({
    'locator': meta.locator,
    'title': meta.title,
    'author': meta.author,
    'format': meta.format,
    'encoding': meta.encoding,
    'sizeBytes': meta.sizeBytes.toString(),
    'coverDataUrl': meta.coverDataUrl,
    'sourceSizeBytes': sourceSizeBytes,
    'sourceModifiedAtMillis': sourceModifiedAtMillis,
    'chapters': meta.chapters
        .map(
          (chapter) => {
            'title': chapter.title,
            'start': chapter.start.toString(),
            'end': chapter.end.toString(),
          },
        )
        .toList(),
  });
}

book_file.BookMeta? decodeBookMeta(String? raw) {
  return decodeBookMetaRecord(raw)?.meta;
}

BookSourceSignature decodeBookSourceSignature(String? raw) {
  return decodeBookMetaRecord(raw)?.sourceSignature ?? const BookSourceSignature();
}

DecodedBookMeta? decodeBookMetaRecord(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final map = jsonDecode(raw);
    if (map is! Map<String, dynamic>) return null;
    final chapters = ((map['chapters'] as List<dynamic>?) ?? const <dynamic>[])
        .map(
          (item) => item as Map<String, dynamic>,
        )
        .map(
          (item) => book_file.BookChapter(
            title: (item['title'] as String?) ?? '',
            start: BigInt.parse('${item['start'] ?? 0}'),
            end: BigInt.parse('${item['end'] ?? 0}'),
          ),
        )
        .toList(growable: false);
    return DecodedBookMeta(
      meta: book_file.BookMeta(
        locator: (map['locator'] as String?) ?? '',
        title: (map['title'] as String?) ?? '',
        author: (map['author'] as String?) ?? '',
        format: (map['format'] as String?) ?? '',
        encoding: (map['encoding'] as String?) ?? '',
        sizeBytes: BigInt.parse('${map['sizeBytes'] ?? 0}'),
        coverDataUrl: map['coverDataUrl'] as String?,
        chapters: chapters,
      ),
      sourceSignature: BookSourceSignature(
        sizeBytes: (map['sourceSizeBytes'] as num?)?.toInt(),
        modifiedAtMillis: (map['sourceModifiedAtMillis'] as num?)?.toInt(),
      ),
    );
  } catch (_) {
    return null;
  }
}