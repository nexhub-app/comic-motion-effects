part of '../frame_compositor.dart';

/// v1.3 自然氛围扩充 pass：火焰、烟雾、气泡、落叶、流星雨。
///
/// 与 v1.1/v1.2 的粒子动效同构——构造期从独立随机流（`0x54D1..0x54D5`）取样子
/// 子参数，逐帧只读这些常量并把 `u` 的整数周期函数喂给三角函数，所以
/// `u=0` 与 `u=1` 逐字节相等。所有落笔都走 `render/raster.dart` 的原语，
/// 档位差异只体现在「legacy 用 v1.2 的软盘/截断加法，standard+ 用 AA 覆盖度 +
/// screen」这一条规则上。

/// 火焰：底部一排火苗，每苗沿高度采 18 个节点堆叠柔盘。
///
/// 节点横向偏移 `sin(2π·(riseCycles·u + k·0.35 + φ))` 里的 `k·0.35` 让同苗各节点
/// 错相 → 苗身弯成 S 形而不是整根平移；尖端额外乘 `(0.55+1.45k)`，越细越摆。
void _renderFlame(FrameCompositor c, RgbaImage frame, double tSec) {
  final list = c._tongues;
  if (list.isEmpty) return;
  final p = c.config.flame;
  final u = c._loopU(tSec);
  final hot = FrameCompositor._hexRgb(p.hot);
  final cold = FrameCompositor._hexRgb(p.cold);
  final hr = (hot >> 16) & 0xff, hg = (hot >> 8) & 0xff, hb = hot & 0xff;
  final cr = (cold >> 16) & 0xff, cg = (cold >> 8) & 0xff, cb = cold & 0xff;
  final w2pi = 2 * math.pi;
  final rise = p.riseCycles.clamp(1, 8);
  final flick = p.flickerCycles.clamp(1, 16);
  final flameH = p.heightFrac.clamp(0.04, 0.8) * c.h;
  final opacity = p.opacity.clamp(0.0, 1.0) * c._env.particles;
  const nodes = 18;
  final aa = c._aa;
  final bright = aa ? BlendOp.screen : BlendOp.additive;
  for (final tg in list) {
    final h = flameH * tg.heightJit;
    final root = h * 0.14 * tg.widthJit; // 根部半宽
    final flick2 = 0.78 + 0.22 * math.sin(w2pi * flick * u + tg.phase);
    final aRoot = (opacity * flick2 * 255).round();
    if (aRoot <= 0) continue;
    final cx = tg.x0 * c.w;
    for (var j = 0; j < nodes; j++) {
      final k = j / (nodes - 1); // 0 根部 → 1 尖端
      final rad = root * (1.0 - 0.72 * k);
      if (rad < 0.7) continue;
      final sway = math.sin(w2pi * (rise * u + k * 0.35 + tg.phase)) *
          root *
          (0.55 + 1.45 * k);
      final x = cx + sway + tg.lean * h * k * k;
      final y = c.h - 1.0 - k * h;
      final a = (aRoot * (1.0 - 0.75 * k * k)).round();
      if (a <= 0) continue;
      final r = (hr + (cr - hr) * k).round();
      final g = (hg + (cg - hg) * k).round();
      final b = (hb + (cb - hb) * k).round();
      if (aa) {
        drawDiscAA(frame, x, y, rad, r, g, b, a, op: bright, exponent: 2.0);
      } else {
        c._drawSoftDisc(frame, x, y, rad, r, g, b, a);
      }
    }
  }
}

class _Tongue {
  const _Tongue({
    required this.x0,
    required this.phase,
    required this.widthJit,
    required this.heightJit,
    required this.lean,
  });

  final double x0; // 苗根横位置（归一化）
  final double phase; // 摆动/闪烁相位（弧度）
  final double widthJit, heightJit;
  final double lean; // 固定倾斜（-1 左 / +1 右）
}

