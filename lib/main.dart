import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'src/rust/api/storage.dart' as storage;
import 'src/rust/frb_generated.dart';
import 'state/settings.dart';

class VeloraBootstrapContext {
  final String docsPath;
  final SharedPreferences prefs;

  const VeloraBootstrapContext({required this.docsPath, required this.prefs});
}

Future<void> main() async {
  await bootstrapVeloraApp();
}

Future<void> bootstrapVeloraApp({
  FutureOr<void> Function(String docsPath, SharedPreferences prefs)? beforeRun,
  ExternalLibrary? externalLibrary,
  Future<String> Function()? resolveDocsPath,
  bool initializeRust = true,
  SharedPreferences? sharedPreferences,
  void Function(String docsPath)? initializeStorage,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  final context = await prepareVeloraBootstrap(
    externalLibrary: externalLibrary,
    resolveDocsPath: resolveDocsPath,
    initializeRust: initializeRust,
    sharedPreferences: sharedPreferences,
    initializeStorage: initializeStorage,
  );

  if (beforeRun != null) {
    await beforeRun(context.docsPath, context.prefs);
  }

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(context.prefs),
      ],
      child: const VeloraApp(),
    ),
  );
}

@visibleForTesting
Future<VeloraBootstrapContext> prepareVeloraBootstrap({
  ExternalLibrary? externalLibrary,
  Future<String> Function()? resolveDocsPath,
  bool initializeRust = true,
  SharedPreferences? sharedPreferences,
  void Function(String docsPath)? initializeStorage,
}) async {
  if (initializeRust) {
    await RustLib.init(externalLibrary: externalLibrary);
  }

  final docsPath =
      resolveDocsPath != null
          ? await resolveDocsPath()
          : (await getApplicationDocumentsDirectory()).path;
  if (initializeStorage != null) {
    initializeStorage(docsPath);
  } else {
    storage.initStorage(rootDir: docsPath);
  }

  final prefs = sharedPreferences ?? await SharedPreferences.getInstance();
  return VeloraBootstrapContext(docsPath: docsPath, prefs: prefs);
}
