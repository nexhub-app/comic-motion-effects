part of '../frame_compositor.dart';

/// v1.3 漫画动势语言 pass：集中线、网点纸、震屏、冲击波环、飞白笔触。
///
/// 与合成器同库，所以能直接用它的私有混合入口（`_blendAddPx`）、质量档
/// （`_aa`）与循环时钟（`_loopU`）。每个 pass 都是 (状态, 帧, u) 的纯函数：
/// 不读写跨帧可变量，帧序无关，因此并行渲染与串行逐字节一致。

/// 集中线：向焦点汇聚的黑/白楔形，整体整圈旋转 + 逐条手绘抖动。
///
/// 采样按「半径 × 弦长」两重循环推进，三角函数每楔形只算一次，每样本只做
/// 乘加，所以代价与**线的覆盖像素数**同阶（而不是楔形数 × 画幅）。
void _renderFocusLines(FrameCompositor c, RgbaImage frame, double tSec) {
  final wedges = c._focusWedges;
  if (wedges.isEmpty) return;
  final p = c.config.focusLines;
  final u = c._loopU(tSec);
  final n = wedges.length;
  // Task 2.1：焦点解析——contentAware 开且调用方未 pin 时收敛到 anchor，
  // 否则回到 params.focalX/focalY（legacy，逐字节等价）。
  final focal = c._focusLinesFocal();
  final cx = focal.fx.clamp(0.05, 0.95) * c.w;
  final cy = focal.fy.clamp(0.05, 0.95) * c.h;
  final diag2 = math.sqrt(c.w * c.w + c.h * c.h) / 2.0;
  final rInner = diag2 * p.innerFrac.clamp(0.04, 0.9);
  final baseHalf =
      math.max(0.0008, p.wedgeDeg.clamp(0.15, 12.0) * math.pi / 180.0);
  final turn = 2 * math.pi * p.turnCycles.clamp(0, 8) * u;
  final aa = c._aa;
  final step = 2 * math.pi / n;
  for (var i = 0; i < n; i++) {
    final wd = wedges[i];
    final rOuter = diag2 * wd.lenJit.clamp(0.6, 1.15);
    final band = rOuter - rInner;
    if (band < 2) continue;
    final theta = step * i + turn + wd.phaseJit;
    final dirX = math.cos(theta), dirY = math.sin(theta);
    final perpX = -dirY, perpY = dirX;
    final reachBase = baseHalf * wd.widthJit;
    final fadeBand = band * 0.22; // 内端淡入：线从留空圈外一点点长出来
    final aBase = p.opacity.clamp(0.0, 1.0) * wd.alphaJit;
    final black = p.mode != 'white' && (p.mode != 'both' || i.isEven);
    for (var r = rInner.ceilToDouble(); r <= rOuter; r += 1.0) {
      final din = r - rInner;
      var env =
          (din < fadeBand ? din / fadeBand : 1.0) * (1 - 0.35 * din / band);
      final dout = rOuter - r;
      final rCov = aa ? coverage(dout) / 255.0 : (dout >= 0.5 ? 1.0 : 0.0);
      final reach = reachBase * r; // 该半径处楔形半宽（像素，用弦近似）
      final samples = reach < 0.75 ? 1 : (2 * reach).ceil() + 1;
      final sStep = samples == 1 ? 0.0 : 2 * reach / (samples - 1);
      for (var k = 0; k < samples; k++) {
        final s = samples == 1 ? 0.0 : sStep * k - reach;
        final edge = reach - s.abs(); // 到楔形角边的距离
        final aCov = aa ? coverage(edge) / 255.0 : (edge >= 0.5 ? 1.0 : 0.0);
        final a = (aBase * env * rCov * aCov * 255).round();
        if (a <= 0) continue;
        final x = (cx + dirX * r + perpX * s).round();
        final y = (cy + dirY * r + perpY * s).round();
        if (x < 0 || y < 0 || x >= c.w || y >= c.h) continue;
        if (black) {
          // 黑线即 0 色的 source-over，代数上等于 multiply：d·(255-a)/255
          var ai = a;
          // Task 2.4（standard+）：黑楔形落在纸白上已经看得见，这里只按 spec
          // §5 的「随亮度加粗/提 alpha」给白纸一极补 1/4 墨量，让墨线压过纸纹。
          // mode 语义（black/white/both 的归属）与 legacy 路径都不受影响。
          if (aa && c.base.luminance(y * c.w + x) > 200) {
            ai = PolarityBrush.bump(a);
          }
          blendPixel(frame, x, y, 0, 0, 0, ai);
        } else {
          c._blendAddPx(frame, x, y, 255, 255, 255, a);
        }
      }
    }
  }
}

