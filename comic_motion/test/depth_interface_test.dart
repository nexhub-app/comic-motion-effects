import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// 自定义估算器：垂直线性深度（上远下近），与启发式输出必然不同。
/// （Dart 不允许函数体内声明局部类，须置于顶层。）
class LinearDepthEstimator implements DepthEstimator {
  const LinearDepthEstimator();

  @override
  DepthMap estimate(RgbaImage img) {
    final dm = DepthMap(img.width, img.height);
    for (var y = 0; y < img.height; y++) {
      for (var x = 0; x < img.width; x++) {
        dm.data[y * img.width + x] = y / (img.height - 1);
      }
    }
    return dm;
  }
}

/// W6：AI 深度接口化 —— DepthEstimator 抽象接口、注入、exportLayers 纹理集。
///
/// 红线锚点：显式注入默认启发式 == 隐式缺省（逐字节）；自定义 estimator
/// 生效（产物改变）；exportLayers 与管线内部分层同源（像素级一致）。
void main() {
  /// 简单灰度渐变测试图。
  RgbaImage gradientRaster() {
    final im = RgbaImage(width: 120, height: 160);
    for (var y = 0; y < 160; y++) {
      for (var x = 0; x < 120; x++) {
        final o = (y * 120 + x) * 4;
        im.data[o] = x * 255 ~/ 120;
        im.data[o + 1] = y * 255 ~/ 160;
        im.data[o + 2] = 100;
        im.data[o + 3] = 255;
      }
    }
    return im;
  }

  Map<String, dynamic> cfgJson() => <String, dynamic>{
        'effects': ['parallax'],
        'fps': 12,
        'durationSec': 1.0,
        'maxDimension': 120,
        'outputFormat': 'gif',
        'seed': 7,
      };

  group('DepthEstimator 接口化', () {
    test('显式注入默认启发式 == 隐式缺省（逐字节）', () async {
      final bytes =
          Uint8List.fromList(ImageIO.encodePngFrame(gradientRaster()));
      final implicit = await MotionPipeline(EffectConfig.fromJson(cfgJson()))
          .processBytes(input: bytes);
      final explicit = await MotionPipeline(EffectConfig.fromJson(cfgJson()),
              depthEstimator: const HeuristicDepthEstimator())
          .processBytes(input: bytes);
      expect(explicit.gifBytes, implicit.gifBytes,
          reason: '接口化不改变启发式输出（逐字节一致）');
    });

    test('注入自定义 estimator 生效（产物改变）', () async {
      final bytes =
          Uint8List.fromList(ImageIO.encodePngFrame(gradientRaster()));
      final heuristic = await MotionPipeline(EffectConfig.fromJson(cfgJson()))
          .processBytes(input: bytes);
      final injected = await MotionPipeline(EffectConfig.fromJson(cfgJson()),
              depthEstimator: const LinearDepthEstimator())
          .processBytes(input: bytes);
      expect(injected.gifBytes, isNotNull);
      expect(injected.gifBytes, isNot(heuristic.gifBytes),
          reason: '自定义深度应改变分层结果');
    });

    test('effectiveDepthEstimator：缺省返回启发式', () {
      expect(MotionPipeline(EffectConfig()).effectiveDepthEstimator,
          isA<HeuristicDepthEstimator>());
      final injected = MotionPipeline(EffectConfig(),
          depthEstimator: const LinearDepthEstimator());
      expect(injected.effectiveDepthEstimator, isA<LinearDepthEstimator>());
    });
  });

  group('exportLayers 纹理集', () {
    test('内存导出与管线内部分层像素级一致', () {
      final cfg = EffectConfig.fromJson(cfgJson());
      final pipeline = MotionPipeline(cfg);
      final src = gradientRaster();
      final export = pipeline.exportLayers(src);
      final (_, internal) = pipeline.downscaleAndSplitForExport(src);

      expect(export.layers, hasLength(internal.length));
      expect(export.width, internal.first.image.width);
      expect(export.height, internal.first.image.height);
      // 解码回像素逐字节比对（同一条 downscaleAndSplit 主干）。
      for (var i = 0; i < export.layers.length; i++) {
        final decoded = ImageIO.decode(export.layers[i].pngBytes);
        expect(decoded.width, internal[i].image.width);
        final a = decoded.data, b = internal[i].image.data;
        final same = () {
          for (var j = 0; j < a.length; j++) {
            if (a[j] != b[j]) return false;
          }
          return true;
        }();
        expect(same, isTrue, reason: '层 $i 像素与内部分层一致');
      }
      // 索引结构。
      final index = jsonDecode(export.indexJson) as Map<String, dynamic>;
      expect(index['kind'], 'layers');
      expect(index['configHash'], cfg.configHash);
      expect((index['layers'] as List), hasLength(internal.length));
    });

    test('panelAware 导出携带格边界 clip', () {
      final cfg = EffectConfig.fromJson(<String, dynamic>{
        ...cfgJson(),
        'panelAware': true,
      });
      // 两格竖排图（白带 90..110，内容块两侧）。
      final im = RgbaImage(width: 120, height: 160);
      for (var y = 0; y < 160; y++) {
        for (var x = 0; x < 120; x++) {
          final o = (y * 120 + x) * 4;
          im.data[o + 3] = 255;
          final dark =
              (y < 90 && x > 10 && x < 110) || (y > 110 && x > 20 && x < 100);
          im.data[o] = dark ? 30 : 255;
          im.data[o + 1] = dark ? 30 : 255;
          im.data[o + 2] = dark ? 30 : 255;
        }
      }
      final export = MotionPipeline(cfg).exportLayers(im);
      expect(export.layers.length, greaterThanOrEqualTo(6),
          reason: '多格图应产出格数×layerCount 层');
      final withClip = export.layers.where((l) => l.clip != null).length;
      expect(withClip, export.layers.length, reason: 'panelAware 层带 clip');
      // 索引记录 clip。
      final index = jsonDecode(export.indexJson) as Map<String, dynamic>;
      final entries = index['layers'] as List;
      expect(entries.every((e) => (e as Map).containsKey('clip')), isTrue);
    });

    test('文件入口落盘 layer_NN.png + index.json', () async {
      final tmp = await Directory.systemTemp.createTemp('w6_layers');
      try {
        final input = '${tmp.path}${Platform.pathSeparator}in.png';
        File(input).writeAsBytesSync(
            Uint8List.fromList(ImageIO.encodePngFrame(gradientRaster())));
        final export = await MotionPipeline(EffectConfig.fromJson(cfgJson()))
            .exportLayersFile(input, tmp.path);
        expect(export.dir, isNotEmpty);
        final dir = Directory(export.dir);
        expect(dir.existsSync(), isTrue);
        final files = dir.listSync().map((f) => f.path).toList();
        expect(files.where((f) => f.endsWith('.png')), isNotEmpty);
        expect(files.any((f) => f.endsWith('index.json')), isTrue);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
