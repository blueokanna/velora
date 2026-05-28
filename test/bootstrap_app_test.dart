import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:velora/main.dart';
import 'package:velora/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  test('prepareVeloraBootstrap 支持注入文档目录与 SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({'locale': 'de'});
    final prefs = await SharedPreferences.getInstance();
    AppTheme.useGoogleFonts = false;
    addTearDown(() => AppTheme.useGoogleFonts = true);

    var initializedDocsPath = '';
    final context = await prepareVeloraBootstrap(
      initializeRust: false,
      sharedPreferences: prefs,
      resolveDocsPath: () async => 'D:/velora_test_docs',
      initializeStorage: (docsPath) => initializedDocsPath = docsPath,
    );

    expect(context.docsPath, 'D:/velora_test_docs');
    expect(identical(context.prefs, prefs), isTrue);
    expect(initializedDocsPath, 'D:/velora_test_docs');
  });
}