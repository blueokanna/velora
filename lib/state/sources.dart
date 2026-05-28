import 'dart:convert';

import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/settings.dart';

class BookSourceModel {
  final String name;
  final String url;
  final bool enabled;
  final String searchUrl;
  final String searchList;
  final String searchName;
  final String searchAuthor;
  final String searchBookUrl;
  final String bookInfoName;
  final String bookInfoAuthor;
  final String bookInfoIntro;
  final String bookInfoTocUrl;
  final String tocList;
  final String tocName;
  final String tocUrl;
  final String contentSelector;

  const BookSourceModel({
    required this.name,
    required this.url,
    this.enabled = true,
    required this.searchUrl,
    required this.searchList,
    required this.searchName,
    required this.searchAuthor,
    required this.searchBookUrl,
    required this.bookInfoName,
    required this.bookInfoAuthor,
    required this.bookInfoIntro,
    required this.bookInfoTocUrl,
    required this.tocList,
    required this.tocName,
    required this.tocUrl,
    required this.contentSelector,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'enabled': enabled,
        'search_url': searchUrl,
        'search_list': searchList,
        'search_name': searchName,
        'search_author': searchAuthor,
        'search_book_url': searchBookUrl,
        'book_info_name': bookInfoName,
        'book_info_author': bookInfoAuthor,
        'book_info_intro': bookInfoIntro,
        'book_info_toc_url': bookInfoTocUrl,
        'toc_list': tocList,
        'toc_name': tocName,
        'toc_url': tocUrl,
        'content_selector': contentSelector,
      };

  String toJsonString() => jsonEncode(toJson());

  factory BookSourceModel.fromJson(Map<String, dynamic> j) => BookSourceModel(
        name: j['name'] as String,
        url: j['url'] as String,
        enabled: (j['enabled'] as bool?) ?? true,
        searchUrl: (j['search_url'] as String?) ?? '',
        searchList: (j['search_list'] as String?) ?? '',
        searchName: (j['search_name'] as String?) ?? '',
        searchAuthor: (j['search_author'] as String?) ?? '',
        searchBookUrl: (j['search_book_url'] as String?) ?? '',
        bookInfoName: (j['book_info_name'] as String?) ?? '',
        bookInfoAuthor: (j['book_info_author'] as String?) ?? '',
        bookInfoIntro: (j['book_info_intro'] as String?) ?? '',
        bookInfoTocUrl: (j['book_info_toc_url'] as String?) ?? '',
        tocList: (j['toc_list'] as String?) ?? '',
        tocName: (j['toc_name'] as String?) ?? '',
        tocUrl: (j['toc_url'] as String?) ?? '',
        contentSelector: (j['content_selector'] as String?) ?? '',
      );

  BookSourceModel copyWith({bool? enabled}) => BookSourceModel(
        name: name,
        url: url,
        enabled: enabled ?? this.enabled,
        searchUrl: searchUrl,
        searchList: searchList,
        searchName: searchName,
        searchAuthor: searchAuthor,
        searchBookUrl: searchBookUrl,
        bookInfoName: bookInfoName,
        bookInfoAuthor: bookInfoAuthor,
        bookInfoIntro: bookInfoIntro,
        bookInfoTocUrl: bookInfoTocUrl,
        tocList: tocList,
        tocName: tocName,
        tocUrl: tocUrl,
        contentSelector: contentSelector,
      );
}

class SourcesNotifier extends StateNotifier<List<BookSourceModel>> {
  SourcesNotifier(this._prefs) : super(_load(_prefs));
  final SharedPreferences _prefs;
  static const _key = 'book_sources';

  static List<BookSourceModel> _load(SharedPreferences p) {
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .cast<Map<String, dynamic>>()
        .map(BookSourceModel.fromJson)
        .toList();
  }

  Future<void> _persist() async {
    await _prefs.setString(
      _key,
      jsonEncode(state.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> addOrUpdate(BookSourceModel src) async {
    final exists = state.indexWhere((e) => e.url == src.url);
    final next = List<BookSourceModel>.from(state);
    if (exists >= 0) {
      next[exists] = src;
    } else {
      next.add(src);
    }
    state = next;
    await _persist();
  }

  Future<void> remove(String url) async {
    state = state.where((e) => e.url != url).toList();
    await _persist();
  }

  Future<void> toggle(String url, bool enabled) async {
    state = state
        .map((e) => e.url == url ? e.copyWith(enabled: enabled) : e)
        .toList();
    await _persist();
  }

  Future<void> importJson(String json) async {
    final decoded = jsonDecode(json);
    if (decoded is List) {
      for (final item in decoded.cast<Map<String, dynamic>>()) {
        await addOrUpdate(BookSourceModel.fromJson(item));
      }
    } else if (decoded is Map<String, dynamic>) {
      await addOrUpdate(BookSourceModel.fromJson(decoded));
    }
  }
}

final sourcesProvider =
    StateNotifierProvider<SourcesNotifier, List<BookSourceModel>>((ref) {
  return SourcesNotifier(ref.watch(sharedPreferencesProvider));
});
