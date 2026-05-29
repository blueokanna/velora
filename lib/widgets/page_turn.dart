import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/motion.dart';

enum PageTurnDirection { next, prev }

class PageTurnController extends ChangeNotifier {
  PageTurnController({required int initialPage}) : _page = initialPage;

  int _page;
  int get page => _page;

  void jumpTo(int page) {
    _page = page;
    notifyListeners();
  }
}

enum PageTurnEffectType { slide, cover, curl, fade, scroll }

class _TurnAnimation extends StatefulWidget {
  final Widget current;
  final Widget? next;
  final PageTurnDirection direction;
  final PageTurnEffectType effect;
  final double beginProgress;
  final double endProgress;
  final VoidCallback onCompleted;

  const _TurnAnimation({
    required this.current,
    required this.next,
    required this.direction,
    required this.effect,
    required this.beginProgress,
    required this.endProgress,
    required this.onCompleted,
  });

  @override
  State<_TurnAnimation> createState() => _TurnAnimationState();
}

class _TurnAnimationState extends State<_TurnAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: _scaledDuration(),
  )..forward();

  late final Animation<double> _progress =
      Tween<double>(
        begin: widget.beginProgress,
        end: widget.endProgress,
      ).animate(
        CurvedAnimation(
          parent: _ctrl,
          curve: widget.endProgress >= widget.beginProgress
              ? M3Motion.emphasizedDecelerate
              : M3Motion.emphasizedAccelerate,
        ),
      );

  static Duration _durationFor(PageTurnEffectType e) => switch (e) {
    PageTurnEffectType.fade => M3Motion.medium4,
    PageTurnEffectType.slide => M3Motion.long2,
    PageTurnEffectType.cover => M3Motion.long2,
    PageTurnEffectType.scroll => M3Motion.medium4,
    PageTurnEffectType.curl => M3Motion.long4,
  };

  Duration _scaledDuration() {
    final base = _durationFor(widget.effect);
    final distance = (widget.endProgress - widget.beginProgress).abs().clamp(
      0.2,
      1.0,
    );
    return Duration(milliseconds: (base.inMilliseconds * distance).round());
  }

  @override
  void initState() {
    super.initState();
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onCompleted();
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) => _TurnPresentation(
        current: widget.current,
        next: widget.next,
        direction: widget.direction,
        effect: widget.effect,
        progress: _progress.value,
      ),
    );
  }
}

class _TurnPresentation extends StatelessWidget {
  final Widget current;
  final Widget? next;
  final PageTurnDirection direction;
  final PageTurnEffectType effect;
  final double progress;
  final bool interactive;
  final double? fingerX;

  const _TurnPresentation({
    required this.current,
    required this.next,
    required this.direction,
    required this.effect,
    required this.progress,
    this.interactive = false,
    this.fingerX,
  });

  @override
  Widget build(BuildContext context) {
    final bounded = progress.clamp(0.0, 1.0).toDouble();
    return switch (effect) {
      PageTurnEffectType.fade => _buildFade(bounded),
      PageTurnEffectType.slide => _buildSlide(context, bounded),
      PageTurnEffectType.cover => _buildCover(context, bounded),
      PageTurnEffectType.scroll => _buildScroll(bounded),
      PageTurnEffectType.curl => _buildCurl(context, bounded),
    };
  }

  Widget _buildFade(double v) {
    final eased = interactive ? v : Curves.easeOut.transform(v);
    return Stack(
      children: [
        Opacity(opacity: 1 - eased, child: current),
        Opacity(opacity: eased, child: next ?? current),
      ],
    );
  }