/// 烟雾：雾团自下而上 + 三频扰动 + 半径随高度放大。
///
/// 生命进度 `k=(y0+riseCycles·u)%1` 同时驱动高度、半径和 `sin(πk)` 明暗包络，
/// 所以雾团在画幅外出生、在画幅外消散，两端 alpha 恰为 0 → 循环无接缝。
void _renderSmoke(FrameCompositor c, RgbaImage frame, double tSec) {
  final list = c._puffs;
  if (list.isEmpty) return;
  final p = c.config.smoke;
  final u = c._loopU(tSec);
  final rgb = FrameCompositor._hexRgb(p.color);
  final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
  final w2pi = 2 * math.pi;
  final rise = p.riseCycles.clamp(1, 4);
  final size = p.sizePx.clamp(4.0, 160.0);
  final turb = p.turbulence.clamp(0.0, 2.0) * size;
  final opacity = p.opacity.clamp(0.0, 1.0) * c._env.particles;
  final aa = c._aa;
  for (final b in list) {
    final k = (b.y0 + rise * u) % 1.0;
    final env = math.sin(math.pi * k);
    if (env <= 0.01) continue;
    // 三频叠加（k=1,2,4 的整数倍 riseCycles）：基频走形、高频起皱。
    final off = turb *
        (math.sin(w2pi * rise * u + b.ph1) +
            0.5 * math.sin(2 * w2pi * rise * u + b.ph2) +
            0.25 * math.sin(4 * w2pi * rise * u + b.ph4));
    final x = b.x0 * c.w + off;
    final y = c.h * (1.02 - 0.95 * k);
    final rad = size * b.sizeJit * (0.45 + 2.4 * k);
    final a = (opacity * env * b.alphaJit * (1.0 - 0.35 * k) * 255).round();
    if (a <= 0) continue;
    if (aa) {
      drawDiscAA(frame, x, y, rad, r0, g0, b0, a, exponent: 1.0);
    } else {
      c._drawSoftDisc(frame, x, y, rad, r0, g0, b0, a);
    }
  }
}

class _Puff {
  const _Puff({
    required this.x0,
    required this.y0,
    required this.sizeJit,
    required this.alphaJit,
    required this.ph1,
    required this.ph2,
    required this.ph4,
  });

  final double x0; // 出生横位置（归一化）
  final double y0; // 生命相位偏移（归一化）
  final double sizeJit, alphaJit;
  final double ph1, ph2, ph4; // 三个扰动频率各自的相位
}

/// 气泡：描边圆环 + 内部弱填充 + 左上高光小盘。
void _renderBubbles(FrameCompositor c, RgbaImage frame, double tSec) {
  final list = c._bubbles;
  if (list.isEmpty) return;
  final p = c.config.bubbles;
  final u = c._loopU(tSec);
  final rgb = FrameCompositor._hexRgb(p.color);
  final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
  final w2pi = 2 * math.pi;
  final rise = p.riseCycles.clamp(1, 6);
  final size = p.sizePx.clamp(2.0, 60.0);
  final opacity = p.opacity.clamp(0.0, 1.0) * c._env.particles;
  final wob = p.wobblePx.clamp(0.0, 80.0);
  final aa = c._aa;
  final bright = aa ? BlendOp.screen : BlendOp.additive;
  for (final b in list) {
    final k = (b.y0 + rise * u) % 1.0;
    final rad = size * b.sizeJit;
    // 出生/破裂都在画幅外，包络取 sin(πk) → 两端为 0
    final env = math.sin(math.pi * k) * b.alphaJit;
    if (env <= 0.01) continue;
    final x = b.x0 * c.w + wob * math.sin(w2pi * b.wobFreq * u + b.wobPhase);
    final y = c.h * (1.05 - 1.1 * k);
    final a = (opacity * env * 255).round();
    if (a <= 0) continue;
    drawRingAA(frame, x, y, rad, 1.6, r0, g0, b0, a, op: bright, aa: aa);
    if (aa) {
      drawDiscAA(frame, x, y, rad - 0.8, r0, g0, b0, (a * 0.12).round(),
          op: bright);
    }
    // 左上高光：1/3 半径处一枚小亮盘
    final hx = x - rad * 0.34, hy = y - rad * 0.34;
    if (aa) {
      drawDiscAA(frame, hx, hy, rad * 0.26, 255, 255, 255, (a * 0.8).round(),
          op: bright, exponent: 1.6);
    } else {
      c._drawSoftDisc(
          frame, hx, hy, rad * 0.26, 255, 255, 255, (a * 0.8).round());
    }
  }
}

class _Bubble {
  const _Bubble({
    required this.x0,
    required this.y0,
    required this.sizeJit,
    required this.alphaJit,
    required this.wobPhase,
    required this.wobFreq,
  });

  final double x0, y0;
  final double sizeJit, alphaJit;
  final double wobPhase;
  final int wobFreq; // 摆动频率（u 的整倍数 → 无缝）
}

