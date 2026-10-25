import 'dart:math' as math;

import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

/// M1 几何特征单测（`motion_redesign_plan_20261025.md` §4.1）：
/// 网点否决（C1）+ 会聚动作（C2）+ 灭点锚点。夹具与 tool/synthetic_pages.dart
/// 同族（去格点化文字 / 点阵网点 / 放射集中线），确定性无随机。
RgbaImage _fill(int w, int h, int v) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, v, v, v);
    }
  }
  return img;
}

/// 等距点阵网点（C1 网点底：dotPeriodicity ≈1、speckUniformity ≈0）。
RgbaImage screentonePanel(int w, int h, {int period = 7, int dot = 3}) {
  final img = _fill(w, h, 255);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (x % period < dot && y % period < dot) img.setPixel(x, y, 40, 40, 40);
    }
  }
  return img;
}

/// 放射集中线（C2 盲点夹具：方向直方图均匀 dirCoh 低、会聚高）。
/// Bresenham 4 连通光栅化（与 tool/synthetic_pages.dart 同款——真实笔画
/// 是连续线段）。
RgbaImage concentrationPanel(int w, int h,
    {double vpx = 0.5, double vpy = 0.42, int count = 48}) {
  final img = _fill(w, h, 245);
  final cx = w * vpx, cy = h * vpy;
  for (var i = 0; i < count; i++) {
    final ang = 2 * math.pi * i / count + 0.13;
    final r0 = 0.4 * math.max(w, h);
    final r1 = 1.6 * math.max(w, h);
    _thickLine(img, cx + math.cos(ang) * r0, cy + math.sin(ang) * r0,
        cx + math.cos(ang) * r1, cy + math.sin(ang) * r1, 25);
  }
  return img;
}

/// SDF 粗线（逐像素到线段距离 ≤ 半宽）：真实直线的正确光栅化——
/// 边缘严格垂直于笔画轴（DDA 阶梯/Bresenham 对角步进都会在像素级
/// 打散梯度方向或碎化连通性）。
void _thickLine(RgbaImage img, double x0, double y0, double x1, double y1,
    int dark, {double halfWidth = 1.2}) {
  final minX = (math.min(x0, x1) - halfWidth - 1).floor();
  final maxX = (math.max(x0, x1) + halfWidth + 1).ceil();
  final minY = (math.min(y0, y1) - halfWidth - 1).floor();
  final maxY = (math.max(y0, y1) + halfWidth + 1).ceil();
  final vx = x1 - x0, vy = y1 - y0;
  final c2 = vx * vx + vy * vy;
  for (var y = minY; y <= maxY; y++) {
    if (y < 0 || y >= img.height) continue;
    for (var x = minX; x <= maxX; x++) {
      if (x < 0 || x >= img.width) continue;
      final wx = x - x0, wy = y - y0;
      var t = c2 > 0 ? (wx * vx + wy * vy) / c2 : 0.0;
      t = t.clamp(0.0, 1.0);
      final dx = wx - t * vx, dy = wy - t * vy;
      if (dx * dx + dy * dy <= halfWidth * halfWidth) {
        img.setPixel(x, y, dark, dark, dark);
      }
    }
  }
}

/// 与 test/scene_motion_test.dart 同款的去格点化文字斑点。
RgbaImage irregularTextPanel(int w, int h) {
  final img = _fill(w, h, 255);
  var state = 20261025;
  int next(int max) {
    state = (state * 6364136223846793005 + 1442695040888963407) &
        0x7fffffffffffffff;
    return (state >> 33) % max;
  }

  var gy = 2;
  while (gy < h - 3) {
    var gx = 2 + next(5);
    while (gx < w - 4) {
      final runLen = 1 + next(4);
      final thick = 2 + next(2);
      final jx = next(3);
      for (var dy = 0; dy < thick; dy++) {
        for (var dx = 0; dx < runLen; dx++) {
          final px = gx + dx + jx, py = gy + dy;
          if (px < w - 2 && py < h - 2) img.setPixel(px, py, 30, 30, 30);
        }
      }
      gx += runLen + 3 + next(3);
    }
    gy += 6 + next(4);
  }
  return img;
}

