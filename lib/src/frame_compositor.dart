import 'dart:math' as math;
import 'dart:typed_data';

import 'depth_splitter.dart';
import 'effect_config.dart';
import 'image_model.dart';
import 'motion_math.dart';

/// Renders animated frames by compositing depth layers with per-layer parallax
/// offsets, a global breathing zoom, and optional ambient particles.
///
/// Determinism: all randomness flows from [EffectConfig.seed] through
/// [DeterministicRandom], so identical input + config => identical frames.
class FrameCompositor {
  FrameCompositor(this.layers, this.base, this.config)
      : w = base.width,
        h = base.height {
    _mult = List<double>.generate(
        layers.length,
        (i) => layers.isEmpty
            ? 1.0
            : 0.25 + 0.75 * i / math.max(1, layers.length - 1));
    _rng = DeterministicRandom(config.seed);
    // Cache rasters once — the per-frame hot path must not copy layers.
    _basePixels = Uint8List.fromList(base.data);
    _layerPixels =
        layers.map((l) => Uint8List.fromList(l.image.data)).toList();
    _initParticles();
    _initNewEffects();
  }

  // ---- v1.1 新动效状态（各自独立随机流，不扰动经典路径的 _rng 序列）----
  late List<_Drop> _rain;
  late List<_SnowFlake> _snow;
  late List<_Petal> _sakura;
  late List<_Firefly> _fireflies;
  late List<_GodRay> _godRays;
  late List<_SpeedLine> _speedLines;
  // ---- v1.2 新动效状态 ----
  late List<_FogBlob> _fogBlobs;
  late List<_Ember> _embers;
  late List<List<_BoltSeg>> _lightningBolts;
  late List<_Star> _stars;
  late List<List<int>> _starSamples; // 星星位置预采样亮度用

  void _initNewEffects() {
    final fx = config.effects;
    _starSamples = []; // 星光亮度预采样表（首次渲染时填充）
    if (fx.contains(EffectKind.rain)) {
      final r = DeterministicRandom(config.seed ^ 0x51A1);
      final p = config.rain;
      _rain = List.generate(p.count.clamp(0, 400), (_) {
        return _Drop(
          x0: r.nextDouble(),
          y0: r.nextDouble(),
          lenJit: 0.7 + r.nextDouble() * 0.6,
          alphaJit: 0.6 + r.nextDouble() * 0.4,
        );
      });
    } else {
      _rain = const [];
    }
    if (fx.contains(EffectKind.snow)) {
      final r = DeterministicRandom(config.seed ^ 0x51A2);
      final p = config.snow;
      _snow = List.generate(p.count.clamp(0, 400), (_) {
        return _SnowFlake(
          x0: r.nextDouble(),
          y0: r.nextDouble(),
          sizeJit: 0.7 + r.nextDouble() * 0.7,
          swayPhase: r.nextDouble() * 2 * math.pi,
          swayFreqMul: r.nextDouble() < 0.5 ? 1 : 2,
          twkPhase: r.nextDouble() * 2 * math.pi,
        );
      });
    } else {
      _snow = const [];
    }
    if (fx.contains(EffectKind.sakura)) {
      final r = DeterministicRandom(config.seed ^ 0x51A3);
      final p = config.sakura;
      _sakura = List.generate(p.count.clamp(0, 300), (_) {
        return _Petal(
          x0: r.nextDouble(),
          y0: r.nextDouble(),
          sizeJit: 0.7 + r.nextDouble() * 0.6,
          rot0: r.nextDouble() * 2 * math.pi,
          spinDir: r.nextDouble() < 0.5 ? -1 : 1,
          swayPhase: r.nextDouble() * 2 * math.pi,
          swayFreqMul: r.nextDouble() < 0.5 ? 1 : 2,
          toneIdx: r.nextInt(3),
        );
      });
    } else {
      _sakura = const [];
    }
    if (fx.contains(EffectKind.fireflies)) {
      final r = DeterministicRandom(config.seed ^ 0x51A4);
      final p = config.fireflies;
      _fireflies = List.generate(p.count.clamp(0, 200), (_) {
        return _Firefly(
          x0: 0.08 + r.nextDouble() * 0.84,
          y0: 0.08 + r.nextDouble() * 0.84,
          ampX: 0.02 + r.nextDouble() * 0.04,
          ampY: 0.02 + r.nextDouble() * 0.04,
          freqX: 1 + r.nextInt(2),
          freqY: 1 + r.nextInt(2),
          phaseX: r.nextDouble() * 2 * math.pi,
          phaseY: r.nextDouble() * 2 * math.pi,
          blinkPhase: r.nextDouble() * 2 * math.pi,
          sizeJit: 0.8 + r.nextDouble() * 0.4,
        );
      });
    } else {
      _fireflies = const [];
    }
    if (fx.contains(EffectKind.godRays)) {
      final r = DeterministicRandom(config.seed ^ 0x51A5);
      final p = config.godRays;
      _godRays = List.generate(p.count.clamp(0, 8), (i) {
        return _GodRay(
          topX: (i + 0.25 + r.nextDouble() * 0.5) / p.count.clamp(1, 8),
          slopeJit: 0.85 + r.nextDouble() * 0.3,
          widthJit: 0.7 + r.nextDouble() * 0.6,
          intenJit: 0.7 + r.nextDouble() * 0.6,
          phase: r.nextDouble() * 2 * math.pi,
        );
      });
    } else {
      _godRays = const [];
    }
    if (fx.contains(EffectKind.speedLines)) {
      final r = DeterministicRandom(config.seed ^ 0x51A6);
      final p = config.speedLines;
      _speedLines = List.generate(p.count.clamp(0, 200), (_) {
        final theta = r.nextDouble() * 2 * math.pi;
        return _SpeedLine(
          theta: theta,
          r0: 0.92 + r.nextDouble() * 0.16,
          lenJit: 0.5 + r.nextDouble() * 0.9,
          phase: r.nextDouble(),
          alphaJit: 0.7 + r.nextDouble() * 0.3,
        );
      });
    } else {
      _speedLines = const [];
    }
    // ---- v1.2 新动效状态 ----
    if (fx.contains(EffectKind.fog)) {
      final r = DeterministicRandom(config.seed ^ 0x52B1);
      final p = config.fog;
      _fogBlobs = List.generate(p.blobs.clamp(0, 40), (_) {
        return _FogBlob(
          x0: r.nextDouble(),
          y0: 0.15 + r.nextDouble() * 0.8,
          rx: 0.18 + r.nextDouble() * 0.30,
          ry: 0.05 + r.nextDouble() * 0.09,
          driftJit: 0.7 + r.nextDouble() * 0.6,
          phase: r.nextDouble() * 2 * math.pi,
          alphaJit: 0.6 + r.nextDouble() * 0.4,
        );
      });
    } else {
      _fogBlobs = const [];
    }
    if (fx.contains(EffectKind.embers)) {
      final r = DeterministicRandom(config.seed ^ 0x52B2);
      final p = config.embers;
      _embers = List.generate(p.count.clamp(0, 300), (_) {
        return _Ember(
          x0: r.nextDouble(),
          y0: r.nextDouble(),
          sizeJit: 0.5 + r.nextDouble() * 0.8,
          swayPhase: r.nextDouble() * 2 * math.pi,
          swayFreqMul: 1 + r.nextInt(2),
          blinkPhase: r.nextDouble() * 2 * math.pi,
          alphaJit: 0.5 + r.nextDouble() * 0.5,
        );
      });
    } else {
      _embers = const [];
    }
    if (fx.contains(EffectKind.lightning)) {
      final r = DeterministicRandom(config.seed ^ 0x52B3);
      _lightningBolts = List.generate(config.lightning.strikes.clamp(1, 8), (_) {
        return _genBolt(r);
      });
    } else {
      _lightningBolts = const [];
    }
    if (fx.contains(EffectKind.starlight)) {
      final r = DeterministicRandom(config.seed ^ 0x52B6);
      final p = config.starlight;
      _stars = List.generate(p.count.clamp(0, 120), (_) {
        // 星星只在亮区：渲染时采样亮度，先随机挑候选点并记录索引
        return _Star(
          x0: 0.05 + r.nextDouble() * 0.9,
          y0: 0.05 + r.nextDouble() * 0.9,
          sizeJit: 0.7 + r.nextDouble() * 0.6,
          blinkPhase: r.nextDouble() * 2 * math.pi,
          brightJit: 0.7 + r.nextDouble() * 0.3,
        );
      });
    } else {
      _stars = const [];
    }
  }

