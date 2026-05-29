import 'package:flutter_test/flutter_test.dart';
import 'package:velora/src/rust/api/app_start.dart';
import 'package:integration_test/integration_test.dart';

import 'test_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await initRustForIntegrationTest());
  testWidgets('Rust engine version is reachable', (WidgetTester tester) async {
    final v = engineVersion();
    expect(v, isNotEmpty);
  });
}
