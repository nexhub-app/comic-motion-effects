import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

RgbaImage _checker(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, (x ~/ 4) * 40 % 256, (y ~/ 4) * 40 % 256, 100, 255);
    }
  }
  return img;
}

EffectConfig _config() => EffectConfig.fromJson(const <String, dynamic>{
      'effects': <String>['parallax'],
      'fps': 12,
      'durationSec': 1.0,
      'maxDimension': 64,
      'layerCount': 3,
      'panelAware': false,
      'outputFormat': 'gif',
      'seed': 7,
    });

int _diffSum(RgbaImage a, RgbaImage b) {
  var sum = 0;
  for (var i = 0; i < a.data.length; i += 4) {
    sum += (a.data[i] - b.data[i]).abs() +
        (a.data[i + 1] - b.data[i + 1]).abs() +
        (a.data[i + 2] - b.data[i + 2]).abs();
  }
  return sum;
}

void main() {
  RgbaImage frameAt(double scale) {
    final base = _checker(64, 64);
    final d = DepthMap(64, 64);
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        d.data[y * 64 + x] = x / 63; // 渐变深度 → 三层
      }
    }
    final layers =
        LayerSplitter(layerCount: 3, tier: RenderTier.standard).split(base, d);
    final comp =
        FrameCompositor(layers, base, _config(), depthSpreadScale: scale);
    return comp.renderFrame(0.25);
  }

  test('默认 scale=1.0 与不传参数逐字节一致（默认路径铁律）', () {
    final base = _checker(64, 64);
    final d = DepthMap(64, 64);
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        d.data[y * 64 + x] = x / 63;
      }
    }
    final layers =
        LayerSplitter(layerCount: 3, tier: RenderTier.standard).split(base, d);
    final a = FrameCompositor(layers, base, _config()).renderFrame(0.25);
    final b = FrameCompositor(layers, base, _config(), depthSpreadScale: 1.0)
        .renderFrame(0.25);
    expect(_diffSum(a, b), 0);
  });

  test('scale=0.5 时帧间位移显著小于 scale=1.0（单调带 0.25-0.75）', () {
    final base = _checker(64, 64);
    final dFull = frameAt(1.0);
    final dHalf = frameAt(0.5);
    final ref = base;
    final full = _diffSum(dFull, ref).toDouble();
    final half = _diffSum(dHalf, ref).toDouble();
    expect(full, greaterThan(0));
    final ratio = half / full;
    expect(ratio, greaterThan(0.25));
    expect(ratio, lessThan(0.75));
  });

  test('scale=0.0 退化为静帧：任意 t 输出逐字节一致（时间不变性）', () {
    // 原 oracle「scale=0 的 t=0.25 帧 == 默认 scale 的 t=0 帧」不成立：
    // standard 档载体 snapWave 有直流偏置（snapWave(0)=0.42/1.24≈0.34，
    // 非零，v1.4 硬张力设计），t=0 层位移本身非零。scale=0 的正确语义 =
    // 消灭全部时间变化（ampPx=0 ⇒ 层栈恒为 (0,0,1.0)），据此断言
    // scale=0 下不同 t 的帧逐字节一致——比时间点对拍更强且不放宽。
    final base = _checker(64, 64);
    final d = DepthMap(64, 64);
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        d.data[y * 64 + x] = x / 63;
      }
    }
    final layers =
        LayerSplitter(layerCount: 3, tier: RenderTier.standard).split(base, d);
    final cfg = _config();
    RgbaImage frameAtT(double t) => FrameCompositor(layers, base, cfg,
            depthSpreadScale: 0.0)
        .renderFrame(t);
    expect(_diffSum(frameAtT(0.25), frameAtT(0.5)), 0);
    expect(_diffSum(frameAtT(0.25), frameAtT(0.0)), 0);
  });
}
