import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:velora/app_keys.dart';
import 'package:velora/l10n/app_localizations.dart';

import 'test_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('打开小说时展示进度并进入阅读页', (tester) async {
    final seeded = await launchSeededApp(tester, locale: 'en');

    await tester.tap(find.byKey(AppKeys.bookshelfBook(seeded.entry.id)));
    await tester.pump(const Duration(milliseconds: 80));

    await pumpUntilAnyFound(tester, [
      find.byKey(AppKeys.readerLoading),
      find.byKey(AppKeys.readerViewport),
    ]);
    if (find.byKey(AppKeys.readerLoading).evaluate().isNotEmpty) {
      expect(find.byKey(AppKeys.readerLoadingProgress), findsOneWidget);
      expect(find.byKey(AppKeys.readerLoadingPercent), findsOneWidget);
    }

    await pumpUntilFound(tester, find.byKey(AppKeys.readerViewport));
    expect(find.byKey(AppKeys.readerPageBody), findsOneWidget);
  });

  testWidgets('切换德语后界面文案同步更新', (tester) async {
    await launchSeededApp(tester, locale: 'en');

    await tester.tap(find.byKey(AppKeys.navSettings).last);
    await tester.pumpAndSettle();
    await pumpUntilFound(tester, find.byKey(AppKeys.settingsPage));

    await tester.tap(find.byKey(AppKeys.settingsLanguageTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(AppKeys.settingsOption('de')));
    await tester.pumpAndSettle();

    expect(find.text('Einstellungen'), findsWidgets);

    await tester.tap(find.byKey(AppKeys.navBookshelf).last);
    await tester.pumpAndSettle();
    expect(find.text('Buchregal'), findsWidgets);
  });

  testWidgets('阅读页功能栏跳转设置页稳定可用', (tester) async {
    final seeded = await launchSeededApp(tester, locale: 'en');

    await openSeededBook(tester, seeded);
    await showReaderOverlay(tester);

    final settingsButton = tester.widget<IconButton>(
      find.byKey(AppKeys.readerOverlaySettings),
    );
    expect(settingsButton.onPressed, isNotNull);
    settingsButton.onPressed!.call();
    await tester.pumpAndSettle();

    await pumpUntilFound(tester, find.byKey(AppKeys.settingsPage));
    expect(find.byKey(AppKeys.settingsLanguageTile), findsOneWidget);
  });

  testWidgets('阅读页阅读设置面板稳定可用', (tester) async {
    final seeded = await launchSeededApp(tester, locale: 'en');

    await openSeededBook(tester, seeded);
    await showReaderOverlay(tester);

    final readerSettingsButton = tester.widget<IconButton>(
      find.byKey(AppKeys.readerOverlayReaderSettings),
    );
    expect(readerSettingsButton.onPressed, isNotNull);
    readerSettingsButton.onPressed!.call();
    await tester.pumpAndSettle();

    expect(
      find.text(AppLocalizations(const Locale('en')).readerFont),
      findsOneWidget,
    );
    expect(find.text('Noto Serif SC'), findsWidgets);
  });
}
