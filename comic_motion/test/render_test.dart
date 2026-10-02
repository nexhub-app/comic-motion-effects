import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// 统计栅格里出现的「非 0 非满」亮度级数：AA 路径应有丰富中间调，
/// 整数取整路径只有极少数几级。
Set<int> _partialLevels(Uint8List data) => {
      for (final v in data)
        if (v > 0 && v < 255) v
    };

RgbaImage _blank([int w = 40, int h = 40]) => RgbaImage(width: w, height: h);

/// v1.2 的画线方式：沿主轴取整后逐点 source-over，用于对照 AA 的收益。
void _legacyLine(
    RgbaImage f, double x0, double y0, double x1, double y1, int alpha) {
  final steps = math.max(2, ((x1 - x0).abs() + (y1 - y0).abs()).round());
  for (var i = 0; i <= steps; i++) {
    final t = i / steps;
    final x = (x0 + (x1 - x0) * t).round();
    final y = (y0 + (y1 - y0) * t).round();
    if (x < 0 || y < 0 || x >= f.width || y >= f.height) continue;
    final o = (y * f.width + x) * 4;
    f.data[o] = alpha;
    f.data[o + 1] = alpha;
    f.data[o + 2] = alpha;
  }
}

/// 竖直黑白条纹（周期 periodPx），用于测重采样的锯齿/锐度。
RgbaImage _stripes(int w, int h, {int periodPx = 4}) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = (x ~/ periodPx) % 2 == 0 ? 255 : 0;
      img.setPixel(x, y, v, v, v);
    }
  }
  return img;
}

/// v1.2 的工作分辨率降采样（双线性），作为面积平均的对照参考。
RgbaImage _bilinearDownscale(RgbaImage src, int maxDim) {
  final maxSide = src.width > src.height ? src.width : src.height;
  if (maxSide <= maxDim) return src;
  final ratio = maxDim / maxSide;
  final nw = (src.width * ratio).round().clamp(1, maxDim);
  final nh = (src.height * ratio).round().clamp(1, maxDim);
  final out = RgbaImage(width: nw, height: nh);
  final sx = src.width / nw, sy = src.height / nh;
  final tmp = List<int>.filled(4, 0);
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      src.sampleBilinear((x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5, tmp);
      out.setPixel(x, y, tmp[0], tmp[1], tmp[2], tmp[3]);
    }
  }
  return out;
}

/// 纯白不透明平场（四通道全 255）。
///
/// 常量输入是面积平均滤波器的**下界**不变量：覆盖权重求和后除以 scale 必须还原
/// 同一个常量，任何一根纹素没被计入都会让整幅输出按轴乘上 `(scale - frac)/scale`。
RgbaImage _flatWhite(int w, int h) {
  final data = Uint8List(w * h * 4);
  data.fillRange(0, data.length, 255);
  return RgbaImage.fromBytes(width: w, height: h, data: data);
}

/// 逐通道全栅格扫描（不抽查：缺陷是周期性的，抽查可能恰好落在好像素上），
/// 返回 `(最小值, 最大值, 不等于 [want] 的像素个数)`。
(int, int, int) _byteRange(RgbaImage img, int want) {
  var lo = 256, hi = -1, bad = 0;
  final data = img.data;
  for (var i = 0; i < data.length; i++) {
    final v = data[i];
    if (v < lo) lo = v;
    if (v > hi) hi = v;
    if (v != want) bad++;
  }
  return (lo, hi, bad);
}

/// 竖直正弦光栅（连续信号 128+120·cos(2πu/period) 按像素中心采样）。
RgbaImage _grating(int w, int h, {double periodPx = 2.5}) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = (128 + 120 * math.cos(2 * math.pi * (x + 0.5) / periodPx))
          .round()
          .clamp(0, 255);
      img.setPixel(x, y, v, v, v);
    }
  }
  return img;
}

/// 每个输出像素所覆盖源区间的**连续信号积分均值**（理想抗锯齿答案）。
List<double> _idealColumns(int sw, int dw, double period) {
  final scale = sw / dw;
  final k = 2 * math.pi / period;
  return [
    for (var i = 0; i < dw; i++)
      128 +
          120 /
              k *
              (math.sin(k * (i + 1) * scale) - math.sin(k * i * scale)) /
              scale
  ];
}

/// 输出图第 0 行与理想值的平方误差。
double _colErr(RgbaImage img, List<double> ideal) {
  var s = 0.0;
  for (var x = 0; x < img.width; x++) {
    final d = img.luminance(x) - ideal[x];
    s += d * d;
  }
  return s;
}

