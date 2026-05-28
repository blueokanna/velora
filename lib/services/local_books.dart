import 'dart:io';

import '../features/reader/book_meta_codec.dart';
import '../services/document_file.dart';
import '../src/rust/api/book_file.dart' as book_file;
import '../src/rust/api/storage.dart' as rs;

class LocalBookSourceInfo {
  final String name;
  final int sizeBytes;
  final int? modifiedAtMillis;

  const LocalBookSourceInfo({
    required this.name,
    required this.sizeBytes,
    required this.modifiedAtMillis,
  });
}

bool isDocumentUriBook(rs.BookshelfEntry book) {
  return book.kind.endsWith('_uri') || book.pathOrUrl.startsWith('content://');
}

bool isManagedOfflineBook(rs.BookshelfEntry book) {
  return book.kind != 'online' &&
      (book.sourceJson == null || book.sourceJson!.isEmpty);
}

Future<LocalBookSourceInfo?> describeLocalBook(rs.BookshelfEntry book) async {
  if (!isManagedOfflineBook(book)) return null;
  if (isDocumentUriBook(book)) {
    if (!DocumentFileChannel.isAndroid) return null;
    final doc = await DocumentFileChannel.describeDocument(book.pathOrUrl);
    if (doc == null) return null;
    return LocalBookSourceInfo(
      name: doc.name,
      sizeBytes: doc.size,
      modifiedAtMillis: doc.lastModifiedMillis,
    );
  }
  final file = File(book.pathOrUrl);
  final stat = await file.stat();
  if (stat.type == FileSystemEntityType.notFound) {
    return null;
  }
  return LocalBookSourceInfo(
    name: _fileName(book.pathOrUrl),
    sizeBytes: stat.size,
    modifiedAtMillis: stat.modified.millisecondsSinceEpoch,
  );
}

Future<rs.BookshelfEntry?> refreshLocalBookEntry(
  rs.BookshelfEntry book, {
  bool force = false,
}) async {
  final source = await describeLocalBook(book);
  if (source == null) return null;
  final signature = decodeBookSourceSignature(book.bookMetaJson);
  final signatureChanged =
      force ||
      signature.sizeBytes != source.sizeBytes ||
      signature.modifiedAtMillis != source.modifiedAtMillis;
  final shouldRefresh =
      signatureChanged ||
      book.bookMetaJson == null ||
      book.bookMetaJson!.isEmpty ||
      book.cover == null ||
      book.cover!.isEmpty;
  if (!shouldRefresh) return null;

  final meta = await _openLocalBookMeta(book, source);
  final encoded = encodeBookMeta(
    meta,
    sourceSizeBytes: source.sizeBytes,
    sourceModifiedAtMillis: source.modifiedAtMillis,
  );
  final next = rs.BookshelfEntry(
    id: book.id,
    title: meta.title.trim().isEmpty ? source.name : meta.title,
    author: meta.author,
    kind: isDocumentUriBook(book) ? '${meta.format}_uri' : meta.format,
    pathOrUrl: book.pathOrUrl,
    bookMetaJson: encoded,
    cover: meta.coverDataUrl,
    lastChapter: book.lastChapter,
    lastOffset: book.lastOffset,
    updatedAt: signatureChanged
        ? DateTime.now().millisecondsSinceEpoch ~/ 1000
        : book.updatedAt,
    sourceName: book.sourceName,
    sourceJson: book.sourceJson,
    tocUrl: book.tocUrl,
  );
  return next == book ? null : next;
}

Future<book_file.BookMeta> _openLocalBookMeta(
  rs.BookshelfEntry book,
  LocalBookSourceInfo source,
) async {
  if (isDocumentUriBook(book)) {
    final bytes = await DocumentFileChannel.readBytes(book.pathOrUrl);
    return book_file.openBookBytes(
      locator: book.pathOrUrl,
      title: source.name,
      bytes: bytes,
    );
  }
  return book_file.openBookFile(path: book.pathOrUrl);
}

String _fileName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  if (index < 0 || index == normalized.length - 1) {
    return normalized;
  }
  return normalized.substring(index + 1);
}
