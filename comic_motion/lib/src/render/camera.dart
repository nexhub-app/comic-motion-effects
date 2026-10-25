/// 镜头 pass（重构方案 M2，`motion_redesign_plan_20261025.md` §3/§7.2）：
/// 对合成后画布的格区域做以程序锚点为焦点的仿射缩放/平移。
///
/// 与层视差的关系：镜头是**全画布一致仿射**（区域内无层间撕扯，文字格
/// 也能安全使用——调研 §10.2 的运动学反转落点），视差是层间相对位移。
/// 导出路径在全部效果渲染完之后应用本 pass（叠加顺序 = 合成 → 效果 →
/// 镜头）；shader 主线以 uniform 表达同一程序（M3）。
///
/// 无缝循环契约（延续到镜头维度）：缩放/漂移载体全部整周期化
/// （`MotionMath.cycleCount` 口径）且以 t=0 为静息点——
/// - t=0：zoom 精确 = zoom0、位移精确 0 → 区域恒等，**跳过重采样**
///   （首帧/静息帧 = 原画，逐字节；对拍契约）；
/// - 一个 duration 内 u 推进整数圈 → 端点相等，无缝。
///
/// 确定性：纯函数（帧字节 + 区域表 + t + tier 同输入同输出）；采样越界
/// 一律边缘延展钳位（无跳点残影）。text sharp 掩码（源坐标位打包）命中
/// 的采样走最近邻整纹素拷贝——镜头缩放是全画布一致仿射、无层间撕扯，
/// 文字锐化语义延续（方案 §3）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../apng_writer.dart' show PixelRect;
import '../image_model.dart';
import '../motion_math.dart';
import '../motion_program.dart';
import 'quality.dart';

/// 带镜头程序的格区域（格矩形 + 该格运动程序）。
class CameraRegion {
  const CameraRegion({required this.rect, required this.program});

  final PixelRect rect;
  final MotionProgram program;
}

/// 对 [frame] 应用逐格镜头 pass。[regions] 中 camera.type == none 的区域
/// 不触碰。t=0 恒等跳过（见文件头契约）。
void applyCameraPass({
  required RgbaImage frame,
  required List<CameraRegion> regions,
  required double tSec,
  required double durationSec,
  required RenderTier tier,
  Uint8List? snapMask,
}) {
  if (regions.isEmpty) return;
  final dur = durationSec > 0 ? durationSec : 1.0;
  for (final region in regions) {
    final cam = region.program.camera;
    if (cam.type == CameraType.none) continue;
    final rect = region.rect;
    final rx = rect.x.clamp(0, frame.width);
    final ry = rect.y.clamp(0, frame.height);
    final rw = math.min(rect.width, frame.width - rx);
    final rh = math.min(rect.height, frame.height - ry);
    if (rw < 2 || rh < 2) continue;

    // 整周期相位（restSnapWave 族静息语义：u=0 处精确归零）。
    final cycles = MotionMath.cycleCount(dur, cam.periodSec);
    final u = 2 * math.pi * math.max(0.0, tSec) * cycles / dur;

    var zoom = cam.zoom0;
    var dx = 0.0, dy = 0.0;
    if (cam.type == CameraType.pushIn) {
      // 往返推镜：w(0)=0、w(半周期)=1（整数谐波，无缝）。zoom(t)∈[z0,z1]。
      final w = 0.5 - 0.5 * math.cos(u);
      zoom = cam.zoom0 + (cam.zoom1 - cam.zoom0) * w;
    } else {
      // 漂移：±driftAmp·格宽，sin 整周期往返（t=0 静息）。
      final ampPx = cam.driftAmp * rw;
      dx = ampPx * math.sin(u);
    }
    // 覆盖放大：平移会露出区域外的源内容——画布级区域（格覆盖整页）时
    // 按震屏同款公式放大盖住；格级区域由克隆边距供样（格间自然延续）。
    if (rx == 0 && ry == 0 && rw == frame.width && rh == frame.height) {
      final cover = 1.0 + (dx.abs() + dy.abs()) * 2.0 / math.min(rw, rh);
      zoom *= cover;
    }
    // 恒等跳过（t=0 静息帧逐字节 = 无镜头渲染；浮点口径下精确比较）。
    if ((zoom - 1.0).abs() <= 1e-12 && dx.abs() <= 1e-12 && dy.abs() <= 1e-12) {
      continue;
    }

    final ax = rx + cam.anchorX * rw;
    final ay = ry + cam.anchorY * rh;
    // 源边距：缩放 ≥1 时采样窗 ⊆ 格内；平移需要 |d| 边距。留 2px 余量。
    final margin = (dx.abs()).ceil() + 2;
    final sx0 = math.max(0, rx - margin);
    final sy0 = math.max(0, ry - margin);
    final sx1 = math.min(frame.width, rx + rw + margin);
    final sy1 = math.min(frame.height, ry + rh + margin);
    final sw = sx1 - sx0, sh = sy1 - sy0;
    if (sw < 2 || sh < 2) continue;

    // 克隆源区域（读-写分离；写入只落在格矩形内）。
    final src = RgbaImage(width: sw, height: sh);
    for (var y = 0; y < sh; y++) {
      src.data.setRange(
          y * sw * 4,
          (y + 1) * sw * 4,
          frame.data,
          ((sy0 + y) * frame.width + sx0) * 4);
    }

    final axl = ax - sx0, ayl = ay - sy0;
    final inv = 1.0 / zoom;
    final dst = frame.data;
    for (var y = ry; y < ry + rh; y++) {
      // dest(p) = src(a + (p − d − a)/z)，纹素中心约定（−0.5）。
      final fy = ayl + (y + 0.5 - dy - ayl) * inv - 0.5;
      for (var x = rx; x < rx + rw; x++) {
        final fx = axl + (x + 0.5 - dx - axl) * inv - 0.5;
        _sampleClamped(src, fx, fy, tier, snapMask, sx0, sy0, frame.width,
            (y * frame.width + x) * 4, dst);
      }
    }
  }
}

