import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/reader_fonts.dart';
import '../../state/settings.dart';
import '../../theme/app_theme.dart';

Future<void> showReaderFontPicker(
  BuildContext context, {
  FutureOr<void> Function()? onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.9,
      child: ReaderFontPicker(onChanged: onChanged),
    ),
  );
}

class ReaderFontPicker extends ConsumerStatefulWidget {
  final FutureOr<void> Function()? onChanged;

  const ReaderFontPicker({super.key, this.onChanged});

  @override
  ConsumerState<ReaderFontPicker> createState() => _ReaderFontPickerState();
}

class _ReaderFontPickerState extends ConsumerState<ReaderFontPicker> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _loadingFamily;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final prefs = ref.watch(sharedPreferencesProvider);
    final googleFonts = ReaderFonts.googleFamilies
        .where(
          (family) => _query.isEmpty || family.toLowerCase().contains(_query),
        )
        .toList(growable: false);
    final localFonts = ReaderFonts.localFonts(prefs);
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '阅读字体 / Reading fonts',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索 Google Fonts',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.clear),
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
          ),
          const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.cloud_download_outlined), text: 'Google'),
              Tab(icon: Icon(Icons.folder_outlined), text: '本地字体'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListView.builder(
                  itemCount: googleFonts.length,
                  itemExtent: 58,
                  itemBuilder: (context, index) {
                    final family = googleFonts[index];
                    return _FontTile(
                      family: family,
                      label: family,
                      selected: settings.readerFontFamily == family,
                      loading: _loadingFamily == family,
                      onTap: () => _selectFamily(family),
                    );
                  },
                ),
                localFonts.isEmpty
                    ? _EmptyLocalFonts(onImport: _importFont)
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 88),
                        children: [
                          for (final font in localFonts)
                            _FontTile(
                              family: font.family,
                              label: font.name,
                              selected:
                                  settings.readerFontFamily == font.family,
                              loading: _loadingFamily == font.family,
                              onTap: () => _selectFamily(font.family),
                              onDelete: () => _deleteFont(font),
                            ),
                        ],
                      ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _loadingFamily == null ? _importFont : null,
                icon: const Icon(Icons.add),
                label: const Text('导入 TTF / OTF'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _selectFamily(String family) async {
    if (_loadingFamily != null) return;
    setState(() => _loadingFamily = family);
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await ReaderFonts.prepare(prefs, family);
      if (!mounted) return;
      await ref
          .read(settingsProvider.notifier)
          .update(
            (previous) => previous.copyWith(
              readerFont: _presetForFamily(family) ?? previous.readerFont,
              readerFontFamily: family,
            ),
          );
      await widget.onChanged?.call();
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('字体加载失败: $error')));
    } finally {
      if (mounted) setState(() => _loadingFamily = null);
    }
  }

  Future<void> _importFont() async {
    if (_loadingFamily != null) return;
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['ttf', 'otf'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    setState(() => _loadingFamily = path);
    try {
      final font = await ReaderFonts.importLocalFont(
        ref.read(sharedPreferencesProvider),
        path,
      );
      if (!mounted) return;
      await ref
          .read(settingsProvider.notifier)
          .update(
            (previous) => previous.copyWith(readerFontFamily: font.family),
          );
      await widget.onChanged?.call();
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('字体导入失败: $error')));
    } finally {
      if (mounted) setState(() => _loadingFamily = null);
    }
  }

  Future<void> _deleteFont(LocalReaderFont font) async {
    if (ref.read(settingsProvider).readerFontFamily == font.family) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在使用的字体不能删除，请先切换字体')));
      return;
    }
    await ReaderFonts.removeLocalFont(
      ref.read(sharedPreferencesProvider),
      font,
    );
    if (mounted) setState(() {});
  }

  ReaderFontPreset? _presetForFamily(String family) => switch (family) {
    'Noto Serif SC' => ReaderFontPreset.notoSerif,
    'Noto Sans SC' => ReaderFontPreset.notoSans,
    'Literata' => ReaderFontPreset.literata,
    'Merriweather' => ReaderFontPreset.merriweather,
    'Lora' => ReaderFontPreset.lora,
    _ => null,
  };
}

class _FontTile extends StatelessWidget {
  final String family;
  final String label;
  final bool selected;
  final bool loading;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _FontTile({
    required this.family,
    required this.label,
    required this.selected,
    required this.loading,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: loading
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            )
          : Icon(selected ? Icons.check_circle : Icons.font_download_outlined),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: family.startsWith('VeloraLocal_')
          ? const Text('本地 / Local')
          : null,
      selected: selected,
      onTap: loading ? null : onTap,
      trailing: onDelete == null
          ? null
          : IconButton(
              tooltip: '删除字体',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
    );
  }
}

class _EmptyLocalFonts extends StatelessWidget {
  final VoidCallback onImport;

  const _EmptyLocalFonts({required this.onImport});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.font_download_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            const Text('尚未导入本地字体'),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.add),
              label: const Text('导入字体'),
            ),
          ],
        ),
      ),
    );
  }
}
