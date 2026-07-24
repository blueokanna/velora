import 'dart:io';

import '../features/reader/book_meta_codec.dart';
import '../services/book_metadata_lookup.dart';
import '../services/document_file.dart';
import '../services/source_adapter.dart';
import '../src/rust/api/book_file.dart' as book_file;
import '../src/rust/api/book_source.dart' as source_api;
import '../src/rust/api/storage.dart' as rs;
import '../state/sources.dart';

const _metadataLookup = BookMetadataLookup();
const _sourceAdapter = SourceAdapterService();

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
  Iterable<BookSourceModel> sources = const [],
}) async {
  final migrated = await _migrateDocumentUriBook(book);
  final workingBook = migrated ?? book;
  final source = await describeLocalBook(workingBook);
  if (source == null) return null;
  final signature = decodeBookSourceSignature(workingBook.bookMetaJson);
  final signatureChanged =
      force ||
      migrated != null ||
      signature.sizeBytes != source.sizeBytes ||
      signature.modifiedAtMillis != source.modifiedAtMillis;
  final shouldRefresh =
      signatureChanged ||
      workingBook.bookMetaJson == null ||
      workingBook.bookMetaJson!.isEmpty ||
      workingBook.cover == null ||
      workingBook.cover!.isEmpty;
  if (!shouldRefresh) return migrated;

  final meta = await _openLocalBookMeta(workingBook, source);
  final title = deriveLocalBookTitle(
    metaTitle: meta.title,
    sourceName: source.name,
    pathOrUrl: workingBook.pathOrUrl,
  );
  final online = await _lookupLocalMetadata(
    title,
    author: meta.author,
    cover: meta.coverDataUrl,
    force: force,
    sources: sources,
  );
  final encoded = encodeBookMeta(
    meta,
    sourceSizeBytes: source.sizeBytes,
    sourceModifiedAtMillis: source.modifiedAtMillis,
  );
  final next = rs.BookshelfEntry(
    id: workingBook.id,
    title: _preferText(title, online?.title),
    author: _preferText(meta.author, online?.author),
    kind: meta.format,
    pathOrUrl: workingBook.pathOrUrl,
    bookMetaJson: encoded,
    cover: resolveStoredBookCover(
      currentCover: workingBook.cover,
      embeddedCover: meta.coverDataUrl,
      onlineCover: online?.coverUrl,
    ),
    lastChapter: workingBook.lastChapter,
    lastOffset: workingBook.lastOffset,
    updatedAt: signatureChanged
        ? DateTime.now().millisecondsSinceEpoch ~/ 1000
        : workingBook.updatedAt,
    sourceName: workingBook.sourceName,
    sourceJson: workingBook.sourceJson,
    tocUrl: workingBook.tocUrl,
  );
  return next == book ? null : next;
}

Future<rs.BookshelfEntry> enrichBookEntryMetadata(
  rs.BookshelfEntry entry, {
  bool force = false,
  Iterable<BookSourceModel> sources = const [],
}) async {
  final needsLookup =
      force || entry.author.trim().isEmpty || _empty(entry.cover);
  if (!needsLookup) return entry;
  final online = entry.kind == 'online'
      ? await _metadataLookup.lookupByUrl(entry.pathOrUrl)
      : await _lookupMetadataFromBookSources(
              entry.title,
              author: entry.author,
              sources: sources,
            ) ??
            await _metadataLookup.lookupByTitle(
              entry.title,
              author: entry.author,
            );
  if (online == null) return entry;
  return rs.BookshelfEntry(
    id: entry.id,
    title: _preferText(entry.title, online.title),
    author: _preferText(entry.author, online.author),
    kind: entry.kind,
    pathOrUrl: entry.pathOrUrl,
    bookMetaJson: entry.bookMetaJson,
    cover: resolveStoredBookCover(
      currentCover: entry.cover,
      embeddedCover: null,
      onlineCover: online.coverUrl,
    ),
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
  required Iterable<BookSourceModel> sources,
}) async {
  if (!force && author.trim().isNotEmpty && !_empty(cover)) return null;
  return await _lookupMetadataFromBookSources(
        title,
        author: author,
        sources: sources,
      ) ??
      await _metadataLookup.lookupByTitle(title, author: author);
}

Future<BookMetadata?> _lookupMetadataFromBookSources(
  String title, {
  required String author,
  required Iterable<BookSourceModel> sources,
}) async {
  final candidates = sources
      .where(
        (source) =>
            source.enabled &&
            source.searchUrl.trim().isNotEmpty &&
            source.searchList.trim().isNotEmpty &&
            !source.searchUrl.toLowerCase().contains('@js') &&
            !source.searchList.toLowerCase().contains('<js>'),
      )
      .take(4)
      .toList(growable: false);
  if (candidates.isEmpty) return null;
  final matches = await Future.wait(
    candidates.map(
      (source) =>
          _lookupMetadataFromBookSource(source, title: title, author: author),
    ),
  );
  for (final match in matches) {
    if (match != null && match.coverUrl.trim().isNotEmpty) return match;
  }
  return null;
}

