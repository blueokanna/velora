import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

enum PageTurnEffect { slide, cover, curl, fade, scroll }

enum ReaderFontScale { small, normal, large, xLarge }

extension ReaderFontScaleX on ReaderFontScale {
  double get value => switch (this) {
    ReaderFontScale.small => 16,
    ReaderFontScale.normal => 18,
    ReaderFontScale.large => 20,
    ReaderFontScale.xLarge => 22,
  };
}

@immutable
class AppSettings {
  final ThemeMode themeMode;
  final ThemeFlavor flavor;
  final String locale;
  final PageTurnEffect pageTurnEffect;
  final ReaderFontPreset readerFont;
  final String readerFontFamily;
  final ReaderFontScale fontScale;
  final double lineHeight;
  final double pagePadding;
  final bool keepScreenOn;
  final bool useDynamicColor;

  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.flavor = ThemeFlavor.pantone,
    this.locale = 'system',
    this.pageTurnEffect = PageTurnEffect.cover,
    this.readerFont = ReaderFontPreset.notoSerif,
    this.readerFontFamily = 'Noto Serif SC',
    this.fontScale = ReaderFontScale.normal,
    this.lineHeight = 1.7,
    this.pagePadding = 20,
    this.keepScreenOn = true,
    this.useDynamicColor = false,
  });

  AppSettings copyWith({
    ThemeMode? themeMode,
    ThemeFlavor? flavor,
    String? locale,
    PageTurnEffect? pageTurnEffect,
    ReaderFontPreset? readerFont,
    String? readerFontFamily,
    ReaderFontScale? fontScale,
    double? lineHeight,
    double? pagePadding,
    bool? keepScreenOn,
    bool? useDynamicColor,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    flavor: flavor ?? this.flavor,
    locale: locale ?? this.locale,
    pageTurnEffect: pageTurnEffect ?? this.pageTurnEffect,
    readerFont: readerFont ?? this.readerFont,
    readerFontFamily: readerFontFamily ?? this.readerFontFamily,
    fontScale: fontScale ?? this.fontScale,
    lineHeight: lineHeight ?? this.lineHeight,
    pagePadding: pagePadding ?? this.pagePadding,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    useDynamicColor: useDynamicColor ?? this.useDynamicColor,
  );
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier(this._prefs) : super(_load(_prefs));

  final SharedPreferences _prefs;

  static AppSettings _load(SharedPreferences p) => AppSettings(
    themeMode: ThemeMode.values[p.getInt('themeMode') ?? 0],
    flavor: ThemeFlavor.values[p.getInt('flavor') ?? 0],
    locale: p.getString('locale') ?? 'system',
    pageTurnEffect: PageTurnEffect
        .values[p.getInt('pageTurnEffect') ?? PageTurnEffect.cover.index],
    readerFont: ReaderFontPreset
        .values[p.getInt('readerFont') ?? ReaderFontPreset.notoSerif.index],
    readerFontFamily: p.getString('readerFontFamily') ?? 'Noto Serif SC',
    fontScale: ReaderFontScale.values[p.getInt('fontScale') ?? 1],
    lineHeight: p.getDouble('lineHeight') ?? 1.7,
    pagePadding: p.getDouble('pagePadding') ?? 20,
    keepScreenOn: p.getBool('keepScreenOn') ?? true,
    useDynamicColor: p.getBool('useDynamicColor') ?? false,
  );

  Future<void> update(AppSettings Function(AppSettings) f) async {
    state = f(state);
    final s = state;
    await _prefs.setInt('themeMode', s.themeMode.index);
    await _prefs.setInt('flavor', s.flavor.index);
    await _prefs.setString('locale', s.locale);
    await _prefs.setInt('pageTurnEffect', s.pageTurnEffect.index);
    await _prefs.setInt('readerFont', s.readerFont.index);
    await _prefs.setString('readerFontFamily', s.readerFontFamily);
    await _prefs.setInt('fontScale', s.fontScale.index);
    await _prefs.setDouble('lineHeight', s.lineHeight);
    await _prefs.setDouble('pagePadding', s.pagePadding);
    await _prefs.setBool('keepScreenOn', s.keepScreenOn);
    await _prefs.setBool('useDynamicColor', s.useDynamicColor);
  }
}

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    '需要在 ProviderScope 中以 override 注入 SharedPreferences',
  );
});

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((
  ref,
) {
  return SettingsNotifier(ref.watch(sharedPreferencesProvider));
});
