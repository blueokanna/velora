import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/app_keys.dart';
import 'package:velora/features/reader/book_meta_codec.dart';
import 'package:velora/main.dart' as app;
import 'package:velora/src/rust/frb_generated.dart';
import 'package:velora/src/rust/api/book_file.dart' as book_file;
import 'package:velora/src/rust/api/storage.dart' as storage;
import 'package:velora/theme/app_theme.dart';

class SeededBook {
  final storage.BookshelfEntry entry;
  final String path;

  const SeededBook({required this.entry, required this.path});
}

bool _rustInitialized = false;

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
  Duration step = const Duration(milliseconds: 120),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for $finder');
}

Future<SeededBook> launchSeededApp(
  WidgetTester tester, {
  String locale = 'en',
}) async {
  late SeededBook seeded;
  await initRustForIntegrationTest();
  _configureIntegrationViewport(tester);
  GoogleFonts.config.allowRuntimeFetching = false;
  AppTheme.useGoogleFonts = false;
  addTearDown(() => AppTheme.useGoogleFonts = true);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await app.bootstrapVeloraApp(
    initializeRust: false,
    resolveDocsPath: _createIntegrationDocsPath,
    sharedPreferences: prefs,
    beforeRun: (docsPath, prefs) async {
      await _resetAppState(prefs);
      if (locale != 'system') {
        await prefs.setString('locale', locale);
      }
      seeded = await _seedBook(docsPath);
    },
  );
  await pumpUntilFound(tester, find.byKey(AppKeys.bookshelfPage));
  await pumpUntilFound(
    tester,
    find.byKey(AppKeys.bookshelfBook(seeded.entry.id)),
  );
  return seeded;
}

Future<void> initRustForIntegrationTest() async {
  if (_rustInitialized) {
    return;
  }
  await RustLib.init(externalLibrary: _resolveRustExternalLibrary());
  _rustInitialized = true;
}

Future<void> openSeededBook(WidgetTester tester, SeededBook seeded) async {
  await tester.tap(find.byKey(AppKeys.bookshelfBook(seeded.entry.id)));
  await tester.pump(const Duration(milliseconds: 80));
  if (find.byKey(AppKeys.readerLoading).evaluate().isEmpty) {
    await pumpUntilAnyFound(tester, [
      find.byKey(AppKeys.readerLoading),
      find.byKey(AppKeys.readerViewport),
    ]);
  }
  await pumpUntilFound(tester, find.byKey(AppKeys.readerViewport));
}

Future<void> showReaderOverlay(WidgetTester tester) async {
  final target = find.byKey(AppKeys.readerPageBody);
  await pumpUntilFound(tester, target);
  await tester.tapAt(tester.getCenter(target));
  await tester.pumpAndSettle();
  await pumpUntilFound(tester, find.byKey(AppKeys.readerOverlay));
}

Future<void> _resetAppState(SharedPreferences prefs) async {
  await prefs.clear();
  final existing = storage.listBookshelf();
  for (final entry in existing) {
    storage.removeBook(id: entry.id);
  }
}

Future<SeededBook> _seedBook(String docsPath) async {
  final file = File('$docsPath/integration_reader_fixture.txt');
  await file.writeAsString(_sampleBook, flush: true);
  final meta = book_file.openBookFile(path: file.path);
  final entry = storage.BookshelfEntry(
    id: 'local://${meta.locator}',
    title: meta.title,
    author: meta.author,
    kind: meta.format,
    pathOrUrl: meta.locator,
    bookMetaJson: encodeBookMeta(meta),
    cover: null,
    lastChapter: 0,
    lastOffset: BigInt.zero,
    updatedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    sourceName: null,
    sourceJson: null,
    tocUrl: null,
  );
  storage.upsertBook(entry: entry);
  return SeededBook(entry: entry, path: file.path);
}

final String _sampleBook = (() {
  final buffer = StringBuffer()
    ..writeln('第1章 风起')
    ..writeln(_chapterParagraphs('风吹过旧书页，纤维轻响，墨香被指尖慢慢推开。', 120))
    ..writeln('第2章 灯下')
    ..writeln(_chapterParagraphs('暖黄的灯光压低了房间的边缘，让阅读节奏变得安静而稳定。', 120))
    ..writeln('第3章 长夜')
    ..writeln(
      _chapterParagraphs('夜色很深，但翻页的动作仍旧明确，每一次前进都应该被温柔回应。', 120),
    );
  return buffer.toString();
})();

String _chapterParagraphs(String seed, int count) {
  return List<String>.generate(
    count,
    (index) => '$seed 第${index + 1}段，页面需要持续排版并展示明确进度。',
  ).join('\n');
}

ExternalLibrary? _resolveRustExternalLibrary() {
  if (!Platform.isWindows) {
    return null;
  }
  const candidates = [
    'rust/target/debug/deps/rust_lib_velora.dll',
    'rust/target/debug/rust_lib_velora.dll',
    'rust/target/release/rust_lib_velora.dll',
  ];
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) {
      return ExternalLibrary.open(file.absolute.path);
    }
  }
  throw ArgumentError('Rust dynamic library not found for integration test');
}

Future<String> _createIntegrationDocsPath() async {
  final dir = await Directory.systemTemp.createTemp('velora_integration_');
  return dir.path;
}

Future<void> pumpUntilAnyFound(
  WidgetTester tester,
  List<Finder> finders, {
  Duration timeout = const Duration(seconds: 15),
  Duration step = const Duration(milliseconds: 120),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(step);
    if (finders.any((finder) => finder.evaluate().isNotEmpty)) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for any finder to appear');
}

void _configureIntegrationViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1440, 2560);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}
