import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// W5：分格感知分层 —— 横向白带检测、逐格独立分层、格边界裁剪。
///
/// 红线锚点：panelAware 默认 false 不写入序列化（configHash 不变）；单格/
/// 无白带图 on/off 逐字节等价（自动回退）；多格图白带行不串色（格边界
/// 裁剪）；并行（worker 携带 ranks/clips）与串行产物一致；确定性。
void main() {
  /// 两格竖排图：上格红块（30..120）、白带（140..160）、下格蓝块（180..280）。
  RgbaImage twoPanelRaster() {
    final im = RgbaImage(width: 200, height: 300);
    for (var y = 0; y < 300; y++) {
      for (var x = 0; x < 200; x++) {
        final o = (y * 200 + x) * 4;
        im.data[o + 3] = 255;
        if (y >= 140 && y < 160) {
          im.data[o] = 255;
          im.data[o + 1] = 255;
          im.data[o + 2] = 255;
        } else if (y < 140) {
          final inRed = y >= 30 && y < 120 && x >= 40 && x < 160;
          im.data[o] = inRed ? 200 : 255;
          im.data[o + 1] = inRed ? 30 : 255;
          im.data[o + 2] = inRed ? 30 : 255;
        } else {
          final inBlue = y >= 180 && y < 280 && x >= 30 && x < 170;
          im.data[o] = inBlue ? 30 : 255;
          im.data[o + 1] = inBlue ? 30 : 255;
          im.data[o + 2] = inBlue ? 200 : 255;
        }
      }
    }
    return im;
  }

  RgbaImage noGutterRaster() {
    final im = RgbaImage(width: 200, height: 300);
    for (var y = 0; y < 300; y++) {
      for (var x = 0; x < 200; x++) {
        final o = (y * 200 + x) * 4;
        im.data[o] = x * 255 ~/ 200;
        im.data[o + 1] = y * 255 ~/ 300;
        im.data[o + 2] = 128;
        im.data[o + 3] = 255;
      }
    }
    return im;
  }

  Map<String, dynamic> cfgJson(bool panel) => <String, dynamic>{
        'effects': ['parallax'],
        'fps': 24,
        'durationSec': 2.0,
        'maxDimension': 200,
        'outputFormat': 'gif',
        'seed': 7,
        if (panel) 'panelAware': true,
      };

  group('PanelSplitter：横向白带检测', () {
    test('两格图检出 2 格，内容块被格覆盖', () {
      final panels = const PanelSplitter().split(twoPanelRaster());
      expect(panels, hasLength(2));
      bool covers(PixelRect p, int y0, int y1) =>
          p.y <= y0 && p.y + p.height >= y1;
      expect(covers(panels[0], 30, 120), isTrue, reason: '上格覆盖红块');
      expect(covers(panels[1], 180, 280), isTrue, reason: '下格覆盖蓝块');
    });

    test('无白带图回退整页单格', () {
      final panels = const PanelSplitter().split(noGutterRaster());
      expect(panels, hasLength(1));
      expect(panels[0].width, 200);
      expect(panels[0].height, 300);
    });

    test('过小图直接回退', () {
      final panels = const PanelSplitter().split(RgbaImage(width: 1, height: 1));
      expect(panels, hasLength(1));
    });
  });

  group('configHash 稳定性', () {
    test('panelAware 默认不写入；true 条件写入', () {
      expect(
          EffectConfig.fromJson({'effects': ['rain']})
              .toJson()
              .containsKey('panelAware'),
          isFalse,
          reason: '默认 false 不写入 → configHash 与旧版一致');
      expect(EffectConfig.fromJson({'panelAware': true}).toJson()['panelAware'],
          true);
    });
  });

  group('管线端到端', () {
    test('多格图 panelAware 逐格分层（格数×layerCount）', () {
      final working = twoPanelRaster();
      final cfg = EffectConfig.fromJson(cfgJson(true));
      final (w, layers) = MotionPipeline(cfg).downscaleAndSplitForExport(working);
      expect(w.width, lessThanOrEqualTo(200));
      expect(layers, hasLength(6), reason: '2 格 × 3 层');
      // 每层携带格边界裁剪（画布坐标，只覆盖本格内容带）。
      final clips = layers.map((l) => l.clip).toList();
      for (var i = 0; i < layers.length; i++) {
        expect(clips[i], isNotNull, reason: 'panelAware 层必须带 clip');
      }
      // 同格 3 层 clip 相同、rank 覆盖 0..2。
      expect(clips[0], clips[1]);
      expect(clips[1], clips[2]);
      expect(clips[0]!.y, isNot(clips[3]!.y), reason: '两格 clip 不同');
      expect(layers.map((l) => l.depthRank).toSet(), {0, 1, 2});
    });

    test('白带行不串色（格边界裁剪根除跨格污染）', () {
      final cfg = EffectConfig.fromJson(cfgJson(true));
      final (working, layers) =
          MotionPipeline(cfg).downscaleAndSplitForExport(twoPanelRaster());
      final frame =
          FrameCompositor(layers, working, cfg).renderFrame(0.25);
      // 白带中心行（源 y=150 → 工作分辨率等比映射）应保持纯白。
      final wy = (150 * working.height ~/ 300).clamp(0, working.height - 1);
      for (var x = 0; x < working.width; x++) {
        final o = (wy * working.width + x) * 4;
        expect(frame.data[o], greaterThanOrEqualTo(240),
            reason: '白带行红色通道保持白（x=$x）');
        expect(frame.data[o + 1], greaterThanOrEqualTo(240));
        expect(frame.data[o + 2], greaterThanOrEqualTo(240));
      }
    });

    test('单格/无白带图 on/off 逐字节等价（自动回退）', () async {
      final bytes = Uint8List.fromList(ImageIO.encodePngFrame(noGutterRaster()));
      final off = await MotionPipeline(EffectConfig.fromJson(cfgJson(false)))
          .processBytes(input: bytes);
      final on = await MotionPipeline(EffectConfig.fromJson(cfgJson(true)))
          .processBytes(input: bytes);
      expect(on.gifBytes, isNotNull);
      expect(off.gifBytes, isNotNull);
      expect(on.gifBytes, off.gifBytes,
          reason: '无白带图回退整页分层，与关闭时逐字节一致');
    });

    test('确定性：同 config 两跑逐字节一致（含 worker 并行路径）', () async {
      final bytes =
          Uint8List.fromList(ImageIO.encodePngFrame(twoPanelRaster()));
      final a = await MotionPipeline(EffectConfig.fromJson(cfgJson(true)))
          .processBytes(input: bytes);
      final b = await MotionPipeline(EffectConfig.fromJson(cfgJson(true)))
          .processBytes(input: bytes);
      expect(a.gifBytes, b.gifBytes);
    });

    test('strip 模式正交：切片后片内仍可 panelAware', () async {
      final dir = await Directory.systemTemp.createTemp('w5_strip');
      try {
        final input = '${dir.path}${Platform.pathSeparator}in.png';
        File(input).writeAsBytesSync(
            Uint8List.fromList(ImageIO.encodePngFrame(twoPanelRaster())));
        final cfg = EffectConfig.fromJson(cfgJson(true));
        final r = await processStrip(input, '${dir.path}${Platform.pathSeparator}out',
            config: cfg);
        expect(r.slices, isNotEmpty);
        // 每片独立走标准管线（panelAware 在片内生效不报错即通过）。
        for (final s in r.slices) {
          expect(s.result.configHash, isNotEmpty);
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
