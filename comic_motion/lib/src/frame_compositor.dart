import 'dart:math' as math;
import 'dart:typed_data';

import 'apng_writer.dart' show PixelRect;
import 'depth_splitter.dart';
import 'effect_config.dart';
import 'image_model.dart';
import 'motion_math.dart';
import 'render/envelope.dart';
import 'render/quality.dart';
import 'render/raster.dart';
import 'render/resampler.dart';
import 'render/waveform.dart';
import 'saliency_anchors.dart';

part 'effects/comic_pass.dart';
part 'effects/particle_raster_pass.dart';

/// Renders animated frames by compositing depth layers with per-layer parallax
/// offsets, a global breathing zoom, and optional ambient particles.
///
/// Determinism: all randomness flows from [EffectConfig.seed] through
/// [DeterministicRandom], so identical input + config => identical frames.
class FrameCompositor {
  FrameCompositor(this.layers, this.base, this.config, {AnchorMap? anchors})
      : w = base.width,
        h = base.height,
        _anchors = anchors,
        _envelope = config.effects.contains(EffectKind.moodScript)
            ? MotionEnvelope.of(config.moodScript.mood,
                strength: config.moodScript.strength,
                cycles: config.moodScript.cycles)
            : null {
    // 层视差倍率：panelAware（W5）下各格层集独立、层按格分块排布，倍率按
    // 格内 depthRank 归一（同 rank 同幅度，跨格一致）；否则沿用 v1.3 的
    // 全局序号线性插值（逐字节契约）。
    final maxRank = layers.isEmpty
        ? 0
        : layers.map((l) => l.depthRank).reduce(math.max);
    _mult = List<double>.generate(
        layers.length,
        (i) => layers.isEmpty
            ? 1.0
            : config.panelAware
                ? 0.25 +
                    0.75 *
                        layers[i].depthRank /
                        math.max(1, maxRank)
                : 0.25 + 0.75 * i / math.max(1, layers.length - 1));
    _rng = DeterministicRandom(config.seed);
    // Reference the rasters directly — they are read-only for the whole
    // animation (frames render into fresh buffers), so copying would just
    // duplicate (layerCount + 1) full-resolution buffers per job.
    _basePixels = base.data;
    _layerPixels = layers.map((l) => l.image.data).toList();
    _layerClips = layers.map((l) => l.clip).toList();
    // Task 2.3：从各层 clip 的**去重非空值**派生本格矩形集（§5 line 75 权威），
    // ≤1 格（单格/无白带/非 panelAware）时逐格路径不启用 → 播种与绘制走原逐字
    // 节路径（R9：panelAware on ≡ off）。构造期一次性静态空间数据，无时钟、
    // 不参与每帧循环，无缝/确定性不受影响。
    _computePanels();
    // Task 2.2：构造期对 activity 网格做一次 max 扫描（单个 double，无数组分配，
    // R5）。门控关时 [config.contentAware]==false → 直接返回 0，零成本、不扫描。
    _activityMax = _computeMaxActivity();
    _initParticles();
    _initNewEffects();
  }