  Widget _buildSlide(BuildContext context, double v) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final sign = direction == PageTurnDirection.next ? 1.0 : -1.0;
        final eased = interactive ? v : Curves.easeOutCubic.transform(v);
        return Stack(
          children: [
            Opacity(
              opacity: 1 - eased * 0.35,
              child: Transform.translate(
                offset: Offset(-sign * eased * width * 0.22, 0),
                child: current,
              ),
            ),
            Opacity(
              opacity: 0.65 + eased * 0.35,
              child: Transform.translate(
                offset: Offset(sign * (1 - eased) * width * 0.72, 0),
                child: next ?? current,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCover(BuildContext context, double v) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final sign = direction == PageTurnDirection.next ? 1.0 : -1.0;
        final eased = interactive
            ? v
            : Curves.easeInOutCubicEmphasized.transform(v);
        final edgeBegin = direction == PageTurnDirection.next
            ? Alignment.centerLeft
            : Alignment.centerRight;
        final edgeEnd = direction == PageTurnDirection.next
            ? Alignment.centerRight
            : Alignment.centerLeft;
        return Stack(
          children: [
            Transform.translate(
              offset: Offset(-sign * eased * width * 0.08, 0),
              child: current,
            ),
            Transform.translate(
              offset: Offset(sign * (1 - eased) * width, 0),
              child: Stack(
                children: [
                  Material(
                    elevation: 16,
                    shadowColor: Colors.black45,
                    color: Theme.of(context).colorScheme.surface,
                    child: next ?? current,
                  ),
                  Positioned(
                    top: 0,
                    bottom: 0,
                    left: direction == PageTurnDirection.next ? 0 : null,
                    right: direction == PageTurnDirection.next ? null : 0,
                    width: 42,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: edgeBegin,
                            end: edgeEnd,
                            colors: [
                              Colors.black.withValues(
                                alpha: interactive ? 0.34 : 0.26,
                              ),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildScroll(double v) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final sign = direction == PageTurnDirection.next ? 1.0 : -1.0;
        final eased = interactive ? v : Curves.easeOutCubic.transform(v);
        return Stack(
          children: [
            Transform.translate(
              offset: Offset(0, -sign * eased * height * 0.4),
              child: current,
            ),
            Transform.translate(
              offset: Offset(0, sign * (1 - eased) * height * 0.7),
              child: next ?? current,
            ),
          ],
        );
      },
    );
  }

  Widget _buildCurl(BuildContext context, double v) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sign = direction == PageTurnDirection.next ? 1.0 : -1.0;
        final turn = interactive ? v : Curves.easeInOutCubic.transform(v);
        final foldX = _resolveFoldX(constraints.maxWidth);
        final foldWidth = (24 + constraints.maxWidth * turn * 0.16).clamp(
          24.0,
          constraints.maxWidth * 0.24,
        );
        final angle = sign * turn * (interactive ? 0.88 : 0.94);
        final edgeBegin = direction == PageTurnDirection.next
            ? Alignment.centerRight
            : Alignment.centerLeft;
        final edgeEnd = direction == PageTurnDirection.next
            ? Alignment.centerLeft
            : Alignment.centerRight;
        return Stack(
          children: [
            Transform.translate(
              offset: Offset(
                -sign * (1 - turn) * constraints.maxWidth * 0.08,
                0,
              ),
              child: next ?? current,
            ),
            Transform(
              alignment: direction == PageTurnDirection.next
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              transform: Matrix4.identity()
                ..setEntry(3, 2, interactive ? 0.0018 : 0.0015)
                ..rotateY(-angle),
              child: ClipPath(
                clipper: _PageCurlClipper(
                  progress: turn,
                  direction: direction,
                  foldX: foldX,
                  foldWidth: foldWidth,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: interactive ? 0.34 : 0.26,
                        ),
                        blurRadius: interactive ? 32 : 26,
                        offset: Offset(
                          direction == PageTurnDirection.next ? -12 : 12,
                          interactive ? 16 : 12,
                        ),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      current,
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: edgeBegin,
                                end: edgeEnd,
                                colors: [
                                  Colors.black.withValues(
                                    alpha: interactive ? 0.34 : 0.28,
                                  ),
                                  Colors.black.withValues(
                                    alpha: interactive ? 0.16 : 0.12,
                                  ),
                                  Colors.transparent,
                                ],
                                stops: const [0, 0.18, 0.5],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (turn > 0.3)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: edgeEnd,
                                  end: edgeBegin,
                                  colors: [
                                    Theme.of(context).colorScheme.surface
                                        .withValues(alpha: 0.05),
                                    Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest
                                        .withValues(
                                          alpha: interactive ? 0.22 : 0.18,
                                        ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            IgnorePointer(
              child: CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: _CurlShadowPainter(
                  progress: turn,
                  direction: direction,
                  interactive: interactive,
                  foldX: foldX,
                  foldWidth: foldWidth,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  double _resolveFoldX(double width) {
    if (fingerX != null) {
      return fingerX!.clamp(width * 0.06, width * 0.94).toDouble();
    }
    return direction == PageTurnDirection.next
        ? width * (1 - progress * 0.96)
        : width * progress * 0.96;
  }
}

class _PageCurlClipper extends CustomClipper<Path> {
  final double progress;
  final PageTurnDirection direction;
  final double? foldX;
  final double foldWidth;

  _PageCurlClipper({
    required this.progress,
    required this.direction,
    required this.foldWidth,
    this.foldX,
  });

  @override
  Path getClip(Size size) {
    final path = Path();
    final width = size.width;
    final height = size.height;
    final resolvedFoldX =
        (foldX ??
                (direction == PageTurnDirection.next
                    ? width * (1 - progress * 0.96)
                    : width * progress * 0.96))
            .clamp(width * 0.04, width * 0.96)
            .toDouble();
    final sweep = foldWidth.clamp(18.0, width * 0.28);
    if (direction == PageTurnDirection.next) {
      path.moveTo(0, 0);
      path.lineTo(resolvedFoldX, 0);
      path.cubicTo(
        math.max(0, resolvedFoldX - sweep * 0.14),
        height * 0.12,
        math.max(0, resolvedFoldX - sweep * 0.96),
        height * 0.36,
        math.max(0, resolvedFoldX - sweep * 0.82),
        height * 0.58,
      );
      path.cubicTo(
        math.max(0, resolvedFoldX - sweep * 0.56),
        height * 0.78,
        math.max(0, resolvedFoldX - sweep * 0.16),
        height * 0.92,
        resolvedFoldX,
        height,
      );
      path.lineTo(0, height);
      path.close();
    } else {
      path.moveTo(resolvedFoldX, 0);
      path.lineTo(width, 0);
      path.lineTo(width, height);
      path.lineTo(resolvedFoldX, height);
      path.cubicTo(
        math.min(width, resolvedFoldX + sweep * 0.16),
        height * 0.92,
        math.min(width, resolvedFoldX + sweep * 0.56),
        height * 0.78,
        math.min(width, resolvedFoldX + sweep * 0.82),
        height * 0.58,
      );
      path.cubicTo(
        math.min(width, resolvedFoldX + sweep * 0.96),
        height * 0.36,
        math.min(width, resolvedFoldX + sweep * 0.14),
        height * 0.12,
        resolvedFoldX,
        0,
      );
      path.close();
    }
    return path;
  }

  @override
  bool shouldReclip(_PageCurlClipper oldClipper) {
    return oldClipper.progress != progress || oldClipper.direction != direction;
  }
}

class _CurlShadowPainter extends CustomPainter {
  final double progress;
  final PageTurnDirection direction;
  final bool interactive;
  final double foldX;
  final double foldWidth;

  _CurlShadowPainter({
    required this.progress,
    required this.direction,
    required this.interactive,
    required this.foldX,
    required this.foldWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final height = size.height;
    final primaryWidth = foldWidth * (interactive ? 1.28 : 1.1);
    final primaryRect = Rect.fromLTWH(
      direction == PageTurnDirection.next
          ? foldX - primaryWidth
          : foldX - primaryWidth * 0.18,
      0,
      primaryWidth * 1.18,
      height,
    );
    final shadowPaint = Paint()
      ..shader = LinearGradient(
        begin: direction == PageTurnDirection.next
            ? Alignment.centerRight
            : Alignment.centerLeft,
        end: direction == PageTurnDirection.next
            ? Alignment.centerLeft
            : Alignment.centerRight,
        colors: [
          Colors.black.withValues(
            alpha: (interactive ? 0.44 : 0.34) * (1 - progress * 0.35),
          ),
          Colors.black.withValues(alpha: interactive ? 0.18 : 0.11),
          Colors.transparent,
        ],
        stops: const [0, 0.42, 1],
      ).createShader(primaryRect);
    canvas.drawRect(primaryRect, shadowPaint);

    final highlightRect = Rect.fromLTWH(
      direction == PageTurnDirection.next ? foldX - 12 : foldX - 4,
      0,
      18,
      height,
    );
    final highlightPaint = Paint()
      ..shader = LinearGradient(
        begin: direction == PageTurnDirection.next
            ? Alignment.centerRight
            : Alignment.centerLeft,
        end: direction == PageTurnDirection.next
            ? Alignment.centerLeft
            : Alignment.centerRight,
        colors: [
          Colors.white.withValues(alpha: interactive ? 0.16 : 0.1),
          Colors.transparent,
        ],
      ).createShader(highlightRect);
    canvas.drawRect(highlightRect, highlightPaint);
  }

  @override
  bool shouldRepaint(_CurlShadowPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.direction != direction ||
        oldDelegate.interactive != interactive;
  }
}

class PageTurnView extends StatefulWidget {
  final int pageCount;
  final int initialPage;
  final IndexedWidgetBuilder pageBuilder;
  final PageTurnEffectType effect;
  final VoidCallback? onTapCenter;
  final ValueChanged<int>? onPageChanged;
  final VoidCallback? onReachStart;
  final VoidCallback? onReachEnd;

  const PageTurnView({
    super.key,
    required this.pageCount,
    required this.pageBuilder,
    this.initialPage = 0,
    this.effect = PageTurnEffectType.cover,
    this.onTapCenter,
    this.onPageChanged,
    this.onReachStart,
    this.onReachEnd,
  });

  @override
  State<PageTurnView> createState() => PageTurnViewState();
}

class PageTurnViewState extends State<PageTurnView> {
  late int _current = widget.initialPage;
  int? _target;
  PageTurnDirection _dir = PageTurnDirection.next;
  double? _dragStartX;
  double? _dragFingerX;
  double _dragProgress = 0;
  double? _animationBegin;
  double? _animationEnd;
  bool _commitAnimation = false;
  PageTurnDirection? _edgeDragDirection;
  Widget? _cachedTransitionCurrentPage;
  Widget? _cachedTransitionNextPage;
  int? _cachedTransitionCurrentIndex;
  int? _cachedTransitionNextIndex;

  bool get _isAnimating => _animationBegin != null && _animationEnd != null;
  bool get _hasTransitionPreview =>
      _target != null && (_isAnimating || _dragProgress > 0);
  int get debugCurrentPage => _current;
  bool get debugHasInteractivePreview => _target != null && _dragProgress > 0;
  double get debugDragProgress => _dragProgress;

  void _clearTransitionCache() {
    _cachedTransitionCurrentPage = null;
    _cachedTransitionNextPage = null;
    _cachedTransitionCurrentIndex = null;
    _cachedTransitionNextIndex = null;
  }

  Widget _buildPage(BuildContext context, int index) {
    return RepaintBoundary(child: widget.pageBuilder(context, index));
  }

  Widget _currentPageFor(BuildContext context) {
    if (!_hasTransitionPreview) {
      return _buildPage(context, _current);
    }
    if (_cachedTransitionCurrentPage == null ||
        _cachedTransitionCurrentIndex != _current) {
      _cachedTransitionCurrentPage = _buildPage(context, _current);
      _cachedTransitionCurrentIndex = _current;
    }
    return _cachedTransitionCurrentPage!;
  }

  Widget? _targetPageFor(BuildContext context) {
    final target = _target;
    if (!_hasTransitionPreview || target == null) {
      return null;
    }
    if (_cachedTransitionNextPage == null ||
        _cachedTransitionNextIndex != target) {
      _cachedTransitionNextPage = _buildPage(context, target);
      _cachedTransitionNextIndex = target;
    }
    return _cachedTransitionNextPage!;
  }

  void debugPreview(PageTurnDirection direction, double progress) {
    if (!_canTurn(direction)) return;
    setState(() {
      _dir = direction;
      _target = _targetPage(direction);
      _dragProgress = progress.clamp(0.0, 1.0).toDouble();
      _dragStartX = null;
      _dragFingerX = null;
      _animationBegin = null;
      _animationEnd = null;
      _edgeDragDirection = null;
    });
  }

  void debugResolvePreview({required bool commit}) {
    final target = _target;
    setState(() {
      if (commit && target != null) {
        _current = target;
      }
      _target = null;
      _dragProgress = 0;
      _dragStartX = null;
      _dragFingerX = null;
      _animationBegin = null;
      _animationEnd = null;
      _edgeDragDirection = null;
      _commitAnimation = false;
      _clearTransitionCache();
    });
    if (commit && target != null) {
      widget.onPageChanged?.call(_current);
    }
  }

  @override
  void didUpdateWidget(covariant PageTurnView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pageCount <= 0) {
      _current = 0;
      _target = null;
      _dragProgress = 0;
      _dragFingerX = null;
      _animationBegin = null;
      _animationEnd = null;
      return;
    }
    if (_current >= widget.pageCount) {
      _current = widget.pageCount - 1;
    }
    if (_target != null && _target! >= widget.pageCount) {
      _target = null;
      _dragProgress = 0;
      _dragFingerX = null;
      _animationBegin = null;
      _animationEnd = null;
    }
    if (oldWidget.pageBuilder != widget.pageBuilder ||
        oldWidget.pageCount != widget.pageCount) {
      _clearTransitionCache();
    }
  }

  bool _canTurn(PageTurnDirection direction) {
    if (widget.pageCount <= 0) return false;
    return switch (direction) {
      PageTurnDirection.next => _current < widget.pageCount - 1,
      PageTurnDirection.prev => _current > 0,
    };
  }

  int _targetPage(PageTurnDirection direction) {
    return switch (direction) {
      PageTurnDirection.next => _current + 1,
      PageTurnDirection.prev => _current - 1,
    };
  }

  void _notifyEdge(PageTurnDirection direction) {
    if (direction == PageTurnDirection.next) {
      widget.onReachEnd?.call();
    } else {
      widget.onReachStart?.call();
    }
  }

  void _beginAnimatedTurn(
    PageTurnDirection direction, {
    required double begin,
    required double end,
    required bool commit,
  }) {
    if (_target != null || _isAnimating) return;
    if (!_canTurn(direction)) {
      if (commit) {
        _notifyEdge(direction);
      }
      return;
    }
    setState(() {
      _dir = direction;
      _target = _targetPage(direction);
      _animationBegin = begin;
      _animationEnd = end;
      _commitAnimation = commit;
      _dragProgress = 0;
      _dragStartX = null;
      _dragFingerX = null;
      _edgeDragDirection = null;
    });
  }

  void next() {
    _beginAnimatedTurn(PageTurnDirection.next, begin: 0, end: 1, commit: true);
  }

  void prev() {
    _beginAnimatedTurn(PageTurnDirection.prev, begin: 0, end: 1, commit: true);
  }

  void jumpTo(int page) {
    setState(() {
      _current = page.clamp(0, widget.pageCount - 1);
      _target = null;
      _dragProgress = 0;
      _dragStartX = null;
      _dragFingerX = null;
      _animationBegin = null;
      _animationEnd = null;
      _edgeDragDirection = null;
      _clearTransitionCache();
    });
    widget.onPageChanged?.call(_current);
  }

  void _completeAnimation() {
    final commit = _commitAnimation;
    final target = _target;
    setState(() {
      if (commit && target != null) {
        _current = target;
      }
      _target = null;
      _dragProgress = 0;
      _dragStartX = null;
      _animationBegin = null;
      _animationEnd = null;
      _edgeDragDirection = null;
      _commitAnimation = false;
      _clearTransitionCache();
    });
    if (commit && target != null) {
      widget.onPageChanged?.call(_current);
    }
  }

  void _updateDrag(double currentX, double width) {
    if (_isAnimating || width <= 0) return;
    final startX = _dragStartX;
    if (startX == null) return;
    final deltaX = currentX - startX;
    if (_target == null) {
      if (deltaX.abs() < 12) return;
      final direction = deltaX < 0
          ? PageTurnDirection.next
          : PageTurnDirection.prev;
      if (!_canTurn(direction)) {
        _edgeDragDirection = direction;
        return;
      }
      _dir = direction;
      _target = _targetPage(direction);
    }
    final rawProgress = switch (_dir) {
      PageTurnDirection.next => (-deltaX / width).clamp(0.0, 1.0),
      PageTurnDirection.prev => (deltaX / width).clamp(0.0, 1.0),
    };
    setState(() {
      final clamped = rawProgress.toDouble();
      _dragProgress = 1 - math.pow(1 - clamped, 1.18).toDouble();
      _dragFingerX = currentX.clamp(0.0, width).toDouble();
    });
  }

  bool _shouldCommit(double velocity) {
    final fastEnough = switch (_dir) {
      PageTurnDirection.next => velocity < -320,
      PageTurnDirection.prev => velocity > 320,
    };
    return fastEnough || _dragProgress > 0.33;
  }

  void _cancelInteractiveTurn({bool animate = true}) {
    if (_target == null) {
      setState(() {
        _dragStartX = null;
        _dragFingerX = null;
        _dragProgress = 0;
        _edgeDragDirection = null;
        _clearTransitionCache();
      });
      return;
    }
    if (!animate || _dragProgress <= 0.01) {
      setState(() {
        _target = null;
        _dragStartX = null;
        _dragFingerX = null;
        _dragProgress = 0;
        _edgeDragDirection = null;
        _clearTransitionCache();
      });
      return;
    }
    setState(() {
      _animationBegin = _dragProgress;
      _animationEnd = 0;
      _commitAnimation = false;
      _dragProgress = 0;
      _dragStartX = null;
      _dragFingerX = null;
      _edgeDragDirection = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pageCount <= 0) {
      return const SizedBox.shrink();
    }

    final currentPage = _currentPageFor(context);
    final nextPage = _targetPageFor(context);

    final child = _isAnimating && _target != null
        ? _TurnAnimation(
            current: currentPage,
            next: nextPage,
            direction: _dir,
            effect: widget.effect,
            beginProgress: _animationBegin!,
            endProgress: _animationEnd!,
            onCompleted: _completeAnimation,
          )
        : _target != null && _dragProgress > 0
        ? _TurnPresentation(
            current: currentPage,
            next: nextPage,
            direction: _dir,
            effect: widget.effect,
            progress: _dragProgress,
            interactive: true,
            fingerX: _dragFingerX,
          )
        : currentPage;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final width = MediaQuery.sizeOf(context).width;
        if (details.localPosition.dx < width / 3) {
          prev();
        } else if (details.localPosition.dx > width * 2 / 3) {
          next();
        } else {
          widget.onTapCenter?.call();
        }
      },
      onHorizontalDragStart: (details) {
        if (_isAnimating) return;
        _dragStartX = details.localPosition.dx;
        _dragFingerX = details.localPosition.dx;
        _dragProgress = 0;
        _edgeDragDirection = null;
      },
      onHorizontalDragUpdate: (details) {
        if (_dragStartX == null) return;
        _updateDrag(details.localPosition.dx, MediaQuery.sizeOf(context).width);
      },
      onHorizontalDragEnd: (details) {
        final startX = _dragStartX;
        if (startX == null) return;
        final velocity = details.primaryVelocity ?? 0;
        if (_target == null) {
          final direction = _edgeDragDirection;
          setState(() {
            _dragStartX = null;
            _dragFingerX = null;
            _dragProgress = 0;
            _edgeDragDirection = null;
          });
          if (direction != null && velocity.abs() > 120) {
            _notifyEdge(direction);
          }
          return;
        }
        if (_dragProgress <= 0.01) {
          _cancelInteractiveTurn(animate: false);
          return;
        }
        setState(() {
          _animationBegin = _dragProgress;
          _animationEnd = _shouldCommit(velocity) ? 1 : 0;
          _commitAnimation = _animationEnd == 1;
          _dragProgress = 0;
          _dragStartX = null;
          _dragFingerX = null;
          _edgeDragDirection = null;
        });
      },
      onHorizontalDragCancel: _cancelInteractiveTurn,
      child: child,
    );
  }
}
