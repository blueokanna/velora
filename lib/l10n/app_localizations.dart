import 'package:flutter/material.dart';

class AppLocalizations {
  AppLocalizations(this.locale);
  final Locale locale;

  static const Map<String, String> languageDisplayNames = {
    'zh': '简体中文',
    'zh_Hant': '繁體中文',
    'en': 'English',
    'ja': '日本語',
    'ko': '한국어',
    'de': 'Deutsch',
  };

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizations(const Locale('en'));

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static final supportedLocales = languageDisplayNames.keys
      .map(_localeFromCode)
      .toList(growable: false);

  static Locale _localeFromCode(String code) {
    if (code.contains('_')) {
      final parts = code.split('_');
      return Locale.fromSubtags(languageCode: parts[0], scriptCode: parts[1]);
    }
    return Locale(code);
  }

  String _t(String key) {
    final code = _resolve(locale);
    return _translations[code]?[key] ?? _translations['en']![key] ?? key;
  }

  static String _resolve(Locale loc) {
    final code = loc.scriptCode != null
        ? '${loc.languageCode}_${loc.scriptCode}'
        : loc.languageCode;
    if (_translations.containsKey(code)) return code;
    if (_translations.containsKey(loc.languageCode)) return loc.languageCode;
    return 'en';
  }

