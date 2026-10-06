part of '../frame_compositor.dart';

/// v1.5 动作动效 pass（X6）：刀光斜闪、火花四溅、冲击尘雾、风线。
///
/// 与 comic_pass / particle_raster_pass 同构：每个 pass 是 (状态, 帧, u) 的
/// 纯函数——无跨帧可变量、无时钟，并行与串行逐字节一致。窗口式设计
/// （meteors/闪电同族）：第 k 道只在 `(cycles·u + k/n)%1` 落于 windowFrac
/// 内时可见，窗口内 `sin(π·local)` 包络两端归零 ⇒ 循环无接缝。
///
/// 四个效果都只在 standard+ 档渲染（入口 `c._aa` 直接 return）——legacy 的
/// 逐字节冻结承诺不覆盖 v1.5 新通道，与 handMotion（Plan B）同一裁决习语。

/// sparkBurst 生效焦点：contentAware 开且调用方未显式 pin 时收敛到权重最高
/// 锚点（与 focusLines/impactRings 的 Task 2.1 语义同源），否则用参数焦点。
({double fx, double fy}) _sparkBurstFocal(FrameCompositor c) {
  final p = c.config.sparkBurst;
  return c._contentAwareFocal(
    paramFx: p.focalX,
    paramFy: p.focalY,
    defaultFx: const SparkBurstParams().focalX,
    defaultFy: const SparkBurstParams().focalY,
  );
}

/// impactDust 生效焦点（同上）。
({double fx, double fy}) _impactDustFocal(FrameCompositor c) {
  final p = c.config.impactDust;
  return c._contentAwareFocal(
    paramFx: p.focalX,
    paramFy: p.focalY,
    defaultFx: const ImpactDustParams().focalX,
    defaultFy: const ImpactDustParams().focalY,
  );
}

/// 刀光斜闪：斜向高斯亮带短窗口扫过全屏，出手猛、收束快（战斗系一闪）。
/// 逐像素走 `_blendAddPx`（standard+ 即 screen，白提亮不撞死在 255），
/// 代价与扫光同阶（每可见道 O(w×h)，其余帧零成本）。
void _renderSlashFlash(FrameCompositor c, RgbaImage frame, double tSec) {
  if (!c._aa) return;
  final beams = c._slashBeams;
  if (beams.isEmpty) return;
  final p = c.config.slashFlash;
  final u = c._loopU(tSec);
  final n = beams.length;
  final cycles = p.flashes.clamp(1, 8);
  final win = p.windowFrac.clamp(0.04, 0.6);
  final rgb = FrameCompositor._hexRgb(p.color);
  final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
  final arad = p.angleDeg * math.pi / 180.0;
  final nx = math.cos(arad), ny = math.sin(arad);
  final baseSigma = p.widthPx.clamp(2.0, 160.0);
  final inten = p.intensity.clamp(0.0, 1.0);
  // 画布四角在法线上的投影范围；亮带中心从范围外 -3σ 扫到 +3σ，配合包络
  // 两端归零，带完整地在画外进、画外出。
  final projMin = math.min(0.0, c.w * nx) + math.min(0.0, c.h * ny);
  final projMax = math.max(0.0, c.w * nx) + math.max(0.0, c.h * ny);
  for (var k = 0; k < n; k++) {
    final ph = (cycles * u + k / n) % 1.0;
    if (ph >= win) continue;
    final local = ph / win;
    final env = math.sin(math.pi * local);
    final beam = beams[k];
    final sigma = baseSigma * beam.widthJit;
    final add0 = (inten * env * beam.intenJit * 255).round();
    if (add0 <= 0) continue;
    final center = projMin - 3 * sigma +
        (projMax - projMin + 6 * sigma) * local * beam.extJit;
    final twoSig2 = 2 * sigma * sigma;
    final cull = sigma * 3;
    for (var y = 0; y < c.h; y++) {
      final rowN = y * ny;
      var o = y * c.w * 4;
      for (var x = 0; x < c.w; x++, o += 4) {
        final d = x * nx + rowN - center;
        if (d > cull || d < -cull) continue;
        final add = (add0 * math.exp(-d * d / twoSig2)).round();
        if (add <= 0) continue;
        c._blendAddPx(frame, x, y, r0, g0, b0, add);
      }
    }
  }
}

