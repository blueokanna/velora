import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/app_keys.dart';
import 'package:velora/features/settings/settings_page.dart';
import 'package:velora/l10n/app_localizations.dart';
import 'package:velora/state/settings.dart';
import 'package:velora/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Locale? resolveLocale(String code) {
    if (code == 'system') return null;
    if (code.contains('_')) {
      final parts = code.split('_');
      return Locale.fromSubtags(languageCode: parts[0], scriptCode: parts[1]);
    }
    return Locale(code);
  }

  testWidgets('设置页切换语言会更新状态与文案', (tester) async {
    SharedPreferences.setMockInitialValues({'locale': 'en'});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, child) {
            final settings = ref.watch(settingsProvider);
            return MaterialApp(
              locale: resolveLocale(settings.locale),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: const SettingsPage(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(AppKeys.settingsPage), findsOneWidget);

    await tester.tap(find.byKey(AppKeys.settingsLanguageTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(AppKeys.settingsOption('de')));
    await tester.pumpAndSettle();

    expect(container.read(settingsProvider).locale, 'de');
    expect(find.text('Einstellungen'), findsOneWidget);
  });

  testWidgets('设置页可切换主题模式与主题风格', (tester) async {
    SharedPreferences.setMockInitialValues({'locale': 'en'});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, child) {
            final settings = ref.watch(settingsProvider);
            return MaterialApp(
              locale: resolveLocale(settings.locale),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: const SettingsPage(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(AppKeys.settingsThemeModeTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(AppKeys.settingsOption(ThemeMode.dark)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(AppKeys.settingsThemeFlavorTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(AppKeys.settingsOption(ThemeFlavor.monet)));
    await tester.pumpAndSettle();

    expect(container.read(settingsProvider).themeMode, ThemeMode.dark);
    expect(container.read(settingsProvider).flavor, ThemeFlavor.monet);
  });
}
