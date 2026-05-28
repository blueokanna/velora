import 'package:flutter/foundation.dart';

class AppKeys {
  AppKeys._();

  static const bookshelfPage = ValueKey('bookshelf.page');
  static const bookshelfGrid = ValueKey('bookshelf.grid');
  static const bookshelfSearch = ValueKey('bookshelf.search');
  static const navBookshelf = ValueKey('nav.bookshelf');
  static const navDiscover = ValueKey('nav.discover');
  static const navSources = ValueKey('nav.sources');
  static const navSettings = ValueKey('nav.settings');
  static const settingsPage = ValueKey('settings.page');
  static const settingsLanguageTile = ValueKey('settings.language');
  static const settingsThemeModeTile = ValueKey('settings.themeMode');
  static const settingsThemeFlavorTile = ValueKey('settings.themeFlavor');
  static const settingsEffectTile = ValueKey('settings.effect');
  static const readerViewport = ValueKey('reader.viewport');
  static const readerPageBody = ValueKey('reader.pageBody');
  static const readerOverlay = ValueKey('reader.overlay');
  static const readerOverlaySettings = ValueKey('reader.overlay.settings');
  static const readerOverlayReaderSettings = ValueKey(
    'reader.overlay.readerSettings',
  );
  static const readerOverlayToc = ValueKey('reader.overlay.toc');
  static const readerLoading = ValueKey('reader.loading');
  static const readerLoadingProgress = ValueKey('reader.loading.progress');
  static const readerLoadingPercent = ValueKey('reader.loading.percent');

  static ValueKey<String> bookshelfBook(String id) =>
      ValueKey('bookshelf.book.$id');

  static ValueKey<String> settingsOption(Object value) =>
      ValueKey('settings.option.${_normalize(value)}');

  static String _normalize(Object value) => value
      .toString()
      .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}