/// 全图亮度标准差，衡量线稿对比度。
double _contrast(RgbaImage img) {
  final n = img.pixelCount;
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    sum += img.luminance(i);
  }
  final mean = sum / n;
  var v = 0.0;
  for (var i = 0; i < n; i++) {
    final d = img.luminance(i) - mean;
    v += d * d;
  }
  return math.sqrt(v / n);
}

/// v1.2 层贴图通路（逆映射双线性 + 越界抽点权重记 0）的独立参考实现。
RgbaImage _referenceBilinear(RgbaImage src, int dw, int dh, double dx,
    double dy, double scale, double anchorY) {
  final dst = RgbaImage(width: dw, height: dh);
  final sw = src.width, sh = src.height, data = src.data, out = dst.data;
  final cx = sw / 2.0, cy = sh * anchorY;
  final inv = 1.0 / scale;
  for (var y = 0; y < dh; y++) {
    final sy = (y + 0.5 - (dh * anchorY)) * inv + cy + dy - 0.5;
    final sy0 = sy.floor();
    final ty = sy - sy0;
    for (var x = 0; x < dw; x++) {
      final sx = (x + 0.5 - (dw * 0.5)) * inv + cx + dx - 0.5;
      final sx0 = sx.floor();
      final tx = sx - sx0;
      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
      for (var j = 0; j < 2; j++) {
        for (var i = 0; i < 2; i++) {
          final yy = sy0 + j, xx = sx0 + i;
          if (xx < 0 || xx >= sw || yy < 0 || yy >= sh) continue;
          final wgt = (i == 0 ? 1 - tx : tx) * (j == 0 ? 1 - ty : ty);
          final o = (yy * sw + xx) * 4;
          r += data[o] * wgt;
          g += data[o + 1] * wgt;
          b += data[o + 2] * wgt;
          a += data[o + 3] * wgt;
        }
      }
      final sa = a / 255.0;
      if (sa <= 0.004) continue;
      final dOff = (y * dw + x) * 4;
      if (sa >= 0.996) {
        out[dOff] = r.round().clamp(0, 255);
        out[dOff + 1] = g.round().clamp(0, 255);
        out[dOff + 2] = b.round().clamp(0, 255);
        out[dOff + 3] = 255;
      } else {
        final da = out[dOff + 3] / 255.0;
        final outA = sa + da * (1 - sa);
        out[dOff] =
            ((r * sa + out[dOff] * da * (1 - sa)) / outA).round().clamp(0, 255);
        out[dOff + 1] = ((g * sa + out[dOff + 1] * da * (1 - sa)) / outA)
            .round()
            .clamp(0, 255);
        out[dOff + 2] = ((b * sa + out[dOff + 2] * da * (1 - sa)) / outA)
            .round()
            .clamp(0, 255);
        out[dOff + 3] = (outA * 255).round().clamp(0, 255);
      }
    }
  }
  return dst;
}

