import 'dart:math' as math;
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

/// Phase D 管线测试：主体钳制 × LayerSplitter 联动（人物割裂感根除）+
/// MotionPipeline 接线契约（configHash 不变、缓存 tag、空掩码逐字节降级）。

/// 确定性「骑跨深度带」场景：背景 0.02；中心圆盘（r = w/4）内纵向渐变
/// 0.2 → 0.6。分位阈值 t1=0.30 / t2=0.35 横穿圆盘上部——无钳制时同一
/// 人物被切进中/近多层（割裂现场）；钳制后整体单带。
class RidingDepthEstimator implements DepthEstimator {
  const RidingDepthEstimator();

  @override
  DepthMap estimate(RgbaImage img) {
    final dm = DepthMap(img.width, img.height);
    final cx = img.width / 2, cy = img.height / 2;
    final r = img.width / 4;
    for (var y = 0; y < img.height; y++) {
      for (var x = 0; x < img.width; x++) {
        final dx = x - cx, dy = y - cy;
        dm.data[y * img.width + x] =
            dx * dx + dy * dy <= r * r ? 0.2 + 0.4 * (y / img.height) : 0.02;
      }
    }
    return dm;
  }
}

/// 与 [RidingDepthEstimator] 同几何的主体掩码（圆盘）。
SubjectMask ridingMask(int w, int h) {
  final prob = List<double>.filled(w * h, 0);
  final cx = w / 2, cy = h / 2;
  final r = w / 4;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - cx, dy = y - cy;
      if (dx * dx + dy * dy <= r * r) prob[y * w + x] = 1.0;
    }
  }
  return SubjectMask.fromProbability(
      prob: prob, probWidth: w, probHeight: h, width: w, height: h);
}

/// 记录调用次数的假分割器：始终返回注入的掩码。
class RecordingSegmenter extends SubjectSegmenter {
  RecordingSegmenter(this.mask);

  final SubjectMask mask;
  int calls = 0;

  @override
  SubjectMask segment(RgbaImage panel) {
    calls++;
    return mask;
  }

  @override
  String get cacheTag => 'u2netp@v1';
}

RgbaImage _grayPage() {
  final img = RgbaImage(width: 240, height: 240);
  for (var y = 0; y < 240; y++) {
    for (var x = 0; x < 240; x++) {
      img.setPixel(x, y, 128, 128, 128);
    }
  }
  return img;
}

/// 两格页（白底 + 上下棋盘 + 12px 白带），供 panelAware 路径使用。
RgbaImage twoPanelPage() {
  final img = RgbaImage(width: 240, height: 240);
  for (var y = 0; y < 240; y++) {
    for (var x = 0; x < 240; x++) {
      img.setPixel(x, y, 255, 255, 255);
    }
  }
  for (var y = 0; y < 100; y++) {
    for (var x = 0; x < 240; x++) {
      final dark = (x ~/ 12 + y ~/ 12).isEven;
      img.setPixel(x, y, dark ? 40 : 220, dark ? 40 : 220, 40);
    }
  }
  for (var y = 112; y < 240; y++) {
    for (var x = 0; x < 240; x++) {
      final dark = (x ~/ 12 + (y - 112) ~/ 12).isEven;
      img.setPixel(x, y, dark ? 30 : 210, dark ? 30 : 210, 30);
    }
  }
  return img;
}

EffectConfig _config({bool panelAware = false}) =>
    EffectConfig.fromJson(<String, dynamic>{
      'effects': <String>['parallax'],
      'fps': 12,
      'durationSec': 0.5,
      'maxDimension': 240,
      'layerCount': 3,
      'panelAware': panelAware,
      'outputFormat': 'gif',
      'seed': 7,
    });

