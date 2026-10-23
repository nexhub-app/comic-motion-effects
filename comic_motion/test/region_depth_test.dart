import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// 横向梯度深度：同一平涂区域内部深度连续变化，用于检验区域一致化。
class HorizontalDepthEstimator implements DepthEstimator {
  const HorizontalDepthEstimator();

  @override
  DepthMap estimate(RgbaImage img) {
    final dm = DepthMap(img.width, img.height);
    for (var y = 0; y < img.height; y++) {
      for (var x = 0; x < img.width; x++) {
        dm.data[y * img.width + x] = x / (img.width - 1);
      }
    }
    return dm;
  }
}

/// 指定「高深度方块」的估算器：其余区域 base，方块内 high。
class BoxDepthEstimator implements DepthEstimator {
  const BoxDepthEstimator({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.base,
    required this.high,
  });

  final int left;
  final int top;
  final int width;
  final int height;
  final double base;
  final double high;

  @override
  DepthMap estimate(RgbaImage img) {
    final dm = DepthMap(img.width, img.height);
    for (var y = 0; y < img.height; y++) {
      for (var x = 0; x < img.width; x++) {
        final inBox =
            x >= left && x < left + width && y >= top && y < top + height;
        dm.data[y * img.width + x] = inBox ? high : base;
      }
    }
    return dm;
  }
}

bool _allEqual(DepthMap map, Iterable<int> indices, {double eps = 1e-9}) {
  final first = map.data[indices.first];
  return indices.every((i) => (map.data[i] - first).abs() <= eps);
}

