import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/app_localizations.dart';
import 'router/app_router.dart';
import 'state/settings.dart';
import 'theme/app_theme.dart';

class VeloraApp extends ConsumerWidget {
  const VeloraApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final router = ref.watch(appRouterProvider);

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ));

    return DynamicColorBuilder(builder: (lightDynamic, darkDynamic) {
      final useDynamic = settings.useDynamicColor || settings.flavor == ThemeFlavor.monet;
      final lightScheme = useDynamic ? lightDynamic : null;
      final darkScheme = useDynamic ? darkDynamic : null;

      return MaterialApp.router(
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        title: 'Velora',
        theme: AppTheme.light(dynamicScheme: lightScheme, flavor: settings.flavor),
        darkTheme: AppTheme.dark(dynamicScheme: darkScheme, flavor: settings.flavor),
        themeMode: settings.themeMode,
        locale: _resolveLocale(settings.locale),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        localeListResolutionCallback: (locales, supported) {
          if (settings.locale != 'system') {
            return _resolveLocale(settings.locale);
          }
          if (locales == null) return const Locale('en');
          for (final l in locales) {
            for (final s in supported) {
              if (s.languageCode == l.languageCode &&
                  (s.scriptCode == null || s.scriptCode == l.scriptCode)) {
                return s;
              }
            }
          }
          return const Locale('en');
        },
      );
    });
  }

  Locale? _resolveLocale(String code) {
    if (code == 'system') return null;
    if (code.contains('_')) {
      final parts = code.split('_');
      return Locale.fromSubtags(languageCode: parts[0], scriptCode: parts[1]);
    }
    return Locale(code);
  }
}