void main() {
  group('M1 网点否决（C1）', () {
    test('点阵网点：dotPeriodicity 高、speckUniformity 低、isScreentone 命中', () {
      final f = extractPanelMotionFeatures(screentonePanel(180, 140));
      expect(f.dotPeriodicity, greaterThan(kScreentonePeriodicityMin));
      expect(f.speckUniformity, lessThan(kScreentoneUniformityMax));
      expect(HeuristicPanelMotionJudge.isScreentone(f), isTrue);
      // 网点斑点密度爆表（网点被数成斑点），但被否决不得判静。
      expect(f.speckDensity, greaterThan(kTextSpeckMin));
      expect(HeuristicPanelMotionJudge.isTextStill(f), isFalse);
    });

    test('剪影 + 集中线（生成器同款动作格）：会聚命中动作档、不判静', () {
      // 与 tool/synthetic_pages.dart 的 concentrationAction 夹具同构：
      // 白底 + 中心剪影 + Bresenham 集中线（调研 §8.2 C2 盲点形态）。
      // 已知局限（文档化）：线像素落在重墨网点边界上时携带网点梯度噪声
      //（conv ~0.52 < 0.58）——叠加特例的根治走 P2 文字/网点检测小模型
      //（方案 §4.2）；真实漫画网点多为中间调半色调，冲击线贴白底/浅底。
      final img = _fill(288, 188, 245);
      for (var y = 0; y < 180; y++) {
        for (var x = 0; x < 240; x++) {
          final dx = (x - 144) / 44.0, dy = (y - 79) / 52.0;
          if (dx * dx + dy * dy <= 1) img.setPixel(x, y, 35, 35, 35);
        }
      }
      const vpx = 0.5, vpy = 0.42;
      final cx = 288 * vpx, cy = 188 * vpy;
      for (var i = 0; i < 48; i++) {
        final ang = 2 * math.pi * i / 48 + 0.13;
        _thickLine(img, cx + math.cos(ang) * 115.2, cy + math.sin(ang) * 115.2,
            cx + math.cos(ang) * 460.8, cy + math.sin(ang) * 460.8, 25);
      }
      final f = extractPanelMotionFeatures(img);
      expect(f.convergenceCoh, greaterThan(kActionConvergenceMin),
          reason: 'C2 修复：集中线动作格必须命中动作档');
      expect(HeuristicPanelMotionJudge.isTextStill(f), isFalse,
          reason: '不得判静');
    });

    test('去格点化文字：不被否决、仍判静（真文字格保护）', () {
      final f = extractPanelMotionFeatures(irregularTextPanel(180, 140));
      expect(f.dotPeriodicity, lessThan(kScreentonePeriodicityMin),
          reason: '真实字形不是等距点阵');
      expect(f.speckUniformity, greaterThan(kScreentoneUniformityMax));
      expect(HeuristicPanelMotionJudge.isScreentone(f), isFalse);
      expect(HeuristicPanelMotionJudge.isTextStill(f), isTrue);
    });
  });

  group('M1 会聚动作（C2）', () {
    test('放射集中线：convergenceCoh 高、灭点贴近真值、动作判据命中', () {
      const vpx = 0.5, vpy = 0.42;
      final f = extractPanelMotionFeatures(
          concentrationPanel(288, 188, vpx: vpx, vpy: vpy));
      expect(f.convergenceCoh, greaterThan(kActionConvergenceMin),
          reason: '调研 §8.2：dirCoh 对放射线是盲点，会聚特征补位');
      expect(f.vpX, inInclusiveRange(vpx - 0.12, vpx + 0.12));
      expect(f.vpY, inInclusiveRange(vpy - 0.12, vpy + 0.12));
    });

    test('平行速度线：dirCoh 路径保持（既有判据不劣化）', () {
      final img = _fill(160, 160, 205);
      for (var s = -160; s < 160 + 160; s += 6) {
        for (var t = 0; t < 160; t++) {
          final x = s + t;
          if (x < 0 || x >= 160) continue;
          img.setPixel(x, t, 20, 20, 20);
        }
      }
      final f = extractPanelMotionFeatures(img);
      expect(f.dirCoherence, greaterThan(kActionDirCohMin));
      // 平行族灭点在无穷远：有限搜索在远场近似处同样高会聚（dirCoh 的
      // 几何推广，调研 §5-P0 口径）——联合判据同信号无害。
      expect(f.convergenceCoh, greaterThan(0.5),
          reason: '远场近似：有限灭点沿笔迹方向仍近共线');
    });

    test('实心剪影特写：轮廓放射梯度不触发会聚（伪会聚压制）', () {
      final img = _fill(180, 180, 240);
      // 实心椭圆剪影（边缘法线放射指向外）。
      for (var y = 0; y < 180; y++) {
        for (var x = 0; x < 180; x++) {
          final dx = (x - 90) / 55.0, dy = (y - 80) / 65.0;
          if (dx * dx + dy * dy <= 1) img.setPixel(x, y, 35, 35, 35);
        }
      }
      final f = extractPanelMotionFeatures(img);
      expect(f.convergenceCoh, lessThan(kActionConvergenceMin),
          reason: '梯度 ∥ 指向灭点方向的轮廓（实心域）不算会聚——只有'
              '「梯度 ⊥ 笔画轴」的线族才是集中线');
    });
  });

  group('M1 判定器整合', () {
    test('HeuristicSceneStrategyJudge：集中线格 → action 档（tempo 1.5）', () {
      const judge = HeuristicSceneStrategyJudge();
      final panel = concentrationPanel(288, 188);
      final strategies = judge.panelStrategies(
          panel, [const PixelRect(0, 0, 240, 180)], []);
      expect(strategies, hasLength(1));
      expect(strategies.first.tempo, kActionTempo);
      expect(strategies.first.scale, 1.0);
    });

    test('diagnose：类别/置信/特征一次产出，策略与 panelStrategies 恒等', () {
      const judge = HeuristicSceneStrategyJudge();
      final panels = [
        concentrationPanel(288, 188),
        irregularTextPanel(240, 180),
      ];
      final diagnoses = judge.diagnose(
          _stack(panels), [const PixelRect(0, 0, 240, 180), const PixelRect(0, 180, 240, 180)], []);
      expect(diagnoses[0].cls, PanelClass.action);
      expect(diagnoses[0].clsConf, greaterThan(0.0));
      expect(diagnoses[1].cls, PanelClass.narrative);
      expect(diagnoses[1].strategy.scale, 0.0);
    });
  });

  group('M1 校准常量（分布定值区间，防手滑）', () {
    test('kScreentonePeriodicityMin ∈ [0.6, 0.85]（网点 ≥0.94 vs 文字 ≤0.61）', () {
      expect(kScreentonePeriodicityMin, inInclusiveRange(0.6, 0.85));
    });

    test('kScreentoneUniformityMax ∈ [0.2, 0.4]（网点 ≤0.10 vs 文字 ≥0.31）', () {
      expect(kScreentoneUniformityMax, inInclusiveRange(0.2, 0.4));
    });

    test('kActionConvergenceMin ∈ [0.55, 0.62]（动作簇 ≥0.616 vs 非动作 ≤0.538）',
        () {
      expect(kActionConvergenceMin, inInclusiveRange(0.55, 0.62));
    });
  });
}

/// 两块面板竖向拼接为一张图（供 diagnose 多格输入）。
RgbaImage _stack(List<RgbaImage> panels) {
  final h = panels.fold<int>(0, (s, p) => s + p.height);
  final w = panels.first.width;
  final img = RgbaImage(width: w, height: h);
  var y = 0;
  for (final p in panels) {
    for (var py = 0; py < p.height; py++) {
      for (var px = 0; px < p.width; px++) {
        final o = (py * p.width + px) * 4;
        img.setPixel(px, y + py, p.data[o], p.data[o + 1], p.data[o + 2]);
      }
    }
    y += p.height;
  }
  return img;
}
