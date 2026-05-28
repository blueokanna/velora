import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_keys.dart';
import '../../l10n/app_localizations.dart';
import '../../state/settings.dart';
import '../../theme/app_theme.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      key: AppKeys.settingsPage,
      appBar: AppBar(title: Text(l10n.settings)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _SectionHeader(text: l10n.appearance),
              _SettingsSwitchTile(
                icon: Icons.color_lens_outlined,
                title: l10n.useSystemMonet,
                subtitle: l10n.useSystemMonetSub,
                value: settings.useDynamicColor,
                onChanged: (value) => notifier.update(
                  (previous) => previous.copyWith(useDynamicColor: value),
                ),
              ),
              _SettingsTile(
                key: AppKeys.settingsThemeModeTile,
                icon: Icons.dark_mode_outlined,
                title: l10n.themeMode,
                subtitle: _themeLabel(context, settings.themeMode),
                onTap: () => _pickThemeMode(context, ref),
              ),
              _SettingsTile(
                key: AppKeys.settingsThemeFlavorTile,
                icon: Icons.palette_outlined,
                title: l10n.themeFlavor,
                subtitle: _flavorLabel(context, settings.flavor),
                onTap: () => _pickThemeFlavor(context, ref),
              ),
              _SettingsTile(
                key: AppKeys.settingsLanguageTile,
                icon: Icons.language,
                title: l10n.languageSetting,
                subtitle: _localeLabel(context, settings.locale),
                onTap: () => _pickLocale(context, ref),
              ),
              const SizedBox(height: 18),
              _SettingsTile(
                icon: Icons.info_outline,
                title: '关于 Velora',
                subtitle: 'Velora 1.0.0+1 · AGPL-3.0 · blueokanna',
                onTap: () => _showVeloraAbout(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _themeLabel(BuildContext context, ThemeMode mode) {
    final l10n = AppLocalizations.of(context);
    return switch (mode) {
      ThemeMode.system => l10n.themeSystem,
      ThemeMode.light => l10n.themeLight,
      ThemeMode.dark => l10n.themeDark,
    };
  }

  String _flavorLabel(BuildContext context, ThemeFlavor flavor) {
    final l10n = AppLocalizations.of(context);
    return switch (flavor) {
      ThemeFlavor.pantone => l10n.flavorPantone,
      ThemeFlavor.monet => l10n.flavorMonet,
      ThemeFlavor.amoled => l10n.flavorAmoled,
    };
  }

  String _localeLabel(BuildContext context, String code) {
    if (code == 'system') return AppLocalizations.of(context).languageSystem;
    return AppLocalizations.languageDisplayNames[code] ?? code;
  }

  Future<void> _pickThemeMode(BuildContext context, WidgetRef ref) async {
    final options = {
      for (final mode in ThemeMode.values) mode: _themeLabel(context, mode),
    };
    final value = await _pickValue<ThemeMode>(
      context,
      AppLocalizations.of(context).themeMode,
      ref.read(settingsProvider).themeMode,
      options,
    );
    if (value != null) {
      await ref
          .read(settingsProvider.notifier)
          .update((previous) => previous.copyWith(themeMode: value));
    }
  }

  Future<void> _pickThemeFlavor(BuildContext context, WidgetRef ref) async {
    final options = {
      for (final flavor in ThemeFlavor.values)
        flavor: _flavorLabel(context, flavor),
    };
    final value = await _pickValue<ThemeFlavor>(
      context,
      AppLocalizations.of(context).themeFlavor,
      ref.read(settingsProvider).flavor,
      options,
    );
    if (value != null) {
      await ref
          .read(settingsProvider.notifier)
          .update((previous) => previous.copyWith(flavor: value));
    }
  }

  Future<void> _pickLocale(BuildContext context, WidgetRef ref) async {
    final options = {
      'system': '系统 / System',
      ...AppLocalizations.languageDisplayNames,
    };
    final value = await _pickValue<String>(
      context,
      AppLocalizations.of(context).languageSetting,
      ref.read(settingsProvider).locale,
      options,
    );
    if (value != null) {
      await ref
          .read(settingsProvider.notifier)
          .update((previous) => previous.copyWith(locale: value));
    }
  }

  Future<T?> _pickValue<T>(
    BuildContext context,
    String title,
    T current,
    Map<T, String> options,
  ) {
    return showDialog<T>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: options.entries
            .map(
              (entry) => SimpleDialogOption(
                key: AppKeys.settingsOption(entry.key ?? 'null'),
                onPressed: () => Navigator.pop(context, entry.key),
                child: Row(
                  children: [
                    Expanded(child: Text(entry.value)),
                    if (entry.key == current) const Icon(Icons.check),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Future<void> _showVeloraAbout(BuildContext context) async {
    final releaseUrl = Uri.parse(
      'https://github.com/blueokanna/velora/releases/latest',
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Velora'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset(
                      'assets/light.png',
                      width: 88,
                      height: 88,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text('版本：1.0.0+1'),
                const SizedBox(height: 8),
                const Text('作者：blueokanna'),
                const SizedBox(height: 8),
                const Text('许可证：GNU Affero General Public License v3.0'),
                const SizedBox(height: 8),
                const SelectableText(
                  '更新：https://github.com/blueokanna/velora/releases/latest',
                ),
                const SizedBox(height: 14),
                Text(
                  'Velora 仅用于阅读和管理用户依法享有授权或合法权利的内容，禁止用于任何侵权抓取、聚合、传播、引流或变现行为。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(AppLocalizations.of(context).cancel),
          ),
          FilledButton.icon(
            onPressed: () async {
              await launchUrl(releaseUrl, mode: LaunchMode.externalApplication);
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('检查更新'),
          ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingsSwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;

  const _SectionHeader({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