  String get appName => _t('appName');
  String get bookshelf => _t('bookshelf');
  String get discover => _t('discover');
  String get settings => _t('settings');
  String get bookSources => _t('bookSources');
  String get importTxt => _t('importTxt');
  String get importBook => _t('importBook');
  String get imported => _t('imported');
  String get importFailed => _t('importFailed');
  String get remove => _t('remove');
  String get backToBookshelf => _t('backToBookshelf');
  String get bookmarks => _t('bookmarks');
  String get addBookmark => _t('addBookmark');
  String get removeBookmark => _t('removeBookmark');
  String get noBookmarks => _t('noBookmarks');
  String get emptyShelfTitle => _t('emptyShelfTitle');
  String get emptyShelfSubtitle => _t('emptyShelfSubtitle');
  String get readerSettings => _t('readerSettings');
  String get readerFont => _t('readerFont');
  String get fontSize => _t('fontSize');
  String get lineHeight => _t('lineHeight');
  String get pageTurnEffect => _t('pageTurnEffect');
  String get effectSlide => _t('effectSlide');
  String get effectCover => _t('effectCover');
  String get effectCurl => _t('effectCurl');
  String get effectFade => _t('effectFade');
  String get effectScroll => _t('effectScroll');
  String get appearance => _t('appearance');
  String get themeMode => _t('themeMode');
  String get themeSystem => _t('themeSystem');
  String get themeLight => _t('themeLight');
  String get themeDark => _t('themeDark');
  String get themeFlavor => _t('themeFlavor');
  String get flavorPantone => _t('flavorPantone');
  String get flavorMonet => _t('flavorMonet');
  String get flavorAmoled => _t('flavorAmoled');
  String get useSystemMonet => _t('useSystemMonet');
  String get useSystemMonetSub => _t('useSystemMonetSub');
  String get reading => _t('reading');
  String get keepScreenOn => _t('keepScreenOn');
  String get language => _t('language');
  String get languageSetting => _t('languageSetting');
  String get languageSystem => _t('languageSystem');
  String get prevChapter => _t('prevChapter');
  String get nextChapter => _t('nextChapter');
  String get tableOfContents => _t('tableOfContents');
  String get brightness => _t('brightness');
  String get searchHint => _t('searchHint');
  String get noResults => _t('noResults');
  String get selectedItems => _t('selectedItems');
  String get selectAll => _t('selectAll');
  String get clearSelection => _t('clearSelection');
  String get deleteSelected => _t('deleteSelected');
  String get allFormats => _t('allFormats');
  String get formatFilter => _t('formatFilter');
  String get syncLibrary => _t('syncLibrary');
  String get booksUpdated => _t('booksUpdated');
  String get noSources => _t('noSources');
  String get noSourcesSub => _t('noSourcesSub');
  String get importJson => _t('importJson');
  String get import => _t('import');
  String get openingBook => _t('openingBook');
  String get loadingChapterLabel => _t('loadingChapterLabel');
  String get cancel => _t('cancel');
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(locale);
  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

final Map<String, Map<String, String>> _translations = {
  'en': {
    'appName': 'Velora',
    'bookshelf': 'Bookshelf',
    'discover': 'Discover',
    'settings': 'Settings',
    'bookSources': 'Book Sources',
    'importTxt': 'Import TXT',
    'importBook': 'Import book',
    'imported': 'Imported',
    'importFailed': 'Import failed',
    'remove': 'Remove',
    'backToBookshelf': 'Back to bookshelf',
    'bookmarks': 'Bookmarks',
    'addBookmark': 'Add bookmark',
    'removeBookmark': 'Remove bookmark',
    'noBookmarks': 'No bookmarks yet',
    'emptyShelfTitle': 'Your bookshelf is empty',
    'emptyShelfSubtitle':
        'Import TXT, EPUB, MOBI, or AZW3, or add an online source to get started.',
    'readerSettings': 'Reader settings',
    'readerFont': 'Reading font',
    'fontSize': 'Font size',
    'lineHeight': 'Line height',
    'pageTurnEffect': 'Page-turn effect',
    'effectSlide': 'Slide',
    'effectCover': 'Cover',
    'effectCurl': 'Curl',
    'effectFade': 'Fade',
    'effectScroll': 'Scroll',
    'appearance': 'Appearance',
    'themeMode': 'Theme mode',
    'themeSystem': 'Follow system',
    'themeLight': 'Light',
    'themeDark': 'Dark',
    'themeFlavor': 'Theme flavor',
    'flavorPantone': 'Pantone 2026 — Cloud Dancer',
    'flavorMonet': 'Monet (system colors)',
    'flavorAmoled': 'AMOLED Monet',
    'useSystemMonet': 'Use system dynamic color',
    'useSystemMonetSub': 'Sample colors from your wallpaper',
    'reading': 'Reading',
    'keepScreenOn': 'Keep screen on',
    'language': 'Language',
    'languageSetting': 'App language',
    'languageSystem': 'System default',
    'prevChapter': 'Previous chapter',
    'nextChapter': 'Next chapter',
    'tableOfContents': 'Table of contents',
    'brightness': 'Brightness',
    'searchHint': 'Search for books, authors…',
    'noResults': 'No results yet',
    'selectedItems': 'selected',
    'selectAll': 'Select all',
    'clearSelection': 'Clear selection',
    'deleteSelected': 'Delete selected',
    'allFormats': 'All formats',
    'formatFilter': 'Format',
    'syncLibrary': 'Rescan local books',
    'booksUpdated': 'Metadata refreshed',
    'noSources': 'No book sources',
    'noSourcesSub':
        'Import JSON, a source URL, or a compatible reading source link.',
    'importJson': 'Import source',
    'import': 'Import',
    'openingBook': 'Opening book',
    'loadingChapterLabel': 'Loading chapter',
    'cancel': 'Cancel',
  },
  'zh': {
    'appName': 'Velora 阅读',
    'bookshelf': '书架',
    'discover': '发现',
    'settings': '设置',
    'bookSources': '书源',
    'importTxt': '导入 TXT',
    'importBook': '导入书籍',
    'imported': '已导入',
    'importFailed': '导入失败',
    'remove': '移除',
    'backToBookshelf': '返回书架',
    'bookmarks': '书签',
    'addBookmark': '添加书签',
    'removeBookmark': '移除书签',
    'noBookmarks': '还没有书签',
    'emptyShelfTitle': '书架还空着',
    'emptyShelfSubtitle': '导入 TXT、EPUB、MOBI 或 AZW3 本地图书，或添加在线书源即可开始阅读。',
    'readerSettings': '阅读设置',
    'readerFont': '阅读字体',
    'fontSize': '字号',
    'lineHeight': '行距',
    'pageTurnEffect': '翻页效果',
    'effectSlide': '平移',
    'effectCover': '覆盖',
    'effectCurl': '仿真',
    'effectFade': '淡入淡出',
    'effectScroll': '上下滚动',
    'appearance': '外观',
    'themeMode': '主题模式',
    'themeSystem': '跟随系统',
    'themeLight': '浅色',
    'themeDark': '深色',
    'themeFlavor': '主题风格',
    'flavorPantone': '潘通 2026 · 云上舞白',
    'flavorMonet': 'Monet（系统取色）',
    'flavorAmoled': 'AMOLED Monet',
    'useSystemMonet': '使用系统动态色',
    'useSystemMonetSub': '从壁纸提取主题色',
    'reading': '阅读',
    'keepScreenOn': '保持屏幕常亮',
    'language': '语言',
    'languageSetting': '应用语言',
    'languageSystem': '跟随系统',
    'prevChapter': '上一章',
    'nextChapter': '下一章',
    'tableOfContents': '目录',
    'brightness': '亮度',
    'searchHint': '搜索书名、作者…',
    'noResults': '暂无结果',
    'selectedItems': '已选',
    'selectAll': '全选',
    'clearSelection': '取消选择',
    'deleteSelected': '批量删除',
    'allFormats': '全部格式',
    'formatFilter': '格式筛选',
    'syncLibrary': '重扫本地图书',
    'booksUpdated': '已刷新图书元数据',
    'noSources': '尚未添加书源',
    'noSourcesSub': '导入 JSON、书源地址或兼容的阅读书源链接即可开启在线阅读。',
    'importJson': '导入书源',
    'import': '导入',
    'openingBook': '正在打开书籍',
    'loadingChapterLabel': '正在加载章节',
    'cancel': '取消',
  },
  'zh_Hant': {
    'appName': 'Velora 閱讀',
    'bookshelf': '書架',
    'discover': '發現',
    'settings': '設定',
    'bookSources': '書源',
    'importTxt': '匯入 TXT',
    'importBook': '匯入書籍',
    'imported': '已匯入',
    'importFailed': '匯入失敗',
    'remove': '移除',
    'backToBookshelf': '返回書架',
    'bookmarks': '書籤',
    'addBookmark': '加入書籤',
    'removeBookmark': '移除書籤',
    'noBookmarks': '還沒有書籤',
    'emptyShelfTitle': '書架還是空的',
    'emptyShelfSubtitle': '匯入 TXT、EPUB、MOBI 或 AZW3 本地書籍，或新增線上書源即可開始閱讀。',
    'readerSettings': '閱讀設定',
    'readerFont': '閱讀字體',
    'fontSize': '字級',
    'lineHeight': '行距',
    'pageTurnEffect': '翻頁效果',
    'effectSlide': '平移',
    'effectCover': '覆蓋',
    'effectCurl': '擬真',
    'effectFade': '淡入淡出',
    'effectScroll': '上下捲動',
    'appearance': '外觀',
    'themeMode': '主題模式',
    'themeSystem': '跟隨系統',
    'themeLight': '淺色',
    'themeDark': '深色',
    'themeFlavor': '主題風格',
    'flavorPantone': 'Pantone 2026 · 雲上舞白',
    'flavorMonet': 'Monet（系統取色）',
    'flavorAmoled': 'AMOLED Monet',
    'useSystemMonet': '使用系統動態色',
    'useSystemMonetSub': '從桌布擷取主題色',
    'reading': '閱讀',
    'keepScreenOn': '螢幕保持開啟',
    'language': '語言',
    'languageSetting': '應用程式語言',
    'languageSystem': '跟隨系統',
    'prevChapter': '上一章',
    'nextChapter': '下一章',
    'tableOfContents': '目錄',
    'brightness': '亮度',
    'searchHint': '搜尋書名、作者…',
    'noResults': '暫無結果',
    'selectedItems': '已選',
    'selectAll': '全選',
    'clearSelection': '取消選擇',
    'deleteSelected': '批次刪除',
    'allFormats': '全部格式',
    'formatFilter': '格式篩選',
    'syncLibrary': '重掃本地書籍',
    'booksUpdated': '已刷新書籍中繼資料',
    'noSources': '尚未新增書源',
    'noSourcesSub': '匯入 JSON、書源地址或相容的閱讀書源連結即可開啟線上閱讀。',
    'importJson': '匯入書源',
    'import': '匯入',
    'openingBook': '正在開啟書籍',
    'loadingChapterLabel': '正在載入章節',
    'cancel': '取消',
  },
  'ja': {
    'appName': 'Velora 読書',
    'bookshelf': '本棚',
    'discover': '発見',
    'settings': '設定',
    'bookSources': '本のソース',
    'importTxt': 'TXT を取り込む',
    'importBook': '本を取り込む',
    'imported': '取り込みました',
    'importFailed': '取り込みに失敗',
    'remove': '削除',
    'backToBookshelf': '本棚に戻る',
    'bookmarks': 'しおり',
    'addBookmark': 'しおりを追加',
    'removeBookmark': 'しおりを削除',
    'noBookmarks': 'しおりはまだありません',
    'emptyShelfTitle': '本棚は空です',
    'emptyShelfSubtitle': 'TXT、EPUB、MOBI、AZW3 を取り込むか、オンラインソースを追加してください。',
    'readerSettings': 'リーダー設定',
    'readerFont': '読書フォント',
    'fontSize': '文字サイズ',
    'lineHeight': '行間',
    'pageTurnEffect': 'ページめくり',
    'effectSlide': 'スライド',
    'effectCover': 'カバー',
    'effectCurl': 'カール',
    'effectFade': 'フェード',
    'effectScroll': 'スクロール',
    'appearance': '外観',
    'themeMode': 'テーマ',
    'themeSystem': 'システムに従う',
    'themeLight': 'ライト',
    'themeDark': 'ダーク',
    'themeFlavor': 'カラーフレーバー',
    'flavorPantone': 'Pantone 2026 · クラウドダンサー',
    'flavorMonet': 'Monet（システムカラー）',
    'flavorAmoled': 'AMOLED Monet',
    'useSystemMonet': 'システム動的カラー',
    'useSystemMonetSub': '壁紙から色を抽出',
    'reading': '読書',
    'keepScreenOn': '画面を常にオン',
    'language': '言語',
    'languageSetting': 'アプリの言語',
    'languageSystem': 'システム',
    'prevChapter': '前章',
    'nextChapter': '次章',
    'tableOfContents': '目次',
    'brightness': '明るさ',
    'searchHint': 'タイトル、著者で検索…',
    'noResults': '結果なし',
    'selectedItems': '件を選択',
    'selectAll': 'すべて選択',
    'clearSelection': '選択解除',
    'deleteSelected': '選択を削除',
    'allFormats': 'すべての形式',
    'formatFilter': '形式',
    'syncLibrary': 'ローカル本を再走査',
    'booksUpdated': 'メタデータを更新しました',
    'noSources': 'ソースがありません',
    'noSourcesSub': 'JSON、ソース URL、互換性のある読書ソースリンクをインポートしてください。',
    'importJson': 'ソースを読み込む',
    'import': '取り込む',
    'openingBook': '本を開いています',
    'loadingChapterLabel': '章を読み込んでいます',
    'cancel': 'キャンセル',
  },
  'ko': {
    'appName': 'Velora 리더',
    'bookshelf': '서재',
    'discover': '발견',
    'settings': '설정',
    'bookSources': '책 소스',
    'importTxt': 'TXT 가져오기',
    'importBook': '책 가져오기',
    'imported': '가져옴',
    'importFailed': '가져오기 실패',
    'remove': '삭제',
    'backToBookshelf': '서재로 돌아가기',
    'bookmarks': '북마크',
    'addBookmark': '북마크 추가',
    'removeBookmark': '북마크 제거',
    'noBookmarks': '북마크가 없습니다',
    'emptyShelfTitle': '서재가 비어 있습니다',
    'emptyShelfSubtitle': 'TXT, EPUB, MOBI, AZW3를 가져오거나 온라인 소스를 추가하세요.',
    'readerSettings': '리더 설정',
    'readerFont': '읽기 글꼴',
    'fontSize': '글자 크기',
    'lineHeight': '줄 간격',
    'pageTurnEffect': '페이지 전환',
    'effectSlide': '슬라이드',
    'effectCover': '커버',
    'effectCurl': '컬',
    'effectFade': '페이드',
    'effectScroll': '스크롤',
    'appearance': '모양',
    'themeMode': '테마 모드',
    'themeSystem': '시스템 사용',
    'themeLight': '라이트',
    'themeDark': '다크',
    'themeFlavor': '테마 스타일',
    'flavorPantone': 'Pantone 2026 · 클라우드 댄서',
    'flavorMonet': 'Monet (시스템)',
    'flavorAmoled': 'AMOLED Monet',
    'useSystemMonet': '시스템 동적 색상',
    'useSystemMonetSub': '배경에서 색 추출',
    'reading': '읽기',
    'keepScreenOn': '화면 켜짐 유지',
    'language': '언어',
    'languageSetting': '앱 언어',
    'languageSystem': '시스템 기본값',
    'prevChapter': '이전 장',
    'nextChapter': '다음 장',
    'tableOfContents': '목차',
    'brightness': '밝기',
    'searchHint': '도서, 저자 검색…',
    'noResults': '결과 없음',
    'selectedItems': '선택됨',
    'selectAll': '전체 선택',
    'clearSelection': '선택 해제',
    'deleteSelected': '선택 삭제',
    'allFormats': '모든 형식',
    'formatFilter': '형식',
    'syncLibrary': '로컬 책 다시 스캔',
    'booksUpdated': '메타데이터를 새로 고쳤습니다',
    'noSources': '소스 없음',
    'noSourcesSub': 'JSON, 소스 URL 또는 호환 읽기 소스 링크를 가져오세요.',
    'importJson': '소스 가져오기',
    'import': '가져오기',
    'openingBook': '책 여는 중',
    'loadingChapterLabel': '장 불러오는 중',
    'cancel': '취소',
  },
  'de': {
    'appName': 'Velora Leser',
    'bookshelf': 'Buchregal',
    'discover': 'Entdecken',
    'settings': 'Einstellungen',
    'bookSources': 'Buchquellen',
    'importTxt': 'TXT importieren',
    'importBook': 'Buch importieren',
    'imported': 'Importiert',
    'importFailed': 'Import fehlgeschlagen',
    'remove': 'Entfernen',
    'backToBookshelf': 'Zurück zum Buchregal',
    'bookmarks': 'Lesezeichen',
    'addBookmark': 'Lesezeichen hinzufügen',
    'removeBookmark': 'Lesezeichen entfernen',
    'noBookmarks': 'Noch keine Lesezeichen',
    'emptyShelfTitle': 'Dein Buchregal ist leer',
    'emptyShelfSubtitle':
        'Importiere TXT, EPUB, MOBI oder AZW3 oder füge eine Online-Quelle hinzu.',
    'readerSettings': 'Leseeinstellungen',
    'readerFont': 'Leseschrift',
    'fontSize': 'Schriftgröße',
    'lineHeight': 'Zeilenhöhe',
    'pageTurnEffect': 'Blättereffekt',
    'effectSlide': 'Schieben',
    'effectCover': 'Überdecken',
    'effectCurl': 'Umblättern',
    'effectFade': 'Überblenden',
    'effectScroll': 'Scrollen',
    'appearance': 'Darstellung',
    'themeMode': 'Themenmodus',
    'themeSystem': 'System folgen',
    'themeLight': 'Hell',
    'themeDark': 'Dunkel',
    'themeFlavor': 'Themenstil',
    'flavorPantone': 'Pantone 2026 · Cloud Dancer',
    'flavorMonet': 'Monet (Systemfarben)',
    'flavorAmoled': 'AMOLED Monet',
    'useSystemMonet': 'Dynamische Systemfarben verwenden',
    'useSystemMonetSub': 'Farben aus dem Hintergrundbild übernehmen',
    'reading': 'Lesen',
    'keepScreenOn': 'Bildschirm eingeschaltet lassen',
    'language': 'Sprache',
    'languageSetting': 'App-Sprache',
    'languageSystem': 'Systemstandard',
    'prevChapter': 'Vorheriges Kapitel',
    'nextChapter': 'Nächstes Kapitel',
    'tableOfContents': 'Inhaltsverzeichnis',
    'brightness': 'Helligkeit',
    'searchHint': 'Nach Büchern oder Autoren suchen…',
    'noResults': 'Noch keine Ergebnisse',
    'selectedItems': 'ausgewählt',
    'selectAll': 'Alle auswählen',
    'clearSelection': 'Auswahl aufheben',
    'deleteSelected': 'Auswahl löschen',
    'allFormats': 'Alle Formate',
    'formatFilter': 'Format',
    'syncLibrary': 'Lokale Bücher neu scannen',
    'booksUpdated': 'Metadaten aktualisiert',
    'noSources': 'Keine Buchquellen',
    'noSourcesSub':
        'Importiere JSON, eine Quellen-URL oder einen kompatiblen Leselink.',
    'importJson': 'Quelle importieren',
    'import': 'Importieren',
    'openingBook': 'Buch wird geöffnet',
    'loadingChapterLabel': 'Kapitel wird geladen',
    'cancel': 'Abbrechen',
  },
};
