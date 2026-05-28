import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/features/reader/paginator.dart';
import 'package:velora/features/reader/reader_bookmarks.dart';
import 'package:velora/services/local_books.dart' show resolveStoredBookCover;
import 'package:velora/services/source_recommendations.dart';
import 'package:velora/src/rust/api/book_source.dart' as bs;
import 'package:velora/state/settings.dart';
import 'package:velora/state/sources.dart'
    show
        BookSourceModel,
        SourcesNotifier,
        SourceImportCancelled,
        SourceImportController,
        SourceImportStage,
        buildImportFetchCandidates,
        decodeSourceImportUrl,
        extractSourceImportUrls;
import 'package:velora/theme/app_theme.dart';

Map<String, Object?> _sourceJson(
  String name,
  String url, {
  bool enabled = true,
}) => {
  'name': name,
  'url': url,
  'enabled': enabled,
  'search_url': '$url/search?q={key}',
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
};

Future<BookSourceModel> _importedSource(
  SharedPreferences prefs,
  String name,
  String url,
) async {
  final notifier = SourcesNotifier(prefs);
  await notifier.importJson(jsonEncode(_sourceJson(name, url)));
  return notifier.state.firstWhere((item) => item.url == url);
}

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
    final json = jsonEncode(_sourceJson('测试书源', 'https://example.com'));

    await notifier.importJson(json);

    expect(notifier.state, hasLength(1));
    expect(notifier.state.single.name, '测试书源');
    expect(notifier.state.single.toJsonString(), contains('content_selector'));
  });

  test('SourcesNotifier maps Legado rule fields and cover selectors', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final notifier = SourcesNotifier(prefs);

    await notifier.importJson(
      jsonEncode({
        'bookSourceName': '社区书源',
        'bookSourceUrl': 'https://example.org',
        'enabled': true,
        'searchUrl': 'https://example.org/search?q={key}',
        'ruleSearch': {
          'bookList': '.result',
          'name': '.title',
          'author': '.author',
          'bookUrl': 'a',
          'coverUrl': 'img.cover',
        },
        'ruleBookInfo': {
          'name': 'h1',
          'author': '.book-author',
          'intro': '.intro',
          'coverUrl': '.cover img',
          'tocUrl': '.toc a',
        },
        'ruleToc': {
          'chapterList': '.chapter',
          'chapterName': 'a',
          'chapterUrl': 'a',
        },
        'ruleContent': {'content': '#content'},
      }),
    );

    final source = notifier.state.single;
    expect(source.name, '社区书源');
    expect(source.url, 'https://example.org');
    expect(source.searchList, '.result');
    expect(source.searchCover, 'img.cover');
    expect(source.bookInfoCover, '.cover img');
    expect(source.contentSelector, '#content');
  });

  test(
    'SourcesNotifier bulk import merges duplicate urls in one pass',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = SourcesNotifier(prefs);

      await notifier.importJson(
        jsonEncode(_sourceJson('旧书源', 'https://a.com')),
      );
      final imported = await notifier.importJson(
        jsonEncode([
          _sourceJson('新书源', 'https://a.com', enabled: false),
          _sourceJson('第二书源', 'https://b.com'),
        ]),
      );

      expect(imported, 1);
      expect(notifier.state, hasLength(2));
      expect(
        notifier.state.firstWhere((item) => item.url == 'https://a.com').name,
        '新书源',
      );
      expect(
        notifier.state
            .firstWhere((item) => item.url == 'https://a.com')
            .enabled,
        isFalse,
      );
    },
  );

  test('SourcesNotifier import can be cancelled before commit', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final notifier = SourcesNotifier(prefs);
    final controller = SourceImportController();

    await expectLater(
      notifier.importPayload(
        jsonEncode(
          List.generate(
            240,
            (index) => _sourceJson('书源$index', 'https://$index.example.com'),
          ),
        ),
        controller: controller,
        onProgress: (progress) {
          if (progress.stage == SourceImportStage.merging &&
              progress.processed >= 64) {
            controller.cancel();
          }
        },
      ),
      throwsA(isA<SourceImportCancelled>()),
    );

    expect(notifier.state, isEmpty);
  });

  test(
    'SourceRecommendationsService reads cached recommendations by signature',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const service = SourceRecommendationsService();

      await service.saveCached(
        prefs,
        signature: 'sig',
        results: const [
          bs.SearchResult(
            name: '测试书',
            author: '作者',
            bookUrl: 'https://book.example.com/1',
            coverUrl: 'https://img.example.com/1.jpg',
            sourceName: '示例书源',
          ),
        ],
      );

      final cached = await service.loadCached(prefs, signature: 'sig');

      expect(cached, isNotNull);
      expect(cached!.isExpired, isFalse);
      expect(cached.results.single.name, '测试书');
      expect(await service.loadCached(prefs, signature: 'other'), isNull);
    },
  );

  test(
    'SourceRecommendationsService assembles cached subsets from per-source entries',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const service = SourceRecommendationsService();
      final sourceA = await _importedSource(
        prefs,
        '源A',
        'https://a.example.com',
      );
      final sourceB = await _importedSource(
        prefs,
        '源B',
        'https://b.example.com',
      );

      await service.saveSourceCached(
        prefs,
        source: sourceA,
        results: const [
          bs.SearchResult(
            name: 'A-1',
            author: '作者A',
            bookUrl: 'https://book.example.com/a1',
            coverUrl: '',
            sourceName: '源A',
          ),
        ],
      );
      await service.saveSourceCached(
        prefs,
        source: sourceB,
        results: const [
          bs.SearchResult(
            name: 'B-1',
            author: '作者B',
            bookUrl: 'https://book.example.com/b1',
            coverUrl: '',
            sourceName: '源B',
          ),
        ],
      );

      final cached = await service.loadCachedSubset(
        prefs,
        sources: [sourceA, sourceB],
        collectionSignature: 'ab',
      );

      expect(cached, isNotNull);
      expect(cached!.isExpired, isFalse);
      expect(cached.results.map((item) => item.name), ['A-1', 'B-1']);
    },
  );

  test(
    'SourceRecommendationsService reuses cached subset when only one source changes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const service = SourceRecommendationsService();
      final sourceA = await _importedSource(
        prefs,
        '源A',
        'https://a.example.com',
      );
      final sourceB = await _importedSource(
        prefs,
        '源B',
        'https://b.example.com',
      );
      final sourceC = await _importedSource(
        prefs,
        '源C',
        'https://c.example.com',
      );

      await service.saveSourceCached(
        prefs,
        source: sourceA,
        results: const [
          bs.SearchResult(
            name: 'A-1',
            author: '作者A',
            bookUrl: 'https://book.example.com/a1',
            coverUrl: '',
            sourceName: '源A',
          ),
        ],
      );
      await service.saveSourceCached(
        prefs,
        source: sourceB,
        results: const [
          bs.SearchResult(
            name: 'B-1',
            author: '作者B',
            bookUrl: 'https://book.example.com/b1',
            coverUrl: '',
            sourceName: '源B',
          ),
        ],
      );

      final cached = await service.loadCachedSubset(
        prefs,
        sources: [sourceA, sourceC],
        collectionSignature: 'ac',
      );

      expect(cached, isNotNull);
      expect(cached!.results.map((item) => item.name), ['A-1']);
      expect(cached.isExpired, isTrue);
    },
  );

  test(
    'SourceRecommendationsService keeps multiple signatures with LRU eviction',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      const service = SourceRecommendationsService();

      for (
        var index = 0;
        index < SourceRecommendationsService.maxCacheEntries;
        index++
      ) {
        await service.saveCached(
          prefs,
          signature: 'sig$index',
          results: [
            bs.SearchResult(
              name: '书$index',
              author: '作者$index',
              bookUrl: 'https://book.example.com/$index',
              coverUrl: 'https://img.example.com/$index.jpg',
              sourceName: '源$index',
            ),
          ],
        );
      }

      expect(await service.loadCached(prefs, signature: 'sig0'), isNotNull);

      await service.saveCached(
        prefs,
        signature: 'sig-new',
        results: const [
          bs.SearchResult(
            name: '新书',
            author: '新作者',
            bookUrl: 'https://book.example.com/new',
            coverUrl: 'https://img.example.com/new.jpg',
            sourceName: '新源',
          ),
        ],
      );

      expect(await service.loadCached(prefs, signature: 'sig0'), isNotNull);
      expect(await service.loadCached(prefs, signature: 'sig1'), isNull);
      expect(await service.loadCached(prefs, signature: 'sig-new'), isNotNull);
    },
  );

  test(
    'SourceRecommendationsService can read legacy single snapshot cache',
    () async {
      SharedPreferences.setMockInitialValues({
        'discover_recommendations_cache_v1': jsonEncode({
          'signature': 'legacy',
          'cachedAt': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
          'items': [
            {
              'name': '旧缓存书',
              'author': '旧作者',
              'bookUrl': 'https://legacy.example.com/book',
              'coverUrl': 'https://legacy.example.com/cover.jpg',
              'sourceName': '旧书源',
            },
          ],
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      const service = SourceRecommendationsService();

      final cached = await service.loadCached(prefs, signature: 'legacy');

      expect(cached, isNotNull);
      expect(cached!.results.single.sourceName, '旧书源');
    },
  );

  test(
    'Source import helpers detect yuedu links, YCKCEO content pages, and batch URLs',
    () {
      final yuedu =
          'yuedu://booksource/importonline?src=https://www.yckceo.com/yuedu/shuyuans/json/id/1128.json';
      expect(
        decodeSourceImportUrl(yuedu),
        'https://www.yckceo.com/yuedu/shuyuans/json/id/1128.json',
      );

      final links = extractSourceImportUrls('''
        https://www.yckceo.com/yuedu/shuyuans/content/id/1128.html
        https://www.yckceo.com/yuedu/shuyuans/json/id/1127.json
        $yuedu
        ''');

      expect(
        links,
        contains('https://www.yckceo.com/yuedu/shuyuans/json/id/1128.json'),
      );
      expect(
        links,
        contains('https://www.yckceo.com/yuedu/shuyuans/json/id/1127.json'),
      );
    },
  );

  test(
    'Source import fetch candidates include http and bare-host fallbacks',
    () {
      final candidates = buildImportFetchCandidates(
        'https://www.yckceo.com/yuedu/shuyuans/json/id/1128.json',
      );

      expect(
        candidates,
        contains('https://www.yckceo.com/yuedu/shuyuans/json/id/1128.json'),
      );
      expect(
        candidates,
        contains('http://www.yckceo.com/yuedu/shuyuans/json/id/1128.json'),
      );
      expect(
        candidates,
        contains('https://yckceo.com/yuedu/shuyuans/json/id/1128.json'),
      );
      expect(
        candidates,
        contains('https://www.yckceo.com/yuedu/shuyuans/content/id/1128.html'),
      );
    },
  );

  test('Manual or remote covers are preserved ahead of embedded covers', () {
    expect(
      resolveStoredBookCover(
        currentCover: 'https://img.example.com/custom.jpg',
        embeddedCover: 'data:image/png;base64,abc',
        onlineCover: 'https://img.example.com/online.jpg',
      ),
      'https://img.example.com/custom.jpg',
    );
    expect(
      resolveStoredBookCover(
        currentCover: null,
        embeddedCover: 'data:image/png;base64,abc',
        onlineCover: 'https://img.example.com/online.jpg',
      ),
      'data:image/png;base64,abc',
    );
    expect(
      resolveStoredBookCover(
        currentCover: null,
        embeddedCover: null,
        onlineCover: 'https://img.example.com/online.jpg',
      ),
      'https://img.example.com/online.jpg',
    );
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
