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
  String get importPreparing => _t('importPreparing');
  String get importFetchingSources => _t('importFetchingSources');
  String get importParsingSources => _t('importParsingSources');
  String get importMergingSources => _t('importMergingSources');
  String get importSavingSources => _t('importSavingSources');
  String get importCancelled => _t('importCancelled');
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
  String get importByQrCode => _t('importByQrCode');
  String get scanQrCode => _t('scanQrCode');
  String get scanQrCodeHint => _t('scanQrCodeHint');
  String get cameraPermissionRequired => _t('cameraPermissionRequired');
  String get import => _t('import');
  String get recommendedBooks => _t('recommendedBooks');
  String get discoverAutoRecommendations => _t('discoverAutoRecommendations');
  String get refreshRecommendations => _t('refreshRecommendations');
  String get noRecommendations => _t('noRecommendations');
  String get openingBook => _t('openingBook');
  String get loadingChapterLabel => _t('loadingChapterLabel');
  String get save => _t('save');
  String get cancel => _t('cancel');
  String get setCoverUrl => _t('setCoverUrl');
  String get clearCover => _t('clearCover');
  String get coverUrlHint => _t('coverUrlHint');
  String get invalidCoverUrl => _t('invalidCoverUrl');
  String get coverUpdated => _t('coverUpdated');
  String get coverCleared => _t('coverCleared');
  String get setCoverImage => _t('setCoverImage');
  String get coverImageUpdated => _t('coverImageUpdated');
  String get bookDetails => _t('bookDetails');
  String get formatLabel => _t('formatLabel');
  String get sourceLink => _t('sourceLink');
  String get locationLabel => _t('locationLabel');
  String get shareBook => _t('shareBook');
  String get shareFailed => _t('shareFailed');
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
    'importPreparing': 'Preparing import',
    'importFetchingSources': 'Fetching sources',
    'importParsingSources': 'Parsing sources',
    'importMergingSources': 'Applying sources',
    'importSavingSources': 'Saving sources',
    'importCancelled': 'Import cancelled',
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
    'importByQrCode': 'Import by QR code',
    'scanQrCode': 'Scan QR code',
    'scanQrCodeHint': 'Point the camera at a source QR code to import it.',
    'cameraPermissionRequired':
        'Camera permission is required for QR code import.',
    'import': 'Import',
    'recommendedBooks': 'Recommended now',
    'discoverAutoRecommendations':
        'Fresh picks loaded from your enabled sources.',
    'refreshRecommendations': 'Refresh recommendations',
    'noRecommendations':
        'No recommendations available yet. Try refreshing or searching directly.',
    'openingBook': 'Opening book',
    'loadingChapterLabel': 'Loading chapter',
    'save': 'Save',
    'cancel': 'Cancel',
    'setCoverUrl': 'Set cover URL',
    'clearCover': 'Clear cover',
    'coverUrlHint': 'https://example.com/cover.jpg',
    'invalidCoverUrl': 'Enter a valid HTTP or HTTPS cover URL.',
    'coverUpdated': 'Cover updated',
    'coverCleared': 'Cover cleared',
    'setCoverImage': 'Set local cover image',
    'coverImageUpdated': 'Cover image updated',
    'bookDetails': 'Book details',
    'formatLabel': 'Format',
    'sourceLink': 'Source',
    'locationLabel': 'Location',
    'shareBook': 'Share book',
    'shareFailed': 'Share failed',
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
    'importPreparing': '正在准备导入',
    'importFetchingSources': '正在抓取书源',
    'importParsingSources': '正在解析书源',
    'importMergingSources': '正在应用书源',
    'importSavingSources': '正在保存书源',
    'importCancelled': '已取消导入',
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
    'importByQrCode': '扫码导入',
    'scanQrCode': '扫描二维码',
    'scanQrCodeHint': '将二维码放入取景框内即可导入书源。',
    'cameraPermissionRequired': '扫码导入需要相机权限。',
    'import': '导入',
    'recommendedBooks': '为你推荐',
    'discoverAutoRecommendations': '已从启用书源自动抓取首批可读内容。',
    'refreshRecommendations': '刷新推荐',
    'noRecommendations': '暂时没有可用推荐，试试刷新或直接搜索。',
    'openingBook': '正在打开书籍',
    'loadingChapterLabel': '正在加载章节',
    'save': '保存',
    'cancel': '取消',
    'setCoverUrl': '设置封面 URL',
    'clearCover': '清除封面',
    'coverUrlHint': 'https://example.com/cover.jpg',
    'invalidCoverUrl': '请输入有效的 HTTP 或 HTTPS 封面地址。',
    'coverUpdated': '封面已更新',
    'coverCleared': '封面已清除',
    'setCoverImage': '设置本地封面图片',
    'coverImageUpdated': '封面图片已更新',
    'bookDetails': '书籍详情',
    'formatLabel': '格式',
    'sourceLink': '书源',
    'locationLabel': '位置',
    'shareBook': '分享图书',
    'shareFailed': '分享失败',
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
    'importPreparing': '正在準備匯入',
    'importFetchingSources': '正在抓取書源',
    'importParsingSources': '正在解析書源',
    'importMergingSources': '正在套用書源',
    'importSavingSources': '正在儲存書源',
    'importCancelled': '已取消匯入',
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
    'recommendedBooks': '為你推薦',
    'discoverAutoRecommendations': '已從啟用書源自動載入首批可讀內容。',
    'refreshRecommendations': '重新整理推薦',
    'noRecommendations': '暫時沒有可用推薦，請嘗試重新整理或直接搜尋。',
    'openingBook': '正在開啟書籍',
    'loadingChapterLabel': '正在載入章節',
    'save': '儲存',
    'cancel': '取消',
    'setCoverUrl': '設定封面 URL',
    'clearCover': '清除封面',
    'coverUrlHint': 'https://example.com/cover.jpg',
    'invalidCoverUrl': '請輸入有效的 HTTP 或 HTTPS 封面網址。',
    'coverUpdated': '封面已更新',
    'coverCleared': '封面已清除',
    'setCoverImage': '設定本地封面圖片',
    'coverImageUpdated': '封面圖片已更新',
    'bookDetails': '書籍詳情',
    'formatLabel': '格式',
    'sourceLink': '書源',
    'locationLabel': '位置',
    'shareBook': '分享書籍',
    'shareFailed': '分享失敗',
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
    'importPreparing': '取り込みを準備しています',
    'importFetchingSources': 'ソースを取得しています',
    'importParsingSources': 'ソースを解析しています',
    'importMergingSources': 'ソースを反映しています',
    'importSavingSources': 'ソースを保存しています',
    'importCancelled': '取り込みをキャンセルしました',
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
    'recommendedBooks': 'おすすめ',
    'discoverAutoRecommendations': '有効なソースから最初の候補を自動で読み込みました。',
    'refreshRecommendations': 'おすすめを更新',
    'noRecommendations': 'まだおすすめを取得できません。更新するか検索してください。',
    'openingBook': '本を開いています',
    'loadingChapterLabel': '章を読み込んでいます',
    'save': '保存',
    'cancel': 'キャンセル',
    'setCoverUrl': '表紙 URL を設定',
    'clearCover': '表紙を削除',
    'coverUrlHint': 'https://example.com/cover.jpg',
    'invalidCoverUrl': '有効な HTTP または HTTPS の表紙 URL を入力してください。',
    'coverUpdated': '表紙を更新しました',
    'coverCleared': '表紙を削除しました',
    'setCoverImage': 'ローカル表紙画像を設定',
    'coverImageUpdated': '表紙画像を更新しました',
    'bookDetails': '書籍情報',
    'formatLabel': '形式',
    'sourceLink': 'ソース',
    'locationLabel': '場所',
    'shareBook': '本を共有',
    'shareFailed': '共有に失敗しました',
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
    'importPreparing': '가져오기를 준비하는 중',
    'importFetchingSources': '소스를 불러오는 중',
    'importParsingSources': '소스를 해석하는 중',
    'importMergingSources': '소스를 적용하는 중',
    'importSavingSources': '소스를 저장하는 중',
    'importCancelled': '가져오기를 취소했습니다',
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
    'recommendedBooks': '추천 콘텐츠',
    'discoverAutoRecommendations': '활성화된 소스에서 첫 추천 목록을 자동으로 불러왔습니다.',
    'refreshRecommendations': '추천 새로고침',
    'noRecommendations': '아직 추천을 불러오지 못했습니다. 새로고침하거나 직접 검색하세요.',
    'openingBook': '책 여는 중',
    'loadingChapterLabel': '장 불러오는 중',
    'save': '저장',
    'cancel': '취소',
    'setCoverUrl': '표지 URL 설정',
    'clearCover': '표지 지우기',
    'coverUrlHint': 'https://example.com/cover.jpg',
    'invalidCoverUrl': '유효한 HTTP 또는 HTTPS 표지 주소를 입력하세요.',
    'coverUpdated': '표지가 업데이트되었습니다',
    'coverCleared': '표지를 지웠습니다',
    'setCoverImage': '로컬 표지 이미지 설정',
    'coverImageUpdated': '표지 이미지가 업데이트되었습니다',
    'bookDetails': '도서 상세',
    'formatLabel': '형식',
    'sourceLink': '소스',
    'locationLabel': '위치',
    'shareBook': '책 공유',
    'shareFailed': '공유 실패',
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
    'importPreparing': 'Import wird vorbereitet',
    'importFetchingSources': 'Quellen werden geladen',
    'importParsingSources': 'Quellen werden verarbeitet',
    'importMergingSources': 'Quellen werden übernommen',
    'importSavingSources': 'Quellen werden gespeichert',
    'importCancelled': 'Import abgebrochen',
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
    'recommendedBooks': 'Empfohlen',
    'discoverAutoRecommendations':
        'Erste Treffer wurden automatisch aus aktivierten Quellen geladen.',
    'refreshRecommendations': 'Empfehlungen aktualisieren',
    'noRecommendations':
        'Noch keine Empfehlungen verfügbar. Aktualisiere oder suche direkt.',
    'openingBook': 'Buch wird geöffnet',
    'loadingChapterLabel': 'Kapitel wird geladen',
    'save': 'Speichern',
    'cancel': 'Abbrechen',
    'setCoverUrl': 'Cover-URL festlegen',
    'clearCover': 'Cover entfernen',
    'coverUrlHint': 'https://example.com/cover.jpg',
    'invalidCoverUrl': 'Gib eine gültige HTTP- oder HTTPS-Cover-URL ein.',
    'coverUpdated': 'Cover aktualisiert',
    'coverCleared': 'Cover entfernt',
    'setCoverImage': 'Lokales Coverbild festlegen',
    'coverImageUpdated': 'Coverbild aktualisiert',
    'bookDetails': 'Buchdetails',
    'formatLabel': 'Format',
    'sourceLink': 'Quelle',
    'locationLabel': 'Ablage',
    'shareBook': 'Buch teilen',
    'shareFailed': 'Teilen fehlgeschlagen',
  },
};