  /// 生成一条分形闪电主干（带 1-2 条分支）。
  List<_BoltSeg> _genBolt(DeterministicRandom r) {
    final segs = <_BoltSeg>[];
    var x = 0.2 + r.nextDouble() * 0.6; // 顶部起点（归一化）
    var y = -0.02;
    const step = 0.09;
    while (y < 0.75) {
      final nx = x + (r.nextDouble() - 0.5) * 0.10;
      final ny = y + step * (0.8 + r.nextDouble() * 0.4);
      segs.add(_BoltSeg(x0: x, y0: y, x1: nx, y1: ny));
      // 分支
      if (r.nextDouble() < 0.22 && y < 0.45) {
        var bx = nx, by = ny;
        const bstep = 0.05;
        for (var b = 0; b < 4; b++) {
          final bnx = bx + (r.nextDouble() - 0.5) * 0.14;
          final bny = by + bstep;
          segs.add(_BoltSeg(x0: bx, y0: by, x1: bnx, y1: bny));
          bx = bnx;
          by = bny;
        }
      }
      x = nx;
      y = ny;
    }
    return segs;
  }

  final List<LayerImage> layers;
  final RgbaImage base; // original image at working resolution
  final EffectConfig config;

  final int w;
  final int h;
  late List<double> _mult;
  late DeterministicRandom _rng;
  late List<_Particle> _particles;
  late List<Uint8List> _layerPixels; // per-layer cached raster (no per-frame copy)
  late Uint8List _basePixels;

  void _initParticles() {
    _particles = [];
    if (!config.effects.contains(EffectKind.ambient)) return;
    final amb = config.ambient;
    for (var i = 0; i < amb.particleCount; i++) {
      _particles.add(_Particle(
        px: _rng.nextDouble(),
        py: _rng.nextDouble(),
        r: 0.8 + _rng.nextDouble() * 2.2,
        alpha: (0.35 + _rng.nextDouble() * 0.65),
        drift: 0.5 + _rng.nextDouble(),
        phase: _rng.nextDouble() * math.pi * 2,
      ));
    }
  }