/// standard 档的二维 Catmull-Rom 参考实现（16 抽点、逐点边界判断）。
///
/// 生产通路为了性能改走可分离滤波，这个独立实现用来锁住语义：
/// 两者必须只差在浮点求和顺序上（逐通道 <=1 级），边界处理也必须一致。
RgbaImage _referenceCatmullRom(RgbaImage src, int dw, int dh, double dx,
    double dy, double scale, double anchorY) {
  final dst = RgbaImage(width: dw, height: dh);
  final sw = src.width, sh = src.height, data = src.data, out = dst.data;
  final inv = 1.0 / scale;
  final wx = List<double>.filled(4, 0), wy = List<double>.filled(4, 0);
  void weights(double t, List<double> o) {
    final t2 = t * t, t3 = t2 * t;
    o[0] = -0.5 * t3 + t2 - 0.5 * t;
    o[1] = 1.5 * t3 - 2.5 * t2 + 1.0;
    o[2] = -1.5 * t3 + 2.0 * t2 + 0.5 * t;
    o[3] = 0.5 * t3 - 0.5 * t2;
  }

  for (var y = 0; y < dh; y++) {
    final sy = (y + 0.5 - (dh * anchorY)) * inv + sh * anchorY + dy - 0.5;
    final sy0 = sy.floor();
    weights(sy - sy0, wy);
    for (var x = 0; x < dw; x++) {
      final sx = (x + 0.5 - (dw * 0.5)) * inv + sw / 2.0 + dx - 0.5;
      final sx0 = sx.floor();
      weights(sx - sx0, wx);
      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
      for (var j = 0; j < 4; j++) {
        final yy = sy0 - 1 + j;
        if (yy < 0 || yy >= sh) continue;
        for (var i = 0; i < 4; i++) {
          final xx = sx0 - 1 + i;
          if (xx < 0 || xx >= sw) continue;
          final wgt = wx[i] * wy[j];
          final o = (yy * sw + xx) * 4;
          r += data[o] * wgt;
          g += data[o + 1] * wgt;
          b += data[o + 2] * wgt;
          a += data[o + 3] * wgt;
        }
      }
      final sa = a / 255.0;
      if (sa <= 0.004) continue;
      final dOff = (y * dw + x) * 4;
      if (sa >= 0.996) {
        out[dOff] = r.round().clamp(0, 255);
        out[dOff + 1] = g.round().clamp(0, 255);
        out[dOff + 2] = b.round().clamp(0, 255);
        out[dOff + 3] = 255;
      } else {
        final da = out[dOff + 3] / 255.0;
        final outA = sa + da * (1 - sa);
        out[dOff] =
            ((r * sa + out[dOff] * da * (1 - sa)) / outA).round().clamp(0, 255);
        out[dOff + 1] = ((g * sa + out[dOff + 1] * da * (1 - sa)) / outA)
            .round()
            .clamp(0, 255);
        out[dOff + 2] = ((b * sa + out[dOff + 2] * da * (1 - sa)) / outA)
            .round()
            .clamp(0, 255);
        out[dOff + 3] = (outA * 255).round().clamp(0, 255);
      }
    }
  }
  return dst;
}