Future<BookMetadata?> _lookupMetadataFromBookSource(
  BookSourceModel source, {
  required String title,
  required String author,
}) async {
  try {
    final searchRequestId = _sourceAdapter.createRequestId('local-cover');
    final results = await _sourceAdapter.search(
      source,
      title,
      requestId: searchRequestId,
    );
    final match = selectBestSourceMetadataMatch(
      results,
      title: title,
      author: author,
    );
    if (match == null) return null;
    var coverUrl = match.coverUrl.trim();
    var matchedAuthor = match.author.trim();
    var matchedTitle = match.name.trim();
    if (coverUrl.isEmpty) {
      final detailRequestId = _sourceAdapter.createRequestId(
        'local-cover-detail',
      );
      final detail = await _sourceAdapter.bookDetail(
        source.toJsonString(),
        match.bookUrl,
        requestId: detailRequestId,
      );
      coverUrl = detail.coverUrl.trim();
      if (detail.author.trim().isNotEmpty) matchedAuthor = detail.author.trim();
      if (detail.name.trim().isNotEmpty) matchedTitle = detail.name.trim();
    }
    if (coverUrl.isEmpty) return null;
    return BookMetadata(
      title: matchedTitle,
      author: matchedAuthor,
      description: '',
      coverUrl: coverUrl,
      detailUrl: match.bookUrl,
      sourceName: source.name,
    );
  } catch (_) {
    return null;
  }
}

source_api.SearchResult? selectBestSourceMetadataMatch(
  Iterable<source_api.SearchResult> results, {
  required String title,
  required String author,
}) {
  final expectedTitle = _normalizeBookIdentity(title);
  final expectedAuthor = _normalizeBookIdentity(author);
  source_api.SearchResult? best;
  var bestScore = -1;
  for (final result in results) {
    final candidateTitle = _normalizeBookIdentity(result.name);
    if (candidateTitle.isEmpty || expectedTitle.isEmpty) continue;
    var score = candidateTitle == expectedTitle
        ? 10
        : (candidateTitle.contains(expectedTitle) ||
              expectedTitle.contains(candidateTitle))
        ? 4
        : -1;
    if (score < 0) continue;
    final candidateAuthor = _normalizeBookIdentity(result.author);
    if (expectedAuthor.isNotEmpty && candidateAuthor.isNotEmpty) {
      if (candidateAuthor == expectedAuthor) {
        score += 4;
      } else if (!candidateAuthor.contains(expectedAuthor) &&
          !expectedAuthor.contains(candidateAuthor)) {
        score -= 3;
      }
    }
    if (result.coverUrl.trim().isNotEmpty) score += 2;
    if (score > bestScore) {
      bestScore = score;
      best = result;
    }
  }
  return bestScore >= 4 ? best : null;
}

String _normalizeBookIdentity(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\p{P}\p{S}_]+', unicode: true), '');

String deriveLocalBookTitle({
  required String metaTitle,
  required String sourceName,
  required String pathOrUrl,
}) {
  final normalizedMetaTitle = metaTitle.trim();
  final sourceStem = _displayFileStem(sourceName);
  if (normalizedMetaTitle.isEmpty || normalizedMetaTitle == '未命名') {
    return sourceStem.isEmpty ? '未命名' : sourceStem;
  }
  final localStem = _displayFileStem(_fileName(pathOrUrl));
  if (sourceStem.isNotEmpty &&
      sourceStem != localStem &&
      normalizedMetaTitle == localStem) {
    return sourceStem;
  }
  return normalizedMetaTitle;
}

String? resolveStoredBookCover({
  required String? currentCover,
  required String? embeddedCover,
  required String? onlineCover,
}) {
  final current = currentCover?.trim() ?? '';
  if (current.isNotEmpty) return current;
  final embedded = embeddedCover?.trim() ?? '';
  if (embedded.isNotEmpty) return embedded;
  final online = onlineCover?.trim() ?? '';
  if (online.isNotEmpty) return online;
  return null;
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
    final migrated = await _migrateDocumentUriBook(book);
    if (migrated == null) {
      throw StateError('无法建立本地阅读缓存');
    }
    return book_file.openBookFile(path: migrated.pathOrUrl);
  }
  return book_file.openBookFile(path: book.pathOrUrl);
}

Future<rs.BookshelfEntry?> _migrateDocumentUriBook(
  rs.BookshelfEntry book,
) async {
  if (!isDocumentUriBook(book) || !DocumentFileChannel.isAndroid) return null;
  final imported = await DocumentFileChannel.importDocument(book.pathOrUrl);
  final localPath = imported?.localPath;
  if (imported == null || localPath == null || localPath.isEmpty) {
    return null;
  }
  return rs.BookshelfEntry(
    id: book.id,
    title: book.title,
    author: book.author,
    kind: book.kind.replaceAll('_uri', ''),
    pathOrUrl: localPath,
    bookMetaJson: book.bookMetaJson,
    cover: book.cover,
    lastChapter: book.lastChapter,
    lastOffset: book.lastOffset,
    updatedAt: book.updatedAt,
    sourceName: book.sourceName,
    sourceJson: book.sourceJson,
    tocUrl: book.tocUrl,
  );
}

String _fileName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  if (index < 0 || index == normalized.length - 1) {
    return normalized;
  }
  return normalized.substring(index + 1);
}

String _displayFileStem(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  final fileName = _fileName(trimmed);
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) {
    return fileName;
  }
  return fileName.substring(0, dot);
}