  /// Render frame at normalized time t in [0, duration).
  RgbaImage renderFrame(double tSec) {
    final frame = RgbaImage(width: w, height: h);
    final dirRad = config.parallax.directionDeg * math.pi / 180.0;
    final dxDir = math.cos(dirRad);
    final dyDir = math.sin(dirRad);

    // Global breathing zoom around the anchor.
    var zoom = 1.0;
    if (config.effects.contains(EffectKind.breathing) &&
        config.breathing.enabled) {
      zoom = 1.0 +
          config.breathing.amplitude *
              MotionMath.wave(tSec,
                  periodSec: config.breathing.periodSec, phase: 0);
    }
    // v1.1 心跳脉冲：双拍缩放（乘法叠加在呼吸之上）。
    if (config.effects.contains(EffectKind.heartbeat)) {
      zoom *= _heartbeatZoom(tSec);
    }
    // v1.2 缓慢推镜：Ken Burns 式单向前推（往返整数周期保证无缝）。
    if (config.effects.contains(EffectKind.slowPush)) {
      zoom *= _slowPushZoom(tSec);
    }

    // 减弱动态降级：单帧静态底图，无任何动效。
    if (config.reducedMotion) {
      _drawLayer(frame, _basePixels, base.width, base.height, 0, 0, 1.0,
          _anchorY());
      return frame;
    }

    // Base with breathing zoom only.
    _drawLayer(frame, _basePixels, base.width, base.height, 0, 0, zoom,
        _anchorY());

    // Layers far-to-near with parallax offsets.
    final p = config.effects.contains(EffectKind.parallax);
    for (var li = 0; li < layers.length; li++) {
      var dx = 0.0, dy = 0.0;
      if (p) {
        final ampPx = config.parallax.amplitude * w * _mult[li];
        final phase = 2 * math.pi * tSec / config.parallax.periodSec;
        dx = math.sin(phase + li * 0.35) * ampPx * dxDir;
        dy = math.sin(phase * 0.8 + li * 0.5 + 0.9) *
            ampPx *
            config.parallax.verticalRatio *
            dyDir;
      }
      // Scale slightly beyond 1 so shifted layers still cover the canvas.
      final cover = 1.0 + 2 * (dx.abs() + dy.abs()) / math.min(w, h);
      _drawLayer(frame, _layerPixels[li], layers[li].image.width,
          layers[li].image.height, dx, dy, zoom * cover, _anchorY());
    }

    if (config.effects.contains(EffectKind.ambient) &&
        config.ambient.enabled) {
      _drawParticles(frame, tSec);
    }
    if (config.effects.contains(EffectKind.lightSweep)) {
      _applyLightSweep(frame, tSec);
    }
    // ---- v1.1 新动效渲染（顺序：光束→雨→雪→樱→萤→速度线→冲击闪光）----
    if (config.effects.contains(EffectKind.godRays)) {
      _applyGodRays(frame, tSec);
    }
    if (config.effects.contains(EffectKind.rain)) {
      _drawRain(frame, tSec);
    }
    if (config.effects.contains(EffectKind.snow)) {
      _drawSnow(frame, tSec);
    }
    if (config.effects.contains(EffectKind.sakura)) {
      _drawSakura(frame, tSec);
    }
    if (config.effects.contains(EffectKind.fireflies)) {
      _drawFireflies(frame, tSec);
    }
    if (config.effects.contains(EffectKind.speedLines)) {
      _drawSpeedLines(frame, tSec);
    }
    if (config.effects.contains(EffectKind.impactFlash)) {
      _applyImpactFlash(frame, tSec);
    }
    // ---- v1.2 新动效渲染 ----
    if (config.effects.contains(EffectKind.shimmer)) {
      _applyShimmer(frame, tSec);
    }
    if (config.effects.contains(EffectKind.fog)) {
      _drawFog(frame, tSec);
    }
    if (config.effects.contains(EffectKind.embers)) {
      _drawEmbers(frame, tSec);
    }
    if (config.effects.contains(EffectKind.starlight)) {
      _drawStarlight(frame, tSec);
    }
    if (config.effects.contains(EffectKind.lightning)) {
      _applyLightning(frame, tSec);
    }
    if (config.effects.contains(EffectKind.toneShift)) {
      _applyToneShift(frame, tSec);
    }
    if (config.effects.contains(EffectKind.vignette)) {
      _applyVignette(frame, tSec);
    }
    return frame;
  }

  double _anchorY() {
    switch (config.breathing.anchor) {
      case 'top':
        return 0.0;
      case 'bottom':
        return 1.0;
      default:
        return 0.5;
    }
  }

  /// Inverse-mapped bilinear layer draw with alpha blending.
  /// Hot path; operates directly on the cached raster.
  static void _drawLayer(RgbaImage dst, Uint8List srcData, int sw, int sh,
      double dx, double dy, double scale, double anchorY) {
    if (scale <= 0) return;
    final w = dst.width, h = dst.height;
    final cx = sw / 2.0, cy = sh * anchorY;
    final inv = 1.0 / scale;
    final dstData = dst.data;
    final sxStep = inv;
    for (var y = 0; y < h; y++) {
      final sy = (y + 0.5 - (h * anchorY)) * inv + cy + dy - 0.5;
      final sy0 = sy.floor();
      final ty = sy - sy0;
      final y0_ok = sy0 >= 0 && sy0 < sh;
      final y1 = sy0 + 1;
      final y1_ok = y1 >= 0 && y1 < sh;
      if (!y0_ok && !y1_ok) continue;
      var sx = (0 + 0.5 - (w * 0.5)) * inv + cx + dx - 0.5;
      for (var x = 0; x < w; x++, sx += sxStep) {
        final sx0 = sx.floor();
        final tx = sx - sx0;
        final x1 = sx0 + 1;
        final x0_ok = sx0 >= 0 && sx0 < sw;
        final x1_ok = x1 >= 0 && x1 < sw;
        if (!x0_ok && !x1_ok) continue;
        final dOff = (y * w + x) * 4;
        // Gather 4 taps (out-of-range taps are skipped via weight 0).
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
        if (x0_ok && y0_ok) {
          final o = (sy0 * sw + sx0) * 4;
          final wgt = (1 - tx) * (1 - ty);
          r += srcData[o] * wgt;
          g += srcData[o + 1] * wgt;
          b += srcData[o + 2] * wgt;
          a += srcData[o + 3] * wgt;
        }
        if (x1_ok && y0_ok) {
          final o = (sy0 * sw + x1) * 4;
          final wgt = tx * (1 - ty);
          r += srcData[o] * wgt;
          g += srcData[o + 1] * wgt;
          b += srcData[o + 2] * wgt;
          a += srcData[o + 3] * wgt;
        }
        if (x0_ok && y1_ok) {
          final o = (y1 * sw + sx0) * 4;
          final wgt = (1 - tx) * ty;
          r += srcData[o] * wgt;
          g += srcData[o + 1] * wgt;
          b += srcData[o + 2] * wgt;
          a += srcData[o + 3] * wgt;
        }
        if (x1_ok && y1_ok) {
          final o = (y1 * sw + x1) * 4;
          final wgt = tx * ty;
          r += srcData[o] * wgt;
          g += srcData[o + 1] * wgt;
          b += srcData[o + 2] * wgt;
          a += srcData[o + 3] * wgt;
        }
        final sa = a / 255.0;
        if (sa <= 0.004) continue;
        if (sa >= 0.996) {
          dstData[dOff] = r.round().clamp(0, 255);
          dstData[dOff + 1] = g.round().clamp(0, 255);
          dstData[dOff + 2] = b.round().clamp(0, 255);
          dstData[dOff + 3] = 255;
        } else {
          final da = dstData[dOff + 3] / 255.0;
          final outA = sa + da * (1 - sa);
          dstData[dOff] =
              ((r * sa + dstData[dOff] * da * (1 - sa)) / outA).round().clamp(0, 255);
          dstData[dOff + 1] =
              ((g * sa + dstData[dOff + 1] * da * (1 - sa)) / outA).round().clamp(0, 255);
          dstData[dOff + 2] =
              ((b * sa + dstData[dOff + 2] * da * (1 - sa)) / outA).round().clamp(0, 255);
          dstData[dOff + 3] = (outA * 255).round().clamp(0, 255);
        }
      }
    }
  }

