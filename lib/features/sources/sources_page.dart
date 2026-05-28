import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../state/sources.dart';

class SourcesPage extends ConsumerWidget {
  const SourcesPage({super.key});

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(AppLocalizations.of(context).importJson),
        content: TextField(
          controller: controller,
          minLines: 6,
          maxLines: 14,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'JSON, https://example.com/sources.json, yuedu://...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(AppLocalizations.of(context).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(AppLocalizations.of(context).import),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await ref
            .read(sourcesProvider.notifier)
            .importTextOrUrl(controller.text);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final list = ref.watch(sourcesProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.bookSources),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: l10n.importJson,
            onPressed: () => _import(context, ref),
          ),
        ],
      ),
      body: list.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cloud_outlined,
                      size: 80,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.noSources,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.noSourcesSub,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => _import(context, ref),
                      icon: const Icon(Icons.file_upload_outlined),
                      label: Text(l10n.importJson),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              itemCount: list.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final src = list[i];
                return SwitchListTile(
                  title: Text(src.name),
                  subtitle: Text(
                    src.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  value: src.enabled,
                  onChanged: (v) =>
                      ref.read(sourcesProvider.notifier).toggle(src.url, v),
                  secondary: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () =>
                        ref.read(sourcesProvider.notifier).remove(src.url),
                  ),
                );
              },
            ),
    );
  }
}
