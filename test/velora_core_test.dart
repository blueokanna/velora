import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:charset/charset.dart';
import 'package:velora/features/reader/paginator.dart';
import 'package:velora/features/reader/reader_bookmarks.dart';
import 'package:velora/services/local_books.dart'
    show deriveLocalBookTitle, resolveStoredBookCover;
import 'package:velora/services/rss_source.dart';
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
        decodeImportResponseBody,
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

Map<String, Object?> _rssSourceJson(
  String name,
  String url, {
  String? ruleArticles,
  String? ruleTitle,
  String? ruleDescription,
  String? ruleLink,
  String? ruleContent,
}) {
  return {
    'sourceName': name,
    'sourceUrl': url,
    'enabled': true,
    if (ruleArticles != null) 'ruleArticles': ruleArticles,
    if (ruleTitle != null) 'ruleTitle': ruleTitle,
    if (ruleDescription != null) 'ruleDescription': ruleDescription,
    if (ruleLink != null) 'ruleLink': ruleLink,
    if (ruleContent != null) 'ruleContent': {'content': ruleContent},
  };
}

Future<BookSourceModel> _importedSource(
  SharedPreferences prefs,
  String name,
  String url,
) async {
  final notifier = SourcesNotifier(prefs);
  await notifier.importJson(jsonEncode(_sourceJson(name, url)));
  return notifier.state.firstWhere((item) => item.url == url);
}

class _MockImportResponse {
  const _MockImportResponse({
    required this.body,
    required this.contentType,
    this.statusCode = HttpStatus.ok,
  });

  final List<int> body;
  final String contentType;
  final int statusCode;
}

class _MockImportServer {
  _MockImportServer._(this._server, this.responses);

  final HttpServer _server;
  final Map<String, _MockImportResponse> responses;

  static Future<_MockImportServer> start(
    Map<String, _MockImportResponse> responses,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _MockImportServer._(server, responses);
    server.listen((request) async {
      final responseSpec = responses[request.uri.path];
      if (responseSpec == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      request.response.statusCode = responseSpec.statusCode;
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        responseSpec.contentType,
      );
      request.response.add(responseSpec.body);
      await request.response.close();
    });
    return instance;
  }

  Uri uri(String path) =>
      Uri.parse('http://${_server.address.host}:${_server.port}$path');

  Future<void> close() async {
    await _server.close(force: true);
  }
}

class _PassthroughHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

