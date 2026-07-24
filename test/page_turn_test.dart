import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velora/widgets/page_turn.dart';

void main() {
  Widget buildHarness({
    required GlobalKey<PageTurnViewState> key,
    PageTurnEffectType effect = PageTurnEffectType.curl,
    VoidCallback? onReachStart,
    VoidCallback? onReachEnd,
    IndexedWidgetBuilder? pageBuilder,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(
          child: PageTurnView(
            key: key,
            pageCount: 3,
            effect: effect,
            onReachStart: onReachStart,
            onReachEnd: onReachEnd,
            pageBuilder:
                pageBuilder ??
                (context, index) => ColoredBox(
                  color: Colors.white,
                  child: Center(child: Text('Page ${index + 1}')),
                ),
          ),
        ),
      ),
    );
  }

  testWidgets('点击左右区域可以翻前后页', (tester) async {
    final key = GlobalKey<PageTurnViewState>();
    await tester.pumpWidget(
      buildHarness(key: key, effect: PageTurnEffectType.cover),
    );

    final view = find.byType(PageTurnView);
    final rect = tester.getRect(view);

    expect(key.currentState?.debugCurrentPage, 0);

    await tester.tapAt(Offset(rect.right - 12, rect.center.dy));
    await tester.pumpAndSettle();
    expect(key.currentState?.debugCurrentPage, 1);

    await tester.tapAt(Offset(rect.left + 12, rect.center.dy));
    await tester.pumpAndSettle();
    expect(key.currentState?.debugCurrentPage, 0);
  });

  testWidgets('curl 拖拽时显示跟手预览，短拖会回弹', (tester) async {
    final key = GlobalKey<PageTurnViewState>();
    await tester.pumpWidget(buildHarness(key: key));

    key.currentState!.debugPreview(PageTurnDirection.next, 0.22);
    await tester.pump();

    expect(key.currentState?.debugHasInteractivePreview, isTrue);
    expect(key.currentState?.debugDragProgress, greaterThan(0));

    key.currentState!.debugResolvePreview(commit: false);
    await tester.pump();

    expect(key.currentState?.debugCurrentPage, 0);
    expect(key.currentState?.debugHasInteractivePreview, isFalse);
  });

  testWidgets('curl 长拖后完成翻页', (tester) async {
    final key = GlobalKey<PageTurnViewState>();
    await tester.pumpWidget(buildHarness(key: key));

    key.currentState!.debugPreview(PageTurnDirection.next, 0.56);
    await tester.pump();
    key.currentState!.debugResolvePreview(commit: true);
    await tester.pump();

    expect(key.currentState?.debugCurrentPage, 1);
  });

  testWidgets('真实拖拽后会完成翻页', (tester) async {
    final key = GlobalKey<PageTurnViewState>();
    await tester.pumpWidget(buildHarness(key: key));

    await tester.drag(find.byType(PageTurnView), const Offset(-320, 0));
    await tester.pumpAndSettle();

    expect(key.currentState?.debugCurrentPage, 1);
  });

  testWidgets('在第一页继续向前拖动会触发边界回调', (tester) async {
    var reachStart = 0;
    final key = GlobalKey<PageTurnViewState>();
    await tester.pumpWidget(
      buildHarness(key: key, onReachStart: () => reachStart += 1),
    );

    await tester.fling(find.byType(PageTurnView), const Offset(220, 0), 1400);
    await tester.pumpAndSettle();

    expect(reachStart, 1);
    expect(key.currentState?.debugCurrentPage, 0);
  });

  testWidgets('翻页预览期间会复用已构建页内容，避免每帧重建', (tester) async {
    final key = GlobalKey<PageTurnViewState>();
    var buildCount = 0;
    await tester.pumpWidget(
      buildHarness(
        key: key,
        pageBuilder: (context, index) {
          buildCount += 1;
          return ColoredBox(
            color: Colors.white,
            child: Center(child: Text('Cached ${index + 1}')),
          );
        },
      ),
    );

    expect(buildCount, 1);

    key.currentState!.debugPreview(PageTurnDirection.next, 0.18);
    await tester.pump();
    final firstPreviewBuildCount = buildCount;

    key.currentState!.debugPreview(PageTurnDirection.next, 0.34);
    await tester.pump();
    key.currentState!.debugPreview(PageTurnDirection.next, 0.61);
    await tester.pump();

    expect(firstPreviewBuildCount, 2);
    expect(buildCount, firstPreviewBuildCount);

    key.currentState!.debugResolvePreview(commit: true);
    await tester.pump();

    expect(key.currentState!.debugCurrentPage, 1);
    expect(find.text('Cached 2'), findsOneWidget);
    expect(buildCount, firstPreviewBuildCount);
  });
}
