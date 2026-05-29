import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../l10n/app_localizations.dart';
import '../../state/sources.dart';

class SourcesPage extends ConsumerStatefulWidget {
  const SourcesPage({super.key});

  @override
  ConsumerState<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends ConsumerState<SourcesPage> {
  Future<void> _import() async {
    final result = await showDialog<_ImportDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ImportSourcesDialog(),
    );
    if (!mounted || result == null) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (result.cancelled) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.importCancelled)));
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.imported > 0
              ? '${l10n.imported}: ${result.imported}'
              : l10n.importFailed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final list = ref.watch(sourcesProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.bookSources),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: l10n.importJson,
            onPressed: _import,
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
                      onPressed: _import,
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

class _ImportSourcesDialog extends ConsumerStatefulWidget {
  const _ImportSourcesDialog();

  @override
  ConsumerState<_ImportSourcesDialog> createState() =>
      _ImportSourcesDialogState();
}

class _ImportSourcesDialogState extends ConsumerState<_ImportSourcesDialog> {
  final _controller = TextEditingController();
  SourceImportController? _importController;
  SourceImportProgress? _progress;
  String? _error;
  bool _running = false;

  bool get _hasInput => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleTextChanged);
  }

  void _handleTextChanged() {
    if (!mounted || _running) return;
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_handleTextChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _startImport() async {
    if (_running || !_hasInput) return;
    final controller = SourceImportController();
    setState(() {
      _running = true;
      _error = null;
      _progress = const SourceImportProgress(
        stage: SourceImportStage.preparing,
      );
      _importController = controller;
    });
    try {
      final imported = await ref
          .read(sourcesProvider.notifier)
          .importTextOrUrl(
            _controller.text,
            controller: controller,
            onProgress: (progress) {
              if (!mounted) return;
              setState(() => _progress = progress);
            },
          );
      if (!mounted) return;
      Navigator.pop(context, _ImportDialogResult.completed(imported));
    } on SourceImportCancelled {
      if (!mounted) return;
      setState(() {
        _running = false;
        _progress = const SourceImportProgress(
          stage: SourceImportStage.cancelled,
        );
        _importController = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '$error';
        _importController = null;
      });
    }
  }

  Future<void> _scanQrAndImport() async {
    if (_running) return;
    final l10n = AppLocalizations.of(context);
    final permission = await Permission.camera.request();
    if (!mounted) return;
    if (!permission.isGranted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.cameraPermissionRequired)));
      return;
    }
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => const _ScanSourceQrPage(),
      ),
    );
    if (!mounted || scanned == null || scanned.trim().isEmpty) return;
    _controller.text = scanned.trim();
    await _startImport();
  }

  void _cancelImport() {
    _importController?.cancel();
  }

  String _progressTitle(AppLocalizations l10n, SourceImportProgress? progress) {
    switch (progress?.stage) {
      case SourceImportStage.fetching:
        return l10n.importFetchingSources;
      case SourceImportStage.parsing:
        return l10n.importParsingSources;
      case SourceImportStage.merging:
        return l10n.importMergingSources;
      case SourceImportStage.saving:
        return l10n.importSavingSources;
      case SourceImportStage.completed:
        return l10n.imported;
      case SourceImportStage.cancelled:
        return l10n.importCancelled;
      case SourceImportStage.preparing:
      case null:
        return l10n.importPreparing;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final progress = _progress;
    final value = progress?.value;
    return PopScope(
      canPop: !_running,
      child: AlertDialog(
        title: Text(l10n.importJson),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: _running ? null : _scanQrAndImport,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(l10n.importByQrCode),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                minLines: 6,
                maxLines: 14,
                readOnly: _running,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText:
                      'JSON, https://example.com/sources.json, yuedu://...',
                ),
              ),
              if (progress != null || _error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _progressTitle(l10n, progress),
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: value),
                if (progress?.total != null) ...[
                  const SizedBox(height: 8),
                  Text('${progress!.processed} / ${progress.total}'),
                ],
                if ((progress?.imported ?? 0) > 0) ...[
                  const SizedBox(height: 4),
                  Text('${l10n.imported}: ${progress!.imported}'),
                ],
                if (progress?.label?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 8),
                  Text(
                    progress!.label!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _running
                ? _cancelImport
                : () => Navigator.pop(context, _ImportDialogResult.cancelled()),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: _running || !_hasInput ? null : _startImport,
            child: Text(l10n.import),
          ),
        ],
      ),
    );
  }
}

class _ImportDialogResult {
  final int imported;
  final bool cancelled;

  const _ImportDialogResult({required this.imported, required this.cancelled});

  factory _ImportDialogResult.completed(int imported) {
    return _ImportDialogResult(imported: imported, cancelled: false);
  }

  factory _ImportDialogResult.cancelled() {
    return const _ImportDialogResult(imported: 0, cancelled: true);
  }
}

class _ScanSourceQrPage extends StatefulWidget {
  const _ScanSourceQrPage();

  @override
  State<_ScanSourceQrPage> createState() => _ScanSourceQrPageState();
}

class _ScanSourceQrPageState extends State<_ScanSourceQrPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleCapture(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue?.trim();
      if (rawValue == null || rawValue.isEmpty) {
        continue;
      }
      _handled = true;
      Navigator.of(context).pop(rawValue);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(l10n.scanQrCode),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _handleCapture),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  border: Border.all(color: colorScheme.primary, width: 3),
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
              child: Text(
                l10n.scanQrCodeHint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