void main() {
  /// 160×120：左半纯白、右半中灰，无墨线。
  RgbaImage twoFlatBlocks() {
    final im = RgbaImage(width: 160, height: 120);
    for (var y = 0; y < 120; y++) {
      for (var x = 0; x < 160; x++) {
        final v = x < 80 ? 255 : 160;
        im.setPixel(x, y, v, v, v);
      }
    }
    return im;
  }

  test('平涂区域内部深度取区域均值（横向梯度被抹平）', () {
    final im = twoFlatBlocks();
    final wrapped = const RegionCoherentDepthEstimator(
      inner: HorizontalDepthEstimator(),
      detailMinArea: 0,
    ).estimate(im);

    final left = <int>[];
    final right = <int>[];
    for (var y = 0; y < 120; y++) {
      for (var x = 0; x < 160; x++) {
        (x < 80 ? left : right).add(y * 160 + x);
      }
    }
    expect(_allEqual(wrapped, left), isTrue, reason: '左块内部必须常数');
    expect(_allEqual(wrapped, right), isTrue, reason: '右块内部必须常数');
    // 区域均值 = 该块内横向梯度的平均（像素中心约定）。
    final leftMean = left.map((i) => (i % 160) / 159).reduce((a, b) => a + b) /
        left.length;
    final rightMean =
        right.map((i) => (i % 160) / 159).reduce((a, b) => a + b) /
            right.length;
    expect(wrapped.data[left.first], closeTo(leftMean, 1e-9));
    expect(wrapped.data[right.first], closeTo(rightMean, 1e-9));
  });

  test('墨线像素取所在墨线连通域的均值（内部一致）', () {
    final im = twoFlatBlocks();
    // 竖向墨条 x=90..109（灰度 20 < 100）。
    for (var y = 20; y < 100; y++) {
      for (var x = 90; x < 110; x++) {
        im.setPixel(x, y, 20, 20, 20);
      }
    }
    final wrapped = const RegionCoherentDepthEstimator(
      inner: HorizontalDepthEstimator(),
      detailMinArea: 0,
    ).estimate(im);

    final bar = <int>[];
    for (var y = 20; y < 100; y++) {
      for (var x = 90; x < 110; x++) {
        bar.add(y * 160 + x);
      }
    }
    expect(_allEqual(wrapped, bar), isTrue, reason: '同一墨线连通域深度必须常数');
    // 墨线上方/下方都是右块（灰 160）像素，墨线应继承右块的区域均值。
    final rightRegionValue = wrapped.data[10 * 160 + 140];
    expect(wrapped.data[bar.first], closeTo(rightRegionValue, 1e-9));
  });

  test('小面积浅色块继承邻近大区域深度（浅色字保护）', () {
    final im = RgbaImage(width: 160, height: 120);
    for (var y = 0; y < 120; y++) {
      for (var x = 0; x < 160; x++) {
        im.setPixel(x, y, 200, 200, 200);
      }
    }
    // 6×6 的浅色小方块（灰度 140 > 100，不是墨；量化色与大背景不同）。
    for (var y = 50; y < 56; y++) {
      for (var x = 50; x < 56; x++) {
        im.setPixel(x, y, 140, 140, 140);
      }
    }
    final inner = const BoxDepthEstimator(
        left: 50, top: 50, width: 6, height: 6, base: 0.1, high: 0.9);
    final protected = RegionCoherentDepthEstimator(
      inner: inner,
      detailMinArea: 64,
    ).estimate(im);
    final raw = RegionCoherentDepthEstimator(
      inner: inner,
      detailMinArea: 0,
    ).estimate(im);

    final box = <int>[];
    for (var y = 50; y < 56; y++) {
      for (var x = 50; x < 56; x++) {
        box.add(y * 160 + x);
      }
    }
    expect(protected.data[box.first], closeTo(0.1, 1e-9),
        reason: '小区域必须继承邻近大区域的深度');
    expect(_allEqual(protected, box), isTrue);
    expect(raw.data[box.first], closeTo(0.9, 1e-9),
        reason: '关闭保护时保留原区域均值');
  });

  test('大墨框内的浅色小字继承墨框深度（不穿墙吸到页面背景）', () {
    final im = RgbaImage(width: 160, height: 120);
    for (var y = 0; y < 120; y++) {
      for (var x = 0; x < 160; x++) {
        im.setPixel(x, y, 200, 200, 200);
      }
    }
    // 80×60 的大墨框（黑，>detailMinArea ⇒ 大块墨也是吸附种子），
    // 内部 6×6 白色小字（非墨小区域）。
    for (var y = 30; y < 90; y++) {
      for (var x = 40; x < 120; x++) {
        im.setPixel(x, y, 10, 10, 10);
      }
    }
    for (var y = 55; y < 61; y++) {
      for (var x = 70; x < 76; x++) {
        im.setPixel(x, y, 255, 255, 255);
      }
    }
    // inner：小字自带一套高深度（0.9），其余 0.1。
    final inner = const BoxDepthEstimator(
        left: 70, top: 55, width: 6, height: 6, base: 0.1, high: 0.9);
    final wrapped = RegionCoherentDepthEstimator(
      inner: inner,
      detailMinArea: 64,
    ).estimate(im);

    final box = <int>[];
    for (var y = 30; y < 90; y++) {
      for (var x = 40; x < 120; x++) {
        if (x >= 70 && x < 76 && y >= 55 && y < 61) continue;
        box.add(y * 160 + x);
      }
    }
    final glyph = <int>[];
    for (var y = 55; y < 61; y++) {
      for (var x = 70; x < 76; x++) {
        glyph.add(y * 160 + x);
      }
    }
    final boxValue = wrapped.data[30 * 160 + 40];
    expect(_allEqual(wrapped, box), isTrue, reason: '墨框连通域回填后必须常数');
    expect(_allEqual(wrapped, glyph), isTrue, reason: '小字区域内部必须常数');
    expect(wrapped.data[glyph.first], closeTo(boxValue, 1e-9),
        reason: '小字必须继承所属墨框的深度');
    expect(boxValue, greaterThan(0.1),
        reason: '墨框值由内部小字与边缘共同决定，必须高于背景 0.1；'
            '旧实现只拿大非墨区域当种子，字会穿过墨框吸到背景 0.1');
  });

  test('detailMinArea 边界：面积恰等于阈值不做继承', () {
    final im = RgbaImage(width: 160, height: 120);
    for (var y = 0; y < 120; y++) {
      for (var x = 0; x < 160; x++) {
        im.setPixel(x, y, 200, 200, 200);
      }
    }
    for (var y = 50; y < 58; y++) {
      for (var x = 50; x < 58; x++) {
        im.setPixel(x, y, 140, 140, 140);
      }
    }
    final inner = const BoxDepthEstimator(
        left: 50, top: 50, width: 8, height: 8, base: 0.1, high: 0.9);
    final map = RegionCoherentDepthEstimator(
      inner: inner,
      detailMinArea: 64,
    ).estimate(im);
    expect(map.data[50 * 160 + 50], closeTo(0.9, 1e-9));
  });

  test('输出标记 constantValued', () {
    final im = twoFlatBlocks();
    final map = const RegionCoherentDepthEstimator(
      inner: HorizontalDepthEstimator(),
      detailMinArea: 0,
    ).estimate(im);
    expect(map.constantValued, isTrue,
        reason: '分层器据此启用恒值安全阈值');
  });

  test('constantValued 标记让分层避开恒值（区域内部不半透明）', () {
    final img = RgbaImage(width: 100, height: 60);
    for (var y = 0; y < 60; y++) {
      for (var x = 0; x < 100; x++) {
        img.setPixel(x, y, 200, 200, 200);
      }
    }
    // 60% 像素深度 0.2、40% 像素深度 0.8：q(0.72) 恰落在 0.8 恒值上。
    DepthMap dm() {
      final d = DepthMap(100, 60);
      for (var y = 0; y < 60; y++) {
        for (var x = 0; x < 100; x++) {
          d.data[y * 100 + x] = y < 36 ? 0.2 : 0.8;
        }
      }
      return d;
    }

    final plain = LayerSplitter(layerCount: 3).split(img, dm());
    final safe = LayerSplitter(layerCount: 3).split(img, dm()..constantValued = true);
    const probe = (50 * 100 + 50) * 4 + 3;
    expect(plain[2].image.data[probe], 128,
        reason: '未标记：0.8 骑在阈值上，近层半透明');
    expect(safe[2].image.data[probe], 255,
        reason: '标记后：阈值移到 0.2/0.8 中点，近层内部完全不透明');
  });

  test('确定性：同一输入两次输出逐值一致', () {
    final im = twoFlatBlocks();
    const est = RegionCoherentDepthEstimator(
        inner: HorizontalDepthEstimator(), detailMinArea: 32);
    final a = est.estimate(im);
    final b = est.estimate(im);
    expect(a.width, b.width);
    expect(a.data, equals(b.data));
  });

  test('保留 inner 的分辨率映射与数值范围', () {
    final im = twoFlatBlocks();
    final map = RegionCoherentDepthEstimator(
      inner: HorizontalDepthEstimator(),
      detailMinArea: 0,
    ).estimate(im);
    expect(map.width, 160);
    expect(map.height, 120);
    expect(map.data.every((v) => v >= 0.0 && v <= 1.0), isTrue);
  });

  test('默认构造包装启发式（可注入管线）', () {
    final est = RegionCoherentDepthEstimator();
    expect(est.inner, isA<HeuristicDepthEstimator>());
    expect(est.colorBits, 5);
    expect(est.detailMinArea, 64);
  });
}
