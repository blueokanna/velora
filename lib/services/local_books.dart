import 'dart:io';

import '../features/reader/book_meta_codec.dart';
import '../services/book_metadata_lookup.dart';
import '../services/document_file.dart';
import '../src/rust/api/book_file.dart' as book_file;
import '../src/rust/api/storage.dart' as rs;

const _metadataLookup = BookMetadataLookup();

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
  final title = meta.title.trim().isEmpty ? source.name : meta.title;
  final online = await _lookupLocalMetadata(
    title,
    author: meta.author,
    cover: meta.coverDataUrl,
    force: force,
  );
  final encoded = encodeBookMeta(
    meta,
    sourceSizeBytes: source.sizeBytes,
    sourceModifiedAtMillis: source.modifiedAtMillis,
  );
  final next = rs.BookshelfEntry(
    id: book.id,
    title: _preferText(title, online?.title),
    author: _preferText(meta.author, online?.author),
    kind: isDocumentUriBook(book) ? '${meta.format}_uri' : meta.format,
    pathOrUrl: book.pathOrUrl,
    bookMetaJson: encoded,
    cover: _preferText(meta.coverDataUrl ?? '', online?.coverUrl),
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

Future<rs.BookshelfEntry> enrichBookEntryMetadata(
  rs.BookshelfEntry entry, {
  bool force = false,
}) async {
  final needsLookup =
      force || entry.author.trim().isEmpty || _empty(entry.cover);
  if (!needsLookup) return entry;
  final online = entry.kind == 'online'
      ? await _metadataLookup.lookupByUrl(entry.pathOrUrl)
      : await _metadataLookup.lookupByTitle(entry.title, author: entry.author);
  if (online == null) return entry;
  return rs.BookshelfEntry(
    id: entry.id,
    title: _preferText(entry.title, online.title),
    author: _preferText(entry.author, online.author),
    kind: entry.kind,
    pathOrUrl: entry.pathOrUrl,
    bookMetaJson: entry.bookMetaJson,
    cover: _preferText(entry.cover ?? '', online.coverUrl),
    lastChapter: entry.lastChapter,
    lastOffset: entry.lastOffset,
    updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    sourceName: entry.sourceName ?? online.sourceName,
    sourceJson: entry.sourceJson,
    tocUrl: entry.tocUrl,
  );
}

Future<BookMetadata?> _lookupLocalMetadata(
  String title, {
  required String author,
  required String? cover,
  required bool force,
}) async {
  if (!force && author.trim().isNotEmpty && !_empty(cover)) return null;
  return _metadataLookup.lookupByTitle(title, author: author);
}

String _preferText(String current, String? candidate) {
  final normalized = current.trim();
  final next = candidate?.trim() ?? '';
  if (normalized.isNotEmpty && normalized != '未命名') return normalized;
  return next.isEmpty ? normalized : next;
}

bool _empty(String? value) => value == null || value.trim().isEmpty;

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