/// 火花四溅：自焦点放射的短促火花（撞击点读感）。焦点吃 contentAware 锚点
/// ——「效果送到主体所在处」对动作效果的直接落地。火花减速推进
/// （easeOutCubic），alpha 按 env² 快速衰减：出手亮、收尾干脆。
void _renderSparkBurst(FrameCompositor c, RgbaImage frame, double tSec) {
  if (!c._aa) return;
  final sparks = c._sparks;
  if (sparks.isEmpty) return;
  final p = c.config.sparkBurst;
  final u = c._loopU(tSec);
  final n = p.bursts.clamp(1, 8);
  final win = p.windowFrac.clamp(0.05, 0.6);
  final focal = _sparkBurstFocal(c);
  final cx = focal.fx * c.w, cy = focal.fy * c.h;
  final travel = p.speedFrac.clamp(0.05, 1.0) * math.min(c.w, c.h);
  final size = p.sizePx.clamp(0.5, 8.0);
  final opacity = p.opacity.clamp(0.0, 1.0) * c._env.particles;
  final rgb = FrameCompositor._hexRgb(p.color);
  final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
  final bright = BlendOp.screen;
  for (var k = 0; k < n; k++) {
    final ph = (u * n + k / n) % 1.0;
    if (ph >= win) continue;
    final local = ph / win;
    final env = math.sin(math.pi * local);
    if (env <= 0.01) continue;
    final e = 1.0 - math.pow(1.0 - local, 3).toDouble();
    final aBase = (opacity * env * env * 255).round();
    if (aBase <= 0) continue;
    for (final sp in sparks) {
      final dist = travel * e * sp.speedJit;
      final dirX = math.cos(sp.angle), dirY = math.sin(sp.angle);
      final x = cx + dirX * dist, y = cy + dirY * dist;
      final tail = size * 4 * sp.lenJit * (1 - e * 0.6);
      final a = (aBase * (0.7 + 0.3 * sp.speedJit)).round().clamp(0, 255);
      drawSegmentAA(frame, x, y, x - dirX * tail, y - dirY * tail, r0, g0, b0,
          a, 1.4, op: bright, aa: true);
      drawDiscAA(frame, x, y, size, r0, g0, b0, a, op: bright, exponent: 2.0);
    }
  }
}

/// 冲击尘雾：自焦点外扩的一圈柔和尘团（落地/撞击的重量感）。
/// 与 impactRings 的视觉分工：软粒子盘 vs 解析距离场硬边环。
void _renderImpactDust(FrameCompositor c, RgbaImage frame, double tSec) {
  if (!c._aa) return;
  final puffs = c._dustPuffs;
  if (puffs.isEmpty) return;
  final p = c.config.impactDust;
  final u = c._loopU(tSec);
  final n = p.pulses.clamp(1, 6);
  final focal = _impactDustFocal(c);
  final cx = focal.fx * c.w, cy = focal.fy * c.h;
  final diag = math.sqrt(c.w * c.w + c.h * c.h) / 2.0;
  final rIn = diag * p.innerFrac.clamp(0.0, 0.5);
  final rOut = diag * p.outerFrac.clamp(0.05, 1.2);
  if (rOut <= rIn) return;
  final size = p.sizePx.clamp(2.0, 80.0);
  final opacity = p.opacity.clamp(0.0, 1.0) * c._env.particles;
  final rgb = FrameCompositor._hexRgb(p.color);
  final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
  for (var k = 0; k < n; k++) {
    final ph = (u * n + k / n) % 1.0;
    final env = math.sin(math.pi * ph);
    if (env <= 0.01) continue;
    final e = 1.0 - math.pow(1.0 - ph, 3).toDouble();
    final rad = rIn + (rOut - rIn) * e;
    final aBase = (opacity * env * 255).round();
    if (aBase <= 0) continue;
    for (final d in puffs) {
      final x = cx + math.cos(d.angle) * rad * d.radJit;
      final y = cy + math.sin(d.angle) * rad * d.radJit;
      final pr = size * d.sizeJit * (0.45 + 1.6 * e);
      final a = (aBase * d.alphaJit * (1.0 - 0.4 * e)).round();
      if (a <= 0) continue;
      drawDiscAA(frame, x, y, pr, r0, g0, b0, a, exponent: 1.0);
    }
  }
}