  void _drawParticles(RgbaImage frame, double tSec) {
    final amb = config.ambient;
    final speedPx = amb.speed * tSec / math.max(1, config.durationSec);
    for (final p in _particles) {
      // Slow upward drift + gentle horizontal sway, wrapping vertically.
      var py = (p.py - (speedPx / h) * p.drift) % 1.0;
      if (py < 0) py += 1.0;
      final px =
          (p.px + 0.01 * math.sin(tSec + p.phase)) % 1.0;
      final cx = px * w, cy = py * h;
      final alpha = (amb.opacity * p.alpha * 255).round().clamp(0, 255);
      final rad = p.r;
      final x0 = (cx - rad).floor(), x1 = (cx + rad).ceil();
      final y0 = (cy - rad).floor(), y1 = (cy + rad).ceil();
      for (var y = y0; y <= y1; y++) {
        if (y < 0 || y >= h) continue;
        for (var x = x0; x <= x1; x++) {
          if (x < 0 || x >= w) continue;
          final dist = math
              .sqrt((x + 0.5 - cx) * (x + 0.5 - cx) + (y + 0.5 - cy) * (y + 0.5 - cy));
          if (dist > rad) continue;
          final fall = 1 - dist / rad;
          final a = (alpha * fall).round().clamp(0, 255);
          final o = (y * w + x) * 4;
          final bright = amb.mode == 'sparkle' ? 255 : 245;
          frame.data[o] =
              ((bright * a) + frame.data[o] * (255 - a)) ~/ 255;
          frame.data[o + 1] =
              ((bright * a) + frame.data[o + 1] * (255 - a)) ~/ 255;
          frame.data[o + 2] =
              ((bright * a) + frame.data[o + 2] * (255 - a)) ~/ 255;
        }
      }
    }
  }