void main() {
  group('分级重采样', () {
    test('boxDownscale 面积平均：接近连续信号的真值，双线性欠采样偏离大', () {
      // 周期 2.5px 的正弦光栅，缩到 300 宽（1 输出像素盖住 2.13 源像素）：
      // 面积平均能算出这段区间的真实均值，双线性只取 2 个抽点 -> 走偏。
      const period = 2.5;
      final src = _grating(640, 8, periodPx: period);
      final box = boxDownscale(src, 300);
      final bil = _bilinearDownscale(src, 300);
      expect(box.width, bil.width);
      expect(box.height, bil.height);
      final ideal = _idealColumns(640, box.width, period);
      expect(_colErr(box, ideal), lessThan(_colErr(bil, ideal)));
    });

    test('boxDownscale 保持 v1.2 的目标尺寸公式，小图原样返回', () {
      final src = _stripes(900, 1300, periodPx: 7);
      for (final maxDim in [640, 1080, 480]) {
        final a = boxDownscale(src, maxDim);
        final b = _bilinearDownscale(src, maxDim);
        expect('${a.width}x${a.height}', '${b.width}x${b.height}');
      }
      expect(boxDownscale(src, 2000), same(src));
    });

    test('boxDownscale 平场不变量：纯白进必须纯白出（非整数比，R33）', () {
      // 面积平均的归一化下界：常量场在任意缩放比下都必须逐通道还原成同一个
      // 常量。历史缺陷（修复轮 R33）在 `_areaAxisX/_areaAxisY` 里把窗口末纹素
      // 算成 `(a + scale - 1).floor()`，比正确的 `(a + scale).ceil() - 1` 少一个
      // 纹素，却仍按 scale 归一，于是每个轴乘上 (scale - frac(a+scale))/scale < 1；
      // 两轴可分离 ⇒ 损失复利。实测：1.5× 纯白变成交替的 113/170，典型漫画页宽度
      // 的 1.2× 掉到 36…213 的条带；**整数比恰好不受影响**，所以既有整比用例
      // （2×、3×）与相对误差用例全绿也照不出它 —— 这条门就是为此而写。
      // 直接调 boxDownscale（不经过档位）⇒ 与 quality.tier 无关的纯滤波器契约。
      for (final (sw, sh, maxDim, ratioLabel) in [
        (2400, 2400, 1600, '1.5×'),
        (1920, 1080, 1600, '1.2× 典型漫画页宽度'),
        (300, 200, 200, '1.5×（小图，含尺寸取整）'),
      ]) {
        final src = _flatWhite(sw, sh);
        final out = boxDownscale(src, maxDim);
        final tag = '$sw x $sh -> $maxDim（$ratioLabel，出 ${out.width}x${out.height}）';
        expect(out.width, lessThan(sw), reason: '$tag：必须真的降采样');
        expect(out.height, lessThan(sh), reason: '$tag：必须真的降采样');
        final (lo, hi, bad) = _byteRange(out, 255);
        expect(bad, 0,
            reason: '$tag：存在 $bad 个非 255 通道，实测值域 $lo..$hi'
                '（尾纹素漏算会把纯白压成灰条带）');
        expect(lo, 255, reason: '$tag：下界必须是 255，实测 $lo');
        expect(hi, 255, reason: '$tag：上界必须是 255，实测 $hi');
      }
    });

    test('legacy 档 drawLayer 与 v1.2 双线性参考实现逐字节一致', () {
      final src = _stripes(64, 40, periodPx: 5);
      final dst = RgbaImage(width: 48, height: 48);
      drawLayer(dst, src.data, src.width, src.height, 3.5, -2.25, 1.03, 0.5,
          tier: RenderTier.legacy);
      expect(dst.data,
          equals(_referenceBilinear(src, 48, 48, 3.5, -2.25, 1.03, 0.5).data));
    });

    test('standard 档分数位移不再被抹平（线稿对比度回升）', () {
      // 1/4 像素位移：双线性把边缘摊成 75/25 混合，Catmull-Rom 的负瓣把它拉回。
      final src = _stripes(64, 64, periodPx: 4);
      final soft = RgbaImage(width: 64, height: 64);
      final sharp = RgbaImage(width: 64, height: 64);
      drawLayer(soft, src.data, 64, 64, 0.25, 0, 1.0, 0.5,
          tier: RenderTier.legacy);
      drawLayer(sharp, src.data, 64, 64, 0.25, 0, 1.0, 0.5,
          tier: RenderTier.standard);
      expect(_contrast(sharp), greaterThan(_contrast(soft)));
    });

    test('standard 档整数对齐时精确复现源像素（CR 权重退化为单抽点）', () {
      final src = _stripes(40, 24, periodPx: 6);
      final dst = RgbaImage(width: 40, height: 24);
      drawLayer(dst, src.data, 40, 24, 0, 0, 1.0, 0.5,
          tier: RenderTier.standard);
      for (var i = 0; i < 40 * 24; i++) {
        expect(dst.data[i * 4], src.data[i * 4], reason: '像素 $i 未被精确复现');
      }
    });

    test('可分离 CR 与二维 16 抽点 CR 逐通道一致（含跨边界与放大）', () {
      // 生产通路为性能拆成两次 4 抽点；这里用独立的二维实现钉住语义，
      // 只允许浮点求和顺序带来的 1 级误差。
      final src = _stripes(52, 36, periodPx: 5);
      for (final (dx, dy, scale, anchorY, dw, dh) in [
        (0.0, 0.0, 1.0, 0.5, 52, 36), // 整数对齐
        (0.25, -0.5, 1.0, 0.5, 52, 36), // 分数位移
        (-1.75, 2.5, 1.06, 0.4, 48, 40), // 层比画布小 + 位移出界
        (3.0, -4.0, 0.94, 0.6, 56, 30), // 缩小 + 大位移
      ]) {
        final got = RgbaImage(width: dw, height: dh);
        drawLayer(got, src.data, src.width, src.height, dx, dy, scale, anchorY,
            tier: RenderTier.standard);
        final ref = _referenceCatmullRom(src, dw, dh, dx, dy, scale, anchorY);
        var worst = 0;
        for (var i = 0; i < got.data.length; i++) {
          final d = (got.data[i] - ref.data[i]).abs();
          if (d > worst) worst = d;
        }
        expect(worst, lessThanOrEqualTo(1),
            reason: 'dx=$dx dy=$dy scale=$scale');
      }
    });
  });

  group('AA 光栅原语', () {
    test('coverage 边界：内满、外空、过渡带线性', () {
      expect(coverage(1.0), 255);
      expect(coverage(0.0), 0);
      expect(coverage(-3.0), 0);
      expect(coverage(0.5), 128);
      expect(coverage(0.25, band: 0.5), 128);
    });

    test('drawSegmentAA 产生中间调覆盖度，legacy 取整路径只有端级', () {
      final soft = _blank();
      drawSegmentAA(soft, 3.3, 6.7, 36.1, 33.2, 255, 255, 255, 200, 1.0);
      final aa = _partialLevels(soft.data);
      expect(aa.length, greaterThan(6)); // AA：丰富的中间覆盖度

      final hard = _blank();
      _legacyLine(hard, 3.3, 6.7, 36.1, 33.2, 200);
      expect(_partialLevels(hard.data).length, lessThan(aa.length));
    });

    test('drawSegmentAA 覆盖主轴两侧像素，斜率不再产生阶梯断点', () {
      final f = _blank(48, 48);
      drawSegmentAA(f, 4.2, 4.2, 43.6, 43.4, 255, 255, 255, 255, 1.0);
      // 45° 线：每一行都必须有被点亮的像素（legacy 会整行留空再跳两格）。
      for (var y = 6; y <= 41; y++) {
        var lit = 0;
        for (var x = 0; x < 48; x++) {
          if (f.luminance(y * 48 + x) > 8) lit++;
        }
        expect(lit, greaterThan(0), reason: '第 $y 行出现断线');
      }
    });

    test('tailFade 沿程单调衰减，尾端不透明度低于首端', () {
      final f = _blank(60, 8);
      drawSegmentAA(f, 2.0, 4.0, 57.0, 4.0, 255, 255, 255, 255, 1.0,
          tailFade: 0.6);
      int headAt(int x) => f.luminance(4 * 60 + x);
      expect(headAt(3), greaterThan(headAt(55)));
      expect(headAt(55), greaterThan(0));
    });

    test('drawDiscAA 边缘有过渡、中心保持软衰减，additive 只提亮', () {
      final f = _blank();
      drawDiscAA(f, 20.4, 20.6, 7.0, 255, 255, 255, 200);
      expect(_partialLevels(f.data).length, greaterThan(6));
      expect(f.luminance(20 * 40 + 20), greaterThan(150)); // 中心实
      expect(f.luminance(0), 0); // 远处不受影响

      final dark = _blank()
        ..data.setRange(0, 40 * 40 * 4, List.filled(40 * 40 * 4, 30));
      final before = dark.clone();
      drawDiscAA(dark, 20, 20, 5, 255, 255, 255, 120, op: BlendOp.additive);
      for (var i = 0; i < dark.data.length; i += 4) {
        expect(dark.data[i] >= before.data[i], isTrue); // 加法不压暗
      }
    });

    test('screen 混合保住高光层次，截断加法把近白区一起撞死', () {
      // 同一束白光打在 200 与 240 两处高光上：additive 把两者都推到 255，
      // 高光内部的落差被抹平；screen 渐近到白，200→213、240→244 仍分得开。
      RgbaImage strip() => RgbaImage(width: 2, height: 1)
        ..data.setRange(0, 8, [200, 200, 200, 255, 240, 240, 240, 255]);
      final add = strip();
      blendPixel(add, 0, 0, 255, 255, 255, 60, op: BlendOp.additive);
      blendPixel(add, 1, 0, 255, 255, 255, 60, op: BlendOp.additive);
      expect(add.data[0], 255);
      expect(add.data[4], 255); // 撞死：两点同值
      final scr = strip();
      blendPixel(scr, 0, 0, 255, 255, 255, 60, op: BlendOp.screen);
      blendPixel(scr, 1, 0, 255, 255, 255, 60, op: BlendOp.screen);
      expect(scr.data[0], greaterThan(add.data[0] - 45)); // 仍提亮
      expect(scr.data[4], greaterThan(scr.data[0])); // 落差保留
      expect(scr.data[4], lessThan(255)); // 未截断
    });

    test('additive 分支逐字复现 v1.2 的截断加法（回滚承诺）', () {
      // 合成器的 _blendAddPx / _applyLightSweep 现在都委派到这里，
      // 所以 legacy 档的提亮必须恒等于 v1.2 的 min(255, d + (s*a)~/255)。
      for (final d0 in [0, 7, 128, 200, 250, 255]) {
        for (final cov in [1, 2, 40, 127, 200, 255]) {
          for (final col in [
            (255, 255, 255),
            (255, 250, 230),
            (220, 235, 255)
          ]) {
            final f = RgbaImage(width: 1, height: 1)
              ..data.setRange(0, 4, [d0, d0, d0, 255]);
            blendPixel(f, 0, 0, col.$1, col.$2, col.$3, cov,
                op: BlendOp.additive);
            expect(f.data[0], math.min(255, d0 + (col.$1 * cov) ~/ 255));
            expect(f.data[1], math.min(255, d0 + (col.$2 * cov) ~/ 255));
            expect(f.data[2], math.min(255, d0 + (col.$3 * cov) ~/ 255));
            expect(f.data[3], 255); // 提亮不动 alpha
          }
        }
      }
      // 纯白光：(255*a)~/255 == a，等价于 v1.2 内联写的 min(255, d + a)
      for (var a = 0; a <= 255; a++) {
        final f = RgbaImage(width: 1, height: 1)
          ..data.setRange(0, 4, [13, 13, 13, 255]);
        blendPixel(f, 0, 0, 255, 255, 255, a, op: BlendOp.additive);
        expect(f.data[0], math.min(255, 13 + a), reason: 'a=$a');
      }
    });

    test('screen 不压暗、零覆盖恒等，且增亮量不超过截断加法', () {
      for (var d = 0; d <= 255; d++) {
        for (final a in [0, 1, 37, 128, 254]) {
          final s = RgbaImage(width: 1, height: 1)
            ..data.setRange(0, 4, [d, d, d, 255]);
          blendPixel(s, 0, 0, 255, 250, 230, a, op: BlendOp.screen);
          expect(s.data[0] >= d, isTrue, reason: 'd=$d a=$a 被压暗');
          expect(s.data[0] <= 255, isTrue);
          expect(s.data[1] >= s.data[2], isTrue); // 通道间次序不被破坏
          final clip = RgbaImage(width: 1, height: 1)
            ..data.setRange(0, 4, [d, d, d, 255]);
          blendPixel(clip, 0, 0, 255, 250, 230, a, op: BlendOp.additive);
          // screen 的增亮量 ≤ 加法：越接近白越收敛，不会额外炸亮。
          expect(s.data[0] <= clip.data[0], isTrue, reason: 'd=$d a=$a');
          expect(s.data[3], 255); // alpha 不参与
        }
      }
      final same = RgbaImage(width: 1, height: 1)
        ..data.setRange(0, 4, [123, 77, 200, 255]);
      blendPixel(same, 0, 0, 255, 255, 255, 0, op: BlendOp.screen);
      expect(same.data[0], 123); // 零覆盖 = 恒等
    });

    test('drawRingAA 只在环带内落笔', () {
      final f = _blank(60, 60);
      drawRingAA(f, 30.0, 30.0, 14.0, 2.5, 255, 255, 255, 220);
      var lit = 0;
      for (var y = 0; y < 60; y++) {
        for (var x = 0; x < 60; x++) {
          final d =
              math.sqrt(math.pow(x + 0.5 - 30, 2) + math.pow(y + 0.5 - 30, 2));
          final on = f.luminance(y * 60 + x) > 8;
          if (d <= 12 || d >= 18) {
            expect(on, isFalse, reason: '($x,$y) d=$d 环带外仍落笔');
          }
          if (on) lit++;
        }
      }
      expect(lit, greaterThan(40));
      expect(f.luminance(30 * 60 + 30), 0); // 空心
    });

    test('越界与零参调用是空操作，不抛也不越写', () {
      final f = _blank(16, 16);
      drawSegmentAA(f, -40.5, -30.25, 5.4, 3.75, 255, 255, 255, 255, 2.0);
      drawDiscAA(f, -3, 20, 6, 255, 255, 255, 255);
      drawRingAA(f, 19, -2, 5, 2, 255, 255, 255, 255);
      drawSegmentAA(f, 1, 1, 1, 1, 255, 255, 255, 200, 1.0); // 退化点
      drawDiscAA(f, 8, 8, 0, 255, 255, 255, 255); // 零半径
      drawSegmentAA(f, 2, 2, 12, 12, 255, 255, 255, 0, 1.0); // alpha=0
      expect(f.data.where((v) => v > 0).length, greaterThan(0));
    });

    test('同参数两次调用逐字节一致（确定性）', () {
      final a = _blank(48, 48), b = _blank(48, 48);
      for (final f in [a, b]) {
        drawSegmentAA(f, 3.3, 6.7, 44.1, 41.2, 200, 220, 255, 190, 1.6,
            tailFade: 0.5, tailPow: 2);
        drawDiscAA(f, 24.25, 24.75, 6.5, 255, 240, 200, 160,
            op: BlendOp.screen);
        drawRingAA(f, 24.25, 24.75, 12.25, 1.5, 255, 255, 255, 90,
            op: BlendOp.additive);
      }
      expect(a.data, equals(b.data));
    });
  });
}
