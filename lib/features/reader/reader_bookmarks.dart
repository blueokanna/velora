import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/settings.dart';

@immutable
class ReaderBookmark {
  final String id;
  final String bookId;
  final String bookTitle;
  final int chapterIndex;
  final String chapterTitle;
  final int pageIndex;
  final String preview;
  final int createdAt;

  const ReaderBookmark({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.pageIndex,
    required this.preview,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'bookId': bookId,
    'bookTitle': bookTitle,
    'chapterIndex': chapterIndex,
    'chapterTitle': chapterTitle,
    'pageIndex': pageIndex,
    'preview': preview,
    'createdAt': createdAt,
  };

  factory ReaderBookmark.fromJson(Map<String, dynamic> json) => ReaderBookmark(
    id: (json['id'] as String?) ?? '',
    bookId: (json['bookId'] as String?) ?? '',
    bookTitle: (json['bookTitle'] as String?) ?? '',
    chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 0,
    chapterTitle: (json['chapterTitle'] as String?) ?? '',
    pageIndex: (json['pageIndex'] as num?)?.toInt() ?? 0,
    preview: (json['preview'] as String?) ?? '',
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
  );
}

class ReaderBookmarksStore {
  ReaderBookmarksStore(this._prefs);

  final SharedPreferences _prefs;

  static const _key = 'reader_bookmarks';

  List<ReaderBookmark> list(String bookId) {
    final bookmarks = _all();
    bookmarks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return bookmarks.where((item) => item.bookId == bookId).toList(growable: false);
  }

  bool contains(String bookId, int chapterIndex, int pageIndex) {
    return _all().any(
      (item) => item.bookId == bookId && item.chapterIndex == chapterIndex && item.pageIndex == pageIndex,
    );
  }

  Future<List<ReaderBookmark>> add({
    required String bookId,
    required String bookTitle,
    required int chapterIndex,
    required String chapterTitle,
    required int pageIndex,
    required String preview,
  }) async {
    final bookmarks = _all();
    final id = '$bookId::$chapterIndex::$pageIndex';
    bookmarks.removeWhere((item) => item.id == id);
    bookmarks.add(
      ReaderBookmark(
        id: id,
        bookId: bookId,
        bookTitle: bookTitle,
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        pageIndex: pageIndex,
        preview: preview.trim(),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await _save(bookmarks);
    return list(bookId);
  }

  Future<List<ReaderBookmark>> remove(String id, String bookId) async {
    final bookmarks = _all();
    bookmarks.removeWhere((item) => item.id == id);
    await _save(bookmarks);
    return list(bookId);
  }

  List<ReaderBookmark> _all() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return <ReaderBookmark>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <ReaderBookmark>[];
    return decoded
        .whereType<Map>()
        .map((item) => item.map((key, value) => MapEntry('$key', value)))
        .map(ReaderBookmark.fromJson)
        .toList(growable: true);
  }

  Future<void> _save(List<ReaderBookmark> bookmarks) {
    return _prefs.setString(
      _key,
      jsonEncode(bookmarks.map((item) => item.toJson()).toList(growable: false)),
    );
  }
}

final readerBookmarksStoreProvider = Provider<ReaderBookmarksStore>((ref) {
  return ReaderBookmarksStore(ref.watch(sharedPreferencesProvider));
});