void main() {
  group('LayerSplitter 联动：钳制根除骑跨割裂', () {
    const est = RidingDepthEstimator();

    /// 圆盘内部像素（避开掩码/双线性边界环）。
    List<(int, int)> interiorPixels(int w, int h) {
      final cx = w / 2, cy = h / 2;
      final r = w / 4 - 4;
      final out = <(int, int)>[];
      for (var y = 0; y < h; y += 2) {
        for (var x = 0; x < w; x += 2) {
          final dx = x - cx, dy = y - cy;
          if (dx * dx + dy * dy <= r * r) out.add((x, y));
        }
      }
      return out;
    }

    /// 像素的层归属：alpha 最大的层（≤128 视为不属于任何层，跳过）。
    int assignment(List<LayerImage> layers, int x, int y) {
      var best = -1, bestA = 128;
      for (var li = 0; li < layers.length; li++) {
        final a = layers[li].image.data[(y * 240 + x) * 4 + 3];
        if (a > bestA) {
          bestA = a;
          best = li;
        }
      }
      return best;
    }

    test('无钳制（负对照）：主体像素分属多层——割裂现象确实存在', () {
      final img = _grayPage();
      final depth = est.estimate(img);
      final layers = LayerSplitter(layerCount: 3, tier: RenderTier.standard)
          .split(img, depth);
      final seen = <int>{};
      for (final (x, y) in interiorPixels(240, 240)) {
        final a = assignment(layers, x, y);
        if (a >= 0) seen.add(a);
      }
      expect(seen.length, greaterThan(1),
          reason: '无钳制时主体深度骑跨 t1/t2，人物被切进多层（割裂现场）');
    });

    test('钳制 + 主体带覆盖：主体像素全部落在同一层（近层）', () {
      final img = _grayPage();
      final depth = est.estimate(img);
      final mask = ridingMask(240, 240);
      final medians = clampSubjectDepth(depth, mask);
      final layers = LayerSplitter(layerCount: 3, tier: RenderTier.standard)
          .split(img, depth,
              subjectMask: mask,
              subjectMedians: medians,
              subjectStretchPx: 24);
      final seen = <int>{};
      for (final (x, y) in interiorPixels(240, 240)) {
        final a = assignment(layers, x, y);
        expect(a, 2, reason: '主体带覆盖后整体落入近层 ($x,$y)');
        seen.add(a);
      }
      expect(seen, {2});
    });

    test('主体带覆盖语义：主体 alpha 实心硬边，背景羽化保留（D5 核心契约）', () {
      final img = _grayPage();
      final depth = est.estimate(img);
      final mask = ridingMask(240, 240);
      final medians = clampSubjectDepth(depth, mask);
      expect(depth.constantValued, isFalse,
          reason: '不再整场恒值化——背景带边界保持羽化');
      final layers = LayerSplitter(layerCount: 3, tier: RenderTier.standard)
          .split(img, depth, subjectMask: mask, subjectMedians: medians);
      // 主体内部像素：所有层 alpha ∈ {0, 255}（覆盖式 1/0，无半透明）。
      for (final (x, y) in interiorPixels(240, 240)) {
        for (final l in layers) {
          final a = l.image.data[(y * 240 + x) * 4 + 3];
          expect(a == 0 || a == 255, isTrue, reason: '主体实心 ($x,$y)');
        }
      }
      // 背景带边界（羽化活着）：存在中间 alpha 的背景像素。
      var soft = 0;
      for (var i = 0; i < 240 * 240; i++) {
        final a = layers[0].image.data[i * 4 + 3];
        if (a > 0 && a < 255) soft++;
      }
      expect(soft, greaterThan(0), reason: '背景过渡带仍被羽化（非硬 membership）');
    });
    test('layerPhaseOffsets：null 与全 0 逐字节一致，−π 改变帧且等价半周期平移',
        () {
      final img = _grayPage();
      // 等价断言用纯羽化层（无主体硬边）：硬 alpha 阶梯会把亚像素位移差
      // 放大成边界像素的整字节差，无法做字节级等价比较。
      final plainDepth = est.estimate(img);
      final plain =
          LayerSplitter(layerCount: 3, tier: RenderTier.standard)
              .split(img, plainDepth);
      final cfg = _config();
      int diffSum(RgbaImage a, RgbaImage b) {
        var s = 0;
        for (var i = 0; i < a.data.length; i++) {
          s += (a.data[i] - b.data[i]).abs();
        }
        return s;
      }

      final baseA = FrameCompositor(plain, img, cfg).renderFrame(0.1);
      final zeros = FrameCompositor(plain, img, cfg,
              layerPhaseOffsets: List<double>.filled(plain.length, 0.0))
          .renderFrame(0.1);
      expect(diffSum(baseA, zeros), 0, reason: '全 0 偏移 = 不参与');
      // 全层统一 −π：整体等价于半周期时间平移（rank0 无偏移时两帧的
      // rank0 位移本来就不同，无法做整帧等价）。
      final shifted = FrameCompositor(plain, img, cfg,
              layerPhaseOffsets: List<double>.filled(plain.length, -math.pi))
          .renderFrame(0.1);
      expect(diffSum(baseA, shifted), greaterThan(0),
          reason: '相位偏移 −π 改变帧');
      // 相位跟随语义：全部层 −π 的帧在 t 的位移 == 原帧在 t + 半周期的
      // 位移（durationSec=0.5、cycles=1 → 半周期 0.25s）。软羽化场下亚
      // 像素浮点噪声穿双线性采样后允许 ≤2/255 的字节差。
      final halfAhead = FrameCompositor(plain, img, cfg).renderFrame(0.35);
      var maxDelta = 0;
      for (var i = 0; i < shifted.data.length; i++) {
        final d = (shifted.data[i] - halfAhead.data[i]).abs();
        if (d > maxDelta) maxDelta = d;
      }
      expect(maxDelta, lessThanOrEqualTo(2),
          reason: '−π 相位 = 半周期平移（反相 → 同相的数学等价，浮点容差）');

      // 主体场景（混合偏移 [0,−π,−π]：主体层跟随、远带保持反相）：真实改变帧。
      final depth = est.estimate(img);
      final mask = ridingMask(240, 240);
      final medians = clampSubjectDepth(depth, mask);
      final ls = LayerSplitter(layerCount: 3, tier: RenderTier.standard)
          .split(img, depth, subjectMask: mask, subjectMedians: medians);
      final subjBase = FrameCompositor(ls, img, cfg).renderFrame(0.1);
      final subjShifted = FrameCompositor(ls, img, cfg,
              layerPhaseOffsets: [0.0, -math.pi, -math.pi])
          .renderFrame(0.1);
      expect(diffSum(subjBase, subjShifted), greaterThan(0));
    });
  });

  group('MotionPipeline 接线', () {
    test('未注入分割器：subjectDirTag 为空串（既有命名逐字节不变）', () {
      expect(MotionPipeline(_config()).subjectDirTag, '');
    });

    test('注入：cacheTag 白名单清洗进目录后缀', () {
      final p = MotionPipeline(_config(),
          subjectSegmenter: RecordingSegmenter(SubjectMask.empty(240, 240)));
      expect(p.subjectDirTag, '_s_u2netp_v1',
          reason: '@ 不是 [0-9A-Za-z_-]，替换为 _');
      final emptyTag = _EmptyTagSegmenter();
      expect(MotionPipeline(_config(), subjectSegmenter: emptyTag).subjectDirTag,
          '_s');
    });

    test('configHash 不变（执行期依赖铁律）', () {
      final cfg = _config();
      expect(
        MotionPipeline(cfg,
                subjectSegmenter: RecordingSegmenter(SubjectMask.empty(240, 240)))
            .config
            .configHash,
        MotionPipeline(cfg).config.configHash,
      );
    });

    test('注入空掩码（降级形态）：GIF 输出与未注入逐字节一致', () async {
      final input = Uint8List.fromList(ImageIO.encodePngFrame(_grayPage()));
      final a = await MotionPipeline(_config())
          .processBytes(input: input, includeFirstFrame: false);
      final b = await MotionPipeline(_config(),
              subjectSegmenter:
                  RecordingSegmenter(SubjectMask.empty(240, 240)))
          .processBytes(input: input, includeFirstFrame: false);
      expect(a.frameCount, b.frameCount);
      expect(b.gifBytes, isNotNull);
      for (var i = 0; i < a.gifBytes!.length; i++) {
        expect(b.gifBytes![i], a.gifBytes![i], reason: '字节 $i');
      }
      expect(b.gifBytes!.length, a.gifBytes!.length);
    });

    test('整页路径：分割器调用一次', () async {
      final seg = RecordingSegmenter(SubjectMask.empty(240, 240));
      await MotionPipeline(_config(), subjectSegmenter: seg)
          .processBytes(
              input: Uint8List.fromList(ImageIO.encodePngFrame(_grayPage())));
      expect(seg.calls, 1);
    });

    test('分格路径：分割器逐格调用', () async {
      final seg = RecordingSegmenter(SubjectMask.empty(240, 240));
      await MotionPipeline(_config(panelAware: true), subjectSegmenter: seg)
          .processBytes(
              input:
                  Uint8List.fromList(ImageIO.encodePngFrame(twoPanelPage())));
      expect(seg.calls, 2, reason: '两格页 → 每格独立分割');
    });

    test('后台 isolate：subjectSegmenterFactory 通道生效', () async {
      // 闭包捕获的对象跨 isolate 是副本，调用计数无法传回；改从产物观测：
      // 后台通道与同步通道（同分割器）输出一致，且与未注入基线不同。
      final input = Uint8List.fromList(ImageIO.encodePngFrame(_grayPage()));
      final baseline =
          await MotionPipeline(_config()).processBytes(input: input);
      final sync = await MotionPipeline(_config(),
              depthEstimator: const RidingDepthEstimator(),
              subjectSegmenter: RecordingSegmenter(ridingMask(240, 240)))
          .processBytes(input: input);
      final bg = await processBytesInBackground(
        input: input,
        config: _config(),
        depthEstimatorFactory: () => const RidingDepthEstimator(),
        subjectSegmenterFactory: () =>
            RecordingSegmenter(ridingMask(240, 240)),
      );
      expect(bg.frameCount, sync.frameCount);
      expect(bg.gifBytes!.length, sync.gifBytes!.length);
      for (var i = 0; i < sync.gifBytes!.length; i++) {
        expect(bg.gifBytes![i], sync.gifBytes![i], reason: '字节 $i');
      }
      var differs = baseline.gifBytes!.length != sync.gifBytes!.length;
      for (var i = 0; !differs && i < sync.gifBytes!.length; i++) {
        differs = baseline.gifBytes![i] != sync.gifBytes![i];
      }
      expect(differs, isTrue, reason: '掩码真实生效（与未注入基线输出不同）');
    });
  });
}

class _EmptyTagSegmenter extends SubjectSegmenter {
  @override
  SubjectMask segment(RgbaImage panel) => SubjectMask.empty(
      panel.width, panel.height);

  @override
  String get cacheTag => '';
}
