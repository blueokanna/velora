import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:just_audio/just_audio.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

const mediaChapterPrefix = 'velora-media-v1:';

class MediaChapterContent {
  final List<String> images;
  final String? audioUrl;
  final String text;

  const MediaChapterContent({
    this.images = const [],
    this.audioUrl,
    this.text = '',
  });

  bool get hasImages => images.isNotEmpty;
  bool get hasAudio => audioUrl != null && audioUrl!.trim().isNotEmpty;

  static MediaChapterContent? decode(String value) {
    if (!value.startsWith(mediaChapterPrefix)) return null;
    try {
      final json = jsonDecode(value.substring(mediaChapterPrefix.length));
      if (json is! Map<String, dynamic>) return null;
      return MediaChapterContent(
        images: (json['images'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .where((url) => url.trim().isNotEmpty)
            .toList(growable: false),
        audioUrl: json['audio'] as String?,
        text: json['text'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

class MarkdownReaderContent extends StatelessWidget {
  final String data;
  final TextStyle textStyle;
  final String documentPath;
  final EdgeInsets padding;

  const MarkdownReaderContent({
    super.key,
    required this.data,
    required this.textStyle,
    required this.documentPath,
    required this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = textStyle.copyWith(
      height: 1.3,
      fontWeight: FontWeight.w700,
    );
    return SelectionArea(
      child: SingleChildScrollView(
        padding: padding,
        child: MarkdownBody(
          data: data,
          selectable: false,
          extensionSet: md.ExtensionSet.gitHubFlavored,
          blockSyntaxes: const [_LatexBlockSyntax()],
          inlineSyntaxes: [_LatexInlineSyntax()],
          builders: {
            'latex-inline': _LatexBuilder(textStyle, block: false),
            'latex-block': _LatexBuilder(textStyle, block: true),
          },
          styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
            p: textStyle,
            h1: heading.copyWith(fontSize: (textStyle.fontSize ?? 18) * 1.65),
            h2: heading.copyWith(fontSize: (textStyle.fontSize ?? 18) * 1.4),
            h3: heading.copyWith(fontSize: (textStyle.fontSize ?? 18) * 1.2),
            blockquote: textStyle.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            code: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
            codeblockDecoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          imageBuilder: (uri, title, alt) => _MarkdownImage(
            uri: _resolveMarkdownImage(uri, documentPath),
            semanticLabel: alt,
          ),
          onTapLink: (_, href, _) async {
            final uri = href == null ? null : Uri.tryParse(href);
            if (uri != null &&
                (uri.scheme == 'http' || uri.scheme == 'https')) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
        ),
      ),
    );
  }
}

class ComicReaderContent extends StatelessWidget {
  final List<String> images;
  final String? audioUrl;
  final String? localAudioPath;
  final EdgeInsets padding;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String? chapterLabel;

  const ComicReaderContent({
    super.key,
    required this.images,
    this.audioUrl,
    this.localAudioPath,
    required this.padding,
    this.onPrevious,
    this.onNext,
    this.chapterLabel,
  });

  @override
  Widget build(BuildContext context) {
    final hasAudio =
        (audioUrl?.isNotEmpty ?? false) ||
        (localAudioPath?.isNotEmpty ?? false);
    return Column(
      children: [
        if (images.isNotEmpty)
          Expanded(
            child: ListView.builder(
              padding: padding,
              scrollCacheExtent: const ScrollCacheExtent.viewport(1.5),
              itemCount: images.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: RepaintBoundary(
                  child: InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    clipBehavior: Clip.none,
                    child: _ReaderImage(source: images[index]),
                  ),
                ),
              ),
            ),
          )
        else
          const Spacer(),
        if (hasAudio)
          AudioReaderControls(url: audioUrl, localPath: localAudioPath),
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: '上一章 / Previous',
                  onPressed: onPrevious,
                  icon: const Icon(Icons.arrow_back),
                ),
                SizedBox(
                  width: 104,
                  child: Text(
                    chapterLabel ?? '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '下一章 / Next',
                  onPressed: onNext,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class AudioReaderControls extends StatefulWidget {
  final String? url;
  final String? localPath;

  const AudioReaderControls({super.key, this.url, this.localPath});

  @override
  State<AudioReaderControls> createState() => _AudioReaderControlsState();
}

class _AudioReaderControlsState extends State<AudioReaderControls> {
  late final AudioPlayer _player = AudioPlayer();
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant AudioReaderControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.localPath != widget.localPath) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      setState(() => _error = null);
      await _player.stop();
      if (widget.localPath?.isNotEmpty ?? false) {
        await _player.setFilePath(widget.localPath!);
      } else if (widget.url?.isNotEmpty ?? false) {
        await _player.setUrl(widget.url!);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_error != null) {
      return Material(
        color: colors.errorContainer,
        child: ListTile(
          leading: Icon(Icons.error_outline, color: colors.onErrorContainer),
          title: Text(
            '音频加载失败',
            style: TextStyle(color: colors.onErrorContainer),
          ),
          subtitle: Text(
            '$_error',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            tooltip: '重试',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ),
      );
    }
    return Material(
      color: colors.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StreamBuilder<Duration?>(
                stream: _player.durationStream,
                builder: (context, durationSnapshot) => StreamBuilder<Duration>(
                  stream: _player.positionStream,
                  builder: (context, positionSnapshot) {
                    final duration = durationSnapshot.data ?? Duration.zero;
                    final position = positionSnapshot.data ?? Duration.zero;
                    final maximum = duration.inMilliseconds
                        .toDouble()
                        .clamp(1, double.infinity)
                        .toDouble();
                    return Row(
                      children: [
                        Text(_durationLabel(position)),
                        Expanded(
                          child: Slider(
                            min: 0,
                            max: maximum,
                            value: position.inMilliseconds
                                .toDouble()
                                .clamp(0, maximum)
                                .toDouble(),
                            onChanged: duration == Duration.zero
                                ? null
                                : (value) => _player.seek(
                                    Duration(milliseconds: value.round()),
                                  ),
                          ),
                        ),
                        Text(_durationLabel(duration)),
                      ],
                    );
                  },
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: '后退 15 秒',
                    onPressed: () => _seekBy(const Duration(seconds: -15)),
                    icon: const Icon(Icons.replay_10),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final state = snapshot.data;
                      final loading =
                          state?.processingState == ProcessingState.loading ||
                          state?.processingState == ProcessingState.buffering;
                      if (loading) {
                        return const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox.square(
                            dimension: 32,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          ),
                        );
                      }
                      final playing = state?.playing ?? false;
                      return IconButton.filled(
                        tooltip: playing ? '暂停' : '播放',
                        iconSize: 30,
                        onPressed: playing ? _player.pause : _player.play,
                        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: '前进 15 秒',
                    onPressed: () => _seekBy(const Duration(seconds: 15)),
                    icon: const Icon(Icons.forward_10),
                  ),
                  PopupMenuButton<double>(
                    tooltip: '播放速度',
                    initialValue: _player.speed,
                    onSelected: _player.setSpeed,
                    itemBuilder: (context) => [
                      for (final speed in const [0.75, 1.0, 1.25, 1.5, 2.0])
                        PopupMenuItem(value: speed, child: Text('${speed}x')),
                    ],
                    icon: const Icon(Icons.speed),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _seekBy(Duration delta) async {
    final duration = _player.duration ?? Duration.zero;
    final target = _player.position + delta;
    await _player.seek(
      Duration(
        milliseconds: target.inMilliseconds.clamp(0, duration.inMilliseconds),
      ),
    );
  }

  String _durationLabel(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (value.inHours > 0) return '${value.inHours}:$minutes:$seconds';
    return '$minutes:$seconds';
  }
}

class _LatexInlineSyntax extends md.InlineSyntax {
  _LatexInlineSyntax() : super(r'(?<!\\)\$(?!\$)(.+?)(?<!\\)\$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('latex-inline', match[1] ?? ''));
    return true;
  }
}

class _LatexBlockSyntax extends md.BlockSyntax {
  const _LatexBlockSyntax();

  @override
  RegExp get pattern => RegExp(r'^\s*\$\$\s*$');

  @override
  md.Node parse(md.BlockParser parser) {
    parser.advance();
    final lines = <String>[];
    while (!parser.isDone) {
      if (pattern.hasMatch(parser.current.content)) {
        parser.advance();
        break;
      }
      lines.add(parser.current.content);
      parser.advance();
    }
    return md.Element.text('latex-block', lines.join('\n'));
  }
}

class _LatexBuilder extends MarkdownElementBuilder {
  final TextStyle textStyle;
  final bool block;

  _LatexBuilder(this.textStyle, {required this.block});

  @override
  bool isBlockElement() => block;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final math = Math.tex(
      element.textContent,
      mathStyle: block ? MathStyle.display : MathStyle.text,
      textStyle: textStyle,
      onErrorFallback: (error) => SelectableText(
        element.textContent,
        style: textStyle.copyWith(color: Theme.of(context).colorScheme.error),
      ),
    );
    if (!block) return math;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: math,
    );
  }
}

class _MarkdownImage extends StatelessWidget {
  final Uri uri;
  final String? semanticLabel;

  const _MarkdownImage({required this.uri, this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: _ReaderImage(source: uri.toString()),
      ),
    );
  }
}

class _ReaderImage extends StatelessWidget {
  final String source;

  const _ReaderImage({required this.source});

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(source);
    if (uri?.scheme == 'data') {
      final bytes = uri?.data?.contentAsBytes();
      if (bytes != null) {
        return Image.memory(Uint8List.fromList(bytes), fit: BoxFit.contain);
      }
    }
    if (uri?.scheme == 'http' || uri?.scheme == 'https') {
      return Image.network(
        source,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : const AspectRatio(
                aspectRatio: 0.72,
                child: Center(child: CircularProgressIndicator()),
              ),
        errorBuilder: (context, error, stackTrace) => const AspectRatio(
          aspectRatio: 0.72,
          child: Center(child: Icon(Icons.broken_image_outlined, size: 44)),
        ),
      );
    }
    final path = uri?.scheme == 'file' ? uri!.toFilePath() : source;
    return Image.file(
      File(path),
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) => const AspectRatio(
        aspectRatio: 0.72,
        child: Center(child: Icon(Icons.broken_image_outlined, size: 44)),
      ),
    );
  }
}

Uri _resolveMarkdownImage(Uri uri, String documentPath) {
  if (uri.hasScheme || documentPath.isEmpty) return uri;
  final normalized = documentPath.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  final base = slash < 0 ? '' : normalized.substring(0, slash + 1);
  return Uri.file(
    '$base${Uri.decodeComponent(uri.toString())}',
    windows: Platform.isWindows,
  );
}
