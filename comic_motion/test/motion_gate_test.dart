import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

RgbaImage _img(int w, int h) => RgbaImage(width: w, height: h);

void main() {
  group('depthSpread', () {
    test('恒值场 spread=0', () {
      final d = DepthMap(4, 4);
      for (var i = 0; i < d.data.length; i++) {
        d.data[i] = 0.5;
      }
      expect(depthSpread(d), 0.0);
    });

    test('最近秩分位 p90-p10（与 LayerSplitter 阈值分位同口径）', () {
      final d = DepthMap(10, 1);
      for (var i = 0; i < 10; i++) {
        d.data[i] = i / 9; // 0, 1/9 ... 1
      }
      // sorted[(0.9*9).round()]=8/9；sorted[(0.1*9).round()]=1/9
      expect(depthSpread(d), closeTo(7 / 9, 1e-9));
    });
  });

  group('DepthSpreadGate', () {
    test('平坦（恒值）→ 不动画', () {
      final d = DepthMap(8, 8)..constantValued = true;
      expect(const DepthSpreadGate(minSpread: 0.08)
          .shouldAnimate(_img(8, 8), [d]), isFalse);
    });

    test('双峰 spread 达标 → 动画', () {
      final d = DepthMap(8, 8);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          d.data[y * 8 + x] = x < 4 ? 0.1 : 0.9;
        }
      }
      expect(const DepthSpreadGate(minSpread: 0.08)
          .shouldAnimate(_img(8, 8), [d]), isTrue);
    });

    test('多图 OR（panelAware 路径）：任一格达标即动画', () {
      final flat = DepthMap(4, 4);
      final rich = DepthMap(4, 4);
      for (var i = 0; i < 16; i++) {
        rich.data[i] = i.isEven ? 0.05 : 0.95;
      }
      const gate = DepthSpreadGate(minSpread: 0.08);
      expect(gate.shouldAnimate(_img(4, 4), [flat, rich]), isTrue);
      expect(gate.shouldAnimate(_img(4, 4), [flat, flat]), isFalse);
    });

    test('边界：spread 恰等于阈值 → 动画（>= 语义）', () {
      // 0.125/0.25 为二进制精确值：0.25-0.125 恰等于 0.125，无 FP 噪声
      // （0.18-0.1 在 IEEE754 下小于 0.08，不能作边界夹具）。
      final d = DepthMap(2, 1);
      d.data[0] = 0.125;
      d.data[1] = 0.25;
      expect(const DepthSpreadGate(minSpread: 0.125)
          .shouldAnimate(_img(2, 1), [d]), isTrue);
    });

    test('边界：spread 略低于阈值 → 不动画', () {
      final d = DepthMap(2, 1);
      d.data[0] = 0.125;
      d.data[1] = 0.249; // spread ≈ 0.124，余量远大于 FP 噪声
      expect(const DepthSpreadGate(minSpread: 0.125)
          .shouldAnimate(_img(2, 1), [d]), isFalse);
    });

    test('默认阈值是 A1 定值，落在合理区间（防手滑写成 0/1）', () {
      expect(kDefaultDepthSpreadMin, inInclusiveRange(0.02, 0.30));
    });
  });
}
