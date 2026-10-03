import 'dart:math' as math;

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// Plan B §1/§6：衰减旋转（taper-rotation）网格形变。
///
/// 语义：绕 [PartShape.root] 旋转，角度随「沿 root→tip 轴的位置」线性增大 ——
/// 掌根不动、指尖最大。逆映射 + `sampleBilinear`，只碰 bbox 内的像素。
void main() {
  const W = 120, H = 120;

  /// 一个横放的「手」：根在左 (20,60)，尖在右 (100,60)。
  PartShape barShape() => PartShape(
        polygon: [
          PartPoint(20 / W, 40 / H),
          PartPoint(100 / W, 40 / H),
          PartPoint(100 / W, 80 / H),
          PartPoint(20 / W, 80 / H),
        ],
        rootX: 20 / W,
        rootY: 60 / H,
        tipX: 100 / W,
        tipY: 60 / H,
      );

  /// 白纸上两块黑标：near 在根侧，far 在指尖侧。
  RgbaImage markers() {
    final img = RgbaImage(width: W, height: H);
    for (var i = 0; i < W * H; i++) {
      final o = i * 4;
      img.data[o] = 250;
      img.data[o + 1] = 250;
      img.data[o + 2] = 250;
      img.data[o + 3] = 255;
    }
    void dot(int cx, int cy) {
      for (var y = cy - 3; y <= cy + 3; y++) {
        for (var x = cx - 3; x <= cx + 3; x++) {
          final o = (y * W + x) * 4;
          img.data[o] = 10;
          img.data[o + 1] = 10;
          img.data[o + 2] = 10;
        }
      }
    }

    dot(30, 60);
    dot(90, 60);
    return img;
  }

  /// 黑标质心（在给定窗口内找暗像素）。
  List<double> centroid(RgbaImage img, int x0, int x1, int y0, int y1) {
    var sx = 0.0, sy = 0.0, n = 0;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        if (img.luminance(y * W + x) < 128) {
          sx += x;
          sy += y;
          n++;
        }
      }
    }
    return [sx / n, sy / n];
  }

  double sad(RgbaImage a, RgbaImage b) {
    var s = 0;
    for (var i = 0; i < W * H; i++) {
      final o = i * 4;
      s += (a.data[o] - b.data[o]).abs() +
          (a.data[o + 1] - b.data[o + 1]).abs() +
          (a.data[o + 2] - b.data[o + 2]).abs();
    }
    return s / (W * H);
  }

  const warper = MeshWarper(featherPx: 2);

  group('角度语义', () {
    test('0° 时输出与输入逐字节相同', () {
      final src = markers();
      final dst = src.clone();
      warper.apply(dst, src, warper.buildPlan(src, barShape()), 0);
      expect(dst.data, src.data);
    });

    test('指尖位移远大于掌根（衰减旋转的定义）', () {
      final src = markers();
      final dst = src.clone();
      warper.apply(dst, src, warper.buildPlan(src, barShape()), 8);
      final near = centroid(dst, 15, 45, 45, 75);
      final far = centroid(dst, 75, 105, 30, 90);
      final nearMove = math.sqrt(math.pow(near[0] - 30, 2) + math.pow(near[1] - 60, 2));
      final farMove = math.sqrt(math.pow(far[0] - 90, 2) + math.pow(far[1] - 60, 2));
      expect(nearMove, lessThan(1.0)); // 根侧不动
      expect(farMove, greaterThan(3.0)); // 尖侧被带走
      expect(farMove, greaterThan(nearMove * 4));
    });

    test('正负角度镜像对称', () {
      final src = markers();
      final a = src.clone(), b = src.clone();
      final plan = warper.buildPlan(src, barShape());
      warper.apply(a, src, plan, 8);
      warper.apply(b, src, plan, -8);
      final ca = centroid(a, 75, 105, 30, 90), cb = centroid(b, 75, 105, 30, 90);
      expect(ca[1] - 60, closeTo(-(cb[1] - 60), 0.35));
      expect(ca[0], closeTo(cb[0], 0.35));
    });
  });

  group('contained 边界', () {
    test('多边形外的像素一个字节都不动', () {
      final src = markers();
      final dst = src.clone();
      warper.apply(dst, src, warper.buildPlan(src, barShape()), 12);
      for (var y = 0; y < H; y++) {
        for (var x = 0; x < W; x++) {
          // 只断言「离多边形 ≥3px 的外侧」；羽化带（外侧 2px）允许被改。
          if (x >= 17 && x <= 103 && y >= 37 && y <= 83) continue;
          final o = (y * W + x) * 4;
          expect(dst.data[o], src.data[o], reason: '($x,$y) 不应被改');
        }
      }
    });

    test('羽化带：mask 覆盖率在边界上介于 0 与 255 之间，内部为 255', () {
      final plan = warper.buildPlan(markers(), barShape());
      expect(plan.alphaAt(60, 60), 255); // 深处
      expect(plan.alphaAt(60, 41), inInclusiveRange(1, 254)); // 上边界 y=40 内侧 1px
      expect(plan.alphaAt(60, 10), 0); // 远处
    });

    test('不产生透明洞：alpha 通道全程不变', () {
      final src = markers();
      final dst = src.clone();
      warper.apply(dst, src, warper.buildPlan(src, barShape()), 14);
      for (var i = 0; i < W * H; i++) {
        expect(dst.data[i * 4 + 3], src.data[i * 4 + 3]);
      }
    });
  });

  group('plan 几何', () {
    test('bbox 只覆盖 mask 邻域，不是整幅画布', () {
      final plan = warper.buildPlan(markers(), barShape());
      expect(plan.width, inInclusiveRange(80, 100));
      expect(plan.height, inInclusiveRange(40, 60));
      expect(plan.width * plan.height, lessThan(W * H));
    });

    test('taper 在根平面为 0、尖平面为 1', () {
      final plan = warper.buildPlan(markers(), barShape());
      expect(plan.taperAt(22, 60), closeTo(0.0, 0.06));
      expect(plan.taperAt(98, 60), closeTo(1.0, 0.06));
      expect(plan.taperAt(60, 60), closeTo(0.5, 0.06));
    });
  });

  group('确定性', () {
    test('同输入两次形变逐字节相同', () {
      final src = markers();
      final a = src.clone(), b = src.clone();
      warper.apply(a, src, warper.buildPlan(src, barShape()), 7.5);
      warper.apply(b, src, warper.buildPlan(src, barShape()), 7.5);
      expect(a.data, b.data);
      final p1 = warper.buildPlan(src, barShape()), p2 = warper.buildPlan(src, barShape());
      expect(p1.alpha, p2.alpha);
      expect(p1.taper.map((v) => v.toStringAsFixed(9)).toList(),
          p2.taper.map((v) => v.toStringAsFixed(9)).toList());
    });

    test('非零角度确实改变了像素（测试非空转）', () {
      final src = markers();
      final dst = src.clone();
      warper.apply(dst, src, warper.buildPlan(src, barShape()), 8);
      expect(sad(src, dst), greaterThan(0.5));
    });
  });

  group('退化输入', () {
    test('形状贴边：越界采样钳到边缘，不崩', () {
      final src = markers();
      final dst = src.clone();
      final edge = PartShape(
        polygon: [
          PartPoint(0, 0),
          PartPoint(1, 0),
          PartPoint(1, 1),
          PartPoint(0, 1),
        ],
        rootX: 0.0,
        rootY: 0.5,
        tipX: 1.0,
        tipY: 0.5,
      );
      warper.apply(dst, src, warper.buildPlan(src, edge), 20);
      expect(sad(src, dst), greaterThan(0.5));
      for (var i = 0; i < W * H; i++) {
        expect(dst.data[i * 4], inInclusiveRange(0, 255));
      }
    });

    test('零面积多边形：plan 为空，apply 无操作', () {
      final src = markers();
      final dst = src.clone();
      final flat = PartShape(
          polygon: [
            PartPoint(0.2, 0.2),
            PartPoint(0.4, 0.4),
            PartPoint(0.6, 0.6),
          ],
          rootX: 0.2,
          rootY: 0.2,
          tipX: 0.6,
          tipY: 0.6);
      final plan = warper.buildPlan(src, flat);
      expect(plan.width, 0);
      warper.apply(dst, src, plan, 10);
      expect(dst.data, src.data);
    });
  });
}