/// 边缘延展钳位采样：CR（standard+）/ 双线性（legacy）；snapMask 命中走
/// 最近邻整纹素拷贝（canvas 坐标掩码）。
void _sampleClamped(
    RgbaImage src,
    double fx,
    double fy,
    RenderTier tier,
    Uint8List? snapMask,
    int sx0,
    int sy0,
    int canvasW,
    int dstOff,
    Uint8List dst) {
  final sw = src.width, sh = src.height;
  if (tier.atLeastStandard) {
    // Catmull-Rom 4×4，抽点索引钳位（边缘延展）；分数取自未钳位 floor。
    final xf = fx.floor(), yf = fy.floor();
    final tx = fx - xf, ty = fy - yf;
    final nx = (fx + 0.5).floor().clamp(0, sw - 1);
    final ny = (fy + 0.5).floor().clamp(0, sh - 1);
    if (snapMask != null) {
      final p = (sy0 + ny) * canvasW + (sx0 + nx);
      if ((snapMask[p >> 3] >> (p & 7)) & 1 != 0) {
        final o = (ny * sw + nx) * 4;
        _writeOpaque(dst, dstOff, src.data[o], src.data[o + 1],
            src.data[o + 2], src.data[o + 3]);
        return;
      }
    }
    final wx = _crWeights(tx);
    final wy = _crWeights(ty);
    var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    for (var j = 0; j < 4; j++) {
      final yy = (yf - 1 + j).clamp(0, sh - 1);
      for (var i = 0; i < 4; i++) {
        final xx = (xf - 1 + i).clamp(0, sw - 1);
        final wgt = wx[i] * wy[j];
        if (wgt == 0) continue;
        final o = (yy * sw + xx) * 4;
        r += src.data[o] * wgt;
        g += src.data[o + 1] * wgt;
        b += src.data[o + 2] * wgt;
        a += src.data[o + 3] * wgt;
      }
    }
    _write(dst, dstOff, r, g, b, a);
    return;
  }
  // legacy：双线性（v1.2 通路语义，边缘延展）。
  final cx = fx.clamp(0.0, (sw - 1).toDouble());
  final cy = fy.clamp(0.0, (sh - 1).toDouble());
  final x0 = cx.floor(), y0 = cy.floor();
  final x1 = (x0 + 1).clamp(0, sw - 1);
  final y1 = (y0 + 1).clamp(0, sh - 1);
  final tx = cx - x0, ty = cy - y0;
  var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
  for (var j = 0; j < 2; j++) {
    final yy = j == 0 ? y0 : y1;
    final wy = j == 0 ? 1 - ty : ty;
    for (var i = 0; i < 2; i++) {
      final xx = i == 0 ? x0 : x1;
      final wx = i == 0 ? 1 - tx : tx;
      final wgt = wx * wy;
      final o = (yy * sw + xx) * 4;
      r += src.data[o] * wgt;
      g += src.data[o + 1] * wgt;
      b += src.data[o + 2] * wgt;
      a += src.data[o + 3] * wgt;
    }
  }
  _write(dst, dstOff, r, g, b, a);
}

List<double> _crWeights(double t) {
  final t2 = t * t, t3 = t2 * t;
  return [
    -0.5 * t3 + t2 - 0.5 * t,
    1.5 * t3 - 2.5 * t2 + 1.0,
    -1.5 * t3 + 2.0 * t2 + 0.5 * t,
    0.5 * t3 - 0.5 * t2,
  ];
}

void _write(Uint8List dst, int off, double r, double g, double b, double a) {
  final sa = a / 255.0;
  if (sa >= 0.996) {
    _writeOpaque(dst, off, r.round().clamp(0, 255), g.round().clamp(0, 255),
        b.round().clamp(0, 255), 255);
    return;
  }
  if (sa <= 0.004) return;
  final da = dst[off + 3] / 255.0;
  final outA = sa + da * (1 - sa);
  dst[off] =
      ((r * sa + dst[off] * da * (1 - sa)) / outA).round().clamp(0, 255);
  dst[off + 1] =
      ((g * sa + dst[off + 1] * da * (1 - sa)) / outA).round().clamp(0, 255);
  dst[off + 2] =
      ((b * sa + dst[off + 2] * da * (1 - sa)) / outA).round().clamp(0, 255);
  dst[off + 3] = (outA * 255).round().clamp(0, 255);
}

void _writeOpaque(Uint8List dst, int off, int r, int g, int b, int a) {
  dst[off] = r;
  dst[off + 1] = g;
  dst[off + 2] = b;
  dst[off + 3] = a;
}
