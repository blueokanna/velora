import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class VeloraPalette {
  VeloraPalette._();

  static const Color cloudDancer = Color(0xFFEDE9DF);

  static const Color softSky = Color(0xFFB7CFE2);
  static const Color seaGlass = Color(0xFFA8C8C0);
  static const Color powderedRose = Color(0xFFE5C8C5);
  static const Color softShadow = Color(0xFF6F7A82);

  static const Color seed = softSky;

  static const Color accentSeed = seaGlass;
}

enum ThemeFlavor { pantone, monet, amoled }

enum ReaderFontPreset { notoSerif, notoSans, literata, merriweather, lora }

class AppTheme {
  AppTheme._();

  static bool useGoogleFonts = true;

  static const readerFontFallback = <String>[
    'Noto Serif SC',
    'Noto Sans SC',
    'Noto Serif',
    'Noto Serif JP',
    'Noto Serif Devanagari',
    'Noto Serif Thai',
    'Noto Serif Bengali',
    'Noto Serif Tamil',
    'Noto Serif Telugu',
    'Noto Serif Hebrew',
    'Noto Naskh Arabic',
  ];

  static TextTheme _textTheme(TextTheme base) {
    final themed = useGoogleFonts
        ? GoogleFonts.notoSerifScTextTheme(base)
        : base.apply(fontFamily: 'Noto Serif SC');
    TextStyle? withFallback(TextStyle? style, {double? height}) =>
        style?.copyWith(fontFamilyFallback: readerFontFallback, height: height);
    return themed.copyWith(
      displayLarge: withFallback(themed.displayLarge),
      displayMedium: withFallback(themed.displayMedium),
      displaySmall: withFallback(themed.displaySmall),
      headlineLarge: withFallback(themed.headlineLarge),
      headlineMedium: withFallback(themed.headlineMedium, height: 1.25),
      headlineSmall: withFallback(themed.headlineSmall),
      titleLarge: withFallback(themed.titleLarge),
      titleMedium: withFallback(themed.titleMedium),
      titleSmall: withFallback(themed.titleSmall),
      bodyLarge: withFallback(themed.bodyLarge, height: 1.6),
      bodyMedium: withFallback(themed.bodyMedium, height: 1.55),
      bodySmall: withFallback(themed.bodySmall, height: 1.5),
      labelLarge: withFallback(themed.labelLarge),
      labelMedium: withFallback(themed.labelMedium),
      labelSmall: withFallback(themed.labelSmall),
    );
  }

  static TextStyle readingTextStyle(TextStyle base, ReaderFontPreset preset) {
    final style = switch (preset) {
      ReaderFontPreset.notoSerif =>
        useGoogleFonts
            ? GoogleFonts.notoSerifSc(textStyle: base)
            : base.copyWith(fontFamily: 'Noto Serif SC'),
      ReaderFontPreset.notoSans =>
        useGoogleFonts
            ? GoogleFonts.notoSansSc(textStyle: base)
            : base.copyWith(fontFamily: 'Noto Sans SC'),
      ReaderFontPreset.literata =>
        useGoogleFonts
            ? GoogleFonts.literata(textStyle: base)
            : base.copyWith(fontFamily: 'Literata'),
      ReaderFontPreset.merriweather =>
        useGoogleFonts
            ? GoogleFonts.merriweather(textStyle: base)
            : base.copyWith(fontFamily: 'Merriweather'),
      ReaderFontPreset.lora =>
        useGoogleFonts
            ? GoogleFonts.lora(textStyle: base)
            : base.copyWith(fontFamily: 'Lora'),
    };
    return style.copyWith(fontFamilyFallback: readerFontFallback);
  }

