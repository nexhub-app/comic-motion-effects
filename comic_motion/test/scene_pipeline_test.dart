import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

/// 两格合成页（240x240）：上格 = 白底密集小暗斑（文字格结构代理），
/// 中间 12px 白带（PanelSplitter 可检出），下格 = 12px 棋盘（大色块，
/// 无文字斑点）。上格被启发式判静，下格保持动——「对话格不动、动作格动」
/// 的最小确定性场景。
RgbaImage twoPanelPage() {
  final img = RgbaImage(width: 240, height: 240);
  // 整页白底（未画的像素是透明黑，白带检测会失败）。
  for (var y = 0; y < 240; y++) {
    for (var x = 0; x < 240; x++) {
      img.setPixel(x, y, 255, 255, 255);
    }
  }
  // 上格 y 0..99：白底 + **去格点化**暗斑 + 两侧棋盘纹理柱（左 16px、右
  // 12px）。柱让每一行都有非白像素（斑点行间的白缝若全宽达标，会被
  // PanelSplitter 当成分隔白带把格切碎——真实对话格由气泡边框/人物线稿
  // 扮演这个角色）；斑点直接贴进两侧柱区（x 14..225），柱与斑点之间不留
  // 全白缝——缝宽 ≥1.2px 会被纵向白带检测切成独立格（纯棋盘碎片会被判
  // 动）。右柱 12px < minPanelFrac×240，即使被切出也会并回上一格。
  // 棋盘纹理方向中性，不抬 dirCoh。斑点**去格点化**（确定性行内抖动）：
  // 等距点阵会被 M1 网点周期性特征否决（真实字形不是格点阵）。
  var speckState = 20261025;
  int speckNext(int max) {
    speckState = (speckState * 6364136223846793005 + 1442695040888963407) &
        0x7fffffffffffffff;
    return (speckState >> 33) % max;
  }

  var speckGy = 2;
  while (speckGy < 95) {
    var speckGx = 14 + speckNext(5);
    while (speckGx < 222) {
      final runLen = 1 + speckNext(4);
      final thick = 2 + speckNext(2);
      final jx = speckNext(3);
      for (var dy = 0; dy < thick; dy++) {
        for (var dx = 0; dx < runLen; dx++) {
          final px = speckGx + dx + jx, py = speckGy + dy;
          if (px < 226 && py < 97) img.setPixel(px, py, 30, 30, 30);
        }
      }
      speckGx += runLen + 3 + speckNext(3);
    }
    speckGy += 6 + speckNext(4);
  }
  for (var y = 0; y < 100; y++) {
    for (var x = 0; x < 240; x++) {
      if (x < 16 || x >= 228) {
        final dark = (x ~/ 8 + y ~/ 8).isEven;
        img.setPixel(x, y, dark ? 40 : 220, dark ? 40 : 220, 40);
      }
    }
  }
  // 白带 y 100..111 保持白底。
  // 下格 y 112..239：12px 棋盘。
  for (var y = 112; y < 240; y++) {
    for (var x = 0; x < 240; x++) {
      final dark = (x ~/ 12 + (y - 112) ~/ 12).isEven;
      img.setPixel(x, y, dark ? 40 : 220, dark ? 40 : 220, 40);
    }
  }
  return img;
}

List<int> _pngEncode(RgbaImage img) => ImageIO.encodePngFrame(img);

EffectConfig _config() => EffectConfig.fromJson(const <String, dynamic>{
      'effects': <String>['parallax'],
      'fps': 12,
      'durationSec': 0.5, // 6 帧
      'maxDimension': 240,
      'layerCount': 2,
      'panelAware': true,
      'outputFormat': 'gif',
      'seed': 7,
    });

int _diffSum(RgbaImage a, RgbaImage b, PixelRect r) {
  var sum = 0;
  for (var y = r.y; y < r.y + r.height; y++) {
    for (var x = r.x; x < r.x + r.width; x++) {
      final o = (y * a.width + x) * 4;
      sum += (a.data[o] - b.data[o]).abs() +
          (a.data[o + 1] - b.data[o + 1]).abs() +
          (a.data[o + 2] - b.data[o + 2]).abs();
    }
  }
  return sum;
}