  /// worker 路径：只凭栅格字节重建合成器，跳过解码/深度估算/切层。
  /// 底图与层必须与主 isolate 下发的栅格同尺寸，这样重建出的合成器与
  /// [FrameCompositor.new] 对同一帧产出逐字节相同的像素。
  factory FrameCompositor.fromRasters({
    required Uint8List base,
    required List<Uint8List> layers,
    required int w,
    required int h,
    required EffectConfig config,
    List<int>? ranks,
    List<PixelRect?>? clips,
    AnchorMap? anchors,
  }) {
    final ls = [
      for (var i = 0; i < layers.length; i++)
        LayerImage(RgbaImage.fromBytes(width: w, height: h, data: layers[i]),
            ranks == null ? i : ranks[i],
            clip: clips == null ? null : clips[i])
    ];
    return FrameCompositor(
        ls, RgbaImage.fromBytes(width: w, height: h, data: base), config,
        anchors: anchors);
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
  late List<List<int>> _starSamples; // 星星亮区位置表（构造期填充）
  // ---- v1.3 新动效状态 ----
  late List<_FocusWedge> _focusWedges;
  late List<_ShakeBurst> _shakeBursts;
  late List<_ShockRing> _shockRings;
  late List<_BrushStroke> _brushStreaks;
  late List<_Tongue> _tongues;
  late List<_Puff> _puffs;
  late List<_Bubble> _bubbles;
  late List<_Leaf> _leaves;
  late List<_Meteor> _meteors;

  void _initNewEffects() {
    final fx = config.effects;
    _starSamples = [];
    if (fx.contains(EffectKind.rain)) {
      final r = DeterministicRandom(config.seed ^ 0x51A1);
      final pos = DeterministicRandom(config.seed ^ 0x5601);
      final p = config.rain;
      final rn = p.count.clamp(0, 400);
      _rain = List.generate(rn, (i) {
        // 先按旧路径消费属性流两个 draw（游标与逐字节基线一致），再在内容感知
        // 开启时用位置专用流 [pos] 的拒绝采样覆盖坐标。Task 2.3：逐格路径启用时
        // 把位置约束到本格并携带 clip。
        final (x0, y0, clip) =
            _seedPlacement(i, rn, pos, r.nextDouble(), r.nextDouble());
        return _Drop(
          x0: x0,
          y0: y0,
          clip: clip,
          lenJit: 0.7 + r.nextDouble() * 0.6,
          alphaJit: 0.6 + r.nextDouble() * 0.4,
        );
      });
    } else {
      _rain = const [];
    }
    if (fx.contains(EffectKind.snow)) {
      final r = DeterministicRandom(config.seed ^ 0x51A2);
      final pos = DeterministicRandom(config.seed ^ 0x5602);
      final p = config.snow;
      final sn = p.count.clamp(0, 400);
      _snow = List.generate(sn, (i) {
        final (x0, y0, clip) =
            _seedPlacement(i, sn, pos, r.nextDouble(), r.nextDouble());
        return _SnowFlake(
          x0: x0,
          y0: y0,
          clip: clip,
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
      final pos = DeterministicRandom(config.seed ^ 0x5603);
      final p = config.sakura;
      final kn = p.count.clamp(0, 300);
      _sakura = List.generate(kn, (i) {
        final (x0, y0, clip) =
            _seedPlacement(i, kn, pos, r.nextDouble(), r.nextDouble());
        return _Petal(
          x0: x0,
          y0: y0,
          clip: clip,
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
      final pos = DeterministicRandom(config.seed ^ 0x5604);
      final p = config.fireflies;
      final fn = p.count.clamp(0, 200);
      _fireflies = List.generate(fn, (i) {
        final (x0, y0, clip) = _seedPlacement(
            i, fn, pos, 0.08 + r.nextDouble() * 0.84, 0.08 + r.nextDouble() * 0.84);
        return _Firefly(
          x0: x0,
          y0: y0,
          clip: clip,
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
      final pos = DeterministicRandom(config.seed ^ 0x5605);
      final p = config.fog;
      final bn = p.blobs.clamp(0, 40);
      _fogBlobs = List.generate(bn, (i) {
        final (x0, y0, clip) =
            _seedPlacement(i, bn, pos, r.nextDouble(), 0.15 + r.nextDouble() * 0.8);
        return _FogBlob(
          x0: x0,
          y0: y0,
          clip: clip,
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
      final pos = DeterministicRandom(config.seed ^ 0x5606);
      final p = config.embers;
      final en = p.count.clamp(0, 300);
      _embers = List.generate(en, (i) {
        final (x0, y0, clip) =
            _seedPlacement(i, en, pos, r.nextDouble(), r.nextDouble());
        return _Ember(
          x0: x0,
          y0: y0,
          clip: clip,
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
      _lightningBolts =
          List.generate(config.lightning.strikes.clamp(1, 8), (_) {
        return _genBolt(r);
      });
    } else {
      _lightningBolts = const [];
    }
    if (fx.contains(EffectKind.starlight)) {
      final r = DeterministicRandom(config.seed ^ 0x52B6);
      final p = config.starlight;
      _stars = List.generate(p.count.clamp(0, 120), (_) {
        return _Star(
          x0: 0.05 + r.nextDouble() * 0.9,
          y0: 0.05 + r.nextDouble() * 0.9,
          sizeJit: 0.7 + r.nextDouble() * 0.6,
          blinkPhase: r.nextDouble() * 2 * math.pi,
          brightJit: 0.7 + r.nextDouble() * 0.3,
        );
      });
      // 亮区表必须在构造期填好：并行渲染会乱序提交帧，首帧懒加载会让帧顺序
      // 影响状态（采样只看底图，所以构造期与首帧结果一致，但构造期最省心）。
      for (final st in _stars) {
        final sx = (st.x0 * w).clamp(0, w - 1).toInt();
        final sy = (st.y0 * h).clamp(0, h - 1).toInt();
        if (base.luminance(sy * w + sx) > 165) _starSamples.add([sx, sy]);
      }
    } else {
      _stars = const [];
    }
    // ---- v1.3 新动效状态 ----
    if (fx.contains(EffectKind.focusLines)) {
      final r = DeterministicRandom(config.seed ^ 0x53C1);
      _focusWedges = List.generate(config.focusLines.lines.clamp(4, 160), (i) {
        return _FocusWedge(
          lenJit: 0.80 + r.nextDouble() * 0.35,
          widthJit: 0.65 + r.nextDouble() * 0.9,
          alphaJit: 0.6 + r.nextDouble() * 0.4,
          // 打破等角间隔的手绘偏差，上限半格间距以免两条线交叉打架
          phaseJit: (r.nextDouble() - 0.5) * (math.pi / 40),
        );
      });
    } else {
      _focusWedges = const [];
    }
    if (fx.contains(EffectKind.mangaShake)) {
      final r = DeterministicRandom(config.seed ^ 0x53C3);
      final p = config.mangaShake;
      final n = p.shakes.clamp(1, 24);
      final jit = p.rotJitDeg.clamp(0.0, 15.0) * math.pi / 180.0;
      // 方向均分圆周 + 逐爆点抖动：抖动只在位移为 0 的爆点边界切换，
      // 所以不会在循环首尾留下不连续。
      _shakeBursts = List.generate(n, (i) {
        final theta = 2 * math.pi * i / n + (r.nextDouble() - 0.5) * 2 * jit;
        return _ShakeBurst(math.cos(theta), math.sin(theta));
      });
    } else {
      _shakeBursts = const [];
    }
    if (fx.contains(EffectKind.impactRings)) {
      final r = DeterministicRandom(config.seed ^ 0x53C4);
      final p = config.impactRings;
      _shockRings = List.generate(p.rings.clamp(1, 12), (_) {
        return _ShockRing(
          radJit: 0.94 + r.nextDouble() * 0.12,
          widthJit: 0.75 + r.nextDouble() * 0.5,
          alphaJit: 0.8 + r.nextDouble() * 0.2,
        );
      });
    } else {
      _shockRings = const [];
    }
    if (fx.contains(EffectKind.brushStreak)) {
      final r = DeterministicRandom(config.seed ^ 0x53C5);
      final p = config.brushStreak;
      _brushStreaks = List.generate(p.streaks.clamp(1, 60), (_) {
        return _BrushStroke(
          x0: 0.06 + r.nextDouble() * 0.88,
          y0: 0.06 + r.nextDouble() * 0.88,
          lenJit: 0.7 + r.nextDouble() * 0.45,
          thickJit: 0.7 + r.nextDouble() * 0.6,
          angleJit: (r.nextDouble() - 0.5) * (math.pi / 36),
          gapPhase: r.nextDouble() * 2 * math.pi,
        );
      });
    } else {
      _brushStreaks = const [];
    }
    // ---- v1.3 自然氛围状态（随机流 0x54D1..0x54D5）----
    if (fx.contains(EffectKind.flame)) {
      final r = DeterministicRandom(config.seed ^ 0x54D1);
      final p = config.flame;
      final n = p.tongues.clamp(1, 40);
      _tongues = List.generate(n, (i) {
        return _Tongue(
          // 等距铺底 + 半格内的抖动：既有节奏又不像栅栏
          x0: (i + 0.15 + r.nextDouble() * 0.7) / n,
          phase: r.nextDouble() * 2 * math.pi,
          widthJit: 0.75 + r.nextDouble() * 0.55,
          heightJit: 0.7 + r.nextDouble() * 0.6,
          lean: (r.nextDouble() - 0.5) * 0.5,
        );
      });
    } else {
      _tongues = const [];
    }
    if (fx.contains(EffectKind.smoke)) {
      final r = DeterministicRandom(config.seed ^ 0x54D2);
      final p = config.smoke;
      _puffs = List.generate(p.puffs.clamp(0, 40), (_) {
        return _Puff(
          x0: 0.12 + r.nextDouble() * 0.76,
          y0: r.nextDouble(),
          sizeJit: 0.8 + r.nextDouble() * 0.5,
          alphaJit: 0.7 + r.nextDouble() * 0.4,
          ph1: r.nextDouble() * 2 * math.pi,
          ph2: r.nextDouble() * 2 * math.pi,
          ph4: r.nextDouble() * 2 * math.pi,
        );
      });
    } else {
      _puffs = const [];
    }
    if (fx.contains(EffectKind.bubbles)) {
      final r = DeterministicRandom(config.seed ^ 0x54D3);
      final pos = DeterministicRandom(config.seed ^ 0x5607);
      final p = config.bubbles;
      final un = p.count.clamp(0, 120);
      _bubbles = List.generate(un, (i) {
        final (x0, y0, clip) = _seedPlacement(
            i, un, pos, 0.04 + r.nextDouble() * 0.92, r.nextDouble());
        return _Bubble(
          x0: x0,
          y0: y0,
          clip: clip,
          sizeJit: 0.6 + r.nextDouble() * 0.9,
          alphaJit: 0.7 + r.nextDouble() * 0.4,
          wobPhase: r.nextDouble() * 2 * math.pi,
          wobFreq: r.nextInt(2) + 1,
        );
      });
    } else {
      _bubbles = const [];
    }
    if (fx.contains(EffectKind.leaves)) {
      final r = DeterministicRandom(config.seed ^ 0x54D4);
      final pos = DeterministicRandom(config.seed ^ 0x5608);
      final p = config.leaves;
      final ln = p.count.clamp(0, 300);
      _leaves = List.generate(ln, (i) {
        final (x0, y0, clip) =
            _seedPlacement(i, ln, pos, r.nextDouble(), r.nextDouble());
        return _Leaf(
          x0: x0,
          y0: y0,
          clip: clip,
          sizeJit: 0.7 + r.nextDouble() * 0.6,
          rot0: r.nextDouble() * 2 * math.pi,
          flipPhase: r.nextDouble() * 2 * math.pi,
          swayPhase: r.nextDouble() * 2 * math.pi,
          swayFreq: r.nextDouble() < 0.5 ? 1 : 2,
          toneIdx: r.nextInt(2),
        );
      });
    } else {
      _leaves = const [];
    }
    if (fx.contains(EffectKind.meteors)) {
      final r = DeterministicRandom(config.seed ^ 0x54D5);
      final pos = DeterministicRandom(config.seed ^ 0x5609);
      final p = config.meteors;
      final mn = p.count.clamp(1, 20);
      _meteors = List.generate(mn, (i) {
        final (x0, y0, clip) = _seedPlacement(
            i, mn, pos, 0.1 + r.nextDouble() * 0.8, 0.05 + r.nextDouble() * 0.55);
        return _Meteor(
          x0: x0,
          y0: y0,
          clip: clip,
          lenJit: 0.7 + r.nextDouble() * 0.7,
          alphaJit: 0.75 + r.nextDouble() * 0.25,
          thick: 1.2 + r.nextDouble() * 1.4,
        );
      });
    } else {
      _meteors = const [];
    }
  }

  /// 震屏本帧位移（像素）。每个爆点内做 [_shakeRattle] 次完整往返，
  /// 幅度按 `(1-ph)^(2·decay)` 衰减 → 起手最猛、收尾归零。
  (double, double) _shakeOffset(double tSec) {
    final bursts = _shakeBursts;
    if (bursts.isEmpty) return (0.0, 0.0);
    final p = config.mangaShake;
    final u = _loopU(tSec);
    final pos = u * bursts.length;
    final k = pos.floor().clamp(0, bursts.length - 1);
    final ph = pos - k;
    final env = math.pow(1.0 - ph, p.decay.clamp(0.05, 3.0) * 2).toDouble();
    // Task 3.4（§6.2/R17）：standard+ 用 snapWave 张力波替换正弦载体。θ =
    // 2π·_shakeRattle·pos，折成 u = θ/2π = _shakeRattle·pos（频率与相位逐字
    // 保持，3·shakes 整数周期 ⇒ 循环仍闭合）。legacy 分支冻结为原 sin 表达式。
    final osc =
        _aa ? snapWave(_shakeRattle * pos) : math.sin(2 * math.pi * _shakeRattle * pos);
    final amp = p.amplitude.clamp(0.0, 0.12) * w * env * osc;
    final b = bursts[k];
    return (b.dirX * amp, b.dirY * amp);
  }

  /// 每个爆点内的高频 rattles 次数；必须是整数，否则循环有接缝。
  static const int _shakeRattle = 3;

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

  /// 交互式视差覆盖（第四轮 V1）：非 null 时，parallax 层位移不再由时间相位
  /// 驱动，而由这里直接指定的归一化偏移决定（水平 `dx = amplitude · phaseX ·
  /// w · 层倍率`，垂直 `dy = amplitude · phaseY · verticalRatio · w · 层倍率`，
  /// phase ∈ [-1, 1]，0 = 无位移）。其余效果全部冻结在 t=0 参考相位——
  /// 调用方以 `renderFrame(0)` 渲染交互帧。默认 null：时间驱动路径与
  /// v1.3 逐字节一致（legacy 契约不受影响）。
  ParallaxOverride? parallaxOverride;

  final int w;
  final int h;

  /// standard+ 档才走 AA 光栅原语；legacy 分支逐字保留 v1.2 的取整画点。
  bool get _aa => config.quality.tier.atLeastStandard;

  /// Task 2.4（spec §5 治白叠白）：极性自适应画笔。
  ///
  /// 只在 standard+ 档惰性构造一次（legacy 恒 null ⇒ 所有旧路径逐字节不变），
  /// 采样对象是**静态底图** `base`，无数组分配（R5 同口径：合成器会被每个
  /// worker job 重建）。因为输入只有像素坐标，输出就是纯函数：不消耗 RNG、
  /// 没有跨帧状态，确定性与无缝循环不受影响（R12）。
  PolarityBrush? get _polarity {
    if (!_aa) return null;
    return _polarityBrush ??= PolarityBrush(base);
  }

  PolarityBrush? _polarityBrush;

  /// v1.3 情绪包络：未启用 moodScript 时为 null，[_env] 恒为 identity
  /// （乘 1.0 / 加 0.0 都不改变任何一位浮点结果，legacy 路径逐字节不变）。
  final MotionEnvelope? _envelope;

  /// Task 1.5（plumb-only）：内容感知分析结果，null = 未启用/未提供。
  /// 本任务只把它随合成器（含 worker 重建的合成器）携带到位；渲染路径在
  /// Task 2.1+ 之前**绝不读取**它，因此 on/off 产物逐字节相同。下游放置
  /// 任务经 [anchors] 只读访问。坐标口径见 `AnchorMap`（grid/canvas）。
  final AnchorMap? _anchors;

  /// 只读暴露本合成器携带的 AnchorMap（无则为 null）。供 Task 2.1+ 的
  /// 效果放置消费。
  AnchorMap? get anchors => _anchors;

  // ---- Task 2.2：内容感知粒子落位（activity 加权播种）----
  //
  // 规格 §A（权威）+ 控制裁决 R5/R6 覆盖 brief：
  //  * R5：用**拒绝采样**（O(count×常数)），绝不建 CDF/前缀和数组——合成器会
  //    在每个 worker job 经 `fromRasters` 重建，O(pixels) 数组会被逐 worker 重分配。
  //    构造期只对 activity 网格做**一次**扫描求 `maxAct`（单个 double，无数组分配）；
  //    逐粒子按 `q <= activity[cell]/maxAct` 接受，密度∝activity。
  //  * R6：仅以 `config.contentAware` 单一门控（不看 tier.atLeastStandard）。
  //    R36（Task 3.6b）复核维持：落位（WHERE）与渲染档（WHICH pixel algorithm）
  //    正交，本次只把 contentAware 的**默认值**翻到 true，门控本身一字不动。
  //  * 空白/平坦（maxAct≈0）/ map 为 null / 门控关 → 回落原均匀 draw（等价旧行为）。
  // 位置采样来自每效果**新增的独立流**，绝不触碰该效果的属性流（sizeJit/alphaJit/…）
  // 与既有 0x51A*/0x52B*/0x53C*/0x54D*/0x54E1 流，故 contentAware=false 逐字节不变
  // （3.6b 起 false 是显式回滚档而非默认档：该等价陈述只约束 off 路径本身）。

  /// 构造期单次扫描 activity 网格得到的最大值（无数组分配）。门控关/无 map 时为 0。
  late final double _activityMax;

  /// 落位加权是否生效：R6 单一门控 `contentAware && anchors != null` 且
  /// 网格可用、`maxAct > 1e-6`（否则无主体 → 等价旧均匀分布）。
  bool get _particleWeightingActive {
    final map = _anchors;
    return config.contentAware &&
        map != null &&
        map.width >= 2 &&
        map.height >= 2 &&
        map.activity.length >= map.width * map.height &&
        _activityMax > 1e-6;
  }

  double _computeMaxActivity() {
    final map = _anchors;
    if (map == null || !config.contentAware) return 0.0;
    final act = map.activity;
    final aw = map.width, ah = map.height;
    if (aw < 2 || ah < 2) return 0.0;
    final limit = act.length < aw * ah ? act.length : aw * ah;
    var mx = 0.0;
    for (var i = 0; i < limit; i++) {
      final v = act[i];
      if (v > mx) mx = v;
    }
    return mx;
  }

  /// 为一个粒子播种归一化位置 `(x0,y0)`。
  ///
  /// [uniformX]/[uniformY] 是调用方**已按旧路径**从该效果属性流取好的均匀位置——
  /// 无论加权与否都会被消费，以确保属性流游标与逐字节基线完全一致（Design B）。
  /// 门控未生效时原样返回这两个均匀值（旧行为）；生效时忽略它们，改从该效果
  /// 位置专用流 [pos] 做有界拒绝采样（密度∝activity），绝不触碰属性流。
  (double, double) _seedPosition(
      DeterministicRandom pos, double uniformX, double uniformY) {
    if (!_particleWeightingActive) return (uniformX, uniformY);
    final map = _anchors!;
    final aw = map.width, ah = map.height;
    final act = map.activity;
    final inv = 1.0 / _activityMax;
    var gx = 0, gy = 0;
    for (var tries = 0; tries < 16; tries++) {
      gx = (pos.nextDouble() * aw).floor();
      if (gx >= aw) gx = aw - 1;
      gy = (pos.nextDouble() * ah).floor();
      if (gy >= ah) gy = ah - 1;
      if (pos.nextDouble() <= act[gy * aw + gx] * inv) break; // 接受该 cell
    }
    // 命中重试上限则取最后一次候选；cell → 归一化中心 + cell 内亚像素抖动铺满 [0,1)。
    final x0 = ((gx + pos.nextDouble()) / aw).clamp(0.0, 1.0);
    final y0 = ((gy + pos.nextDouble()) / ah).clamp(0.0, 1.0);
    return (x0, y0);
  }

  /// 测试访问器（Task 2.2，非公共契约）：返回某粒子效果在构造期播种的归一化
  /// 初始位置 `(x0,y0)` 列表，用于断言落位分布与数量。仅覆盖内容感知加权涉及的
  /// 粒子族；其余返回空表。
  List<(double, double)> debugParticleSeeds(EffectKind kind) {
    switch (kind) {
      case EffectKind.rain:
        return [for (final d in _rain) (d.x0, d.y0)];
      case EffectKind.snow:
        return [for (final f in _snow) (f.x0, f.y0)];
      case EffectKind.sakura:
        return [for (final t in _sakura) (t.x0, t.y0)];
      case EffectKind.fireflies:
        return [for (final f in _fireflies) (f.x0, f.y0)];
      case EffectKind.fog:
        return [for (final b in _fogBlobs) (b.x0, b.y0)];
      case EffectKind.embers:
        return [for (final e in _embers) (e.x0, e.y0)];
      case EffectKind.bubbles:
        return [for (final b in _bubbles) (b.x0, b.y0)];
      case EffectKind.leaves:
        return [for (final l in _leaves) (l.x0, l.y0)];
      case EffectKind.meteors:
        return [for (final m in _meteors) (m.x0, m.y0)];
      case EffectKind.ambient:
        return [for (final p in _particles) (p.px, p.py)];
      default:
        return const [];
    }
  }

  // ---- Task 2.1：内容感知焦点解析（规格 §A：焦点取 anchors.first，显式非默认 focal 覆盖）----
  ({double fx, double fy}) _contentAwareFocal({
    required double paramFx,
    required double paramFy,
    required double defaultFx,
    required double defaultFy,
  }) {
    final map = _anchors;
    final a = map?.anchors;
    final callerPinned =
        (paramFx != defaultFx) || (paramFy != defaultFy); // 与规范默认值精确比较
    if (config.contentAware &&
        map != null &&
        !callerPinned &&
        a != null &&
        a.isNotEmpty) {
      return (fx: a.first.nx, fy: a.first.ny); // 权重最高 anchor（已降序）
    }
    return (fx: paramFx, fy: paramFy); // 显式或默认 → 旧行为
  }

  /// focusLines 生效焦点（归一化）。
  ({double fx, double fy}) _focusLinesFocal() {
    final p = config.focusLines;
    return _contentAwareFocal(
      paramFx: p.focalX,
      paramFy: p.focalY,
      defaultFx: const FocusLinesParams().focalX,
      defaultFy: const FocusLinesParams().focalY,
    );
  }

  /// impactRings 生效焦点（归一化）。
  ({double fx, double fy}) _impactRingsFocal() {
    final p = config.impactRings;
    return _contentAwareFocal(
      paramFx: p.focalX,
      paramFy: p.focalY,
      defaultFx: const ImpactRingsParams().focalX,
      defaultFy: const ImpactRingsParams().focalY,
    );
  }

  /// 本帧生效的包络因子，由 [renderFrame] 在入口处刷新一次。
  EnvelopeFactors _env = EnvelopeFactors.identity;

  late List<double> _mult;
  late DeterministicRandom _rng;
  late List<_Particle> _particles;
  late List<Uint8List>
      _layerPixels; // per-layer cached raster (no per-frame copy)
  late List<PixelRect?> _layerClips; // W5 分格裁剪（null = 全画布）
  late Uint8List _basePixels;

  // ---- Task 2.3：分格叠加裁剪 + 逐格播种 ----
  //
  // 规格 §5 line 75（权威）：panelAware 下叠加 pass 逐格播种 + 用本格 clip 裁剪。
  // 裁决 R7：clip 是**新增**的可选原语参数（`_blendPx`/`_drawSoftDisc`/AA 段路径/
  //   blendPixel），**不是**复用 `_layerClips`（后者只作用于层重采样，从不经手粒子）。
  // 裁决 R8：门控 = `config.panelAware`（不看 contentAware）——两轴正交。
  // 裁决 R9：本格矩形集来自 `_layerClips` 的去重非空值；≤1 个 → 逐格路径关闭，
  //   播种/绘制原样走全画布路径，故单格/无白带图 panelAware on ≡ off 逐字节等。
  /// 去重后的本格画布矩形（首次出现序）；非 panelAware / 单格时可为空或单元素。
  List<PixelRect> _panelRects = const [];
  /// 逐格播种 + 裁剪是否启用（panelAware 且派生格数 ≥2）。
  bool _perPanelActive = false;
  /// 按粒子总数缓存的面积∝数量切分（纯函数：total + 本格面积 → 各格计数）。
  final Map<int, List<int>> _splitCache = {};

  void _computePanels() {
    if (!config.panelAware) {
      _panelRects = const [];
      _perPanelActive = false;
      return;
    }
    // 去重：同格 3 层共享同一 PixelRect；用值键去重（PixelRect 无 ==）。
    final seen = <String>{};
    final rects = <PixelRect>[];
    for (final c in _layerClips) {
      if (c == null) continue;
      final key = '${c.x},${c.y},${c.width},${c.height}';
      if (seen.add(key)) rects.add(c);
    }
    _panelRects = rects;
    _perPanelActive = rects.length >= 2;
  }

  /// 面积∝数量把 [total] 切到各本格：per = floor(area_share·total)，
  /// 确定性余数（total − Σ floors）全给面积最大的格（并列取首个）。纯函数。
  List<int> _splitFor(int total) {
    final cached = _splitCache[total];
    if (cached != null) return cached;
    final n = _panelRects.length;
    final counts = List<int>.filled(n, 0);
    if (n == 0 || total <= 0) {
      _splitCache[total] = counts;
      return counts;
    }
    final areas = [for (final p in _panelRects) p.width * p.height];
    var totalArea = 0;
    for (final a in areas) {
      totalArea += a;
    }
    if (totalArea <= 0) {
      // 退化（零面积格）：均匀切，余数给最后一格。
      final base = total ~/ n;
      for (var i = 0; i < n; i++) {
        counts[i] = base;
      }
      counts[n - 1] += total - base * n;
      _splitCache[total] = counts;
      return counts;
    }
    var assigned = 0;
    for (var i = 0; i < n; i++) {
      final c = (total * areas[i] / totalArea).floor();
      counts[i] = c;
      assigned += c;
    }
    // 余数给面积最大的格（并列取最小下标 → 确定性）。
    var largest = 0;
    for (var i = 1; i < n; i++) {
      if (areas[i] > areas[largest]) largest = i;
    }
    counts[largest] += total - assigned;
    _splitCache[total] = counts;
    return counts;
  }

  /// 粒子序号 [index]（0..total）落在哪个本格：按 [counts] 的累计区间。
  int _panelIndexFor(int index, List<int> counts) {
    var acc = 0;
    for (var i = 0; i < counts.length; i++) {
      acc += counts[i];
      if (index < acc) return i;
    }
    return counts.length - 1;
  }

  /// 为一个粒子播种归一化位置并给出所属本格裁剪矩形。
  ///
  /// 逐格路径**未**启用时返回 `_seedPosition` 的全画布结果 + null clip（等价旧
  /// 行为，逐字节不变）；启用时把该 [total] 序号映射到本格，并把全画布归一基准
  /// 位置线性重映射进本格归一矩形（`x0 = panelNx + base·panelNW`）——RNG 消费
  /// 序列与旧路径完全一致（仍调用一次 `_seedPosition`），仅位置落点约束到本格。
  (double, double, PixelRect?) _seedPlacement(
      int index, int total, DeterministicRandom pos, double uniformX, double uniformY) {
    final base = _seedPosition(pos, uniformX, uniformY);
    if (!_perPanelActive) return (base.$1, base.$2, null);
    final counts = _splitFor(total);
    final panel = _panelRects[_panelIndexFor(index, counts)];
    final nx = panel.x / w, ny = panel.y / h;
    final nw = panel.width / w, nh = panel.height / h;
    final x0 = (nx + base.$1 * nw).clamp(0.0, 1.0);
    final y0 = (ny + base.$2 * nh).clamp(0.0, 1.0);
    return (x0, y0, panel);
  }

  /// 测试访问器（Task 2.3，非公共契约）：返回构造期派生的本格画布矩形集。
  /// 未启用逐格路径（非 panelAware / 单格）时为空或单元素列表。
  List<PixelRect> debugPanelRects() => _panelRects;

  /// 测试访问器（Task 2.3，非公共契约）：按面积∝数量把 [total] 切到各本格，
  /// 返回各格计数列表（与 `_panelRects` 同序）。逐格路径未启用时返回空表。
  List<int> debugPerPanelCounts(int total) =>
      _perPanelActive ? List<int>.from(_splitFor(total)) : const [];

  void _initParticles() {
    _particles = [];
    if (!config.effects.contains(EffectKind.ambient)) return;
    final amb = config.ambient;
    final pos = DeterministicRandom(config.seed ^ 0x5600);
    final an = amb.particleCount;
    for (var i = 0; i < an; i++) {
      final (px, py, clip) =
          _seedPlacement(i, an, pos, _rng.nextDouble(), _rng.nextDouble());
      _particles.add(_Particle(
        px: px,
        py: py,
        clip: clip,
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
    final tier = config.quality.tier;
    // 情绪包络每帧只取一次因子，后面各 pass 直接读 [_env]。
    final envelope = _envelope;
    _env =
        envelope == null ? EnvelopeFactors.identity : envelope.at(_loopU(tSec));
    final dirRad = config.parallax.directionDeg * math.pi / 180.0;
    final dxDir = math.cos(dirRad);
    final dyDir = math.sin(dirRad);

    // Global breathing zoom around the anchor.
    var zoom = 1.0;
    if (config.effects.contains(EffectKind.breathing) &&
        config.breathing.enabled) {
      zoom = 1.0 +
          config.breathing.amplitude *
              _env.motion *
              MotionMath.wave(tSec,
                  periodSec: MotionMath.alignedPeriodSec(
                      config.durationSec, config.breathing.periodSec),
                  phase: 0);
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
          _anchorY(), tier);
      return frame;
    }

    // v1.3 震屏：整体平移底图与层（减弱动态分支已在上面 return，不受影响）。
    var shakeX = 0.0, shakeY = 0.0;
    if (config.effects.contains(EffectKind.mangaShake)) {
      final s = _shakeOffset(tSec);
      shakeX = s.$1;
      shakeY = s.$2;
    }

    // Base with breathing zoom only.
    // 平移会露出画布外的空白，所以底图也按位移量略微放大覆盖（无抖时系数
    // 恰为 1.0，legacy 路径逐字节不变）。
    final baseCover =
        1.0 + (shakeX.abs() + shakeY.abs()) * 2.0 / math.min(w, h);
    _drawLayer(frame, _basePixels, base.width, base.height, shakeX, shakeY,
        zoom * baseCover, _anchorY(), tier);

    // Layers far-to-near with parallax offsets.
    final p = config.effects.contains(EffectKind.parallax);
    final pOverride = parallaxOverride;
    // R18/R19 的单一真值：整周期数与对齐周期只在层循环外算一次（两值都只依赖
    // config，与 li 无关）。竖向基底在下面复用同一个 `cycles`，避免同一量出现
    // 两个来源（3.6/3.7 不能再各自算一遍）。`alignedPeriod` 仍是一次
    // `durationSec / cycleCount(...)`，与 alignedPeriodSec 的浮点运算逐位相同。
    final cycles = MotionMath.cycleCount(
        config.durationSec, config.parallax.periodSec);
    final alignedPeriod = config.durationSec / cycles;
    for (var li = 0; li < layers.length; li++) {
      var dx = shakeX, dy = shakeY;
      if (p) {
        if (pOverride != null) {
          // 交互式视差（第四轮 V1）：层位移直接由调用方指定，替代时间驱动的
          // 视差相位。不乘 _env.motion——情绪包络属于时间域，交互帧冻结在
          // 参考相位（renderFrame(0) 语义）。phase=0 时两项均为精确 0.0，
          // 与「无 parallax 效果」的层位移逐位一致（测试锁定）。
          final ampPx = config.parallax.amplitude * w * _mult[li];
          dx += ampPx * pOverride.phaseX;
          dy += ampPx * config.parallax.verticalRatio * pOverride.phaseY;
        } else {
          final ampPx = config.parallax.amplitude * _env.motion * w * _mult[li];
          final phase = 2 * math.pi * tSec / alignedPeriod;
          // v1.4 硬张力（规格 §6.1）：相邻深度层反相（相位步进 li·π），
          // 奇数层与偶数层反向摆动，相邻层相对位移翻倍且肉眼可见；
          // 旧 li*0.35 同向微差在摆幅内互相对销，看不出纵深。
          // Task 3.4（§6.2/R17）：standard+ 载体换成 snapWave，θ/(2π) 折算
          // 保持 3.2 的 li·π 反相步进（奇数层 u+0.5 → 反瓣）；legacy 分支
          // 冻结为原 sin 表达式。多幅度项（ampPx/dxDir/verticalRatio/dyDir）不动。
          final snapDx = _aa
              ? snapWave((phase + li * math.pi) / (2 * math.pi))
              : math.sin(phase + li * math.pi);
          // R19：竖向基底频率用整数 cycleCount 替代非整 0.8 倍率，
          // 保证 dyCycles 整周期闭合（directionDeg≠0/180 时竖向不再跳缝）。
          // cycles 取自循环外的单一真值（见上），此处只做 0.8 倍率取整。
          final dyCycles = math.max(1, (cycles * 0.8).round());
          final dyPhase =
              2 * math.pi * tSec * dyCycles / config.durationSec;
          final snapDy = _aa
              ? snapWave((dyPhase + li * math.pi + 0.9) / (2 * math.pi))
              : math.sin(dyPhase + li * math.pi + 0.9);
          dx += snapDx * ampPx * dxDir;
          dy += snapDy * ampPx * config.parallax.verticalRatio * dyDir;
        }
      }
      // Scale slightly beyond 1 so shifted layers still cover the canvas.
      final cover = 1.0 + 2 * (dx.abs() + dy.abs()) / math.min(w, h);
      _drawLayer(frame, _layerPixels[li], layers[li].image.width,
          layers[li].image.height, dx, dy, zoom * cover, _anchorY(), tier,
          clip: _layerClips[li]);
    }

    if (config.effects.contains(EffectKind.ambient) && config.ambient.enabled) {
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
    // ---- v1.3 自然氛围渲染（氛围层在漫画叠加层之前）----
    if (config.effects.contains(EffectKind.flame)) {
      _renderFlame(this, frame, tSec);
    }
    if (config.effects.contains(EffectKind.smoke)) {
      _renderSmoke(this, frame, tSec);
    }
    if (config.effects.contains(EffectKind.bubbles)) {
      _renderBubbles(this, frame, tSec);
    }
    if (config.effects.contains(EffectKind.leaves)) {
      _renderLeaves(this, frame, tSec);
    }
    if (config.effects.contains(EffectKind.meteors)) {
      _renderMeteors(this, frame, tSec);
    }
    // ---- v1.3 漫画动势渲染 ----
    if (config.effects.contains(EffectKind.screenTone)) {
      _renderScreenTone(this, frame, tSec);
    }
    if (config.effects.contains(EffectKind.focusLines)) {
      _renderFocusLines(this, frame, tSec);
    }
    if (config.effects.contains(EffectKind.impactRings)) {
      _renderImpactRings(this, frame, tSec);
    }
    if (config.effects.contains(EffectKind.brushStreak)) {
      _renderBrushStreak(this, frame, tSec);
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

  /// 层贴图：重采样按质量档分派（legacy=逐字节双线性，standard+=Catmull-Rom），
  /// 实现见 `render/resampler.dart`。
  static void _drawLayer(
          RgbaImage dst,
          Uint8List srcData,
          int sw,
          int sh,
          double dx,
          double dy,
          double scale,
          double anchorY,
          RenderTier tier,
          {PixelRect? clip}) =>
      drawLayer(dst, srcData, sw, sh, dx, dy, scale, anchorY,
          tier: tier, clip: clip);

  void _drawParticles(RgbaImage frame, double tSec) {
    final amb = config.ambient;
    final speedPx = amb.speed * tSec / math.max(1, config.durationSec);
    for (final p in _particles) {
      // Slow upward drift + gentle horizontal sway, wrapping vertically.
      var py = (p.py - (speedPx / h) * p.drift) % 1.0;
      if (py < 0) py += 1.0;
      final px = (p.px + 0.01 * math.sin(tSec + p.phase)) % 1.0;
      final cx = px * w, cy = py * h;
      final clip = p.clip;
      final alpha =
          (amb.opacity * _env.particles * p.alpha * 255).round().clamp(0, 255);
      final rad = p.r;
      final x0 = (cx - rad).floor(), x1 = (cx + rad).ceil();
      final y0 = (cy - rad).floor(), y1 = (cy + rad).ceil();
      for (var y = y0; y <= y1; y++) {
        if (y < 0 || y >= h) continue;
        if (clip != null && (y < clip.y || y >= clip.y + clip.height)) continue;
        for (var x = x0; x <= x1; x++) {
          if (x < 0 || x >= w) continue;
          // Task 2.3（R7）：ambient 直写 frame.data（不经 _blendPx），故在此手动
          // 裁剪本格矩形；clip==null 时条件恒 false → 逐字节旧行为。
          if (clip != null &&
              (x < clip.x || x >= clip.x + clip.width)) continue;
          final dist = math.sqrt((x + 0.5 - cx) * (x + 0.5 - cx) +
              (y + 0.5 - cy) * (y + 0.5 - cy));
          if (dist > rad) continue;
          final fall = 1 - dist / rad;
          final a = (alpha * fall).round().clamp(0, 255);
          final o = (y * w + x) * 4;
          final bright = amb.mode == 'sparkle' ? 255 : 245;
          frame.data[o] = ((bright * a) + frame.data[o] * (255 - a)) ~/ 255;
          frame.data[o + 1] =
              ((bright * a) + frame.data[o + 1] * (255 - a)) ~/ 255;
          frame.data[o + 2] =
              ((bright * a) + frame.data[o + 2] * (255 - a)) ~/ 255;
        }
      }
    }
  }

  /// 扫光：斜向掠过的柔光带。
  ///
  /// legacy 档保持 v1.2 的截断加法白光；standard+ 档（Task 2.4）按带内每点
  /// 底图亮度选极性——白纸用 [BlendOp.multiply] 压出灰调光带（白叠白等于没画），
  /// 暗区沿用 `_blendAddPx` 的 screen 爆白。
  void _applyLightSweep(RgbaImage frame, double tSec) {
    final prog = (tSec / config.durationSec) % 1.0;
    final bandCenter = (prog * (w + h * 0.7)) - h * 0.35;
    final brush = _polarity; // legacy 档为 null ⇒ 逐字节走 v1.2 的加法白光
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final d = (x + y * 0.35 - bandCenter).abs();
        if (d > 80) continue;
        var add =
            (60 * _env.exposure * math.exp(-d * d / (2 * 30 * 30))).round();
        if (add == 0) continue;
        if (brush == null) {
          _blendAddPx(frame, x, y, 255, 255, 255, add);
          continue;
        }
        final lum = brush.lumaAt(x, y);
        if (PolarityBrush.midLuma(lum)) add = PolarityBrush.bump(add);
        if (samplePolarity(lum) == Polarity.toInk) {
          blendPixel(frame, x, y, brush.inkR, brush.inkG, brush.inkB, add,
              op: BlendOp.multiply);
        } else {
          _blendAddPx(frame, x, y, 255, 255, 255, add);
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

  void _blendPx(RgbaImage f, int x, int y, int r, int g, int b, int a,
      {PixelRect? clip}) {
    if (a <= 0 || x < 0 || y < 0 || x >= w || y >= h) return;
    // Task 2.3（R7）：分格裁剪。null clip ⇒ 逐字节旧行为（越界检查不变）。
    if (clip != null &&
        (x < clip.x ||
            x >= clip.x + clip.width ||
            y < clip.y ||
            y >= clip.y + clip.height)) return;
    if (a > 255) a = 255;
    final o = (y * w + x) * 4;
    final inv = 255 - a;
    f.data[o] = (r * a + f.data[o] * inv) ~/ 255;
    f.data[o + 1] = (g * a + f.data[o + 1] * inv) ~/ 255;
    f.data[o + 2] = (b * a + f.data[o + 2] * inv) ~/ 255;
  }

  /// 光效提亮。legacy 档逐字沿用 v1.2 的截断加法；standard+ 改走 screen，
  /// 近白高光不再一起撞死在 255（Q5）。r=g=b=255 时 additive 分支等价于
  /// v1.2 内联写的 `min(255, d + add)`，所以扫光这类纯白光可直接复用本函数。
  void _blendAddPx(RgbaImage f, int x, int y, int r, int g, int b, int add,
          {PixelRect? clip}) =>
      blendPixel(f, x, y, r, g, b, add,
          op: _aa ? BlendOp.screen : BlendOp.additive, clip: clip);

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
      final clip = d.clip;
      final a =
          (p.opacity * _env.particles * d.alphaJit * 255).round().clamp(0, 255);
      final steps = (len * d.lenJit).round().clamp(2, 220);
      if (_aa) {
        drawSegmentAA(
            frame, px, py, px + dx * steps, py + dy * steps, r0, g0, b0, a, 1.0,
            tailFade: 0.6, clip: clip);
        continue;
      }
      for (var s = 0; s < steps; s++) {
        final fade = 1 - 0.6 * s / steps;
        _blendPx(frame, (px + dx * s).round(), (py + dy * s).round(), r0, g0,
            b0, (a * fade).round(),
            clip: clip);
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
              p.swayPx * math.sin(w2pi * (f.swayFreqMul * u) + f.swayPhase)) %
          w;
      final rad = (p.sizePx * f.sizeJit).clamp(0.8, 12.0);
      final twk = 0.78 + 0.22 * math.sin(w2pi * u * 2 + f.twkPhase);
      final a = (p.opacity * _env.particles * twk * 255).round().clamp(0, 255);
      _drawSoftDisc(frame, px, py, rad, 250, 252, 255, a, clip: f.clip);
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
      final a = (p.opacity * _env.particles * 255).round().clamp(0, 255);
      final ca = math.cos(rot), sa = math.sin(rot);
      for (var s = -half; s <= half; s++) {
        final cxp = px + ca * s;
        final cyp = py + sa * s;
        final width = half * 0.55 * (1 - (s.abs() / half) * 0.55);
        for (var t2 = -width; t2 <= width; t2 += 1.0) {
          _blendPx(frame, (cxp - sa * t2).round(), (cyp + ca * t2).round(), rr,
              gg, bb, a,
              clip: t.clip);
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
      final px =
          (f.x0 + f.ampX * math.sin(w2pi * (drift * f.freqX * u) + f.phaseX)) *
              w;
      final py =
          (f.y0 + f.ampY * math.cos(w2pi * (drift * f.freqY * u) + f.phaseY)) *
              h;
      final blinkV = 0.30 +
          0.70 *
              math.pow(
                  0.5 + 0.5 * math.sin(w2pi * blink * u + f.blinkPhase), 2.0);
      final rad = (p.glowPx * f.sizeJit).clamp(3.0, 80.0);
      final aBase =
          (p.opacity * _env.particles * blinkV * 255).round().clamp(0, 255);
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
          _blendAddPx(frame, x, y, r0, g0, b0, add, clip: f.clip);
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
      final ang = p.angleDeg + 4.0 * math.sin(w2pi * sway * u + ray.phase);
      final tanA = math.tan(ang * math.pi / 180.0);
      final sigma = (p.widthFrac * w * ray.widthJit).clamp(8.0, w * 0.3);
      final inten = (p.intensity *
              _env.exposure *
              ray.intenJit *
              (0.8 + 0.2 * math.sin(w2pi * u + ray.phase)))
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
      // Task 3.4（§6.2/R17）：脉冲载体 standard+ 走 snapWave。θ =
      // w2pi·(pulses·u + l.phase) 折成 u' = pulses·u + l.phase（l.phase 是
      // RNG 出的 [0,2π) 弧度，留在括号内原样使用）；max(0,·) 半波整流与
      // pow(·,3) 成形保持不动，legacy 分支的 sin 逐字节冻结。
      final pulse = math.pow(
          math.max(
              0.0,
              _aa
                  ? snapWave(pulses * u + l.phase)
                  : math.sin(w2pi * (pulses * u + l.phase))),
          3.0).toDouble();
      if (pulse <= 0.02) continue;
      final a = (p.intensity * pulse * l.alphaJit * 255).round().clamp(0, 255);
      final ux = math.cos(l.theta), uy = math.sin(l.theta);
      final sx = cx + ux * diag * l.r0;
      final sy = cy + uy * diag * l.r0;
      final steps = (len * l.lenJit).round().clamp(2, 400);
      if (_aa) {
        // Task 2.4：几何与 alpha 链路一字未改，只把「白色 source-over」换成
        // 逐像素极性（白纸压墨 #1a1a1a/darken、暗区爆白 white/screen）。
        drawSegmentAA(frame, sx, sy, sx - ux * steps, sy - uy * steps, 255, 255,
            255, a, p.thickness < 1 ? 1.0 : p.thickness.toDouble(),
            polarity: _polarity);
        continue;
      }
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
  ///
  /// legacy 档保留 v1.2 的「整体推向白」；standard+ 档改判为**双向对比冲击**
  /// （Task 2.4 / spec §5）：同一包络 `k` 下，白纸压向黑、暗区爆向白，白纸上
  /// 不再出现 no-op。极性只读静态底图，与帧序、RNG 无关。
  void _applyImpactFlash(RgbaImage frame, double tSec) {
    final p = config.impactFlash;
    final u = _loopU(tSec);
    final flashes = p.flashes.clamp(1, 12);
    final duty = p.dutyFrac.clamp(0.02, 0.5);
    final phase = (u * flashes) % 1.0;
    if (phase >= duty) return; // 大多数帧直接跳过
    final env = math.sin(math.pi * phase / duty); // 0→1→0
    final k = (env * p.intensity * _env.exposure * 256).round().clamp(0, 256);
    if (k <= 0) return;
    final data = frame.data;
    if (!_aa) {
      for (var i = 0; i < data.length; i += 4) {
        data[i] = data[i] + ((255 - data[i]) * k >> 8);
        data[i + 1] = data[i + 1] + ((255 - data[i + 1]) * k >> 8);
        data[i + 2] = data[i + 2] + ((255 - data[i + 2]) * k >> 8);
      }
      return;
    }
    // 底图与 frame 同尺寸（合成器按 base 宽高建帧），像素索引 1:1 对应。
    for (var i = 0, pi = 0; i < data.length; i += 4, pi++) {
      final lum = base.luminance(pi);
      // 中段亮度两档极性都不痛，按 spec §5 放大幅度（离散 bump，非连续 lerp；
      // bump 自带 256 上限，否则 `d + (255-d)·k/256` 会溢出成回绕的负值）。
      final kk = PolarityBrush.midLuma(lum) ? PolarityBrush.bump(k) : k;
      if (samplePolarity(lum) == Polarity.toInk) {
        data[i] = data[i] - ((data[i] * kk) >> 8);
        data[i + 1] = data[i + 1] - ((data[i + 1] * kk) >> 8);
        data[i + 2] = data[i + 2] - ((data[i + 2] * kk) >> 8);
      } else {
        data[i] = data[i] + ((255 - data[i]) * kk >> 8);
        data[i + 1] = data[i + 1] + ((255 - data[i + 1]) * kk >> 8);
        data[i + 2] = data[i + 2] + ((255 - data[i + 2]) * kk >> 8);
      }
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
    return 1.0 + p.intensity.clamp(0.0, 0.10) * beat;
  }

  /// 缓慢推镜：每循环 pushFrac 的推近-拉回（往返整数周期保证无缝）。
  double _slowPushZoom(double tSec) {
    final p = config.slowPush;
    final u = _loopU(tSec);
    final cyc = p.cycles.clamp(1, 4);
    final wv = math.sin(2 * math.pi * cyc * u - math.pi / 2); // -1→1→-1
    return 1.0 + p.pushFrac.clamp(0.002, 0.15) * (wv * 0.5 + 0.5); // 0→1→0
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
      final aBase =
          (p.opacity * _env.particles * b.alphaJit * 255).round().clamp(0, 255);
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
          _blendPx(frame, x, y, r0, g0, b0, a, clip: b.clip);
          _blendPx(frame, x + 1, y, r0, g0, b0, a, clip: b.clip);
          _blendPx(frame, x, y + 1, r0, g0, b0, a, clip: b.clip);
          _blendPx(frame, x + 1, y + 1, r0, g0, b0, a, clip: b.clip);
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
      final px =
          (e.x0 * w + 12 * math.sin(w2pi * (e.swayFreqMul * u) + e.swayPhase)) %
              w;
      final blink = 0.45 +
          0.55 *
              math.pow(0.5 + 0.5 * math.sin(w2pi * u * 3 + e.blinkPhase), 2.0);
      final rad = (p.glowPx * e.sizeJit).clamp(1.2, 20.0);
      final a = (p.opacity * _env.particles * e.alphaJit * blink * 255)
          .round()
          .clamp(0, 255);
      if (_aa) {
        // 余烬是自发光：screen 让火星叠在亮部时仍提亮而不是糊成一块白斑，
        // 衰减式与 legacy 的 0.35+0.65·fall 同形，只多了边缘覆盖度。
        drawDiscAA(frame, px, py, rad, r0, g0, b0, a,
            op: BlendOp.screen, clip: e.clip);
        continue;
      }
      _drawSoftDisc(frame, px, py, rad, r0, g0, b0, a, clip: e.clip);
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
    final flashK =
        (math.exp(-local * 7.0) * p.flashIntensity * _env.exposure * 256)
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
    if (_aa) {
      // 主干 2px + 冷色柔光晕：对应 legacy 的「主点 + 右邻 + 下邻」三笔。
      drawSegmentAA(f, x0, y0, x1, y1, 240, 244, 255, (a * 0.4).round(), 4.0);
      drawSegmentAA(f, x0, y0, x1, y1, 255, 255, 255, a, 2.0);
      return;
    }
    final steps = math.max(2, ((x1 - x0).abs() + (y1 - y0).abs()).round());
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
    final warm = (((p.shift.clamp(0.0, 0.15) * s) + _env.warmth) * 255).round();
    if (warm == 0) return;
    final addR = warm > 0 ? warm : (warm * 0.4).round();
    final addB = warm > 0 ? (-warm * 0.6).round() : -warm;
    final subR = warm > 0 ? 0 : warm;
    final subB = warm > 0 ? warm : 0;
    // 预计算 LUT：r LUT 与 b LUT 各 256 项
    final lutR =
        List<int>.generate(256, (v) => (v + addR - subR).clamp(0, 255));
    final lutB =
        List<int>.generate(256, (v) => (v + addB - subB).clamp(0, 255));
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
    final strength = p.strength.clamp(0.0, 0.8) *
        (0.5 + 0.5 * math.sin(2 * math.pi * cyc * u - math.pi / 2)) *
        (1.0 + _env.vignette);
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
    for (var i = 0; i < _starSamples.length; i++) {
      final st = _stars[i];
      final blinkV = math
          .pow(0.5 + 0.5 * math.sin(w2pi * blink * u + st.blinkPhase), 2.0)
          .toDouble();
      if (blinkV < 0.06) continue;
      final a = (p.intensity * _env.particles * st.brightJit * blinkV * 255)
          .round()
          .clamp(0, 255);
      final arm = (p.sizePx * st.sizeJit).clamp(2.0, 30.0);
      final sx = _starSamples[i][0].toDouble();
      final sy = _starSamples[i][1].toDouble();
      if (_aa) {
        // 四臂各自从中心外扩，fade² 与 legacy 一致（中心被四笔叠成亮核）。
        for (final dir in const [
          [1.0, 0.0],
          [-1.0, 0.0],
          [0.0, 1.0],
          [0.0, -1.0]
        ]) {
          drawSegmentAA(frame, sx, sy, sx + dir[0] * arm, sy + dir[1] * arm,
              255, 250, 230, a, 1.0,
              op: BlendOp.screen, tailFade: 1.0, tailPow: 2);
        }
        continue;
      }
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
        final add = (p.intensity * _env.exposure * fall * 120).round();
        if (add <= 0) continue;
        for (var x = 0; x < w; x += 2) {
          _blendAddPx(frame, x, y, 220, 235, 255, add);
          _blendAddPx(frame, x + 1, y, 220, 235, 255, add);
        }
      }
    }
  }

  void _drawSoftDisc(RgbaImage f, double cx, double cy, double rad, int r,
      int g, int b, int a,
      {PixelRect? clip}) {
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
        _blendPx(f, x, y, r, g, b, (a * (0.35 + 0.65 * fall)).round(),
            clip: clip);
      }
    }
  }
}

class _Particle {
  _Particle({
    required this.px,
    required this.py,
    this.clip,
    required this.r,
    required this.alpha,
    required this.drift,
    required this.phase,
  });

  final double px;
  final double py;
  final PixelRect? clip;
  final double r;
  final double alpha;
  final double drift;
  final double phase;
}

/// 交互式视差覆盖参数（第四轮 V1）：两个分量彼此独立，各轴取值 [-1, 1]，
/// 0 = 该轴无位移。仅在使用方显式设置 [FrameCompositor.parallaxOverride]
/// 时生效；默认 null 下渲染路径逐字节不变。
class ParallaxOverride {
  const ParallaxOverride({this.phaseX = 0.0, this.phaseY = 0.0});

  /// 水平归一化偏移（[-1, 1]）。正值 = 层向右位移。
  final double phaseX;

  /// 垂直归一化偏移（[-1, 1]）。正值 = 层向下位移（受
  /// `parallax.verticalRatio` 缩放，与时间路径同一耦合系数）。
  final double phaseY;
}

// ---- v1.1 新动效粒子状态 ----

class _Drop {
  _Drop({
    required this.x0,
    required this.y0,
    this.clip,
    required this.lenJit,
    required this.alphaJit,
  });

  final double x0;
  final double y0;
  final PixelRect? clip;
  final double lenJit;
  final double alphaJit;
}

class _SnowFlake {
  _SnowFlake({
    required this.x0,
    required this.y0,
    this.clip,
    required this.sizeJit,
    required this.swayPhase,
    required this.swayFreqMul,
    required this.twkPhase,
  });

  final double x0;
  final double y0;
  final PixelRect? clip;
  final double sizeJit;
  final double swayPhase;
  final int swayFreqMul;
  final double twkPhase;
}

class _Petal {
  _Petal({
    required this.x0,
    required this.y0,
    this.clip,
    required this.sizeJit,
    required this.rot0,
    required this.spinDir,
    required this.swayPhase,
    required this.swayFreqMul,
    required this.toneIdx,
  });

  final double x0;
  final double y0;
  final PixelRect? clip;
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
    this.clip,
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
  final PixelRect? clip;
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
    this.clip,
    required this.rx,
    required this.ry,
    required this.driftJit,
    required this.phase,
    required this.alphaJit,
  });

  final double x0;
  final double y0;
  final PixelRect? clip;
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
    this.clip,
    required this.sizeJit,
    required this.swayPhase,
    required this.swayFreqMul,
    required this.blinkPhase,
    required this.alphaJit,
  });

  final double x0;
  final double y0;
  final PixelRect? clip;
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
