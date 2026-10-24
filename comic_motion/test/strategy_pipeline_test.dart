import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

/// Phase E 画面自适应测试：PanelMotionStrategy 接缝（scale/tempo/
/// subjectBoost）、侧车加性字段、HeuristicSceneStrategyJudge 张力分档。

/// 固定策略判断器：所有格返回同一策略。
class FixedStrategyJudge extends PanelStrategyJudge {
  const FixedStrategyJudge(this.strategy);
  final PanelMotionStrategy strategy;

  @override
  List<PanelMotionStrategy> panelStrategies(RgbaImage working,
          List<PixelRect> panels, List<SubjectMask> subjects) =>
      List.filled(panels.length, strategy);
}

/// 骑跨深度带假估计器（与 subject_pipeline_test 同几何）。
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

class FixedMaskSegmenter extends SubjectSegmenter {
  FixedMaskSegmenter(this.mask);
  final SubjectMask mask;
  @override
  SubjectMask segment(RgbaImage panel) => mask;
  @override
  String get cacheTag => 'fake';
}

RgbaImage grayPage() {
  final img = RgbaImage(width: 240, height: 240);
  for (var y = 0; y < 240; y++) {
    for (var x = 0; x < 240; x++) {
      img.setPixel(x, y, 128, 128, 128);
    }
  }
  return img;
}