const _top = PixelRect(0, 0, 240, 100);
const _bottom = PixelRect(0, 112, 240, 128);

/// 渲染并取帧 0 与末帧的栅格（经 onFrame PNG 通路，与产物同源）。
/// [build] 接收 onFrame 回调（管线 ctor 参数），负责把管线构造出来。
Future<(RgbaImage, RgbaImage, int, List<String>)> _renderFrames(
    MotionPipeline Function(void Function(int, Uint8List) onFrame) build) async {
  final frames = <int, Uint8List>{};
  final r = await build((i, png) => frames[i] = png).processBytes(
    input: Uint8List.fromList(_pngEncode(twoPanelPage())),
    includeFirstFrame: false,
  );
  expect(frames.length, r.frameCount,
      reason: '帧流事件数 == frameCount（压制时 n=1）');
  final f0 = ImageIO.decode(frames[0]!);
  final f3 = ImageIO.decode(frames[frames.length - 1]!);
  return (f0, f3, r.frameCount, r.warnings);
}

void main() {
  group('FrameCompositor layerMotionScales（合成器契约）', () {
    RgbaImage base() => twoPanelPage();

    List<LayerImage> layersFor(RgbaImage b) {
      final d = const HeuristicDepthEstimator().estimate(b);
      return LayerSplitter(layerCount: 2, tier: RenderTier.standard)
          .split(b, d);
    }

    test('默认（不传）与显式 null 逐字节一致', () {
      final b = base();
      final ls = layersFor(b);
      final cfg = _config();
      final a = FrameCompositor(ls, b, cfg).renderFrame(0.25);
      final c =
          FrameCompositor(ls, b, cfg, layerMotionScales: null).renderFrame(0.25);
      for (var i = 0; i < a.data.length; i++) {
        expect(c.data[i], a.data[i], reason: '像素 $i');
      }
    });

    test('parallax-only 配置下全 0 scale → 帧间时间不变（该层集合静止）', () {
      final b = base();
      final ls = layersFor(b);
      final cfg = _config();
      final zeros = List<double>.filled(ls.length, 0.0);
      final f1 = FrameCompositor(ls, b, cfg, layerMotionScales: zeros)
          .renderFrame(0.25);
      final f2 = FrameCompositor(ls, b, cfg, layerMotionScales: zeros)
          .renderFrame(0.75);
      expect(_diffSum(f1, f2, PixelRect(0, 0, b.width, b.height)), 0,
          reason: '幅度为 0 ⇒ 所有帧相同（静止），不受 snapWave 直流偏置影响');
    });

    test('全 1.0 scale 与不传逐字节一致（乘 1 无操作）', () {
      final b = base();
      final ls = layersFor(b);
      final cfg = _config();
      final ones = List<double>.filled(ls.length, 1.0);
      final a = FrameCompositor(ls, b, cfg).renderFrame(0.25);
      final c = FrameCompositor(ls, b, cfg, layerMotionScales: ones)
          .renderFrame(0.25);
      expect(_diffSum(a, c, PixelRect(0, 0, b.width, b.height)), 0);
    });
  });

  group('管线：动效画面判断（格级裁决）', () {
    test('内置启发式：文字格静（跨帧差分 0）、棋盘格动（差分 >0）', () async {
      final (f0, f3, n, _) = await _renderFrames((onFrame) => MotionPipeline(
          _config(),
          panelMotionJudge: const HeuristicPanelMotionJudge(),
          onFrame: onFrame));
      expect(n, 6);
      expect(_diffSum(f0, f3, _top), 0, reason: '文字格不需要动效');
      expect(_diffSum(f0, f3, _bottom), greaterThan(0),
          reason: '动作格保持动效');
    });

    test('侧车压制上格（无 judge 注入）：同语义生效', () async {
      const scene = '{"version":1,"panels":['
          '{"x":0,"y":0,"w":1,"h":0.5,"motion":false}]}';
      final (f0, f3, n, _) = await _renderFrames(
          (onFrame) => MotionPipeline(_config(), scene: scene, onFrame: onFrame));
      expect(n, 6);
      expect(_diffSum(f0, f3, _top), 0);
      expect(_diffSum(f0, f3, _bottom), greaterThan(0));
    });

    test('侧车优先于启发式：整页 scale 0.5 覆盖文字格的 0.0 → 上格也动，'
        '且幅度介于静与满幅之间（同区域对比 scale 才单调——diff 正比于'
        '边缘密度×位移，跨区域比会被频率内容干扰）', () async {
      // 同一页面两次渲染（只差侧车 scale），各自取帧 0 与末帧的上格差分。
      Future<(int, int)> topDiffFor(String scene) async {
        final frames = <int, Uint8List>{};
        final r = await MotionPipeline(_config(), scene: scene,
                onFrame: (i, png) => frames[i] = png)
            .processBytes(
                input: Uint8List.fromList(_pngEncode(twoPanelPage())));
        expect(r.frameCount, 6);
        final f0 = ImageIO.decode(frames[0]!);
        final f5 = ImageIO.decode(frames[r.frameCount - 1]!);
        return (_diffSum(f0, f5, _top), _diffSum(f0, f5, _bottom));
      }

      final (halfTop, halfBottom) = await topDiffFor(
          '{"version":1,"panels":[{"x":0,"y":0,"w":1,"h":1,"motion":true,'
          '"scale":0.5}]}');
      final (fullTop, _) = await topDiffFor(
          '{"version":1,"panels":[{"x":0,"y":0,"w":1,"h":1,"motion":true,'
          '"scale":1.0}]}');
      expect(halfTop, greaterThan(0),
          reason: '侧车 scale 0.5 覆盖启发式的 0.0（侧车优先）');
      expect(halfTop, lessThan(fullTop),
          reason: '0.5 幅度小于 1.0（同区域同内容，单调成立）');
      expect(halfBottom, greaterThan(0));
    });

    test('全格判静 → 单帧输出（n=1）+ scene gate warning', () async {
      const scene = '{"version":1,"panels":['
          '{"x":0,"y":0,"w":1,"h":0.5,"motion":false},'
          '{"x":0,"y":0.5,"w":1,"h":0.5,"motion":false}]}';
      final r = await MotionPipeline(_config(), scene: scene)
          .processBytes(input: Uint8List.fromList(_pngEncode(twoPanelPage())));
      expect(r.frameCount, 1);
      expect(r.warnings.join('\n'), contains('scene gate'));
    });

    test('无 judge 无侧车：文字格照常动（既有路径零变化）', () async {
      final (f0, f3, n, _) =
          await _renderFrames((onFrame) => MotionPipeline(_config(), onFrame: onFrame));
      expect(n, 6);
      expect(_diffSum(f0, f3, _top), greaterThan(0));
    });

    test('judge 与侧车都不进 configHash（执行期依赖铁律）', () {
      final cfg = _config();
      const scene = '{"version":1,"panels":[]}';
      expect(
        MotionPipeline(cfg,
                panelMotionJudge: const HeuristicPanelMotionJudge(),
                scene: scene)
            .config
            .configHash,
        MotionPipeline(cfg).config.configHash,
      );
    });

    test('scene 侧车文本指纹：非空、随文本变化（缓存撞名论证）', () {
      const a = '{"version":1,"panels":[{"x":0,"y":0,"w":1,"h":1,"motion":false}]}';
      const b = '{"version":1,"panels":[{"x":0,"y":0,"w":1,"h":1,"motion":true}]}';
      final pa = MotionPipeline(_config(), scene: a);
      final pb = MotionPipeline(_config(), scene: b);
      expect(pa.sceneDigest, isNotNull);
      expect(pb.sceneDigest, isNotNull);
      expect(pa.sceneDigest, isNot(pb.sceneDigest));
      expect(pa.sceneDirTag, '_${pa.sceneDigest}');
      expect(MotionPipeline(_config()).sceneDigest, isNull);
    });

    test('坏 sidecar JSON：解析告警冒泡到 PipelineResult.warnings，渲染照常',
        () async {
      final r = await MotionPipeline(_config(), scene: '{bad json')
          .processBytes(input: Uint8List.fromList(_pngEncode(twoPanelPage())));
      expect(r.warnings.join('\n'), contains('scene'));
      expect(r.frameCount, 6, reason: '侧车不可用时回落：无 judge → 全动');
    });
  });
}