/// 落叶：与樱花共用「下落 + 摇摆」骨架，把自转换成翻面。
///
/// 宽度 `∝ |cos(2π·flipTurns·u + φ)|`：侧立的瞬间收成 1px 亮刃，同时切到该档
/// 配色的深色，两片叶面因此看起来不同。
void _renderLeaves(FrameCompositor c, RgbaImage frame, double tSec) {
  final list = c._leaves;
  if (list.isEmpty) return;
  final p = c.config.leaves;
  final u = c._loopU(tSec);
  final pal = p.paletteRgb();
  final w2pi = 2 * math.pi;
  final fall = p.fallCycles.clamp(1, 12);
  final flips = p.flipTurns.clamp(0, 12);
  final size = p.sizePx.clamp(2.0, 40.0);
  final opacity = p.opacity.clamp(0.0, 1.0) * c._env.particles;
  final sway = p.swayPx.clamp(0.0, 120.0);
  final aa = c._aa;
  for (final L in list) {
    final py = ((L.y0 + fall * u) % 1.0) * c.h;
    final px =
        (L.x0 * c.w + sway * math.sin(w2pi * (L.swayFreq * u) + L.swayPhase)) %
            c.w;
    final f = math.cos(w2pi * flips * u + L.flipPhase);
    final af = f.abs();
    final edgeOn = af < 0.30;
    final rgb = edgeOn ? pal[2] : (L.toneIdx == 0 ? pal[0] : pal[1]);
    final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
    final hl = size * L.sizeJit;
    final rot = L.rot0 + 0.45 * math.sin(w2pi * u + L.swayPhase);
    final ca = math.cos(rot), sa = math.sin(rot);
    // 翻面时收成 1px（drawSegmentAA 内部对 <1 的厚度取 1），故侧刃仍可见
    final thick = hl * (0.30 + 0.75 * af);
    final a = (opacity * (edgeOn ? 0.9 : 0.72 + 0.28 * af) * 255).round();
    if (a <= 0) continue;
    drawSegmentAA(frame, px - ca * hl, py - sa * hl, px + ca * hl, py + sa * hl,
        r0, g0, b0, a, thick,
        aa: aa);
  }
}

class _Leaf {
  const _Leaf({
    required this.x0,
    required this.y0,
    required this.sizeJit,
    required this.rot0,
    required this.flipPhase,
    required this.swayPhase,
    required this.swayFreq,
    required this.toneIdx,
  });

  final double x0, y0;
  final double sizeJit, rot0, flipPhase, swayPhase;
  final int swayFreq, toneIdx;
}

/// 流星雨：窗口式设计（与闪电同族）——第 k 颗只在 `(streakCycles·u + k/n)%1`
/// 落在 `windowFrac` 内时可见，窗口内取 `sin(π·local)` 包络，两头归零不留接缝。
void _renderMeteors(FrameCompositor c, RgbaImage frame, double tSec) {
  final list = c._meteors;
  if (list.isEmpty) return;
  final p = c.config.meteors;
  final u = c._loopU(tSec);
  final n = list.length;
  final cycles = p.streakCycles.clamp(1, 8);
  final win = p.windowFrac.clamp(0.04, 0.6);
  final diag = math.sqrt(c.w * c.w + c.h * c.h);
  final path = diag * 1.15; // 窗口内总推进：足够从画外进、画外出
  final len0 = p.lengthFrac.clamp(0.04, 0.9) * math.min(c.w, c.h);
  final opacity = p.opacity.clamp(0.0, 1.0) * c._env.particles;
  final arad = p.angleDeg * math.pi / 180.0;
  final dirX = math.cos(arad), dirY = math.sin(arad);
  final aa = c._aa;
  final bright = aa ? BlendOp.screen : BlendOp.additive;
  for (var i = 0; i < n; i++) {
    final m = list[i];
    final ph = (cycles * u + i / n) % 1.0;
    if (ph >= win) continue;
    final local = ph / win; // 0→1
    final env = math.sin(math.pi * local);
    final a = (opacity * env * m.alphaJit * 255).round();
    if (a <= 0) continue;
    final travel = path * (local - 0.5); // 包络峰值正好在画面中央
    final hx = m.x0 * c.w + dirX * travel;
    final hy = m.y0 * c.h + dirY * travel;
    final len = len0 * m.lenJit;
    drawSegmentAA(frame, hx, hy, hx - dirX * len, hy - dirY * len, 255, 255,
        255, a, m.thick,
        op: bright, tailFade: 1.0, tailPow: 1.0, aa: aa);
    if (aa) {
      drawDiscAA(frame, hx, hy, m.thick * 1.5, 255, 255, 255, a,
          op: bright, exponent: 2.0);
    } else {
      c._drawSoftDisc(frame, hx, hy, m.thick * 1.5, 255, 255, 255, a);
    }
  }
}

class _Meteor {
  const _Meteor({
    required this.x0,
    required this.y0,
    required this.lenJit,
    required this.alphaJit,
    required this.thick,
  });

  final double x0, y0; // 窗口中点经过的位置（归一化）
  final double lenJit, alphaJit;
  final double thick; // 尾迹粗细
}
