import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalReaderFont {
  final String family;
  final String name;
  final String path;

  const LocalReaderFont({
    required this.family,
    required this.name,
    required this.path,
  });

  Map<String, String> toJson() => {
    'family': family,
    'name': name,
    'path': path,
  };

  factory LocalReaderFont.fromJson(Map<String, dynamic> json) {
    return LocalReaderFont(
      family: json['family'] as String? ?? '',
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
    );
  }
}

class ReaderFonts {
  ReaderFonts._();

  static const _catalogKey = 'readerLocalFontsV1';
  static final Set<String> _loadedLocalFamilies = <String>{};
  static List<String>? _googleFamilies;

  static List<String> get googleFamilies =>
      _googleFamilies ??= (GoogleFonts.asMap().keys.toList()..sort());

  static bool isGoogleFamily(String family) =>
      GoogleFonts.asMap().containsKey(family);

  static List<LocalReaderFont> localFonts(SharedPreferences prefs) {
    final raw = prefs.getString(_catalogKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(LocalReaderFont.fromJson)
          .where(
            (font) =>
                font.family.isNotEmpty &&
                font.name.isNotEmpty &&
                font.path.isNotEmpty,
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<LocalReaderFont> importLocalFont(
    SharedPreferences prefs,
    String sourcePath,
  ) async {
    final source = File(sourcePath);
    if (!await source.exists()) throw StateError('字体文件不存在');
    final lower = sourcePath.toLowerCase();
    if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) {
      throw StateError('仅支持 TTF 和 OTF 字体');
    }
    final bytes = await source.readAsBytes();
    if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
      throw StateError('字体文件为空或超过 32MB');
    }
    final fingerprint = _fingerprint(bytes);
    final family = 'VeloraLocal_$fingerprint';
    final existing = localFonts(prefs);
    final duplicate = existing
        .where((font) => font.family == family)
        .firstOrNull;
    if (duplicate != null) {
      await ensureLocalFont(duplicate);
      return duplicate;
    }
    if (existing.length >= 24) {
      throw StateError('本地字体最多保留 24 个，请先删除不再使用的字体');
    }
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}reader_fonts',
    );
    await directory.create(recursive: true);
    final extension = lower.endsWith('.otf') ? 'otf' : 'ttf';
    final destination = File(
      '${directory.path}${Platform.pathSeparator}$fingerprint.$extension',
    );
    if (!await destination.exists()) await destination.writeAsBytes(bytes);
    final name = _fileStem(sourcePath);
    final font = LocalReaderFont(
      family: family,
      name: name.isEmpty ? '本地字体' : name,
      path: destination.path,
    );
    await _saveCatalog(prefs, [...existing, font]);
    await _loadLocalBytes(font.family, bytes);
    return font;
  }

  static Future<void> prepare(SharedPreferences prefs, String family) async {
    if (family.isEmpty || isGoogleFamily(family)) {
      if (family.isEmpty) return;
      GoogleFonts.getFont(family);
      await GoogleFonts.pendingFonts();
      return;
    }
    final matches = localFonts(prefs).where((font) => font.family == family);
    if (matches.isEmpty) throw StateError('本地字体已被移除');
    await ensureLocalFont(matches.first);
  }

  static Future<void> ensureLocalFont(LocalReaderFont font) async {
    if (_loadedLocalFamilies.contains(font.family)) return;
    final bytes = await File(font.path).readAsBytes();
    await _loadLocalBytes(font.family, bytes);
  }

  static Future<void> removeLocalFont(
    SharedPreferences prefs,
    LocalReaderFont font,
  ) async {
    final remaining = localFonts(
      prefs,
    ).where((item) => item.family != font.family).toList(growable: false);
    await _saveCatalog(prefs, remaining);
    final file = File(font.path);
    if (await file.exists()) await file.delete();
  }

  static Future<void> _loadLocalBytes(String family, Uint8List bytes) async {
    if (_loadedLocalFamilies.contains(family)) return;
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    _loadedLocalFamilies.add(family);
  }

  static Future<void> _saveCatalog(
    SharedPreferences prefs,
    List<LocalReaderFont> fonts,
  ) {
    return prefs.setString(
      _catalogKey,
      jsonEncode(fonts.map((font) => font.toJson()).toList()),
    );
  }

  static String _fileStem(String path) {
    final fileName = path.replaceAll('\\', '/').split('/').last;
    final dot = fileName.lastIndexOf('.');
    return (dot > 0 ? fileName.substring(0, dot) : fileName).trim();
  }

  static String _fingerprint(Uint8List bytes) {
    var hash = 0xcbf29ce484222325;
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
