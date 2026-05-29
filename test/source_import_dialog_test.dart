import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/features/sources/sources_page.dart';
import 'package:velora/l10n/app_localizations.dart';
import 'package:velora/state/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('书源导入对话框会在输入后立即启用导入按钮', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const SourcesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.file_upload_outlined).first);
    await tester.pumpAndSettle();

    final importButtonFinder = find.widgetWithText(FilledButton, '导入');
    expect(tester.widget<FilledButton>(importButtonFinder).onPressed, isNull);

    await tester.enterText(
      find.byType(TextField),
      '{"bookSourceName":"测试","bookSourceUrl":"https://example.com"}',
    );
    await tester.pump();

    expect(
      tester.widget<FilledButton>(importButtonFinder).onPressed,
      isNotNull,
    );
  });
}
