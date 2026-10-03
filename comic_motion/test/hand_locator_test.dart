import 'dart:math' as math;

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// Plan B §2.1：启发式手部定位器。
///
/// 语料实测（`build/hand_probe.dart`）证明黑白漫画页 skinness 覆盖 0.00%，
/// 所以定位必须**几何优先**：墨线围出的封闭亮区 → 径向轮廓 → 指状突出计数。
/// 测试用合成星形轮廓（能精确控制突出数与尺寸），真实语料标定放在验收阶段。
void main() {
  /// 画一条闭合径向轮廓 `R(θ) = base + Σ spikeLen·exp(-(Δθ/σ)²)`，墨线粗约 2px。
  /// 轮廓内是唯一的封闭非墨区，即定位器要识别的「部件」。
  RgbaImage outlinedPart({
    int size = 200,
    double cx = 100,
    double cy = 100,
    double base = 30,
    List<double> spikes = const [],
    double spikeLen = 25,
    double sigmaDeg = 9,
    int ink = 40,
    int paper = 245,
  }) {
    final img = RgbaImage(width: size, height: size);
    for (var i = 0; i < size * size; i++) {
      final o = i * 4;
      img.data[o] = paper;
      img.data[o + 1] = paper;
      img.data[o + 2] = paper;
      img.data[o + 3] = 255;
    }
    final sigma = sigmaDeg * math.pi / 180;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final dx = x + 0.5 - cx, dy = y + 0.5 - cy;
        final r = math.sqrt(dx * dx + dy * dy);
        final th = math.atan2(dy, dx);
        var rr = base;
        for (final s in spikes) {
          final deg = s * math.pi / 180;
          var d = th - deg;
          d = (d + math.pi) % (2 * math.pi) - math.pi;
          rr += spikeLen * math.exp(-(d * d) / (sigma * sigma));
        }
        if ((r - rr).abs() <= 1.8) {
          final o = (y * size + x) * 4;
          img.data[o] = ink;
          img.data[o + 1] = ink;
          img.data[o + 2] = ink;
        }
      }
    }
    return img;
  }

  /// 4 根手指聚在一侧（-60°..30°，屏幕坐标 y 向下），掌根在对面 —— 真实挥手的拓扑。
  const hand4 = [-60.0, -30.0, 0.0, 30.0];

  const locator = HeuristicHandLocator();

  group('指状突出判别', () {
    test('4 指手形：命中一个候选', () {
      final got = locator.locate(outlinedPart(spikes: hand4));
      expect(got, hasLength(1));
      expect(got.single.score, greaterThanOrEqualTo(HeuristicHandLocator.confidenceFloor));
    });

    test('3 指（含并指）仍命中', () {
      expect(locator.locate(outlinedPart(spikes: [-20.0, 20.0, 60.0])), hasLength(1));
    });

    test('圆（脸的代理形状）不命中：没有突出', () {
      expect(locator.locate(outlinedPart()), isEmpty);
    });

    test('2 指不命中：少于 3 根', () {
      expect(locator.locate(outlinedPart(spikes: [0.0, 40.0])), isEmpty);
    });

    test('6 指不命中：多于 5 根（不是手，是集中线/毛发）', () {
      expect(
          locator
              .locate(outlinedPart(spikes: [-45.0, -25.0, -5.0, 15.0, 35.0, 55.0])),
          isEmpty);
    });

    test('短粗突出不命中：指长不足掌径一半（袖子/拳头）', () {
      expect(
          locator.locate(outlinedPart(spikes: hand4, spikeLen: 6)), isEmpty);
    });
  });

  group('旋转根点', () {
    test('根点落在指尖对侧、指尖落在最远突出上', () {
      final got = locator.locate(outlinedPart(spikes: hand4));
      final c = got.single;
      // 指尖簇在 -30°..60° 一侧 ⇒ 根点应在圆心的左下方。
      expect(c.rootX, lessThan(0.5));
      expect(c.rootY, greaterThan(0.5));
      // tip 是最远突出端：位于右上方。
      expect(c.tipX, greaterThan(0.6));
      expect(c.tipY, lessThan(0.5));
      // 根到尖的距离≈轮廓长轴（base 30 + spikeLen 25 = 55px / 200 ≈ 0.275）
      final axis = math.sqrt(
          math.pow(c.tipX - c.rootX, 2) + math.pow(c.tipY - c.rootY, 2));
      expect(axis, inInclusiveRange(0.25, 0.55));
    });

    test('归一化坐标落在 0..1', () {
      final c = locator.locate(outlinedPart(spikes: hand4)).single;
      for (final p in [...c.outline, PartPoint(c.rootX, c.rootY), PartPoint(c.tipX, c.tipY)]) {
        expect(p.x, inInclusiveRange(0, 1));
        expect(p.y, inInclusiveRange(0, 1));
      }
    });
  });

  test('整幅画布只有一个封闭区：多部件页要逐格喂', () {
    final two = outlinedPart(spikes: hand4);
    // 同图两处手形会互相连通到同一背景，第二处需要单独裁片才能识别。
    expect(locator.locate(two), hasLength(1));
  });

  group('尺寸闸与退化', () {
    test('小于最小边长：拒绝（这个尺寸看不出手指）', () {
      expect(
          locator.locate(outlinedPart(size: 200, base: 6, spikes: hand4, spikeLen: 5)),
          isEmpty);
    });

    test('最小边长闸本身有效（同一张图，抬高门槛就拒绝）', () {
      final img = outlinedPart(spikes: hand4);
      expect(const HeuristicHandLocator(minSidePx: 40).locate(img), hasLength(1));
      expect(const HeuristicHandLocator(minSidePx: 90).locate(img), isEmpty);
    });

    test('占画面过大：拒绝（多半是整页背景框，不是手）', () {
      final img = outlinedPart(spikes: hand4);
      expect(const HeuristicHandLocator(maxAreaFrac: 0.35).locate(img), hasLength(1));
      expect(const HeuristicHandLocator(maxAreaFrac: 0.02).locate(img), isEmpty);
    });

    test('纯色图：无候选、不崩', () {
      final flat = RgbaImage(width: 64, height: 64);
      for (var i = 0; i < 64 * 64; i++) {
        final o = i * 4;
        flat.data[o] = 250;
        flat.data[o + 1] = 250;
        flat.data[o + 2] = 250;
        flat.data[o + 3] = 255;
      }
      expect(locator.locate(flat), isEmpty);
    });

    test('1x1 图：不崩', () {
      expect(locator.locate(RgbaImage(width: 1, height: 1)), isEmpty);
    });
  });

  group('确定性', () {
    test('同图两次调用逐字段相同', () {
      final img = outlinedPart(spikes: hand4);
      final a = locator.locate(img);
      final b = locator.locate(img);
      expect(b.length, a.length);
      expect(b.single.score, a.single.score);
      expect(b.single.rootX, a.single.rootX);
      expect(b.single.rootY, a.single.rootY);
      expect(b.single.outline.map((p) => p.x).toList(),
          a.single.outline.map((p) => p.x).toList());
    });

    test('整体平移后：归一化坐标按平移量同步移动', () {
      final at = (double cx, double cy) =>
          locator.locate(outlinedPart(cx: cx, cy: cy, spikes: hand4)).single;
      final a = at(100, 100);
      final b = at(120, 80);
      expect(b.rootX - a.rootX, closeTo(20 / 200, 1e-6));
      expect(b.rootY - a.rootY, closeTo(-20 / 200, 1e-6));
      expect(b.score, closeTo(a.score, 1e-6));
    });
  });
}
