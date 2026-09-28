// PageCurlView widget 测试：拖拽进度跟手、松手提交/回弹收敛、回调触发、
// 页边界保护、减弱动态回退、子树缓存不重调 builder。
//
// 测试策略：页内容用纯色 Container（无资源依赖）；截屏在 flutter_test 的
// software renderer 下可用（RepaintBoundary.toImage 真实产出 ui.Image），
// 因此卷曲路径可以完整走通。动画用 pumpAndSettle 收敛（ticker 驱动）。
import 'package:comic_motion_flutter/comic_motion_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _page(Color color) => ColoredBox(color: color);

Widget _host(
  Widget child, {
  bool disableAnimations = false,
}) =>
    MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(width: 200, height: 300, child: child),
      ),
    );

/// 记录型宿主：监听 builder 调用次数与当前页。
class _Recorder {
  int frontBuilds = 0;
  final List<int> frontPages = [];
  final List<String> starts = [];
  final List<String> ends = [];
}

void main() {
  late _Recorder rec;

  PageCurlView view() => PageCurlView(
        pageCount: 4,
        // idle 呼吸 ticker 会让 pumpAndSettle 永不收敛，测试统一关掉；
        // 呼吸本身是纯画布变换，行为不在本套件断言。
        idleBreath: false,
        onPageTurnStart: (from, to) => rec.starts.add('$from->$to'),
        onPageTurnEnd: (from, to, committed) =>
            rec.ends.add('$from->$to:${committed ? 'ok' : 'no'}'),
        frontBuilder: (context, i) {
          rec.frontBuilds++;
          rec.frontPages.add(i);
          return _page(i.isEven
              ? const Color(0xFF202020)
              : const Color(0xFFE0E0E0));
        },
        backBuilder: (context, i) => _page(const Color(0xFF336699)),
      );

  double progress(WidgetTester tester) =>
      PageCurlView.progressOf(tester.element(find.byType(PageCurlView)));

  setUp(() => rec = _Recorder());

  group('回调触发', () {
    testWidgets('点击右半屏 → 下一页：Start/End 按序触发且 committed', (tester) async {
      await tester.pumpWidget(_host(view()));
      await tester.pumpAndSettle(); // idle 首抓
      expect(rec.starts, isEmpty);

      await tester.tapAt(const Offset(150, 150)); // 右半屏
      await tester.pump();
      expect(rec.starts, ['0->1'], reason: '翻页开始即触发 Start');
      expect(rec.ends, isEmpty);

      await tester.pumpAndSettle();
      expect(rec.ends, ['0->1:ok'], reason: '补间完成后 End(committed)');
      expect(rec.frontPages.last, 1, reason: '提交后 front builder 收到新页');
    });

    testWidgets('点击左半屏在第 0 页无动作（页边界保护）', (tester) async {
      await tester.pumpWidget(_host(view()));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(50, 150)); // 左半屏
      await tester.pump();
      await tester.pumpAndSettle();
      expect(rec.starts, isEmpty, reason: '越界方向不触发翻页');
      expect(rec.frontPages.last, 0);
    });
  });

  group('拖拽', () {
    testWidgets('短拖 < 阈值 → 回弹：End(committed=false)，页码不变', (tester) async {
      await tester.pumpWidget(_host(view()));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(const Offset(150, 150));
      await gesture.moveBy(const Offset(-40, 0)); // 40/200 = 0.2 < 0.32
      await tester.pump();
      expect(rec.starts, ['0->1'], reason: '拖拽起步即触发 Start');
      await gesture.up();
      await tester.pumpAndSettle();

      expect(rec.ends, ['0->1:no'], reason: '未过阈值回弹');
      expect(rec.frontPages.last, 0, reason: '回弹后页码不变');
    });

    testWidgets('长拖 > 阈值 → 提交翻页，进度收敛到新页', (tester) async {
      await tester.pumpWidget(_host(view()));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(const Offset(180, 150));
      await gesture.moveBy(const Offset(-100, 0)); // 0.5 > 0.32
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(rec.ends, ['0->1:ok']);
      expect(rec.frontPages.last, 1);
    });

    testWidgets('拖拽进度跟手：位移比例映射到卷页进度', (tester) async {
      await tester.pumpWidget(_host(view()));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(const Offset(180, 150));
      // 首 ~18px 是水平拖拽 slop，不计入进度。
      await gesture.moveBy(const Offset(-80, 0)); // (80-18)/200 ≈ 0.31
      await tester.pump();
      await tester.pump(); // 截屏完成帧
      await gesture.moveBy(const Offset(-40, 0)); // (120-18)/200 ≈ 0.51
      await tester.pump();

      expect(progress(tester), closeTo(0.51, 0.06));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(progress(tester), 0.0, reason: '补间结束进度归零');
    });
  });

  group('减弱动态', () {
    testWidgets('disableAnimations：点击翻页走平移淡入淡出，仍正常换页', (tester) async {
      await tester.pumpWidget(_host(view(), disableAnimations: true));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(150, 150));
      await tester.pump();
      expect(rec.starts, ['0->1']);
      await tester.pumpAndSettle();
      expect(rec.ends, ['0->1:ok']);
      expect(rec.frontPages.last, 1);
    });
  });

  group('子树缓存', () {
    testWidgets('拖拽帧不重调 front builder（零重建路径）', (tester) async {
      await tester.pumpWidget(_host(view()));
      await tester.pumpAndSettle();
      final buildsAfterIdle = rec.frontBuilds;

      final gesture = await tester.startGesture(const Offset(180, 150));
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(-10, 0));
        await tester.pump();
      }
      expect(rec.frontBuilds, buildsAfterIdle,
          reason: '拖拽帧只做局部重绘，builder 子树按页缓存');
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('资源', () {
    testWidgets('销毁不抛异常', (tester) async {
      await tester.pumpWidget(_host(view()));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      // dispose 释放快照与 ticker；engine 断言交给 leak 追踪，此处冒烟。
    });
  });
}