  static ThemeData _build(ColorScheme scheme, {bool amoled = false}) {
    final ColorScheme s = amoled
        ? scheme.copyWith(
            surface: Colors.black,
            surfaceContainerLowest: Colors.black,
            surfaceContainerLow: const Color(0xFF050505),
            surfaceContainer: const Color(0xFF0A0A0A),
            surfaceContainerHigh: const Color(0xFF111111),
            surfaceContainerHighest: const Color(0xFF1A1A1A),
          )
        : scheme;

    return ThemeData(
      useMaterial3: true,
      colorScheme: s,
      brightness: s.brightness,
      scaffoldBackgroundColor: s.surface,
      textTheme: _textTheme(
        Typography.material2021().black,
      ).apply(bodyColor: s.onSurface, displayColor: s.onSurface),
      appBarTheme: AppBarTheme(
        backgroundColor: s.surface,
        foregroundColor: s.onSurface,
        elevation: 0,
        scrolledUnderElevation: 3,
        surfaceTintColor: s.surfaceTint,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: s.surfaceContainer,
        indicatorColor: s.secondaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
            fontSize: 12,
            color: s.onSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
        height: 80,
        elevation: 0,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: s.surface,
        indicatorColor: s.secondaryContainer,
        selectedIconTheme: IconThemeData(color: s.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: s.onSurfaceVariant),
        useIndicator: true,
      ),
      cardTheme: CardThemeData(
        color: s.surfaceContainerLow,
        surfaceTintColor: s.surfaceTint,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: const StadiumBorder(),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: const StadiumBorder(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: const StadiumBorder(),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(shape: const CircleBorder()),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: s.outlineVariant),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: s.primary,
        thumbColor: s.primary,
        overlayColor: s.primary.withValues(alpha: 0.12),
      ),
      dividerTheme: DividerThemeData(
        color: s.outlineVariant,
        space: 1,
        thickness: 0.5,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: s.inverseSurface,
        contentTextStyle: TextStyle(color: s.onInverseSurface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: s.surfaceContainerHigh,
        surfaceTintColor: s.surfaceTint,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: s.surfaceContainerLow,
        surfaceTintColor: s.surfaceTint,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        showDragHandle: true,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: ZoomPageTransitionsBuilder(
            allowEnterRouteSnapshotting: false,
          ),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: ZoomPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
          TargetPlatform.fuchsia: ZoomPageTransitionsBuilder(),
        },
      ),
    );
  }

  static ThemeData light({
    ColorScheme? dynamicScheme,
    ThemeFlavor flavor = ThemeFlavor.pantone,
  }) {
    final ColorScheme scheme = switch (flavor) {
      ThemeFlavor.monet =>
        (dynamicScheme ?? ColorScheme.fromSeed(seedColor: VeloraPalette.seed))
            .harmonized(),
      ThemeFlavor.pantone || ThemeFlavor.amoled =>
        (dynamicScheme?.harmonized() ??
            ColorScheme.fromSeed(
              seedColor: VeloraPalette.seed,
              brightness: Brightness.light,
              secondary: VeloraPalette.seaGlass,
              tertiary: VeloraPalette.powderedRose,
            ).copyWith(surface: VeloraPalette.cloudDancer)),
    };
    return _build(scheme);
  }

  static ThemeData dark({
    ColorScheme? dynamicScheme,
    ThemeFlavor flavor = ThemeFlavor.pantone,
  }) {
    final ColorScheme scheme = switch (flavor) {
      ThemeFlavor.monet =>
        (dynamicScheme ??
                ColorScheme.fromSeed(
                  seedColor: VeloraPalette.seed,
                  brightness: Brightness.dark,
                ))
            .harmonized(),
      ThemeFlavor.pantone =>
        dynamicScheme?.harmonized() ??
            ColorScheme.fromSeed(
              seedColor: VeloraPalette.seed,
              brightness: Brightness.dark,
              secondary: VeloraPalette.seaGlass,
              tertiary: VeloraPalette.powderedRose,
            ),
      ThemeFlavor.amoled =>
        dynamicScheme?.harmonized() ??
            ColorScheme.fromSeed(
              seedColor: VeloraPalette.seed,
              brightness: Brightness.dark,
            ),
    };
    return _build(scheme, amoled: flavor == ThemeFlavor.amoled);
  }
}