/// 两格页：上=文字格（白底密斑），下=12px 棋盘（动作格）。
RgbaImage twoPanelPage() {
  final img = RgbaImage(width: 240, height: 240);
  for (var y = 0; y < 240; y++) {
    for (var x = 0; x < 240; x++) {
      img.setPixel(x, y, 255, 255, 255);
    }
  }
  for (var gy = 2; gy < 97; gy += 7) {
    for (var gx = 14; gx < 226; gx += 7) {
      for (var dy = 0; dy < 3; dy++) {
        for (var dx = 0; dx < 3; dx++) {
          img.setPixel(gx + dx, gy + dy, 30, 30, 30);
        }
      }
    }
  }
  for (var y = 0; y < 100; y++) {
    for (var x = 0; x < 240; x++) {
      if (x < 16 || x >= 228) {
        final dark = (x ~/ 8 + y ~/ 8).isEven;
        img.setPixel(x, y, dark ? 40 : 220, dark ? 40 : 220, 40);
      }
    }
  }
  for (var y = 112; y < 240; y++) {
    for (var x = 0; x < 240; x++) {
      final dark = (x ~/ 12 + (y - 112) ~/ 12).isEven;
      img.setPixel(x, y, dark ? 40 : 220, dark ? 40 : 220, 40);
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

int _diffSum(RgbaImage a, RgbaImage b) {
  var s = 0;
  for (var i = 0; i < a.data.length; i++) {
    s += (a.data[i] - b.data[i]).abs();
  }
  return s;
}

void main() {
  group('FrameCompositor layerTempoScales（合成器契约）', () {
    test('null 与全 1.0 逐字节一致；tempo 2 的 t=0.125 == tempo 1 的 t=0.25', () {
      final img = grayPage();
      final depth = const RidingDepthEstimator().estimate(img);
      final ls = LayerSplitter(layerCount: 3, tier: RenderTier.standard)
          .split(img, depth);
      final cfg = _config();
      final a = FrameCompositor(ls, img, cfg).renderFrame(0.1);
      final ones = FrameCompositor(ls, img, cfg,
              layerTempoScales: List<double>.filled(ls.length, 1.0))
          .renderFrame(0.1);
      expect(_diffSum(a, ones), 0, reason: '全 1 tempo = 不参与');
      final fast = FrameCompositor(ls, img, cfg,
              layerTempoScales: List<double>.filled(ls.length, 2.0))
          .renderFrame(0.125);
      final ref = FrameCompositor(ls, img, cfg).renderFrame(0.25);
      // tempo 2 → 周期折半：t=0.125 的相位 == tempo1 在 t=0.25 的相位
      // （两条浮点路径恰好同值：2π·0.125/0.25 == 2π·0.25/0.5 == π）。
      expect(_diffSum(fast, ref), 0, reason: 'tempo 2 = 半周期处相位对齐');
    });
  });

  group('管线：画面自适应策略', () {
    test('strategyJudge scale 0.5：帧间差分介于 0 与满幅之间（幅度生效）',
        () async {
          // 用棋盘页（边缘密度均匀）：平移主导帧间差分，单调性成立。
          // （均匀灰页的差分由 Catmull-Rom 栅格边界负瓣伪影主导，非单调。）
          Future<int> diffFor(PanelMotionStrategy s) async {
            final frames = <int, Uint8List>{};
            await MotionPipeline(_config(),
                    panelStrategyJudge: FixedStrategyJudge(s),
                    onFrame: (i, png) => frames[i] = png)
                .processBytes(
                    input: Uint8List.fromList(
                        ImageIO.encodePngFrame(twoPanelPage())));
            final f0 = ImageIO.decode(frames[0]!);
            final f5 = ImageIO.decode(frames[frames.length - 1]!);
            return _diffSum(f0, f5);
          }

          final full = await diffFor(PanelMotionStrategy.neutral);
          final half = await diffFor(const PanelMotionStrategy(scale: 0.5));
          expect(full, greaterThan(0));
          expect(half, greaterThan(0));
          expect(half, lessThan(full));
          // scale 0（全格判静）→ 静态原图直通：无帧事件，原图字节原样返回。
          final frames = <int, Uint8List>{};
          final input = Uint8List.fromList(
              ImageIO.encodePngFrame(twoPanelPage()));
          final r = await MotionPipeline(_config(),
                  panelStrategyJudge:
                      const FixedStrategyJudge(PanelMotionStrategy(scale: 0.0)),
                  onFrame: (i, png) => frames[i] = png)
              .processBytes(input: input);
          expect(frames, isEmpty, reason: '直通：零帧渲染');
          expect(r.staticPassthroughBytes, input, reason: '原图零修改返回');
        });

    test('strategyJudge tempo 2：静帧节奏对齐（renderStillFrame 通路）', () async {
      final input = Uint8List.fromList(ImageIO.encodePngFrame(grayPage()));
      final fast = await MotionPipeline(_config(),
              panelStrategyJudge:
                  const FixedStrategyJudge(PanelMotionStrategy(tempo: 2.0)))
          .renderStillFrame(input: input, t: 0.125);
      final ref = await MotionPipeline(_config(),
              panelStrategyJudge: const FixedStrategyJudge(
                  PanelMotionStrategy.neutral))
          .renderStillFrame(input: input, t: 0.25);
      final a = ImageIO.decode(fast);
      final b = ImageIO.decode(ref);
      expect(_diffSum(a, b), 0, reason: 'tempo 2 在 t=0.125 与 tempo1 t=0.25 同相位');
    });

    test('subjectBoost：主体层幅度放大（需分割器注入，无分割器无增强）', () async {
      final input = Uint8List.fromList(ImageIO.encodePngFrame(grayPage()));
      Future<int> diffWithBoost(double boost) async {
        final frames = <int, Uint8List>{};
        await MotionPipeline(_config(),
                depthEstimator: const RidingDepthEstimator(),
                subjectSegmenter: FixedMaskSegmenter(ridingMask(240, 240)),
                panelStrategyJudge:
                    FixedStrategyJudge(PanelMotionStrategy(subjectBoost: boost)),
                onFrame: (i, png) => frames[i] = png)
            .processBytes(input: input);
        final f0 = ImageIO.decode(frames[0]!);
        final f5 = ImageIO.decode(frames[frames.length - 1]!);
        return _diffSum(f0, f5);
      }

      final plain = await diffWithBoost(1.0);
      final boosted = await diffWithBoost(1.5);
      expect(plain, greaterThan(0));
      expect(boosted, greaterThan(plain),
          reason: 'subjectBoost 1.5 放大主体层位移');
    });

    test('configHash 不变（策略判断器执行期依赖铁律）', () {
      final cfg = _config();
      expect(
        MotionPipeline(cfg,
                panelStrategyJudge:
                    const FixedStrategyJudge(PanelMotionStrategy.neutral))
            .config
            .configHash,
        MotionPipeline(cfg).config.configHash,
      );
    });

    test('侧车命中格优先于 strategyJudge；侧车加性字段生效', () async {
      // 侧车整页 scale 0.5 + tempo 1 → 覆盖 judge 的 tempo 2。
      const scene = '{"version":1,"panels":[{"x":0,"y":0,"w":1,"h":1,'
          '"motion":true,"scale":0.5,"tempo":1.0}]}';
      final input = Uint8List.fromList(ImageIO.encodePngFrame(grayPage()));
      final fast = await MotionPipeline(_config(),
              scene: scene,
              panelStrategyJudge:
                  const FixedStrategyJudge(PanelMotionStrategy(tempo: 2.0)))
          .renderStillFrame(input: input, t: 0.125);
      final half = await MotionPipeline(_config(), scene: scene)
          .renderStillFrame(input: input, t: 0.125);
      expect(_diffSum(ImageIO.decode(fast), ImageIO.decode(half)), 0,
          reason: '侧车命中 → tempo 1.0（judge 的 2.0 被覆盖）');
    });
  });

  group('scene 侧车加性字段解析', () {
    test('tempo/subjectBoost 合法值解析 + 越界钳制', () {
      final parse = SceneMotionParser.parse('{"version":1,"panels":['
          '{"x":0,"y":0,"w":1,"h":1,"motion":true,"tempo":1.5,"subjectBoost":1.2},'
          '{"x":0,"y":0,"w":1,"h":1,"motion":true,"tempo":99,"subjectBoost":-1}'
          ']}');
      final spec = parse.spec!;
      expect(spec.panels[0].tempo, 1.5);
      expect(spec.panels[0].subjectBoost, 1.2);
      expect(spec.panels[1].tempo, 4.0, reason: '越界钳到 [0.25, 4]');
      expect(spec.panels[1].subjectBoost, 1.0,
          reason: '负值非法 → 警告 + 回落 1.0（与 tempo 的合法钳制不同）');
      expect(parse.warnings.join(), contains('subjectBoost'),
          reason: '不静默：非法值必须产警告');
    });

    test('非法 tempo 类型：警告 + 回落 1.0，条目保留', () {
      final parse = SceneMotionParser.parse('{"version":1,"panels":['
          '{"x":0,"y":0,"w":1,"h":1,"motion":true,"tempo":"fast"}]}');
      final spec = parse.spec!;
      expect(spec.panels[0].tempo, 1.0);
      expect(spec.panels, hasLength(1));
      expect(parse.warnings.join(), contains('tempo'));
    });

    test('缺省字段 = 1.0（旧侧车零变化）', () {
      final parse = SceneMotionParser.parse(
          '{"version":1,"panels":[{"x":0,"y":0,"w":1,"h":1,"motion":false}]}');
      final p = parse.spec!.panels[0];
      expect(p.scale, 0.0);
      expect(p.tempo, 1.0);
      expect(p.subjectBoost, 1.0);
      expect(parse.warnings, isEmpty);
    });
  });

  group('HeuristicSceneStrategyJudge（张力分档）', () {
    test('文字格 → scale 0；棋盘动作格 → tempo 加快', () {
      final working = twoPanelPage();
      final panels = const PanelSplitter().split(working);
      expect(panels.length, 2);
      final strategies = const HeuristicSceneStrategyJudge()
          .panelStrategies(working, panels, [
        SubjectMask.empty(working.width, working.height),
        SubjectMask.empty(working.width, working.height),
      ]);
      expect(strategies[0].scale, 0.0, reason: '文字格静止');
      expect(strategies[1].tempo, greaterThan(1.0),
          reason: '棋盘方向笔触族 → 动作格加快节奏');
    });

    test('特写格（主体域占格大）→ tempo 放慢 + subjectBoost', () {
      // 圆盘占格 ~35%（≥ kCloseupBlobMin=0.25）的特写页。
      final img = RgbaImage(width: 200, height: 200);
      for (var y = 0; y < 200; y++) {
        for (var x = 0; x < 200; x++) {
          img.setPixel(x, y, 128, 128, 128);
        }
      }
      final prob = List<double>.filled(200 * 200, 0);
      for (var y = 0; y < 200; y++) {
        for (var x = 0; x < 200; x++) {
          final dx = x - 100, dy = y - 100;
          if (dx * dx + dy * dy <= 6400) prob[y * 200 + x] = 1.0; // r=80
        }
      }
      final mask = SubjectMask.fromProbability(
          prob: prob, probWidth: 200, probHeight: 200, width: 200, height: 200);
      expect(mask.maxBlobFrac, greaterThan(kCloseupBlobMin));
      final strategies = const HeuristicSceneStrategyJudge().panelStrategies(
          img, [PixelRect(0, 0, 200, 200)], [mask]);
      expect(strategies[0].subjectBoost, kCloseupBoost);
      expect(strategies[0].tempo, kCloseupTempo);
    });

    test('氛围格（近空渐变）→ 中幅呼吸；叙事细节格 → 默认静止（用户裁决翻转）',
        () {
      // 氛围：均匀浅灰近空页（edgeFrac≈0）。
      final atmo = RgbaImage(width: 120, height: 120);
      for (var i = 0; i < 120 * 120; i++) {
        atmo.data[i * 4] = 200;
        atmo.data[i * 4 + 1] = 200;
        atmo.data[i * 4 + 2] = 200;
        atmo.data[i * 4 + 3] = 255;
      }
      final atmoS = const HeuristicSceneStrategyJudge().panelStrategies(
          atmo, [PixelRect(0, 0, 120, 120)], [SubjectMask.empty(120, 120)]);
      expect(atmoS[0].scale, kAtmosphereScale, reason: '氛围格呼吸幅度');
      expect(atmoS[0].tempo, kAtmosphereTempo);

      // 叙事细节格：大圆斑阵列（r=10，面积>48 不误判文字斑点；圆形各向
      // 同性 → dirCoh 低不误判动作；edgeFrac≈0.14 高于氛围阈值）→ 默认静止。
      final narrative = RgbaImage(width: 120, height: 120);
      for (var y = 0; y < 120; y++) {
        for (var x = 0; x < 120; x++) {
          narrative.setPixel(x, y, 220, 220, 220);
        }
      }
      for (var cy = 14; cy < 120; cy += 28) {
        for (var cx = 14; cx < 120; cx += 28) {
          for (var y = 0; y < 120; y++) {
            for (var x = 0; x < 120; x++) {
              final dx = x - cx, dy = y - cy;
              if (dx * dx + dy * dy <= 100) {
                narrative.setPixel(x, y, 40, 40, 40);
              }
            }
          }
        }
      }
      final f = extractPanelMotionFeatures(narrative);
      expect(f.edgeFrac, greaterThan(kAtmosphereEdgeMax),
          reason: '前置：棋盘纹理确实高边缘密度');
      expect(f.speckDensity, lessThan(kTextSpeckMin),
          reason: '前置：非文字格');
      final narrS = const HeuristicSceneStrategyJudge().panelStrategies(
          narrative, [PixelRect(0, 0, 120, 120)], [SubjectMask.empty(120, 120)]);
      expect(narrS[0].scale, 0.0, reason: '叙事/细节格默认静止');
    });
  });
}