class _FocusWedge {
  _FocusWedge({
    required this.lenJit,
    required this.widthJit,
    required this.alphaJit,
    required this.phaseJit,
  });

  final double lenJit; // 外端半径倍率
  final double widthJit; // 半顶角倍率
  final double alphaJit;
  final double phaseJit; // 角度抖动（弧度）
}

/// 震屏的一个爆点：单位方向向量（构造期算好，逐帧只做两次乘法）。
class _ShakeBurst {
  const _ShakeBurst(this.dirX, this.dirY);

  final double dirX, dirY;
}

/// 冲击波环：多环错相外扩，easeOutCubic 半径 + `sin(π·ph)` 明暗包络。
///
/// 环带本身是解析距离场，legacy/standard 的差别只在边缘是否走过渡带
/// （`aa: c._aa`）与提亮用截断加法还是 screen——几何时不会退化成阶梯圆。

/// Task 3.4（R17）：standard 档环闪包络用 snapWave 整流后乘 `sin(π·ph)`
/// 窗——窗不可省：snapWave(u) 恒 ≥0.3387 于 u=0（非零起点），裸替换会让环
/// 永不淡出（端点弹出/环间叠死）；乘窗保证 ph→0 与 ph→1 两端仍精确归零，
/// 同时正瓣偏前（峰 ph≈0.416）给出 §6.2 快起慢落的打击感。
/// C = 该乘积的实测峰值（1e8 密扫 + 黄金分割精化，ph≈0.4157084284868357 处
/// max = 0.6933307478007389），除归一后 standard 峰值 env≈1.0。const，
/// 与 `_peak` 同法：不逐调用寻峰。
const double _ringSnapWindowPeak = 0.6933307478007389;

void _renderImpactRings(FrameCompositor c, RgbaImage frame, double tSec) {
  final rings = c._shockRings;
  if (rings.isEmpty) return;
  final p = c.config.impactRings;
  final u = c._loopU(tSec);
  final n = rings.length;
  final pulses = p.pulses.clamp(1, 8);
  final diag = math.sqrt(c.w * c.w + c.h * c.h) / 2.0;
  final rIn = diag * p.innerFrac.clamp(0.0, 0.9);
  final rOut = diag * p.outerFrac.clamp(0.05, 1.6);
  if (rOut <= rIn) return;
  // Task 2.1：焦点解析（同 focusLines，legacy 逐字节等价）。
  final focal = c._impactRingsFocal();
  final cx = focal.fx.clamp(-0.5, 1.5) * c.w;
  final cy = focal.fy.clamp(-0.5, 1.5) * c.h;
  final baseTh = p.thicknessPx.clamp(0.6, 40.0);
  final aa = c._aa;
  final bright = aa ? BlendOp.screen : BlendOp.additive;
  for (var k = 0; k < n; k++) {
    final rg = rings[k];
    final ph = (u * pulses + k / n) % 1.0;
    final e = 1.0 - math.pow(1.0 - ph, 3); // easeOutCubic：出手快、收尾缓
    final rad = rIn + (rOut - rIn) * e * rg.radJit;
    // Task 3.4（§6.2/R17）：一次性淡入淡出不是周期载体——standard 用
    // 「整流 snapWave × sin(π·ph) 窗 ÷ 实测峰」做快起慢落闪光；legacy 冻结。
    final env = aa
        ? math.max(0.0, snapWave(ph)) * math.sin(math.pi * ph) / _ringSnapWindowPeak
        : math.sin(math.pi * ph);
    final a = (p.opacity.clamp(0.0, 1.0) * env * rg.alphaJit * 255).round();
    if (a <= 0 || rad <= 0) continue;
    final th = baseTh * rg.widthJit * (1.0 - 0.4 * e); // 越远越细
    drawRingAA(frame, cx, cy, rad, th, 255, 255, 255, a, op: bright, aa: aa);
    if (p.mode == 'shock') {
      // 内侧暗边：环后拖一道 1.5× 宽、0.35 强度的黑边 → 漫画描边厚度感。
      drawRingAA(
          frame, cx, cy, rad - th * 0.9, th * 1.5, 0, 0, 0, (a * 0.35).round(),
          aa: aa);
    }
  }
}

