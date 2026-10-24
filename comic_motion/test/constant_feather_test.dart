import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

RgbaImage _twoColorImage(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (x < w ~/ 2) {
        img.setPixel(x, y, 200, 60, 60, 255);
      } else {
        img.setPixel(x, y, 60, 200, 60, 255);
      }
    }
  }
  return img;
}

void main() {
  test('恒值场：层 alpha 只取 {0,255}（跳过跨区羽化，边界即原画边界）',
      () {
    final img = _twoColorImage(16, 8);
    final d = DepthMap(16, 8)..constantValued = true;
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 16; x++) {
        d.data[y * 16 + x] = x < 8 ? 0.2 : 0.8;
      }
    }
    final layers = LayerSplitter(
            layerCount: 3, tier: RenderTier.standard, edgeStretchPx: 0)
        .split(img, d);
    final alphas = <int>{};
    for (final l in layers) {
      for (var i = 3; i < l.image.data.length; i += 4) {
        alphas.add(l.image.data[i]);
      }
    }
    expect(alphas.every((a) => a == 0 || a == 255), isTrue,
        reason: '实际 alpha 集合：$alphas');
  });

  test('平滑深度场：保留羽化过渡带（既有契约回归锁定）', () {
    final img = _twoColorImage(16, 8);
    final d = DepthMap(16, 8); // constantValued=false（默认）
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 16; x++) {
        d.data[y * 16 + x] = x / 15; // 平滑渐变
      }
    }
    final layers = LayerSplitter(
            layerCount: 3, tier: RenderTier.standard, edgeStretchPx: 0)
        .split(img, d);
    final intermediate = <int>{};
    for (final l in layers) {
      for (var i = 3; i < l.image.data.length; i += 4) {
        final a = l.image.data[i];
        if (a != 0 && a != 255) intermediate.add(a);
      }
    }
    expect(intermediate, isNotEmpty,
        reason: '平滑场必须有 alpha 过渡带（羽化 + membership 软边）');
  });
}