  void _applyLightSweep(RgbaImage frame, double tSec) {
    final prog = (tSec / config.durationSec) % 1.0;
    final bandCenter = (prog * (w + h * 0.7)) - h * 0.35;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final d = (x + y * 0.35 - bandCenter).abs();
        if (d > 80) continue;
        final add = (60 * math.exp(-d * d / (2 * 30 * 30))).round();
        if (add == 0) continue;
        final o = (y * w + x) * 4;
        for (var c = 0; c < 3; c++) {
          frame.data[o + c] = math.min(255, frame.data[o + c] + add);
        }
      }
    }
  }

  // ---------- v1.1 新动效实现 ----------

  /// 归一化循环进度 u∈[0,1)；所有新效果只用 u 的整数周期函数，保证
  /// u=0 与 u=1 帧完全一致（GIF 无缝循环）。
  double _loopU(double tSec) =>
      (tSec / math.max(0.001, config.durationSec)) % 1.0;

  static int _hexRgb(String hex) => int.parse(hex, radix: 16);

  void _blendPx(
      RgbaImage f, int x, int y, int r, int g, int b, int a) {
    if (a <= 0 || x < 0 || y < 0 || x >= w || y >= h) return;
    if (a > 255) a = 255;
    final o = (y * w + x) * 4;
    final inv = 255 - a;
    f.data[o] = (r * a + f.data[o] * inv) ~/ 255;
    f.data[o + 1] = (g * a + f.data[o + 1] * inv) ~/ 255;
    f.data[o + 2] = (b * a + f.data[o + 2] * inv) ~/ 255;
  }

  void _blendAddPx(
      RgbaImage f, int x, int y, int r, int g, int b, int add) {
    if (add <= 0 || x < 0 || y < 0 || x >= w || y >= h) return;
    final o = (y * w + x) * 4;
    f.data[o] = math.min(255, f.data[o] + (r * add) ~/ 255);
    f.data[o + 1] = math.min(255, f.data[o + 1] + (g * add) ~/ 255);
    f.data[o + 2] = math.min(255, f.data[o + 2] + (b * add) ~/ 255);
  }

  /// 雨丝：竖直循环下落 + 固定倾角线段。
  void _drawRain(RgbaImage frame, double tSec) {
    final p = config.rain;
    final rgb = _hexRgb(p.color);
    final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
    final u = _loopU(tSec);
    final cycles = p.fallCycles.clamp(1, 12);
    final arad = p.angleDeg * math.pi / 180.0;
    final dx = -math.sin(arad), dy = -math.cos(arad);
    final len = p.lengthPx.clamp(2.0, 200.0);
    for (final d in _rain) {
      final py = ((d.y0 + cycles * u) % 1.0) * h;
      final px = d.x0 * w;
      final a = (p.opacity * d.alphaJit * 255).round().clamp(0, 255);
      final steps = (len * d.lenJit).round().clamp(2, 220);
      for (var s = 0; s < steps; s++) {
        final fade = 1 - 0.6 * s / steps;
        _blendPx(frame, (px + dx * s).round(), (py + dy * s).round(), r0,
            g0, b0, (a * fade).round());
      }
    }
  }

  /// 雪花：竖直循环下落 + 正弦横摆 + 轻微明暗闪烁。
  void _drawSnow(RgbaImage frame, double tSec) {
    final p = config.snow;
    final u = _loopU(tSec);
    final cycles = p.fallCycles.clamp(1, 12);
    final w2pi = 2 * math.pi;
    for (final f in _snow) {
      final py = ((f.y0 + cycles * u) % 1.0) * h;
      final px = (f.x0 * w +
              p.swayPx *
                  math.sin(w2pi * (f.swayFreqMul * u) + f.swayPhase)) %
          w;
      final rad = (p.sizePx * f.sizeJit).clamp(0.8, 12.0);
      final twk = 0.78 + 0.22 * math.sin(w2pi * u * 2 + f.twkPhase);
      final a = (p.opacity * twk * 255).round().clamp(0, 255);
      _drawSoftDisc(frame, px, py, rad, 250, 252, 255, a);
    }
  }

  /// 樱花瓣：下落 + 摇摆 + 自转的小花瓣（沿长轴的短棒 + 两侧加宽）。
  void _drawSakura(RgbaImage frame, double tSec) {
    final p = config.sakura;
    final rgb = _hexRgb(p.color);
    final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
    const tones = [
      [1.0, 1.0, 1.0],
      [0.93, 0.95, 0.97],
      [1.0, 0.88, 0.92],
    ];
    final u = _loopU(tSec);
    final cycles = p.fallCycles.clamp(1, 12);
    final w2pi = 2 * math.pi;
    final half = (p.sizePx).clamp(2.0, 24.0);
    for (final t in _sakura) {
      final py = ((t.y0 + cycles * u) % 1.0) * h;
      final px = (t.x0 * w +
              p.swayPx * math.sin(w2pi * (t.swayFreqMul * u) + t.swayPhase)) %
          w;
      final rot = t.rot0 + w2pi * t.spinDir * p.spinTurns.clamp(0, 8) * u;
      final tone = tones[t.toneIdx % 3];
      final rr = (r0 * tone[0]).round();
      final gg = (g0 * tone[1]).round();
      final bb = (b0 * tone[2]).round();
      final a = (p.opacity * 255).round().clamp(0, 255);
      final ca = math.cos(rot), sa = math.sin(rot);
      for (var s = -half; s <= half; s++) {
        final cxp = px + ca * s;
        final cyp = py + sa * s;
        final width = half * 0.55 * (1 - (s.abs() / half) * 0.55);
        for (var t2 = -width; t2 <= width; t2 += 1.0) {
          _blendPx(frame, (cxp - sa * t2).round(), (cyp + ca * t2).round(),
              rr, gg, bb, a);
        }
      }
    }
  }

  /// 萤火虫：暖色光晕加性叠加 + 呼吸式明灭 + 慢速游移。
  void _drawFireflies(RgbaImage frame, double tSec) {
    final p = config.fireflies;
    final rgb = _hexRgb(p.color);
    final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
    final u = _loopU(tSec);
    final w2pi = 2 * math.pi;
    final blink = p.blinkCycles.clamp(1, 12);
    final drift = p.driftCycles.clamp(1, 8);
    for (final f in _fireflies) {
      final px = (f.x0 +
              f.ampX * math.sin(w2pi * (drift * f.freqX * u) + f.phaseX)) *
          w;
      final py = (f.y0 +
              f.ampY * math.cos(w2pi * (drift * f.freqY * u) + f.phaseY)) *
          h;
      final blinkV =
          0.30 + 0.70 * math.pow(0.5 + 0.5 * math.sin(w2pi * blink * u + f.blinkPhase), 2.0);
      final rad = (p.glowPx * f.sizeJit).clamp(3.0, 80.0);
      final aBase = (p.opacity * blinkV * 255).round().clamp(0, 255);
      final x0 = (px - rad).floor(), x1 = (px + rad).ceil();
      final y0 = (py - rad).floor(), y1 = (py + rad).ceil();
      for (var y = y0; y <= y1; y++) {
        if (y < 0 || y >= h) continue;
        for (var x = x0; x <= x1; x++) {
          if (x < 0 || x >= w) continue;
          final dist = math.sqrt((x + 0.5 - px) * (x + 0.5 - px) +
              (y + 0.5 - py) * (y + 0.5 - py));
          if (dist >= rad) continue;
          var fall = 1 - dist / rad;
          fall *= fall;
          // 中心亮核 + 柔和光晕
          final core = dist < rad * 0.16 ? 1.0 : 0.0;
          final add = (aBase * (fall * 0.85 + core * 0.6)).round();
          _blendAddPx(frame, x, y, r0, g0, b0, add);
        }
      }
    }
  }

  /// 丁达尔光束：顶部斜射柔光柱，半分辨率渲染（软渐变无精度损失）。
  void _applyGodRays(RgbaImage frame, double tSec) {
    final p = config.godRays;
    final rgb = _hexRgb(p.color);
    final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
    final u = _loopU(tSec);
    final w2pi = 2 * math.pi;
    final sway = p.swayCycles.clamp(1, 8);
    final baseTan = math.tan(p.angleDeg * math.pi / 180.0);
    for (final ray in _godRays) {
      final ang =
          p.angleDeg + 4.0 * math.sin(w2pi * sway * u + ray.phase);
      final tanA = math.tan(ang * math.pi / 180.0);
      final sigma = (p.widthFrac * w * ray.widthJit).clamp(8.0, w * 0.3);
      final inten =
          (p.intensity * ray.intenJit * (0.8 + 0.2 * math.sin(w2pi * u + ray.phase)))
              .clamp(0.0, 1.0);
      final band = 2.5 * sigma;
      // 半分辨率：步长 2
      for (var y = 0; y < h; y += 2) {
        final xc = ray.topX * w + baseTan * y * 0.3 + (tanA - baseTan) * y;
        final xStart = (xc - band).floor(), xEnd = (xc + band).ceil();
        final vfade = 1.0 - 0.25 * y / h;
        for (var x = xStart; x <= xEnd; x += 2) {
          if (x < 0 || x >= w) continue;
          final t = (x + 0.5 - xc) / band;
          var fall = 1 - t * t;
          if (fall <= 0) continue;
          fall *= fall;
          final add = (inten * fall * vfade * 255).round();
          if (add <= 0) continue;
          _blendAddPx(frame, x, y, r0, g0, b0, add);
          _blendAddPx(frame, x + 1, y, r0, g0, b0, add);
          _blendAddPx(frame, x, y + 1, r0, g0, b0, add);
          _blendAddPx(frame, x + 1, y + 1, r0, g0, b0, add);
        }
      }
    }
  }

  /// 速度线：边缘向心的放射短线，成组脉冲（漫画动势语言）。
  void _drawSpeedLines(RgbaImage frame, double tSec) {
    final p = config.speedLines;
    final u = _loopU(tSec);
    final pulses = p.pulses.clamp(1, 12);
    final cx = w / 2.0, cy = h / 2.0;
    final diag = math.sqrt(w * w + h * h) / 2;
    final len = p.lengthFrac * math.min(w, h);
    final w2pi = 2 * math.pi;
    for (final l in _speedLines) {
      final pulse = math
          .pow(math.max(0.0, math.sin(w2pi * (pulses * u + l.phase))), 3.0)
          .toDouble();
      if (pulse <= 0.02) continue;
      final a = (p.intensity * pulse * l.alphaJit * 255).round().clamp(0, 255);
      final ux = math.cos(l.theta), uy = math.sin(l.theta);
      final sx = cx + ux * diag * l.r0;
      final sy = cy + uy * diag * l.r0;
      final steps = (len * l.lenJit).round().clamp(2, 400);
      for (var s = 0; s < steps; s++) {
        final x = (sx - ux * s).round();
        final y = (sy - uy * s).round();
        _blendPx(frame, x, y, 255, 255, 255, a);
        if (p.thickness > 1) {
          _blendPx(frame, x + 1, y, 255, 255, 255, (a * 0.7).round());
        }
      }
    }
  }

  /// 冲击闪光：每循环 N 次的柔白短闪，快速起衰。
  void _applyImpactFlash(RgbaImage frame, double tSec) {
    final p = config.impactFlash;
    final u = _loopU(tSec);
    final flashes = p.flashes.clamp(1, 12);
    final duty = p.dutyFrac.clamp(0.02, 0.5);
    final phase = (u * flashes) % 1.0;
    if (phase >= duty) return; // 大多数帧直接跳过
    final env = math.sin(math.pi * phase / duty); // 0→1→0
    final k = (env * p.intensity * 256).round().clamp(0, 256);
    if (k <= 0) return;
    final data = frame.data;
    for (var i = 0; i < data.length; i += 4) {
      data[i] = data[i] + ((255 - data[i]) * k >> 8);
      data[i + 1] = data[i + 1] + ((255 - data[i + 1]) * k >> 8);
      data[i + 2] = data[i + 2] + ((255 - data[i + 2]) * k >> 8);
    }
  }

  /// 心跳缩放：每循环 beats 次双拍（lub-dub）。
  double _heartbeatZoom(double tSec) {
    final p = config.heartbeat;
    final u = _loopU(tSec);
    final beats = p.beats.clamp(1, 12);
    final ph = (u * beats) % 1.0;
    final g1 = math.exp(-math.pow((ph - 0.06) / 0.055, 2) * 1.0);
    var beat = g1;
    if (p.doubleBeat) {
      beat += 0.55 * math.exp(-math.pow((ph - 0.32) / 0.075, 2) * 1.0);
    }
    return 1.0 + p.intensity.clamp(0.0, 0.05) * beat;
  }

  /// 缓慢推镜：每循环 pushFrac 的推近-拉回（往返整数周期保证无缝）。
  double _slowPushZoom(double tSec) {
    final p = config.slowPush;
    final u = _loopU(tSec);
    final cyc = p.cycles.clamp(1, 4);
    final wv = math.sin(2 * math.pi * cyc * u - math.pi / 2); // -1→1→-1
    return 1.0 +
        p.pushFrac.clamp(0.002, 0.08) * (wv * 0.5 + 0.5); // 0→1→0
  }

  /// 流雾：大半透明雾团横向缓移 + 浓淡起伏。
  void _drawFog(RgbaImage frame, double tSec) {
    final p = config.fog;
    final rgb = _hexRgb(p.color);
    final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
    final u = _loopU(tSec);
    final drift = p.driftCycles.clamp(1, 4);
    final w2pi = 2 * math.pi;
    for (final b in _fogBlobs) {
      final px = ((b.x0 + drift * b.driftJit * u) % 1.0) * w;
      final py = (b.y0 + 0.01 * math.sin(w2pi * u + b.phase)) * h;
      final rx = b.rx * w, ry = b.ry * h;
      // 半分辨率渲染（软渐变无精度损失）
      final aBase = (p.opacity * b.alphaJit * 255).round().clamp(0, 255);
      for (var y = (py - ry).floor(); y <= (py + ry).ceil(); y += 2) {
        if (y < 0 || y >= h) continue;
        final ty = (y - py) / ry;
        for (var x = (px - rx).floor(); x <= (px + rx).ceil(); x += 2) {
          final tx = (x - px) / rx;
          var fall = 1 - (tx * tx + ty * ty);
          if (fall <= 0) continue;
          fall *= fall;
          final a = (aBase * fall).round();
          if (a <= 0) continue;
          _blendPx(frame, x, y, r0, g0, b0, a);
          _blendPx(frame, x + 1, y, r0, g0, b0, a);
          _blendPx(frame, x, y + 1, r0, g0, b0, a);
          _blendPx(frame, x + 1, y + 1, r0, g0, b0, a);
        }
      }
    }
  }

  /// 余烬：橙红微粒自下而上升腾、摇曳明灭。
  void _drawEmbers(RgbaImage frame, double tSec) {
    final p = config.embers;
    final rgb = _hexRgb(p.color);
    final r0 = (rgb >> 16) & 0xff, g0 = (rgb >> 8) & 0xff, b0 = rgb & 0xff;
    final u = _loopU(tSec);
    final rise = p.riseCycles.clamp(1, 8);
    final w2pi = 2 * math.pi;
    for (final e in _embers) {
      final py = ((e.y0 - rise * u) % 1.0 + 1.0) % 1.0 * h;
      final px = (e.x0 * w +
              12 * math.sin(w2pi * (e.swayFreqMul * u) + e.swayPhase)) %
          w;
      final blink = 0.45 +
          0.55 * math.pow(0.5 + 0.5 * math.sin(w2pi * u * 3 + e.blinkPhase), 2.0);
      final rad = (p.glowPx * e.sizeJit).clamp(1.2, 20.0);
      final a = (p.opacity * e.alphaJit * blink * 255).round().clamp(0, 255);
      _drawSoftDisc(frame, px, py, rad, r0, g0, b0, a);
    }
  }

  /// 闪电：分形主干 + 全屏瞬亮，短促起衰。
  void _applyLightning(RgbaImage frame, double tSec) {
    final p = config.lightning;
    final u = _loopU(tSec);
    final strikes = p.strikes.clamp(1, 8);
    // 每次落雷占循环 8% 时长；落雷窗口内前 30% 主干可见，全屏瞬亮快速衰减
    final win = 0.08;
    final phase = (u * strikes) % 1.0;
    if (phase >= win) return;
    final local = phase / win; // 0..1
    // 全屏瞬亮：快速起衰
    final flashK = (math.exp(-local * 7.0) * p.flashIntensity * 256)
        .round()
        .clamp(0, 256);
    if (flashK > 0) {
      final data = frame.data;
      for (var i = 0; i < data.length; i += 4) {
        data[i] = data[i] + ((255 - data[i]) * flashK >> 8);
        data[i + 1] = data[i + 1] + ((255 - data[i + 1]) * flashK >> 8);
        data[i + 2] = data[i + 2] + ((255 - data[i + 2]) * flashK >> 8);
      }
    }
    // 主干：前 30% 窗口可见，透明度先升后降
    if (local < 0.3) {
      final vis = math.sin(math.pi * local / 0.3);
      final a = (p.boltOpacity * vis * 255).round().clamp(0, 255);
      for (final bolt in _lightningBolts) {
        for (final seg in bolt) {
          _drawFogLine(frame, seg, a);
        }
      }
    }
  }

  void _drawFogLine(RgbaImage f, _BoltSeg s, int a) {
    final x0 = s.x0 * w, y0 = s.y0 * h, x1 = s.x1 * w, y1 = s.y1 * h;
    final steps =
        math.max(2, ((x1 - x0).abs() + (y1 - y0).abs()).round());
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final x = (x0 + (x1 - x0) * t).round();
      final y = (y0 + (y1 - y0) * t).round();
      // 主干 2px 宽 + 柔光晕
      _blendPx(f, x, y, 255, 255, 255, a);
      _blendPx(f, x + 1, y, 255, 255, 255, (a * 0.75).round());
      _blendPx(f, x, y + 1, 240, 244, 255, (a * 0.4).round());
    }
  }

  /// 色调呼吸：全图色温缓慢偏暖/偏冷（LUT：一次三查表）。
  void _applyToneShift(RgbaImage frame, double tSec) {
    final p = config.toneShift;
    final u = _loopU(tSec);
    final cyc = p.warmthCycles.clamp(1, 4);
    final s = math.sin(2 * math.pi * cyc * u); // -1..1
    final warm = (p.shift.clamp(0.0, 0.15) * s * 255).round();
    if (warm == 0) return;
    final addR = warm > 0 ? warm : (warm * 0.4).round();
    final addB = warm > 0 ? (-warm * 0.6).round() : -warm;
    final subR = warm > 0 ? 0 : warm;
    final subB = warm > 0 ? warm : 0;
    // 预计算 LUT：r LUT 与 b LUT 各 256 项
    final lutR = List<int>.generate(256, (v) => (v + addR - subR).clamp(0, 255));
    final lutB = List<int>.generate(256, (v) => (v + addB - subB).clamp(0, 255));
    final data = frame.data;
    for (var i = 0; i < data.length; i += 4) {
      data[i] = lutR[data[i]];
      data[i + 2] = lutB[data[i + 2]];
    }
  }

  /// 暗角呼吸：四周暗角周期性收拢（预计算半径平方表）。
  void _applyVignette(RgbaImage frame, double tSec) {
    final p = config.vignette;
    final u = _loopU(tSec);
    final cyc = p.cycles.clamp(1, 4);
    final strength =
        p.strength.clamp(0.0, 0.8) * (0.5 + 0.5 * math.sin(2 * math.pi * cyc * u - math.pi / 2));
    if (strength < 0.005) return;
    final cx = w / 2.0, cy = h / 2.0;
    final maxD = math.sqrt(cx * cx + cy * cy);
    final data = frame.data;
    for (var y = 0; y < h; y++) {
      final dy = y - cy;
      for (var x = 0; x < w; x++) {
        final dx = x - cx;
        final d = math.sqrt(dx * dx + dy * dy) / maxD; // 0..1
        var fall = (d - 0.55) / 0.45; // 中心 55% 不受影响
        if (fall <= 0) continue;
        fall = fall * fall;
        final k = (strength * fall * 256).round().clamp(0, 256);
        if (k <= 0) continue;
        final o = (y * w + x) * 4;
        data[o] = data[o] - (data[o] * k >> 8);
        data[o + 1] = data[o + 1] - (data[o + 1] * k >> 8);
        data[o + 2] = data[o + 2] - (data[o + 2] * k >> 8);
      }
    }
  }

  /// 星光闪烁：在亮区（预采样亮度判定）画十字星明灭。
  void _drawStarlight(RgbaImage frame, double tSec) {
    final p = config.starlight;
    final u = _loopU(tSec);
    final blink = p.blinkCycles.clamp(1, 8);
    final w2pi = 2 * math.pi;
    if (_starSamples.isEmpty) {
      // 首帧：预采样亮度，保留亮度 > 170 的候选点
      _starSamples = [];
      for (final st in _stars) {
        final sx = (st.x0 * w).clamp(0, w - 1).toInt();
        final sy = (st.y0 * h).clamp(0, h - 1).toInt();
        final lum = base.luminance(sy * w + sx);
        if (lum > 165) _starSamples.add([sx, sy]);
      }
    }
    for (var i = 0; i < _starSamples.length; i++) {
      final st = _stars[i];
      final blinkV = math
          .pow(0.5 + 0.5 * math.sin(w2pi * blink * u + st.blinkPhase), 2.0)
          .toDouble();
      if (blinkV < 0.06) continue;
      final a = (p.intensity * st.brightJit * blinkV * 255).round().clamp(0, 255);
      final arm = (p.sizePx * st.sizeJit).clamp(2.0, 30.0);
      final sx = _starSamples[i][0].toDouble();
      final sy = _starSamples[i][1].toDouble();
      for (var d = 0; d < arm; d++) {
        final fade = 1 - d / arm;
        final aa = (a * fade * fade).round();
        _blendAddPx(frame, sx.toInt() + d, sy.toInt(), 255, 250, 230, aa);
        _blendAddPx(frame, sx.toInt() - d, sy.toInt(), 255, 250, 230, aa);
        _blendAddPx(frame, sx.toInt(), sy.toInt() + d, 255, 250, 230, aa);
        _blendAddPx(frame, sx.toInt(), sy.toInt() - d, 255, 250, 230, aa);
      }
    }
  }

  /// 波光：横向亮带缓慢起伏（底部区域为主，水/反光面）。
  void _applyShimmer(RgbaImage frame, double tSec) {
    final p = config.shimmer;
    final u = _loopU(tSec);
    final cyc = p.cycles.clamp(1, 4);
    final w2pi = 2 * math.pi;
    final rows = p.rows.clamp(1, 40);
    final band = p.bandPx.clamp(4.0, 120.0);
    for (var i = 0; i < rows; i++) {
      // 每条亮带：底部区域内的基线 y + 缓慢正弦游移
      final baseY = h * (0.55 + 0.45 * i / rows);
      final yC =
          baseY + band * 1.5 * math.sin(w2pi * (cyc + i * 0.13) * u + i * 1.7);
      for (var y = (yC - band).round(); y <= (yC + band).round(); y += 2) {
        if (y < 0 || y >= h) continue;
        final t = (y - yC) / band;
        var fall = 1 - t * t;
        if (fall <= 0) continue;
        fall *= fall;
        final add = (p.intensity * fall * 120).round();
        if (add <= 0) continue;
        for (var x = 0; x < w; x += 2) {
          _blendAddPx(frame, x, y, 220, 235, 255, add);
          _blendAddPx(frame, x + 1, y, 220, 235, 255, add);
        }
      }
    }
  }

  void _drawSoftDisc(
      RgbaImage f, double cx, double cy, double rad, int r, int g, int b, int a) {
    final x0 = (cx - rad).floor(), x1 = (cx + rad).ceil();
    final y0 = (cy - rad).floor(), y1 = (cy + rad).ceil();
    for (var y = y0; y <= y1; y++) {
      if (y < 0 || y >= h) continue;
      for (var x = x0; x <= x1; x++) {
        if (x < 0 || x >= w) continue;
        final dist = math.sqrt(
            (x + 0.5 - cx) * (x + 0.5 - cx) + (y + 0.5 - cy) * (y + 0.5 - cy));
        if (dist > rad) continue;
        final fall = 1 - dist / rad;
        _blendPx(f, x, y, r, g, b, (a * (0.35 + 0.65 * fall)).round());
      }
    }
  }
}