/// 风线：横贯画面的细长气流线（环境风；与 speedLines 的放射集中线分工）。
/// 泳道 y0 走内容感知播种管线（activity 加权 + effectRegions ROI + 分格
/// 约束全部生效），行进方向倾角可调。
void _renderWindStreak(FrameCompositor c, RgbaImage frame, double tSec) {
  if (!c._aa) return;
  final list = c._windStreaks;
  if (list.isEmpty) return;
  final p = c.config.windStreak;
  final u = c._loopU(tSec);
  final n = list.length;
  final cycles = p.cycles.clamp(1, 4);
  final win = p.windowFrac.clamp(0.1, 1.0);
  final rgb = FrameCompositor._hexRgb(p.color);
  final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
  final opacity = p.opacity.clamp(0.0, 1.0) * c._env.particles;
  final arad = p.angleDeg * math.pi / 180.0;
  final dirX = math.cos(arad), dirY = math.sin(arad);
  final len0 = p.lengthFrac.clamp(0.05, 1.0) * math.min(c.w, c.h);
  final thick = p.thicknessPx.clamp(0.5, 8.0);
  final sway = p.swayPx.clamp(0.0, 120.0);
  final swayCycles = p.swayCycles.clamp(0, 8);
  for (var i = 0; i < n; i++) {
    final st = list[i];
    // x0 参与窗口错相：同泳道的线不同时出发（确定性，无时钟）。
    final ph = (cycles * u + (i + st.x0) / n) % 1.0;
    if (ph >= win) continue;
    final local = ph / win;
    final env = math.sin(math.pi * local);
    if (env <= 0.01) continue;
    final laneY =
        st.y0 * c.h + sway * math.sin(2 * math.pi * swayCycles * u + st.phase);
    final dist = (local * 1.3 - 0.15) * (c.w + 2 * len0);
    final hx = dirX * dist, hy = laneY + dirY * dist;
    final a = (opacity * env * st.alphaJit * 255).round();
    if (a <= 0) continue;
    drawSegmentAA(frame, hx, hy, hx - dirX * len0 * st.lenJit,
        hy - dirY * len0 * st.lenJit, r0, g0, b0, a, thick * st.thickJit,
        aa: true, tailFade: 0.7, clip: st.clip);
  }
}

class _SlashBeam {
  const _SlashBeam({
    required this.widthJit,
    required this.intenJit,
    required this.angleJit,
    required this.extJit,
  });

  final double widthJit; // 亮带半宽倍率
  final double intenJit; // 峰值亮度倍率
  final double angleJit; // 逐道方向抖动（弧度，±2°）
  final double extJit; // 扫程倍率
}

class _Spark {
  const _Spark({
    required this.angle,
    required this.speedJit,
    required this.lenJit,
  });

  final double angle; // 放射方向（弧度，均匀圆周 + 半格内抖动）
  final double speedJit; // 射程倍率
  final double lenJit; // 尾长倍率
}

class _DustPuff {
  const _DustPuff({
    required this.angle,
    required this.radJit,
    required this.sizeJit,
    required this.alphaJit,
  });

  final double angle; // 外扩方向（弧度，均匀圆周 + 半格内抖动）
  final double radJit; // 环半径倍率
  final double sizeJit; // 尘团半径倍率
  final double alphaJit;
}

class _WindLine {
  const _WindLine({
    required this.x0,
    required this.y0,
    this.clip,
    required this.lenJit,
    required this.thickJit,
    required this.alphaJit,
    required this.phase,
  });

  final double x0; // 窗口错相偏移（播种 x，归一化）
  final double y0; // 泳道（播种 y，归一化）
  final PixelRect? clip; // 分格/ROI 裁剪
  final double lenJit;
  final double thickJit;
  final double alphaJit;
  final double phase; // 纵摆相位（弧度）
}