/// 飞白笔触：把一条干笔切成 2px 段链，逐段算缺口噪声与笔尖渐显。
///
/// 缺口用 `sin` 的平移阈值曲线（`(0.5+0.5sin)` 低于 0.25 的相位整段啃掉，
/// 其余按 `(x-0.25)/0.75` 平方衰减）而非真噪声：零查表、零 RNG 消耗，且沿笔划
/// 连续 → 白隙有方向性。段长必须显著短于缺口波长，否则逐段采样会同相混叠
/// （整条笔划一起消失），所以 `gapFreq` 上限被夹到 0.25（波长 ≥ 4px）。
void _renderBrushStreak(FrameCompositor c, RgbaImage frame, double tSec) {
  final list = c._brushStreaks;
  if (list.isEmpty) return;
  final p = c.config.brushStreak;
  final u = c._loopU(tSec);
  final n = list.length;
  final pulses = p.pulses.clamp(1, 8);
  final short = math.min(c.w, c.h).toDouble();
  final gapFreq = p.gapFreq.clamp(0.01, 0.25);
  final baseRad = p.angleDeg * math.pi / 180.0;
  final opacity = p.opacity.clamp(0.0, 1.0);
  final thick0 = p.thicknessPx.clamp(1.0, 60.0);
  final len0 = p.lengthFrac.clamp(0.05, 1.5) * short;
  const segLen = 2.0;
  const drawFrac = 0.45; // 前 45% 运笔，其余停留后淡出
  final aa = c._aa;
  for (var i = 0; i < n; i++) {
    final st = list[i];
    final ph = (u * pulses + i / n) % 1.0;
    final double reveal, env;
    if (ph < drawFrac) {
      reveal = ph / drawFrac;
      env = 1.0;
    } else {
      reveal = 1.0;
      env = 1.0 - (ph - drawFrac) / (1.0 - drawFrac);
    }
    if (env <= 0.004) continue;
    final theta = baseRad + st.angleJit;
    final dirX = math.cos(theta), dirY = math.sin(theta);
    final len = len0 * st.lenJit;
    final penUp = len * reveal; // 笔已走过的长度
    if (penUp < 1) continue;
    final ox = st.x0 * c.w - dirX * len * 0.5;
    final oy = st.y0 * c.h - dirY * len * 0.5;
    final step = segLen + 0.5; // 0.5px 搭接，避免珠节
    final segs = (penUp / step).ceil();
    for (var s = 0; s < segs; s++) {
      final s0 = s * step;
      final s1 = math.min(s0 + step, penUp);
      if (s1 <= s0) continue;
      final mid = (s0 + s1) * 0.5;
      final x = 0.5 + 0.5 * math.sin(2 * math.pi * gapFreq * mid + st.gapPhase);
      final cut = (x - 0.25) / 0.75;
      if (cut <= 0) continue; // 干笔白隙：这一段完全不着墨
      final gap = cut >= 1.0 ? 1.0 : cut * cut;
      final tip = (penUp - mid) / (segLen * 3.0); // 笔头 3 段渐入
      final a = (opacity * env * gap * (tip < 1 ? tip : 1.0) * 255).round();
      if (a <= 0) continue;
      drawSegmentAA(frame, ox + dirX * s0, oy + dirY * s0, ox + dirX * s1,
          oy + dirY * s1, 0, 0, 0, a, thick0 * st.thickJit * (0.7 + 0.3 * x),
          aa: aa);
    }
  }
}

class _ShockRing {
  const _ShockRing({
    required this.radJit,
    required this.widthJit,
    required this.alphaJit,
  });

  final double radJit; // 终止半径倍率
  final double widthJit;
  final double alphaJit;
}

class _BrushStroke {
  const _BrushStroke({
    required this.x0,
    required this.y0,
    required this.lenJit,
    required this.thickJit,
    required this.angleJit,
    required this.gapPhase,
  });

  final double x0, y0; // 笔划中心（归一化）
  final double lenJit, thickJit, angleJit, gapPhase;
}

