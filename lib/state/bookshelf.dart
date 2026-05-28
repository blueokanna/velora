import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../src/rust/api/storage.dart' as rs;

class BookshelfNotifier extends StateNotifier<AsyncValue<List<rs.BookshelfEntry>>> {
  BookshelfNotifier() : super(const AsyncValue.loading()) {
    refresh();
  }

  Future<void> refresh() async {
    try {
      final list = rs.listBookshelf().toList(growable: false)
        ..sort((left, right) {
          final updated = right.updatedAt.compareTo(left.updatedAt);
          if (updated != 0) return updated;
          final title = left.title.toLowerCase().compareTo(
            right.title.toLowerCase(),
          );
          if (title != 0) return title;
          return left.id.compareTo(right.id);
        });
      state = AsyncValue.data(list);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> upsert(rs.BookshelfEntry entry) async {
    rs.upsertBook(entry: entry);
    await refresh();
  }

  Future<void> upsertMany(Iterable<rs.BookshelfEntry> entries) async {
    for (final entry in entries) {
      rs.upsertBook(entry: entry);
    }
    await refresh();
  }

  Future<void> remove(String id) async {
    rs.removeBook(id: id);
    await refresh();
  }

  Future<void> removeMany(Iterable<String> ids) async {
    for (final id in ids) {
      rs.removeBook(id: id);
    }
    await refresh();
  }

  Future<void> updateProgress(String id, int chapter, BigInt offset) async {
    rs.updateProgress(
      id: id,
      chapter: chapter,
      offset: offset,
      ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await refresh();
  }
}

final bookshelfProvider = StateNotifierProvider<BookshelfNotifier,
    AsyncValue<List<rs.BookshelfEntry>>>((ref) {
  return BookshelfNotifier();
});