class _Particle {
  _Particle({
    required this.px,
    required this.py,
    required this.r,
    required this.alpha,
    required this.drift,
    required this.phase,
  });

  final double px;
  final double py;
  final double r;
  final double alpha;
  final double drift;
  final double phase;
}

// ---- v1.1 新动效粒子状态 ----

class _Drop {
  _Drop({
    required this.x0,
    required this.y0,
    required this.lenJit,
    required this.alphaJit,
  });

  final double x0;
  final double y0;
  final double lenJit;
  final double alphaJit;
}

class _SnowFlake {
  _SnowFlake({
    required this.x0,
    required this.y0,
    required this.sizeJit,
    required this.swayPhase,
    required this.swayFreqMul,
    required this.twkPhase,
  });

  final double x0;
  final double y0;
  final double sizeJit;
  final double swayPhase;
  final int swayFreqMul;
  final double twkPhase;
}

class _Petal {
  _Petal({
    required this.x0,
    required this.y0,
    required this.sizeJit,
    required this.rot0,
    required this.spinDir,
    required this.swayPhase,
    required this.swayFreqMul,
    required this.toneIdx,
  });

  final double x0;
  final double y0;
  final double sizeJit;
  final double rot0;
  final int spinDir;
  final double swayPhase;
  final int swayFreqMul;
  final int toneIdx;
}