Future<T> _runWithRealHttp<T>(Future<T> Function() action) {
  return HttpOverrides.runWithHttpOverrides(
    action,
    _PassthroughHttpOverrides(),
  );
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

  test('deriveLocalBookTitle prefers original source name over cache stem', () {
    expect(
      deriveLocalBookTitle(
        metaTitle: '344cde6b29cb55266ea',
        sourceName: '杀神.txt',
        pathOrUrl: r'D:\books\344cde6b29cb55266ea\344cde6b29cb55266ea.txt',
      ),
      '杀神',
    );

    expect(
      deriveLocalBookTitle(
        metaTitle: '杀神',
        sourceName: '杀神.txt',
        pathOrUrl: r'D:\books\abc\杀神.txt',
      ),
      '杀神',
    );
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
    'Book source validation and rule version survive import serialization',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = SourcesNotifier(prefs);
      final payload = _sourceJson('可验证书源', 'https://validation.example')
        ..['version'] = 7
        ..['validation'] = {
          'min_text_chars': 320,
          'deny_keywords': ['自定义验证页', '请登录'],
        };

      await notifier.importJson(jsonEncode(payload));

      final source = notifier.state.single;
      expect(source.ruleVersion, 7);
      expect(source.minTextChars, 320);
      expect(source.denyKeywords, ['自定义验证页', '请登录']);
      final serialized =
          jsonDecode(source.toJsonString()) as Map<String, dynamic>;
      expect(serialized['rule_version'], 7);
      expect(
        (serialized['validation'] as Map<String, dynamic>)['min_text_chars'],
        320,
      );
    },
  );

  test('SourcesNotifier maps explore and RSS rule fields', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final notifier = SourcesNotifier(prefs);

    await notifier.importJson(
      jsonEncode({
        'bookSourceName': '探索书源',
        'bookSourceUrl': 'https://example.org',
        'enabled': true,
        'enabledExplore': true,
        'exploreUrl': '男生::/discover/{{page}}',
        'ruleExplore': {
          'bookList': '.card',
          'name': '.title',
          'author': '.author',
          'bookUrl': 'a',
          'coverUrl': 'img',
        },
        'searchUrl': 'https://example.org/search?q={key}',
        'ruleSearch': {
          'bookList': '.result',
          'name': '.title',
          'author': '.author',
          'bookUrl': 'a',
        },
        'ruleBookInfo': {'name': 'h1', 'author': '.author', 'intro': '.intro'},
        'ruleToc': {
          'chapterList': '.chapter',
          'chapterName': 'a',
          'chapterUrl': 'a',
        },
        'ruleContent': {'content': '#content'},
      }),
    );
    await notifier.importJson(
      jsonEncode(
        _rssSourceJson(
          'RSS 订阅',
          'https://example.org/feed.xml',
          ruleArticles: r'$.items[*]',
          ruleTitle: r'$.title',
          ruleDescription: r'$.summary',
          ruleLink: r'$.link',
          ruleContent: r'$.content',
        ),
      ),
    );

    final explore = notifier.state.firstWhere((item) => item.name == '探索书源');
    final rss = notifier.state.firstWhere((item) => item.name == 'RSS 订阅');

    expect(explore.enabledExplore, isTrue);
    expect(explore.exploreEntryUrls, ['https://example.org/discover/1']);
    expect(
      explore.toExploreSearchSource(explore.exploreEntryUrls.first),
      isNotNull,
    );
    expect(
      explore.toExploreSearchSource(explore.exploreEntryUrls.first)!.searchList,
      '.card',
    );
    expect(rss.isRssSource, isTrue);
    expect(rss.rssArticles, r'$.items[*]');
    expect(rss.rssTitle, r'$.title');
    expect(rss.rssLink, r'$.link');
    expect(rss.rssContent, r'$.content');
    expect(rss.contentSelector, isEmpty);
  });

  test('SourcesNotifier accepts JSON exploreUrl category payloads', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final notifier = SourcesNotifier(prefs);

    await notifier.importJson(
      jsonEncode({
        'bookSourceName': '分类发现书源',
        'bookSourceUrl': 'https://example.org',
        'enabled': true,
        'enabledExplore': true,
        'exploreUrl': jsonEncode([
          {
            'title': '【分类】',
            'url': '',
            'style': {'layout_flexBasisPercent': 1},
          },
          {
            'title': '男生',
            'url': '/discover/male/{{page}}',
            'style': {'layout_flexBasisPercent': 0.5},
          },
          {
            'title': '女生',
            'url': 'https://cdn.example.org/discover/female/{{page}}',
          },
        ]),
        'ruleExplore': {
          'bookList': '.card',
          'name': '.title',
          'author': '.author',
          'bookUrl': 'a',
          'coverUrl': 'img',
        },
        'ruleBookInfo': {'name': 'h1', 'author': '.author', 'intro': '.intro'},
        'ruleToc': {
          'chapterList': '.chapter',
          'chapterName': 'a',
          'chapterUrl': 'a',
        },
        'ruleContent': {'content': '#content'},
      }),
    );

    final source = notifier.state.single;
    expect(source.exploreEntryUrls, [
      'https://example.org/discover/male/1',
      'https://cdn.example.org/discover/female/1',
    ]);
    expect(
      source.toExploreSearchSource(source.exploreEntryUrls.first),
      isNotNull,
    );
    expect(
      source.toExploreSearchSource(source.exploreEntryUrls.first)!.searchUrl,
      'https://example.org/discover/male/1',
    );
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
    'RssSourceService loads standard RSS feed and caches readable text',
    () async {
      await _runWithRealHttp(() async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final server = await _MockImportServer.start({
          '/feed.xml': _MockImportResponse(
            contentType: 'application/rss+xml; charset=utf-8',
            body: utf8.encode('''
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0">
              <channel>
                <title>Velora Feed</title>
                <item>
                  <title>第一篇</title>
                  <link>https://example.com/post-1</link>
                  <description><![CDATA[<p>这是一段可读内容</p>]]></description>
                  <author>Velora</author>
                  <pubDate>Fri, 29 May 2026 12:00:00 GMT</pubDate>
                </item>
              </channel>
            </rss>
          '''),
          ),
        });
        addTearDown(server.close);
        const service = RssSourceService();
        final source = BookSourceModel.fromJson(
          _rssSourceJson('标准 RSS', server.uri('/feed.xml').toString()),
        );

        final results = await service.loadItems(
          prefs,
          source: source,
          maxItems: 8,
        );

        expect(results, hasLength(1));
        expect(
          RssSourceService.isSyntheticBookUrl(results.single.bookUrl),
          isTrue,
        );
        expect(results.single.name, '第一篇');

        final content = await service.loadReadableContent(
          prefs,
          source: source,
          syntheticUrl: results.single.bookUrl,
          fallbackTitle: results.single.name,
        );

        expect(content, '这是一段可读内容');
      });
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

  test('Source import helpers detect encoded yuedu links in mixed text', () {
    final mixed = '''
      https://www.yckceo.com/yuedu/shuyuans/json/id/1112.json
      yuedu://booksource/importonline?src=https%3A%2F%2Fwww.yckceo.com%2Fyuedu%2Fshuyuans%2Fjson%2Fid%2F1113.json
    ''';

    final urls = extractSourceImportUrls(mixed);

    expect(
      urls,
      contains('https://www.yckceo.com/yuedu/shuyuans/json/id/1112.json'),
    );
    expect(
      urls,
      contains('https://www.yckceo.com/yuedu/shuyuans/json/id/1113.json'),
    );
  });

  test(
    'Source import response decoding keeps UTF-8 source payloads intact',
    () {
      final payload = jsonEncode(
        _sourceJson('测试书源', 'https://utf8.example.com'),
      );

      final decoded = decodeImportResponseBody(utf8.encode(payload));

      expect(decoded, contains('测试书源'));
      expect(decoded, contains('https://utf8.example.com'));
    },
  );

  test('Source import response decoding auto-detects GBK payloads', () {
    final payload = jsonEncode(_sourceJson('中文书源', 'https://gbk.example.com'));
    final gbk = Charset.getByName('gbk')!;

    final decoded = decodeImportResponseBody(
      gbk.encode(payload),
      contentType: 'application/json; charset=gb2312',
    );

    expect(decoded, contains('中文书源'));
    expect(decoded, contains('https://gbk.example.com'));
  });

  test(
    'SourcesNotifier imports UTF-8 payloads over HTTP with JSON content-type',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = SourcesNotifier(prefs);
      final payload = jsonEncode(
        _sourceJson('网络 UTF-8 书源', 'https://utf8.mock.example'),
      );
      final server = await _MockImportServer.start({
        '/utf8.json': _MockImportResponse(
          body: utf8.encode(payload),
          contentType: 'application/json; charset=utf-8',
        ),
      });
      addTearDown(server.close);

      final imported = await _runWithRealHttp(
        () => notifier.importTextOrUrl(server.uri('/utf8.json').toString()),
      );

      expect(imported, 1);
      expect(notifier.state, hasLength(1));
      expect(notifier.state.single.name, '网络 UTF-8 书源');
      expect(notifier.state.single.url, 'https://utf8.mock.example');
    },
  );

  test(
    'SourcesNotifier imports GBK payloads despite mojibake charset headers',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = SourcesNotifier(prefs);
      final payload = jsonEncode(
        _sourceJson('网络中文书源', 'https://gbk.mock.example'),
      );
      final gbk = Charset.getByName('gbk')!;
      final server = await _MockImportServer.start({
        '/legacy.txt': _MockImportResponse(
          body: gbk.encode(payload),
          contentType: 'text/plain; charset=iso-8859-1',
        ),
      });
      addTearDown(server.close);

      final imported = await _runWithRealHttp(
        () => notifier.importTextOrUrl(server.uri('/legacy.txt').toString()),
      );

      expect(imported, 1);
      expect(notifier.state, hasLength(1));
      expect(notifier.state.single.name, '网络中文书源');
      expect(notifier.state.single.url, 'https://gbk.mock.example');
    },
  );

  test(
    'SourcesNotifier follows mislabelled HTML import pages to nested source payloads',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = SourcesNotifier(prefs);
      final gbk = Charset.getByName('gbk')!;
      final responses = <String, _MockImportResponse>{};
      final server = await _MockImportServer.start(responses);
      addTearDown(server.close);
      final payload = jsonEncode(
        _sourceJson('页面导入书源', 'https://html.mock.example'),
      );
      final nestedUrl = server.uri('/nested.json').toString();
      final yueduLink =
          'yuedu://booksource/importonline?src=${Uri.encodeComponent(nestedUrl)}';
      final html =
          '''
      <html>
        <head><title>书源导入页</title></head>
        <body>
          <a href="$yueduLink">立即导入</a>
        </body>
      </html>
    ''';
      responses['/import.html'] = _MockImportResponse(
        body: gbk.encode(html),
        contentType: 'text/html; charset=windows-1252',
      );
      responses['/nested.json'] = _MockImportResponse(
        body: gbk.encode(payload),
        contentType: 'application/json; charset=latin1',
      );

      final imported = await _runWithRealHttp(
        () => notifier.importTextOrUrl(server.uri('/import.html').toString()),
      );

      expect(imported, 1);
      expect(notifier.state, hasLength(1));
      expect(notifier.state.single.name, '页面导入书源');
      expect(notifier.state.single.url, 'https://html.mock.example');
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
