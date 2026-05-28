import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/l10n/app_localizations.dart';

void main() {
  test('支持语言列表与显示名保持一致', () {
    final supportedCodes = AppLocalizations.supportedLocales
        .map(
          (locale) => locale.scriptCode == null
              ? locale.languageCode
              : '${locale.languageCode}_${locale.scriptCode}',
        )
        .toSet();

    expect(supportedCodes, AppLocalizations.languageDisplayNames.keys.toSet());
  });

  test('德语文案不再回退到英文', () {
    final l10n = AppLocalizations(const Locale('de'));

    expect(l10n.settings, 'Einstellungen');
    expect(l10n.bookshelf, 'Buchregal');
    expect(l10n.openingBook, 'Buch wird geöffnet');
  });

  test('繁体中文通过 scriptCode 正确解析', () {
    final l10n = AppLocalizations(
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    );

    expect(l10n.settings, '設定');
    expect(l10n.readerFont, '閱讀字體');
  });
}