class _Firefly {
  _Firefly({
    required this.x0,
    required this.y0,
    required this.ampX,
    required this.ampY,
    required this.freqX,
    required this.freqY,
    required this.phaseX,
    required this.phaseY,
    required this.blinkPhase,
    required this.sizeJit,
  });

  final double x0;
  final double y0;
  final double ampX;
  final double ampY;
  final int freqX;
  final int freqY;
  final double phaseX;
  final double phaseY;
  final double blinkPhase;
  final double sizeJit;
}

class _GodRay {
  _GodRay({
    required this.topX,
    required this.slopeJit,
    required this.widthJit,
    required this.intenJit,
    required this.phase,
  });

  final double topX;
  final double slopeJit;
  final double widthJit;
  final double intenJit;
  final double phase;
}

class _SpeedLine {
  _SpeedLine({
    required this.theta,
    required this.r0,
    required this.lenJit,
    required this.phase,
    required this.alphaJit,
  });

  final double theta;
  final double r0;
  final double lenJit;
  final double phase;
  final double alphaJit;
}

// ---- v1.2 新动效粒子状态 ----

class _FogBlob {
  _FogBlob({
    required this.x0,
    required this.y0,
    required this.rx,
    required this.ry,
    required this.driftJit,
    required this.phase,
    required this.alphaJit,
  });

  final double x0;
  final double y0;
  final double rx;
  final double ry;
  final double driftJit;
  final double phase;
  final double alphaJit;
}

class _Ember {
  _Ember({
    required this.x0,
    required this.y0,
    required this.sizeJit,
    required this.swayPhase,
    required this.swayFreqMul,
    required this.blinkPhase,
    required this.alphaJit,
  });

  final double x0;
  final double y0;
  final double sizeJit;
  final double swayPhase;
  final int swayFreqMul;
  final double blinkPhase;
  final double alphaJit;
}

class _BoltSeg {
  _BoltSeg({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
  });

  final double x0;
  final double y0;
  final double x1;
  final double y1;
}

class _Star {
  _Star({
    required this.x0,
    required this.y0,
    required this.sizeJit,
    required this.blinkPhase,
    required this.brightJit,
  });

  final double x0;
  final double y0;
  final double sizeJit;
  final double blinkPhase;
  final double brightJit;
}