/// 网点纸：旋转点阵网点/线网/十字网，按整格漂移 + 疏密呼吸压暗底图。
///
/// 掩码只建一张 `tile×tile` 的规则点阵（每帧一次，代价 ≤ 64² 次运算），渲染
/// 时以旋转后的格坐标取模查表：逐像素只有「2 次加法 + 2 次回绕 + 1 次查表」，
/// 没有三角函数也没有除法，所以全画幅覆盖仍然便宜。
///
/// 无缝性来自两处整数化：漂移按整格取模（u=1 时偏移 ≡ 0 mod tile），疏密呼吸
/// 用 `densityCycles` 的整数倍正弦（u=0 与 u=1 半径相等）。
void _renderScreenTone(FrameCompositor c, RgbaImage frame, double tSec) {
  final p = c.config.screenTone;
  final u = c._loopU(tSec);
  final alpha = p.opacity.clamp(0.0, 1.0);
  if (alpha <= 0) return;
  final ti = p.spacingPx.clamp(4.0, 64.0).round();
  final tile = ti.toDouble();
  final density = p.density.clamp(0.02, 0.98);
  final breath =
      0.75 + 0.25 * math.sin(2 * math.pi * p.densityCycles.clamp(0, 8) * u);
  // 占空比归一：让三种 mode 的「墨面积 / 格面积」都等于 density。
  final r = switch (p.mode) {
    'line' => tile * density / 2.0,
    'cross' => tile * math.sqrt(density) / 4.0,
    _ => tile * math.sqrt(density / math.pi),
  };
  final mask = _toneTile(p.mode, ti, r * breath, aa: c._aa);
  // alpha 折进查表：mask 值本身是 0..255 的覆盖度，乘 opacity 即最终压暗量，
  // 逐像素省一次除法。
  final lut = Uint8List(256);
  for (var i = 1; i < 256; i++) {
    lut[i] = (i * alpha).round();
  }
  final driftX = (p.driftTilesX.clamp(0, 16) * u * tile).round().toInt() % ti;
  final driftY = (p.driftTilesY.clamp(0, 16) * u * tile).round().toInt() % ti;
  final arad = p.angleDeg * math.pi / 180.0;
  final ca = math.cos(arad), sa = math.sin(arad);
  final data = frame.data;
  final w = c.w, h = c.h;
  for (var y = 0; y < h; y++) {
    var uu = (driftX - y * sa) % tile; // Dart 的 double % 保留符号 → 下面回绕
    if (uu < 0) uu += tile;
    var vv = (driftY + y * ca) % tile;
    if (vv < 0) vv += tile;
    var o = y * w * 4;
    for (var x = 0; x < w; x++, o += 4) {
      final cov = lut[mask[vv.toInt() * ti + uu.toInt()]];
      uu += ca;
      if (uu >= tile) {
        uu -= tile;
      } else if (uu < 0) {
        uu += tile;
      }
      vv += sa;
      if (vv >= tile) {
        vv -= tile;
      } else if (vv < 0) {
        vv += tile;
      }
      if (cov == 0) continue;
      final inv = 255 - cov;
      // 网点只压暗（黑色 source-over 的代数等价式）
      data[o] = (data[o] * inv) ~/ 255;
      data[o + 1] = (data[o + 1] * inv) ~/ 255;
      data[o + 2] = (data[o + 2] * inv) ~/ 255;
    }
  }
}

/// 生成 `ts×ts` 规则格掩码，值 = 0..255 的覆盖率（到网点边界的解析距离）。
/// dot=圆点，line=竖直带（宽 2r），cross=十字（臂长 2.5r×两臂）。
Uint8List _toneTile(String mode, int ts, double r, {required bool aa}) {
  final mask = Uint8List(ts * ts);
  final half = ts * 0.5;
  final arm = r * 2.5;
  for (var ty = 0; ty < ts; ty++) {
    final cy = ty + 0.5 - half;
    for (var tx = 0; tx < ts; tx++) {
      final cx = tx + 0.5 - half;
      final double d; // >0 落在网点内，值即 1px 过渡带内的覆盖度
      switch (mode) {
        case 'line':
          d = r - cx.abs();
        case 'cross':
          d = math.max(math.min(arm - cx.abs(), r - cy.abs()),
              math.min(arm - cy.abs(), r - cx.abs()));
        default:
          d = r - math.sqrt(cx * cx + cy * cy);
      }
      mask[ty * ts + tx] = aa ? coverage(d) : (d >= 0.5 ? 255 : 0);
    }
  }
  return mask;
}
