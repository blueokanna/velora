import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/features/reader/reader_bookmarks.dart';
import 'package:velora/features/reader/paginator.dart';
import 'package:velora/state/settings.dart';
import 'package:velora/state/sources.dart';
import 'package:velora/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  AppTheme.useGoogleFonts = false;

  test('Pantone light theme uses Material 3 and Cloud Dancer surface', () {
    final theme = AppTheme.light(flavor: ThemeFlavor.pantone);

    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.surface, VeloraPalette.cloudDancer);
    expect(theme.colorScheme.brightness, Brightness.light);
  });

  test('AMOLED dark theme uses black surface containers', () {
    final theme = AppTheme.dark(flavor: ThemeFlavor.amoled);

    expect(theme.colorScheme.surface, Colors.black);
    expect(theme.scaffoldBackgroundColor, Colors.black);
    expect(theme.colorScheme.brightness, Brightness.dark);
  });

  testWidgets('TextPaginator splits long novel text without losing content', (
    tester,
  ) async {
    const text = '第1章 初见\n\n这是第一段内容。这里继续铺陈人物和场景。\n这是第二段内容。这里继续铺陈冲突和转折。';
    final paginator = TextPaginator(
      style: const TextStyle(fontSize: 18, height: 1.7),
      maxWidth: 180,
      maxHeight: 90,
    );

    final pages = paginator.paginate(text);

    expect(pages.length, greaterThan(1));
    expect(pages.join(), text);
  });

  testWidgets('TextPaginator supports incremental windows', (tester) async {
    const text = '第一段。第二段。第三段。第四段。第五段。第六段。第七段。第八段。第九段。第十段。';
    final paginator = TextPaginator(
      style: const TextStyle(fontSize: 18, height: 1.7),
      maxWidth: 180,
      maxHeight: 90,
    );

    final first = paginator.paginateWindow(text, startOffset: 0, maxPages: 2);
    final second = paginator.paginateWindow(
      text,
      startOffset: first.nextOffset,
      maxPages: 2,
    );

    expect(first.pages, isNotEmpty);
    expect(first.nextOffset, greaterThan(0));
    expect(
      first.pages.followedBy(second.pages).map((page) => page.text).join(),
      text,
    );
  });

  test('SourcesNotifier imports Legado compatible source json', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final notifier = SourcesNotifier(prefs);
    final json = jsonEncode({
      'name': '测试书源',
      'url': 'https://example.com',
      'enabled': true,
      'search_url': 'https://example.com/search?q={key}',
      'search_list': '.book',
      'search_name': '.name',
      'search_author': '.author',
      'search_book_url': 'a',
      'book_info_name': 'h1',
      'book_info_author': '.author',
      'book_info_intro': '.intro',
      'book_info_toc_url': '.toc a',
      'toc_list': '.chapter',
      'toc_name': 'a',
      'toc_url': 'a',
      'content_selector': '#content',
    });

    await notifier.importJson(json);

    expect(notifier.state, hasLength(1));
    expect(notifier.state.single.name, '测试书源');
    expect(notifier.state.single.toJsonString(), contains('content_selector'));
  });

  test('SettingsNotifier persists core reading settings', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final notifier = SettingsNotifier(prefs);

    await notifier.update(
      (settings) => settings.copyWith(
        themeMode: ThemeMode.dark,
        flavor: ThemeFlavor.amoled,
        pageTurnEffect: PageTurnEffect.curl,
        readerFont: ReaderFontPreset.lora,
        lineHeight: 1.9,
      ),
    );
    final reloaded = SettingsNotifier(prefs);

    expect(reloaded.state.themeMode, ThemeMode.dark);
    expect(reloaded.state.flavor, ThemeFlavor.amoled);
    expect(reloaded.state.pageTurnEffect, PageTurnEffect.curl);
    expect(reloaded.state.readerFont, ReaderFontPreset.lora);
    expect(reloaded.state.lineHeight, 1.9);
  });

  test('ReaderBookmarksStore adds and removes bookmarks', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = ReaderBookmarksStore(prefs);

    final created = await store.add(
      bookId: 'book-1',
      bookTitle: '测试书',
      chapterIndex: 2,
      chapterTitle: '第三章',
      pageIndex: 15,
      preview: '这里是书签预览',
    );

    expect(created, hasLength(1));
    expect(store.contains('book-1', 2, 15), isTrue);

    final remaining = await store.remove(created.single.id, 'book-1');

    expect(remaining, isEmpty);
  });
}
