import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as pkg;
import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

void main() {
  group('EffectConfig 参数解析', () {
    test('默认参数可序列化并还原', () {
      final a = EffectConfig();
      final j = a.toJson();
      final b = EffectConfig.fromJson(j);
      expect(b.configHash, a.configHash);
      expect(b.fps, 24);
      expect(b.frameCount, inInclusiveRange(2, b.maxFrames));
    });

    test('同参数 hash 一致，改参数 hash 变化', () {
      final a = EffectConfig(seed: 42);
      final b = EffectConfig(seed: 42);
      final c = EffectConfig(seed: 43);
      expect(a.configHash, b.configHash);
      expect(a.configHash, isNot(c.configHash));
    });

    test('坏 JSON 文件抛 ConfigException', () {
      final f = File('.openclaw/tmp/bad_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{ not json');
      expect(() => EffectConfig.fromFile(f.path), throwsConfigException);
    });

    test('不存在的配置文件抛 ConfigException', () {
      expect(() => EffectConfig.fromFile('Z:/nope/none.json'),
          throwsConfigException);
    });

    test('frameCount 受 maxFrames 钳制', () {
      final cfg = EffectConfig(fps: 60, durationSec: 10, maxFrames: 48);
      expect(cfg.frameCount, 48);
    });

    test('结构性参数非法即抛 ConfigException（fail-fast，不静默退化）', () {
      expect(() => EffectConfig(fps: 0), throwsConfigException);
      expect(() => EffectConfig(fps: -1), throwsConfigException);
      expect(() => EffectConfig(durationSec: 0), throwsConfigException);
      expect(() => EffectConfig(durationSec: -1.5), throwsConfigException);
      expect(() => EffectConfig(layerCount: 0), throwsConfigException);
      expect(() => EffectConfig(layerCount: 9), throwsConfigException);
      expect(() => EffectConfig(maxDimension: 0), throwsConfigException);
      expect(() => EffectConfig(maxFrames: 1), throwsConfigException);
      // fromJson 走同一构造路径，同样拦截
      expect(() => EffectConfig.fromJson({'fps': 0}), throwsConfigException);
      expect(() => EffectConfig.fromJson({'layerCount': 99}),
          throwsConfigException);
      // 带 code 的 ConfigException，供程序化分支
      try {
        EffectConfig(fps: 0);
      } on ConfigException catch (e) {
        expect(e.code, 'E_BAD_CONFIG');
        expect(e.message, contains('fps'));
      }
    });

    test('结构性参数合法边界值不抛、行为不变', () {
      expect(EffectConfig(fps: 1, durationSec: 4).frameCount, 4);
      expect(EffectConfig(layerCount: 1).layerCount, 1);
      expect(EffectConfig(layerCount: 8).layerCount, 8);
      expect(EffectConfig(maxDimension: 1).maxDimension, 1);
      expect(EffectConfig(maxFrames: 2, fps: 1, durationSec: 10).frameCount, 2);
      expect(EffectConfig(durationSec: 0.1).frameCount, 2);
      // 合法域内序列化回放 hash 不变（校验不触碰 hash 输入）
      final a = EffectConfig(fps: 1, layerCount: 8, durationSec: 0.5);
      expect(EffectConfig.fromJson(a.toJson()).configHash, a.configHash);
    });
  });

  group('图像解码异常处理', () {
    test('空文件被拒', () {
      expect(
          () => ImageIO.decode(<int>[]), throwsA(isA<ImageDecodeException>()));
    });

    test('文本文件被拒', () {
      final bytes = 'this is not an image at all........'.codeUnits;
      expect(() => ImageIO.decode(bytes), throwsA(isA<ImageDecodeException>()));
    });

    test('损坏 PNG 被拒', () {
      final bytes = <int>[137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3];
      expect(() => ImageIO.decode(bytes), throwsA(isA<ImageDecodeException>()));
    });

    test('合法 PNG 解码尺寸正确', () {
      // 生成 4x3 纯色图
      final img = RgbaImage(width: 4, height: 3);
      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 4; x++) {
          img.setPixel(x, y, x * 60, y * 80, 128);
        }
      }
      // 用 image 包编码再走 ImageIO 解码（通过 GifEncoder 路径外的 PNG 编码）
      final png = _pngEncode(img);
      final decoded = ImageIO.decode(png);
      expect(decoded.width, 4);
      expect(decoded.height, 3);
    });

    test('边长合法但像素总量超限：头解析即拒', () {
      // 7000x7000 = 49M 像素 > 40M 默认上限；边长 7000 < 12000 合法。
      // 体数据只有 1x1 —— 证明拒绝发生在分配整幅栅格之前。
      final bytes = _pngWithDeclaredSize(7000, 7000);
      expect(
          () => ImageIO.decode(bytes),
          throwsA(isA<ImageTooLargeException>()
              .having((e) => e.pixelCount, 'pixelCount', 49000000)
              .having((e) => e.maxPixels, 'maxPixels', ImageIO.defaultMaxPixels)
              .having((e) => e.toString(), 'message', contains('49000000'))));
    });

    test('头解析即拒：IHDR 后截断的文件也按像素总量拒绝', () {
      // 只有签名 + IHDR，没有任何图像数据——若等到整图解码才校验，
      // 这里会得到 ImageDecodeException 而非像素预算拒绝。
      final bytes = _pngWithDeclaredSize(7000, 7000, truncate: true);
      expect(() => ImageIO.decode(bytes),
          throwsA(isA<ImageTooLargeException>()));
    });

    test('maxPixels 可按调用方配置收紧', () {
      final png = _pngEncode(_gradientImage(64, 64)); // 4096 像素
      expect(() => ImageIO.decode(png, maxPixels: 4095),
          throwsA(isA<ImageTooLargeException>()));
      // 恰好等于上限时放行，证明嗅探读出的宽高精确可信。
      expect(ImageIO.decode(png, maxPixels: 4096).pixelCount, 4096);
    });

    test('JPEG 头嗅探：宽高读数与真实解码一致', () {
      final jpg = pkg.encodeJpg(_pngToPkg(_gradientImage(64, 48))).toList();
      // 上限 64*48-1 拒绝、64*48 放行 => 嗅探必须精确读到 64x48。
      expect(() => ImageIO.decode(jpg, maxPixels: 64 * 48 - 1),
          throwsA(isA<ImageTooLargeException>()));
      expect(ImageIO.decode(jpg, maxPixels: 64 * 48).pixelCount, 64 * 48);
    });

    test('WebP 头嗅探：VP8X 扩展头的画布尺寸参与预算校验', () {
      // image 包没有 WebP 编码器，手工构造 VP8X 头（只声明画布尺寸），
      // 8000x8000 = 64M 像素 > 40M：拒绝必须发生在嗅探层。
      final bytes = _webpWithCanvasSize(8000, 8000);
      expect(() => ImageIO.decode(bytes),
          throwsA(isA<ImageTooLargeException>()));
    });
  });

  group('分层拆解', () {
    test('垂直渐变图拆出非空层', () {
      final img = RgbaImage(width: 100, height: 100);
      for (var y = 0; y < 100; y++) {
        for (var x = 0; x < 100; x++) {
          // 顶部暗(前景线索) 底部亮
          final v = (y * 2.2).clamp(0, 255).toInt();
          img.setPixel(x, y, v, v, v);
        }
      }
      final depth = DepthEstimator().estimate(img);
      expect(depth.data.any((d) => d > 0.7), isTrue);
      expect(depth.data.any((d) => d < 0.3), isTrue);
      final layers = LayerSplitter(layerCount: 3).split(img, depth);
      expect(layers.length, 3);
      // 近景层应含不透明像素
      final near = layers[2];
      var opaque = 0;
      for (var i = 3; i < near.image.data.length; i += 4) {
        if (near.image.data[i] == 255) opaque++;
      }
      expect(opaque, greaterThan(0));
    });

    test('层数 2 与 4 均可工作', () {
      final img = _flatWithBlob();
      final depth = DepthEstimator().estimate(img);
      expect(LayerSplitter(layerCount: 2).split(img, depth).length, 2);
      expect(LayerSplitter(layerCount: 4).split(img, depth).length, 4);
    });
  });

  group('v1.3 层掩码质量：双线性深度、羽化、边缘外扩', () {
    final img = _flatWithBlob();
    final depth = DepthEstimator(workScale: 0.5).estimate(img);

    /// 水平 alpha 突跳（>90）出现的列号。最近邻 2× 放大把深度按 2×2 方块复制，
    /// 跳变只可能落在偶数列；双线性插值会在奇数列也产生过渡。
    Set<int> stepColumnsX(RgbaImage a) {
      final cols = <int>{};
      for (var y = 0; y < a.height; y++) {
        for (var x = 2; x < a.width; x++) {
          if ((a.data[(y * a.width + x) * 4 + 3] -
                      a.data[(y * a.width + x - 1) * 4 + 3])
                  .abs() >
              90) cols.add(x);
        }
      }
      return cols;
    }

    /// 相邻像素 alpha 突跳（>90）计数：硬边界的总量。
    int hardSteps(RgbaImage a) {
      var n = 0;
      for (var y = 0; y < a.height; y++) {
        for (var x = 1; x < a.width; x++) {
          if ((a.data[(y * a.width + x) * 4 + 3] -
                      a.data[(y * a.width + x - 1) * 4 + 3])
                  .abs() >
              90) n++;
        }
      }
      for (var y = 1; y < a.height; y++) {
        for (var x = 0; x < a.width; x++) {
          if ((a.data[(y * a.width + x) * 4 + 3] -
                      a.data[((y - 1) * a.width + x) * 4 + 3])
                  .abs() >
              90) n++;
        }
      }
      return n;
    }

    int softAlpha(RgbaImage a) {
      var n = 0;
      for (var i = 3; i < a.data.length; i += 4) {
        if (a.data[i] > 8 && a.data[i] < 247) n++;
      }
      return n;
    }

    RgbaImage nearOf(LayerSplitter s) => s.split(img, depth)[2].image;

    test('standard 档双线性深度放大：掩码不再按 2×2 方块复制', () {
      final legacy = nearOf(LayerSplitter(layerCount: 3));
      final std = nearOf(LayerSplitter(
          layerCount: 3,
          tier: RenderTier.standard,
          featherPx: 0,
          edgeStretchPx: 0));
      expect(stepColumnsX(legacy).every((c) => c.isEven), isTrue,
          reason: 'v1.2 的最近邻掩码只应有偶数列方块边');
      expect(stepColumnsX(std).any((c) => c.isOdd), isTrue,
          reason: '双线性插值必须在奇数列补出过渡像素');
    });

    test('legacy 档忽略 featherPx 与 edgeStretchPx（回滚承诺）', () {
      final base = nearOf(LayerSplitter(layerCount: 3));
      for (final s in [
        LayerSplitter(layerCount: 3, featherPx: 0),
        LayerSplitter(layerCount: 3, featherPx: 12),
        LayerSplitter(layerCount: 3, edgeStretchPx: 6),
        LayerSplitter(
            layerCount: 3,
            featherPx: 12,
            edgeStretchPx: 16,
            tier: RenderTier.legacy),
      ]) {
        expect(nearOf(s).data, equals(base.data),
            reason: 'legacy 掩码必须与 v1.2 同');
      }
      expect(base.data, equals(nearOf(LayerSplitter(layerCount: 3)).data));
    });

    test('羽化只展宽 alpha 过渡带，不改 RGB', () {
      final off = nearOf(LayerSplitter(
          layerCount: 3,
          tier: RenderTier.standard,
          featherPx: 0,
          edgeStretchPx: 0));
      final on = nearOf(LayerSplitter(
          layerCount: 3,
          tier: RenderTier.standard,
          featherPx: 6,
          edgeStretchPx: 0));
      var colorChanged = 0;
      for (var i = 0; i < off.pixelCount; i++) {
        final o = i * 4;
        if (off.data[o] != on.data[o] ||
            off.data[o + 1] != on.data[o + 1] ||
            off.data[o + 2] != on.data[o + 2]) colorChanged++;
      }
      expect(colorChanged, 0, reason: '卷积只碰 alpha 通道');
      expect(hardSteps(on), lessThan(hardSteps(off)), reason: '硬边界总量必须变少');
      expect(softAlpha(on), greaterThan(softAlpha(off) * 3),
          reason: '过渡带必须摊开成中间 alpha');
    });

    test('边缘外扩按轮推进：透明带继承邻域色，内部实像素不动', () {
      RgbaImage withStretch(int px) => nearOf(LayerSplitter(
          layerCount: 3,
          tier: RenderTier.standard,
          featherPx: 0,
          edgeStretchPx: px));
      final plain = withStretch(0);
      final grown = withStretch(3);
      final w = plain.width, h = plain.height;
      const palette = [(235, 240, 245), (30, 28, 36)];
      var inside = 0, ring = 0;
      for (var y = 1; y < h - 1; y++) {
        for (var x = 1; x < w - 1; x++) {
          final p = (y * w + x) * 4;
          if (plain.data[p + 3] == 255) {
            // 内部实像素必须原样保留
            expect(grown.data[p], plain.data[p]);
            expect(grown.data[p + 3], 255);
            inside++;
            continue;
          }
          if (grown.data[p + 3] == 0) continue;
          ring++;
          // 外扩只做整数像素搬运：颜色必须原样来自源图，绝不混合出第三条色，
          // 否则视差位移时边缘会露出一圈灰边。alpha 逐轮衰减且不会自造满值。
          final rgb = (grown.data[p], grown.data[p + 1], grown.data[p + 2]);
          expect(palette.contains(rgb), isTrue,
              reason: '($x,$y) 外扩出了杜撰颜色 $rgb');
          expect(grown.data[p + 3] < 255, isTrue);
        }
      }
      expect(inside, greaterThan(0));
      expect(ring, greaterThan(0));
      // 深度受 rounds 约束：3 轮最多把边界外推 3 像素。
      final far = withStretch(9);
      var deeper = 0;
      for (var i = 0; i < plain.pixelCount; i++) {
        if (plain.data[i * 4 + 3] == 0 && far.data[i * 4 + 3] > 0) deeper++;
      }
      expect(deeper, greaterThan(ring));
    });

    test('standard 分层结果确定（同一 depth 两次拆分逐字节一致）', () {
      final s = LayerSplitter(
          layerCount: 3, tier: RenderTier.standard, edgeStretchPx: 6);
      expect(s.split(img, depth).map((l) => l.image.data).toList()[2],
          equals(s.split(img, depth)[2].image.data));
    });
  });

  group('动效合成与可复现性', () {
    test('同一帧 t 相同则像素完全一致（确定性）', () {
      final img = _flatWithBlob();
      final cfg = EffectConfig(fps: 8, durationSec: 1, seed: 7);
      final depth = DepthEstimator().estimate(img);
      final layers = LayerSplitter(layerCount: 3).split(img, depth);
      final c1 = FrameCompositor(layers, img, cfg);
      final c2 = FrameCompositor(layers, img, cfg);
      final f1 = c1.renderFrame(0.25);
      final f2 = c2.renderFrame(0.25);
      expect(f1.data, f2.data);
    });

    test('不同 t 帧产生运动（帧间差异）', () {
      final img = _flatWithBlob();
      final cfg = EffectConfig(fps: 8, durationSec: 1);
      final depth = DepthEstimator().estimate(img);
      final layers = LayerSplitter(layerCount: 3).split(img, depth);
      final c = FrameCompositor(layers, img, cfg);
      final f0 = c.renderFrame(0.0);
      final f1 = c.renderFrame(0.5);
      var diff = 0;
      for (var i = 0; i < f0.data.length; i++) {
        if (f0.data[i] != f1.data[i]) diff++;
      }
      expect(diff, greaterThan(0));
    });

    test('修改幅度参数改变输出', () {
      final img = _flatWithBlob();
      final depth = DepthEstimator().estimate(img);
      final layers = LayerSplitter(layerCount: 3).split(img, depth);
      final quiet = EffectConfig(
          parallax: ParallaxParams(amplitude: 0.0), fps: 8, durationSec: 1);
      final loud = EffectConfig(
          parallax: ParallaxParams(amplitude: 0.05), fps: 8, durationSec: 1);
      final f0 = FrameCompositor(layers, img, quiet).renderFrame(0.25);
      final f1 = FrameCompositor(layers, img, loud).renderFrame(0.25);
      var diff = 0;
      for (var i = 0; i < f0.data.length; i++) {
        if (f0.data[i] != f1.data[i]) diff++;
      }
      expect(diff, greaterThan(0));
    });
  });

  group('管线与台账', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cm_test');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('processFile 输出文件齐全且 params.json 可还原 hash', () async {
      final png = _pngEncode(_gradientImage(64, 96));
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final r = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, '${tmp.path}/out');
      expect(File(r.outputGif).existsSync(), isTrue);
      expect(Directory(r.frameDir).existsSync(), isTrue);
      final paramsFile = File(
          '${r.outputGif.substring(0, r.outputGif.lastIndexOf('/'))}/params.json');
      expect(paramsFile.existsSync(), isTrue);
      final restored =
          EffectConfig.fromJson(_decodeJson(paramsFile.readAsStringSync()));
      expect(restored.configHash, cfg.configHash);
      expect(r.frameCount, cfg.frameCount);
      expect(r.elapsedMs, greaterThan(0));
    });

    test('POSIX 风格路径：输出目录层级与文件名全平台一致', () async {
      // 用相对 + 纯 "/" 路径跑完整管线。POSIX 上 "\" 是合法文件名字符，
      // 任何混入都会让产物变成「名字带反斜杠的平铺文件」而非子目录。
      final workDir = 'build/posix_path_test';
      Directory(workDir).createSync(recursive: true);
      addTearDown(() => Directory(workDir).deleteSync(recursive: true));
      File('$workDir/in.png')
          .writeAsBytesSync(_pngEncode(_gradientImage(32, 32)));
      final cfg = EffectConfig(fps: 2, durationSec: 1, maxDimension: 32);
      final r = await MotionPipeline(cfg, parallel: 1)
          .processFile('$workDir/in.png', '$workDir/out');
      final jobName = 'in_${cfg.configHash.substring(0, 8)}';
      expect(r.outputGif, '$workDir/out/$jobName/anim.gif');
      expect(r.frameDir, '$workDir/out/$jobName/frames');
      expect(File(r.outputGif).existsSync(), isTrue);
      expect(File('$workDir/out/$jobName/params.json').existsSync(), isTrue);
      expect(ImageIO.pngPathFor('a/b', 1), 'a/b/frame_0001.png');
      expect(r.outputGif.contains('\\'), isFalse,
          reason: '产物路径不得含反斜杠（POSIX 上是文件名字符）');
    });

    test('内存预算充裕时零降级，输出与无预算逐字节一致', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(96, 64)));
      final cfg = EffectConfig(fps: 2, durationSec: 1, maxDimension: 96);
      final plain =
          await MotionPipeline(cfg, parallel: 1).processFile(inPath, '${tmp.path}/b0');
      final budgeted = await MotionPipeline(cfg, parallel: 1, memoryBudgetMb: 4096)
          .processFile(inPath, '${tmp.path}/b1');
      expect(File(budgeted.outputGif).readAsBytesSync(),
          equals(File(plain.outputGif).readAsBytesSync()),
          reason: '预算充裕不得触碰像素路径');
      expect(budgeted.warnings.join(), isNot(contains('memory budget')));
    });

    test('内存预算紧张时降为串行并在 warnings 记录', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(96, 64)));
      final cfg = EffectConfig(fps: 2, durationSec: 1, maxDimension: 512);
      final r = await MotionPipeline(cfg, parallel: 8, memoryBudgetMb: 100)
          .processFile(inPath, '${tmp.path}/b2');
      expect(r.parallel, 1);
      expect(r.parallelFallback, isTrue, reason: '预算导致的并行降级要如实上报');
      final w = r.warnings.join(' | ');
      expect(w, contains('memory budget'));
      expect(w, contains('parallel capped at 1'));
      // 源图远小于分辨率下限，预算不得虚报分辨率降级
      expect(w, isNot(contains('working resolution')));
    });

    test('内存预算极小时收缩工作分辨率并记录', () async {
      final inPath = '${tmp.path}/big.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(1024, 1024)));
      final cfg = EffectConfig(fps: 2, durationSec: 1, maxDimension: 1024);
      final r = await MotionPipeline(cfg, parallel: 1, memoryBudgetMb: 180)
          .processFile(inPath, '${tmp.path}/b3');
      // PipelineResult.width 报源图尺寸；工作分辨率从 GIF 逻辑屏幕宽验证
      // （GIF 头偏移 6-7 为小端 u16 宽）。
      final gifBytes = File(r.outputGif).readAsBytesSync();
      final gifWidth = gifBytes[6] | (gifBytes[7] << 8);
      expect(gifWidth, 716, reason: '1024 * 0.7 = 716：预算推导应如实降档');
      final w = r.warnings.join(' | ');
      expect(w, contains('working resolution capped at 716px'));
    });

    test('并行与串行输出逐字节一致（GIF 与 PNG 帧序列）', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(96, 64)));
      final cfg = EffectConfig(
        fps: 6,
        durationSec: 1,
        maxDimension: 96,
        outputFormat: OutputFormat.both,
        effects: const [
          EffectKind.parallax,
          EffectKind.breathing,
          EffectKind.ambient,
          EffectKind.rain,
          EffectKind.starlight,
          EffectKind.lightning,
        ],
      );
      for (final tier in RenderTier.values.take(2)) {
        final c = EffectConfig.fromJson(cfg.toJson());
        c.quality = c.quality.copyWith(tier: tier);
        final serial = await MotionPipeline(c, parallel: 1)
            .processFile(inPath, '${tmp.path}/p1_${tier.name}');
        final worker = await MotionPipeline(c, parallel: 3)
            .processFile(inPath, '${tmp.path}/p3_${tier.name}');
        expect(File(worker.outputGif).readAsBytesSync(),
            equals(File(serial.outputGif).readAsBytesSync()),
            reason: 'tier=${tier.name} 的 GIF 字节不一致');
        for (var i = 0; i < c.frameCount; i++) {
          expect(
              File(ImageIO.pngPathFor(worker.frameDir, i)).readAsBytesSync(),
              equals(File(ImageIO.pngPathFor(serial.frameDir, i))
                  .readAsBytesSync()),
              reason: 'tier=${tier.name} 第 $i 帧 PNG 不一致');
        }
        if (Platform.numberOfProcessors > 1) {
          expect(worker.parallel, greaterThan(1),
              reason: '多核机器上应真正走 worker 路径');
        }
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('批处理失败项不中断且台账记录原因', () async {
      // 建一个输入目录: 一张好图 + 一个空文件 + 一个文本文件
      final inDir = Directory('${tmp.path}/imgs')..createSync();
      File('${inDir.path}/a.png')
          .writeAsBytesSync(_pngEncode(_gradientImage(48, 48)));
      File('${inDir.path}/b.png').writeAsBytesSync(<int>[]);
      File('${inDir.path}/c.png')
          .writeAsBytesSync('plain text, not an image!'.codeUnits);

      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 48);
      final ledger = Ledger('${tmp.path}/ledger');
      final results = await BatchRunner(ledger).runFolder(
          inputDir: inDir.path,
          outputDir: '${tmp.path}/out',
          config: cfg,
          parallel: 1);
      expect(results.length, 3);
      expect(results.where((r) => r.ok).length, 1);
      expect(results.where((r) => !r.ok).length, 2);
      // 失败原因明确
      for (final bad in results.where((r) => !r.ok)) {
        expect(bad.error, isNotNull);
        expect(bad.error!, isNotEmpty);
      }
      // 台账可查
      final failed = ledger.query(status: 'failed');
      expect(failed.length, 2);
      final okJobs = ledger.query(status: 'success');
      expect(okJobs.length, 1);
      // 按 jobId 追溯
      final one = ledger.query(jobId: results.first.jobId);
      expect(one.length, 1);
    });

    test('非图片目录抛 ConfigException', () {
      final cfg = EffectConfig(fps: 4, durationSec: 1);
      final ledger = Ledger('${tmp.path}/ledger');
      expect(
        () => BatchRunner(ledger).runFolder(
            inputDir: '${tmp.path}/nope',
            outputDir: '${tmp.path}/out',
            config: cfg),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('StreamingGifBuilder 流式 GIF 编码器', () {
    RgbaImage gradFrame(int w, int h, int phase) {
      final img = RgbaImage(width: w, height: h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          img.setPixel(x, y, x * 255 ~/ (w - 1), y * 255 ~/ (h - 1),
              (phase * 40 + ((x + y) * 60) ~/ (w + h)) & 0xff);
        }
      }
      return img;
    }

    test('产出的 GIF 可被 image 包逐帧解码：尺寸与帧数正确', () {
      const w = 48, h = 32, n = 5;
      final b = StreamingGifBuilder(w, h, fps: 10);
      for (var p = 0; p < n; p++) {
        b.addFrame(gradFrame(w, h, p));
      }
      final bytes = Uint8List.fromList(b.finish());
      expect(bytes.length, greaterThan(100));

      final dec = pkg.GifDecoder(bytes);
      expect(dec.info!.numFrames, n);
      final f0 = dec.decodeFrame(0)!;
      expect(f0.width, w);
      expect(f0.height, h);
      expect(dec.decodeFrame(n), isNull, reason: '越界帧应为 null');
    });

    test('LZW 大渐变图编码后解码平均色一致（码宽切换路径）', () {
      const w = 128, h = 128;
      final b = StreamingGifBuilder(w, h, fps: 5);
      b.addFrame(gradFrame(w, h, 3));
      final bytes = Uint8List.fromList(b.finish());

      final dec = pkg.GifDecoder(bytes);
      final f = dec.decodeFrame(0)!;
      var rs = 0, gs = 0, cnt = 0;
      for (var y = 0; y < h; y += 4) {
        for (var x = 0; x < w; x += 4) {
          final c = f.getPixel(x, y);
          rs += c.r.toInt();
          gs += c.g.toInt();
          cnt++;
        }
      }
      // 源图 R/G 均值≈127（x/y 双向渐变），量化后应落在邻域内
      expect(rs / cnt, inInclusiveRange(100, 155));
      expect(gs / cnt, inInclusiveRange(100, 155));
    });

    test('帧尺寸不匹配抛错', () {
      final b = StreamingGifBuilder(16, 16, fps: 8);
      expect(() => b.addFrame(gradFrame(20, 16, 0)), throwsArgumentError);
    });
  });

  group('v1.1 新增动效', () {
    const newKinds = [
      EffectKind.rain,
      EffectKind.snow,
      EffectKind.sakura,
      EffectKind.fireflies,
      EffectKind.godRays,
      EffectKind.speedLines,
      EffectKind.impactFlash,
      EffectKind.heartbeat,
    ];

    RgbaImage flatImg() {
      final img = RgbaImage(width: 96, height: 96);
      for (var y = 0; y < 96; y++) {
        for (var x = 0; x < 96; x++) {
          img.setPixel(x, y, 40 + x, 60 + y ~/ 2, 90);
        }
      }
      return img;
    }

    List<LayerImage> layersOf(RgbaImage img) {
      final depth = DepthEstimator().estimate(img);
      return LayerSplitter(layerCount: 3).split(img, depth);
    }

    EffectConfig cfgWith(List<EffectKind> kinds, {int seed = 11}) =>
        EffectConfig(effects: kinds, fps: 8, durationSec: 2, seed: seed);

    test('每个新效果：启用后画面改变（非空差异）', () {
      final img = flatImg();
      final layers = layersOf(img);
      final base = FrameCompositor(layers, img, cfgWith([EffectKind.parallax]))
          .renderFrame(0.4);
      for (final k in newKinds) {
        // impactFlash/heartbeat 采样两次：脉冲相位内 + 间隙相位，至少一次非零差异
        final ts = k == EffectKind.impactFlash
            ? [0.05, 0.4]
            : k == EffectKind.heartbeat
                ? [0.04, 0.4]
                : [0.4];
        var diff = 0;
        for (final t in ts) {
          final f =
              FrameCompositor(layers, img, cfgWith([EffectKind.parallax, k]))
                  .renderFrame(t);
          for (var i = 0; i < base.data.length; i++) {
            if (base.data[i] != f.data[i]) diff++;
          }
        }
        expect(diff, greaterThan(0), reason: '效果 ${k.name} 应改变画面');
      }
    });

    test('新效果确定性：同参数同帧完全一致', () {
      final img = flatImg();
      final layers = layersOf(img);
      final cfg = cfgWith([
        EffectKind.parallax,
        EffectKind.rain,
        EffectKind.snow,
        EffectKind.sakura,
        EffectKind.fireflies,
        EffectKind.godRays,
        EffectKind.speedLines,
        EffectKind.impactFlash,
        EffectKind.heartbeat,
      ]);
      final f1 = FrameCompositor(layers, img, cfg).renderFrame(0.7);
      final f2 = FrameCompositor(layers, img, cfg).renderFrame(0.7);
      expect(f1.data, f2.data);
    });

    test('新效果整循环周期化：t=0 与 t=时长 帧一致（无缝循环）', () {
      final img = flatImg();
      final layers = layersOf(img);
      // 只启用新效果，避免旧效果的近似循环干扰断言
      final cfg = cfgWith([
        EffectKind.rain,
        EffectKind.snow,
        EffectKind.sakura,
        EffectKind.fireflies,
        EffectKind.godRays,
        EffectKind.speedLines,
        EffectKind.impactFlash,
        EffectKind.heartbeat,
      ]);
      final c = FrameCompositor(layers, img, cfg);
      final f0 = c.renderFrame(0.0);
      final fN = c.renderFrame(cfg.durationSec);
      var diff = 0;
      for (var i = 0; i < f0.data.length; i++) {
        if (f0.data[i] != fN.data[i]) diff++;
      }
      expect(diff, 0, reason: '循环首尾应逐字节一致（diff=$diff）');
    });

    test('默认配置序列化向后兼容：无新增键且哈希锁定', () {
      final j = EffectConfig().toJson();
      expect(j.containsKey('rain'), isFalse);
      expect(j.containsKey('snow'), isFalse);
      expect(j.containsKey('sakura'), isFalse);
      expect(j.containsKey('fireflies'), isFalse);
      expect(j.containsKey('godRays'), isFalse);
      expect(j.containsKey('speedLines'), isFalse);
      expect(j.containsKey('impactFlash'), isFalse);
      expect(j.containsKey('heartbeat'), isFalse);
      expect(j.containsKey('reducedMotion'), isFalse);
      // v1.0.0 指纹锁定（tool/config_fingerprint.dart）
      expect(EffectConfig().configHash, '-477687d5e8bded5f');
      expect(
          EffectConfig(fps: 12, durationSec: 3.0, maxDimension: 640).configHash,
          '2e1a45e07164337e');
    });

    test('新效果参数 JSON 往返还原且哈希一致', () {
      final cfg = EffectConfig(
        effects: [
          EffectKind.parallax,
          EffectKind.breathing,
          EffectKind.rain,
          EffectKind.snow,
          EffectKind.sakura,
          EffectKind.fireflies,
          EffectKind.godRays,
          EffectKind.speedLines,
          EffectKind.impactFlash,
          EffectKind.heartbeat,
        ],
        rain: RainParams(count: 55, opacity: 0.5),
        snow: SnowParams(count: 40, sizePx: 3.0),
        sakura: SakuraParams(count: 24, spinTurns: 3),
        fireflies: FirefliesParams(count: 18, glowPx: 18),
        godRays: GodRaysParams(count: 4, intensity: 0.4),
        speedLines: SpeedLinesParams(count: 60, pulses: 3),
        impactFlash: ImpactFlashParams(flashes: 3, intensity: 0.6),
        heartbeat: HeartbeatParams(beats: 4, intensity: 0.012),
        fps: 12,
        durationSec: 3,
      );
      final restored = EffectConfig.fromJson(_decodeJson(cfg.toJsonString()));
      expect(restored.configHash, cfg.configHash);
      expect(restored.rain.count, 55);
      expect(restored.sakura.spinTurns, 3);
      expect(restored.heartbeat.beats, 4);
    });

    test('reducedMotion：帧数钳为 1 且画面与基线不同', () {
      final cfg = EffectConfig(
        effects: [EffectKind.parallax, EffectKind.rain],
        fps: 8,
        durationSec: 2,
        reducedMotion: true,
      );
      expect(cfg.frameCount, 1);
      expect(cfg.toJson()['reducedMotion'], isTrue);
      final img = flatImg();
      final layers = layersOf(img);
      final f = FrameCompositor(layers, img, cfg).renderFrame(1.3);
      final base =
          FrameCompositor(layers, img, EffectConfig(fps: 8, durationSec: 2))
              .renderFrame(0.0);
      // 静态帧 = 底图（无缩放），与有缩放的基线帧不同
      var diff = 0;
      for (var i = 0; i < f.data.length; i++) {
        if (base.data[i] != f.data[i]) diff++;
      }
      expect(diff, greaterThan(0));
    });
  });

  group('v1.2 新增动效', () {
    const v12Kinds = [
      EffectKind.fog,
      EffectKind.embers,
      EffectKind.lightning,
      EffectKind.toneShift,
      EffectKind.vignette,
      EffectKind.starlight,
      EffectKind.slowPush,
      EffectKind.shimmer,
    ];

    RgbaImage sceneImg() {
      // 亮暗混合场景（含亮区供星光采样）
      final img = RgbaImage(width: 96, height: 96);
      for (var y = 0; y < 96; y++) {
        for (var x = 0; x < 96; x++) {
          final lum = (60 + x * 130 ~/ 96 + y * 60 ~/ 96).clamp(0, 255);
          img.setPixel(x, y, lum, lum, (lum * 0.9).toInt());
        }
      }
      return img;
    }

    List<LayerImage> layers12(RgbaImage img) {
      final depth = DepthEstimator().estimate(img);
      return LayerSplitter(layerCount: 3).split(img, depth);
    }

    EffectConfig cfg12(List<EffectKind> kinds, {int seed = 21}) =>
        EffectConfig(effects: kinds, fps: 8, durationSec: 2, seed: seed);

    test('每个 v1.2 效果：启用后画面改变', () {
      final img = sceneImg();
      final layers = layers12(img);
      final base = FrameCompositor(layers, img, cfg12([EffectKind.parallax]))
          .renderFrame(0.4);
      for (final k in v12Kinds) {
        final ts = k == EffectKind.lightning ? [0.02, 0.5] : [0.4];
        var diff = 0;
        for (final t in ts) {
          final f =
              FrameCompositor(layers, img, cfg12([EffectKind.parallax, k]))
                  .renderFrame(t);
          for (var i = 0; i < base.data.length; i++) {
            if (base.data[i] != f.data[i]) diff++;
          }
        }
        expect(diff, greaterThan(0), reason: '效果 ${k.name} 应改变画面');
      }
    });

    test('v1.2 确定性 + 整循环无缝', () {
      final img = sceneImg();
      final layers = layers12(img);
      final cfg = cfg12(v12Kinds);
      final c1 = FrameCompositor(layers, img, cfg);
      final c2 = FrameCompositor(layers, img, cfg);
      expect(c1.renderFrame(0.9).data, c2.renderFrame(0.9).data);
      final f0 = c1.renderFrame(0.0);
      final fN = c1.renderFrame(cfg.durationSec);
      expect(f0.data, fN.data, reason: '循环首尾应逐字节一致');
    });

    test('v1.2 配置 JSON 往返 + 条件序列化', () {
      final cfg = EffectConfig(
        effects: [EffectKind.parallax, EffectKind.fog, EffectKind.vignette],
        fog: FogParams(blobs: 10, opacity: 0.14),
        vignette: VignetteParams(strength: 0.4),
        quality: QualityParams(dither: true),
      );
      final j = cfg.toJson();
      expect(j.containsKey('fog'), isTrue);
      expect(j.containsKey('snow'), isFalse, reason: '未启用不序列化');
      expect((j['quality'] as Map)['dither'], isTrue);
      // 默认（dither=false）不写 quality 段：保经典指纹
      expect(EffectConfig().toJson().containsKey('quality'), isFalse);
      final restored = EffectConfig.fromJson(_decodeJson(cfg.toJsonString()));
      expect(restored.configHash, cfg.configHash);
      expect(restored.fog.blobs, 10);
      expect(restored.quality.dither, isTrue);
    });

    test('GIF 抖动开关：dither=true 可解码且与关闭时输出不同', () {
      const wd = 64, ht = 48;
      RgbaImage grad() {
        final img = RgbaImage(width: wd, height: ht);
        for (var y = 0; y < ht; y++) {
          for (var x = 0; x < wd; x++) {
            final v = x * 255 ~/ (wd - 1);
            img.setPixel(x, y, v, v, v);
          }
        }
        return img;
      }

      Uint8List encode(bool dither) {
        final b = StreamingGifBuilder(wd, ht, fps: 8, dither: dither);
        b.addFrame(grad());
        return Uint8List.fromList(b.finish());
      }

      final on = encode(true);
      final off = encode(false);
      expect(on, isNot(off), reason: '抖动应改变编码输出');
      for (final bytes in [on, off]) {
        final dec = pkg.GifDecoder(bytes);
        expect(dec.info!.numFrames, 1);
        expect(dec.decodeFrame(0)!.width, wd);
      }
    });
  });
  group('v1.3 基础：像素模型与 IO 通路', () {
    test('RgbaImage 底层为 Uint8List 且 fromBytes 无拷贝语义差异', () {
      final img = RgbaImage(width: 4, height: 4);
      expect(img.data, isA<Uint8List>());
      img.setPixel(1, 1, 10, 20, 30, 255);
      final clone = RgbaImage.fromBytes(width: 4, height: 4, data: img.data);
      expect(clone.data[20], 10); // (1 * 4 + 1) * 4
      expect(clone.data, same(img.data));
    });

    test('解码走批量字节通路且与源像素逐字节一致', () {
      final src = RgbaImage(width: 32, height: 24);
      for (var y = 0; y < 24; y++) {
        for (var x = 0; x < 32; x++) {
          src.setPixel(x, y, (x * 7) & 255, (y * 9) & 255, 128, 255);
        }
      }
      final back = ImageIO.decode(_pngEncode(src));
      for (var i = 0; i < src.data.length; i += 4) {
        expect(back.data[i], src.data[i]);
        expect(back.data[i + 1], src.data[i + 1]);
        expect(back.data[i + 2], src.data[i + 2]);
        expect(back.data[i + 3], 255);
      }
    });

    test('PNG 帧编码保持 v1.2 的 RGB 通路（丢 alpha，逐字节可复现）', () {
      final f = _flatWithBlob();
      expect(Uint8List.fromList(ImageIO.encodePngFrame(f)),
          equals(Uint8List.fromList(_pngEncode(f))));
    });

    test('QualityParams 默认 legacy 且默认配置不序列化 quality 段', () {
      expect(EffectConfig().toJson().containsKey('quality'), isFalse);
      expect(EffectConfig().quality.tier, RenderTier.legacy);
      // v1.2 语义：仅 dither=true 时出现且只含 dither 一个键
      final d = EffectConfig()..quality = QualityParams(dither: true);
      expect(d.toJson()['quality'], {'dither': true});
    });

    test('tier/ditherMode/mipLevels JSON 往返且哈希稳定', () {
      final cfg = EffectConfig(fps: 12, durationSec: 3, maxDimension: 640)
        ..quality = const QualityParams(
            dither: true,
            ditherMode: 'sierra',
            tier: RenderTier.standard,
            mipLevels: 1,
            edgeStretchPx: 0);
      final j = cfg.toJson()['quality'] as Map;
      expect(j['tier'], 'standard');
      expect(j['ditherMode'], 'sierra');
      expect(j['mipLevels'], 1);
      expect(j['edgeStretchPx'], 0);
      final back = EffectConfig.fromJson(_decodeJson(cfg.toJsonString()));
      expect(back.configHash, cfg.configHash);
      expect(back.quality.tier, RenderTier.standard);
      expect(back.quality.edgeStretchPx, 0);
    });

    test('quality 段缺省 dither 时与构造默认一致（不静默开抖动）', () {
      final back = EffectConfig.fromJson(_decodeJson(
          '{"effects":["parallax","breathing"],"quality":{"tier":"standard"}}'));
      expect(back.quality.dither, isFalse);
      expect(back.quality.tier, RenderTier.standard);
      final cli = EffectConfig()
        ..effects = const [EffectKind.parallax, EffectKind.breathing];
      cli.quality = cli.quality.copyWith(tier: RenderTier.standard);
      expect(back.configHash, cli.configHash);
    });

    test('配置里的未知效果名报 ConfigException，不静默退化成 parallax', () {
      expect(
          () => EffectConfig.fromJson(
              _decodeJson('{"effects":["parallax","raiin"]}')),
          throwsA(isA<ConfigException>()
              .having((e) => e.code, 'code', 'E_UNKNOWN_EFFECT')));
      expect(
          () => EffectConfig.fromJson(_decodeJson('{"effects":[42]}')),
          throwsA(isA<ConfigException>()
              .having((e) => e.code, 'code', 'E_UNKNOWN_EFFECT')));
    });

    test('异常体系携带稳定错误码，与 HTTP API 错误码对齐', () {
      // 解码族
      expect(
          () => ImageIO.decode(<int>[]),
          throwsA(isA<ImageDecodeException>()
              .having((e) => e.code, 'code', 'E_DECODE_EMPTY')));
      expect(
          () => ImageIO.decode(
              <int>[137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3]),
          throwsA(isA<ImageDecodeException>()
              .having((e) => e.code, 'code', 'E_DECODE_CORRUPT')));
      // 像素预算族
      expect(
          () => ImageIO.decode(_pngWithDeclaredSize(7000, 7000)),
          throwsA(isA<ImageTooLargeException>()
              .having((e) => e.code, 'code', 'E_TOO_LARGE')));
      // 文件不存在
      final missing =
          '${Directory.systemTemp.path}/no_such_${DateTime.now().millisecondsSinceEpoch}.png';
      expect(
          () => ImageIO.decodeFile(missing),
          throwsA(isA<ImageDecodeException>()
              .having((e) => e.code, 'code', 'E_DECODE_NOT_FOUND')));
      // 配置族：字段类型错走 fromFile 的 TypeError 包装
      final badFile = File(
              '${Directory.systemTemp.path}/bad_cfg_${DateTime.now().millisecondsSinceEpoch}.json')
        ..writeAsStringSync('{"fps": "fast"}');
      addTearDown(() => badFile.deleteSync());
      expect(
          () => EffectConfig.fromFile(badFile.path),
          throwsA(isA<ConfigException>()
              .having((e) => e.code, 'code', 'E_BAD_CONFIG')));
      // worker 崩溃码
      expect(EngineWorkerException(3, 'x').code, 'E_WORKER_CRASH');
    });

    test('越界质量参数被钳制、未知 tier 回落 legacy、未知 ditherMode 回落 floyd', () {
      final q = QualityParams.fromJson({
        'tier': 'ultra',
        'ditherMode': 'blue-noise',
        'mipLevels': 9,
        'edgeStretchPx': -4,
      });
      expect(q.tier, RenderTier.legacy);
      expect(q.ditherMode, 'floyd');
      expect(q.mipLevels, 2);
      expect(q.edgeStretchPx, 0);
    });

    test('GIF 量化：standard 档 LUT 路径与 legacy 同样可解码、帧数一致', () {
      const w = 64, h = 48, n = 4;
      RgbaImage grad(int p) {
        final img = RgbaImage(width: w, height: h);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            img.setPixel(x, y, x * 255 ~/ (w - 1), y * 255 ~/ (h - 1),
                (p * 50 + x * 255 ~/ (w - 1)) & 255);
          }
        }
        return img;
      }

      Uint8List encode(RenderTier tier) {
        final b = StreamingGifBuilder(w, h, fps: 8, dither: true, tier: tier);
        for (var p = 0; p < n; p++) {
          b.addFrame(grad(p));
        }
        return Uint8List.fromList(b.finish());
      }

      for (final tier in [RenderTier.legacy, RenderTier.standard]) {
        final bytes = encode(tier);
        final dec = pkg.GifDecoder(bytes);
        expect(dec.info!.numFrames, n, reason: '${tier.name} 档帧数');
        expect(dec.decodeFrame(n - 1)!.width, w, reason: '${tier.name} 档可解码');
      }
    });

    test('GIF 抖动：legacy 档忽略 sierra（与 floyd 逐字节一致），standard 档生效', () {
      RgbaImage grad() {
        final img = RgbaImage(width: 40, height: 24);
        for (var y = 0; y < 24; y++) {
          for (var x = 0; x < 40; x++) {
            final v = x * 255 ~/ 39;
            img.setPixel(x, y, v, v, v);
          }
        }
        return img;
      }

      Uint8List encode(String mode, RenderTier tier) {
        final b = StreamingGifBuilder(40, 24,
            fps: 8, dither: true, ditherMode: mode, tier: tier);
        b.addFrame(grad());
        return Uint8List.fromList(b.finish());
      }

      expect(encode('sierra', RenderTier.legacy),
          equals(encode('floyd', RenderTier.legacy)),
          reason: '回滚承诺：legacy 的抖动行为不变');
      expect(encode('sierra', RenderTier.standard),
          isNot(encode('floyd', RenderTier.standard)));
    });

    test('primePalette 只在未建板时生效，重复调用不改变输出', () {
      RgbaImage solid(int r, int g, int b) {
        final img = RgbaImage(width: 16, height: 16);
        for (var i = 0; i < img.pixelCount; i++) {
          img.setPixel(i % 16, i ~/ 16, r, g, b);
        }
        return img;
      }

      Uint8List build({required bool secondPrime}) {
        final enc =
            StreamingGifBuilder(16, 16, fps: 8, tier: RenderTier.standard);
        enc.primePalette([solid(255, 0, 0), solid(0, 255, 0)]);
        enc.addFrame(solid(0, 0, 255));
        if (secondPrime) enc.primePalette([solid(0, 0, 255)]);
        return Uint8List.fromList(enc.finish());
      }

      final bytes = build(secondPrime: false);
      expect(build(secondPrime: true), equals(bytes));
      // 调色板来自红/绿探针帧：纯蓝帧只能落到探针色的近邻，蓝通道不该发亮
      final px = pkg.GifDecoder(bytes).decodeFrame(0)!.getPixel(8, 8);
      expect(px.b.toInt(), lessThan(128));
    });
  });

  group('v1.3 质量档：AA 与 screen 生效', () {
    /// 亮暗混合场景：screen 与截断加法的差别只在近白区，故高光带必须够亮。
    RgbaImage scene() {
      final img = RgbaImage(width: 80, height: 80);
      for (var y = 0; y < 80; y++) {
        for (var x = 0; x < 80; x++) {
          final lum = (120 + x * 135 ~/ 79).clamp(0, 255);
          img.setPixel(x, y, lum, lum, lum);
        }
      }
      return img;
    }

    EffectConfig qcfg(List<EffectKind> kinds, RenderTier tier) => EffectConfig(
          effects: kinds,
          fps: 8,
          durationSec: 2,
          seed: 33,
          quality: QualityParams(tier: tier),
        );

    RgbaImage render(List<EffectKind> kinds, RenderTier tier, double t) {
      final img = scene();
      final layers = LayerSplitter(layerCount: 3)
          .split(img, DepthEstimator().estimate(img));
      return FrameCompositor(layers, img, qcfg(kinds, tier)).renderFrame(t);
    }

    test('光效类元在 standard 档改走 screen，画面与 legacy 不同', () {
      for (final k in [
        EffectKind.lightSweep,
        EffectKind.godRays,
        EffectKind.fireflies,
        EffectKind.starlight,
        EffectKind.embers,
        EffectKind.shimmer,
      ]) {
        final a = render([EffectKind.parallax, k], RenderTier.legacy, 0.5);
        final b = render([EffectKind.parallax, k], RenderTier.standard, 0.5);
        var diff = 0;
        for (var i = 0; i < a.data.length; i++) {
          if (a.data[i] != b.data[i]) diff++;
        }
        expect(diff, greaterThan(0), reason: '${k.name} 的 standard 路径未生效');
      }
    });

    test('standard 档叠光只会提亮，不会把底图压暗', () {
      // screen 的增亮量恒 ≤ 截断加法（见 render_test），跨档比亮度没有意义：
      // Catmull-Rom 本身就会改动亮部。这里只钉住同档内的单调性。
      for (final tier in [RenderTier.legacy, RenderTier.standard]) {
        final plain = render([EffectKind.parallax], tier, 0.5);
        final lit =
            render([EffectKind.parallax, EffectKind.godRays], tier, 0.5);
        var darker = 0;
        for (var i = 0; i < plain.pixelCount; i++) {
          if (lit.luminance(i) < plain.luminance(i) - 1) darker++;
        }
        expect(darker, 0, reason: '${tier.name} 档出现被压暗的像素');
      }
    });

    test('standard 档保持确定性与无缝循环', () {
      // 只启用新效果：视差/呼吸的周期与时长不成整倍数，首尾本就只近似相等。
      const kinds = [
        EffectKind.godRays,
        EffectKind.fireflies,
        EffectKind.starlight,
        EffectKind.embers,
        EffectKind.shimmer,
        EffectKind.rain,
        EffectKind.snow,
        EffectKind.speedLines,
      ];
      expect(render(kinds, RenderTier.standard, 0.7).data,
          equals(render(kinds, RenderTier.standard, 0.7).data));
      final cfg = qcfg(kinds, RenderTier.standard);
      expect(render(kinds, RenderTier.standard, 0.0).data,
          equals(render(kinds, RenderTier.standard, cfg.durationSec).data),
          reason: 'standard 档首尾帧必须逐字节一致');
    });
  });

  group('v1.3 漫画动势：focusLines 集中线', () {
    RgbaImage scene() {
      final img = RgbaImage(width: 96, height: 96);
      for (var y = 0; y < 96; y++) {
        for (var x = 0; x < 96; x++) {
          final lum = (70 + x * 150 ~/ 95).clamp(0, 255);
          img.setPixel(x, y, lum, lum, lum);
        }
      }
      return img;
    }

    final img = scene();
    final layers =
        LayerSplitter(layerCount: 3).split(img, DepthEstimator().estimate(img));

    EffectConfig fcfg({
      FocusLinesParams focus = const FocusLinesParams(),
      RenderTier tier = RenderTier.legacy,
    }) =>
        EffectConfig(
          effects: const [EffectKind.focusLines],
          fps: 8,
          durationSec: 2,
          seed: 41,
          focusLines: focus,
          quality: QualityParams(tier: tier),
        );

    final plainCfg =
        EffectConfig(effects: const [], fps: 8, durationSec: 2, seed: 41);

    RgbaImage draw(EffectConfig cfg, double t) =>
        FrameCompositor(layers, img, cfg).renderFrame(t);

    /// 相对无效果基线的变化像素数 / 弱变化（部分覆盖）像素数。
    (int, int) stats(RgbaImage f, RgbaImage base) {
      var changed = 0, faint = 0;
      for (var i = 0; i < base.pixelCount; i++) {
        final d = (f.luminance(i) - base.luminance(i)).abs();
        if (d == 0) continue;
        changed++;
        if (d <= 6) faint++;
      }
      return (changed, faint);
    }

    test('三种 mode 都改变画面', () {
      final base = draw(plainCfg, 0.5);
      for (final mode in ['black', 'white', 'both']) {
        final s =
            stats(draw(fcfg(focus: FocusLinesParams(mode: mode)), 0.5), base);
        expect(s.$1, greaterThan(500), reason: '$mode 模式几乎没有落笔');
      }
    });

    test('黑集中线只做压暗，白线只提亮，both 两者都有', () {
      final base = draw(plainCfg, 0.5);
      (int, int) dirs(String mode) {
        final f = draw(fcfg(focus: FocusLinesParams(mode: mode)), 0.5);
        var darker = 0, lighter = 0;
        for (var i = 0; i < base.pixelCount; i++) {
          final d = f.luminance(i) - base.luminance(i);
          if (d < 0) darker++;
          if (d > 0) lighter++;
        }
        return (darker, lighter);
      }

      final black = dirs('black');
      expect(black.$1, greaterThan(0));
      expect(black.$2, 0, reason: 'black 模式不该提亮');
      final white = dirs('white');
      expect(white.$1, 0, reason: 'white 模式不该压暗');
      expect(white.$2, greaterThan(0));
      final both = dirs('both');
      expect(both.$1, greaterThan(0));
      expect(both.$2, greaterThan(0));
    });

    test('innerFrac 内圈留空：焦点周围逐字节不变', () {
      const fl = FocusLinesParams(innerFrac: 0.3);
      final base = draw(plainCfg, 0.5);
      final f = draw(fcfg(focus: fl, tier: RenderTier.standard), 0.5);
      final diag2 = 96 * 1.4142135623730951 / 2;
      final rIn = diag2 * fl.innerFrac;
      final cx = 0.5 * 96, cy = 0.45 * 96;
      var inside = 0, outside = 0;
      for (var y = 0; y < 96; y++) {
        for (var x = 0; x < 96; x++) {
          final dx = x + 0.5 - cx, dy = y + 0.5 - cy;
          final changed =
              f.data[(y * 96 + x) * 4] != base.data[(y * 96 + x) * 4];
          if (dx * dx + dy * dy < (rIn - 1.5) * (rIn - 1.5)) {
            if (changed) inside++;
          } else if (changed) {
            outside++;
          }
        }
      }
      expect(inside, 0, reason: '留空圈内不应有一笔');
      expect(outside, greaterThan(0));
    });

    test('standard 档楔形边缘走 AA：部分覆盖像素严格增多', () {
      final base = draw(plainCfg, 0.5);
      for (final mode in ['black', 'white', 'both']) {
        final fl = FocusLinesParams(mode: mode);
        final l = stats(draw(fcfg(focus: fl), 0.5), base);
        final s =
            stats(draw(fcfg(focus: fl, tier: RenderTier.standard), 0.5), base);
        expect(s.$2, greaterThan(l.$2), reason: '$mode 档的 AA 过渡带没出现');
      }
    });

    test('确定性 / 整循环无缝 / turnCycles=0 时整圈不转', () {
      final cfg = fcfg(tier: RenderTier.standard);
      expect(draw(cfg, 0.7).data, equals(draw(cfg, 0.7).data));
      expect(draw(cfg, 0.0).data, equals(draw(cfg, cfg.durationSec).data),
          reason: '旋转必须是整数圈，否则循环有接缝');
      final still = fcfg(
          focus: const FocusLinesParams(turnCycles: 0),
          tier: RenderTier.standard);
      expect(draw(still, 0.0).data, equals(draw(still, 1.0).data));
    });

    test('focusLines 仅在启用时序列化，JSON 往返保哈希', () {
      final cfg = fcfg(focus: const FocusLinesParams(mode: 'both', lines: 40));
      final j = _decodeJson(cfg.toJsonString());
      expect(j['focusLines']['mode'], 'both');
      expect(EffectConfig.fromJson(j).configHash, cfg.configHash);
      final off = EffectConfig(effects: const [EffectKind.parallax]);
      expect(off.toJson().containsKey('focusLines'), isFalse,
          reason: '未启用时不得写入 JSON，否则经典指纹会变');
    });

    test('未知 mode 回落 black', () {
      final j = _decodeJson(
          EffectConfig(effects: const [EffectKind.focusLines]).toJsonString());
      (j['focusLines'] as Map)['mode'] = 'rainbow';
      final cfg = EffectConfig.fromJson(j);
      expect(cfg.focusLines.mode, 'black');
    });
  });

  group('v1.3 漫画动势：screenTone 网点纸', () {
    RgbaImage scene() {
      final img = RgbaImage(width: 96, height: 96);
      for (var y = 0; y < 96; y++) {
        for (var x = 0; x < 96; x++) {
          final lum = (70 + x * 150 ~/ 95).clamp(0, 255);
          img.setPixel(x, y, lum, lum, lum);
        }
      }
      return img;
    }

    /// 平场底图：让「同一覆盖率」对应「同一压暗量」，从而能数出过渡带有几种强度。
    RgbaImage flatScene() {
      final img = RgbaImage(width: 96, height: 96);
      for (var i = 0; i < img.pixelCount; i++) {
        img.setPixel(i % 96, i ~/ 96, 200, 200, 200);
      }
      return img;
    }

    final img = scene();
    final layers =
        LayerSplitter(layerCount: 3).split(img, DepthEstimator().estimate(img));
    final flat = flatScene();
    final flatLayers = LayerSplitter(layerCount: 3)
        .split(flat, DepthEstimator().estimate(flat));

    EffectConfig tcfg({
      ScreenToneParams tone = const ScreenToneParams(),
      RenderTier tier = RenderTier.legacy,
    }) =>
        EffectConfig(
          effects: const [EffectKind.screenTone],
          fps: 8,
          durationSec: 2,
          seed: 41,
          screenTone: tone,
          quality: QualityParams(tier: tier),
        );

    final plainCfg =
        EffectConfig(effects: const [], fps: 8, durationSec: 2, seed: 41);

    RgbaImage draw(EffectConfig cfg, double t, {RgbaImage? src}) =>
        FrameCompositor(src == null ? layers : flatLayers, src ?? img, cfg)
            .renderFrame(t);

    /// (变化像素数, 提亮像素数)
    (int, int) ink(RgbaImage f, RgbaImage base) {
      var changed = 0, lighter = 0;
      for (var i = 0; i < base.pixelCount; i++) {
        final d = f.luminance(i) - base.luminance(i);
        if (d == 0) continue;
        if (d > 0) lighter++;
        changed++;
      }
      return (changed, lighter);
    }

    /// 平场上出现的压暗强度种数（legacy 的二值掩码只有 1 种）。
    Set<int> deltas(RgbaImage f, RgbaImage base) {
      final s = <int>{};
      for (var i = 0; i < base.pixelCount; i++) {
        final d = base.luminance(i) - f.luminance(i);
        if (d != 0) s.add(d);
      }
      return s;
    }

    test('三种 mode 都压暗画面，且绝不提亮', () {
      final base = draw(plainCfg, 0.5);
      for (final mode in ['dot', 'line', 'cross']) {
        final s =
            ink(draw(tcfg(tone: ScreenToneParams(mode: mode)), 0.5), base);
        expect(s.$1, greaterThan(1000), reason: '$mode 模式几乎没有落墨');
        expect(s.$2, 0, reason: '$mode 网点只能压暗');
      }
    });

    test('opacity=0 时逐字节不动画面', () {
      final base = draw(plainCfg, 0.5);
      final off = draw(tcfg(tone: const ScreenToneParams(opacity: 0)), 0.5);
      expect(off.data, equals(base.data));
    });

    test('legacy 掩码二值、standard 网点边缘有过渡带', () {
      final b = draw(plainCfg, 0.5, src: flat);
      final l = draw(tcfg(tone: const ScreenToneParams(spacingPx: 12)), 0.5,
          src: flat);
      final s = draw(
          tcfg(
              tone: const ScreenToneParams(spacingPx: 12),
              tier: RenderTier.standard),
          0.5,
          src: flat);
      expect(deltas(l, b).length, 1, reason: 'legacy 必须保持 v1.2 式的硬边网点');
      expect(deltas(s, b).length, greaterThan(1),
          reason: 'standard 的解析覆盖度要给出过渡强度');
      expect(ink(s, b).$1, greaterThan(ink(l, b).$1));
    });

    test('density 单调控制覆盖率，standard 档更接近标称墨量', () {
      final base = draw(plainCfg, 0.5);
      final total = base.pixelCount;
      var prev = 0;
      for (final d in [0.10, 0.34, 0.80]) {
        final s = ink(
            draw(
                tcfg(
                    tone: ScreenToneParams(density: d),
                    tier: RenderTier.standard),
                0.5),
            base);
        expect(s.$1, greaterThan(prev), reason: 'density=$d 未增大覆盖率');
        prev = s.$1;
        // 稀网点（0.10）在 8px 格上只有几像素可分，两档会撞成同一个整数格；
        // 只在点距足以分辨的疏密段上比较精度。
        if (d < 0.2) continue;
        final errStd = (s.$1 / total - d).abs();
        final errLegacy =
            (ink(draw(tcfg(tone: ScreenToneParams(density: d)), 0.5), base).$1 /
                        total -
                    d)
                .abs();
        expect(errStd, lessThan(errLegacy), reason: '解析覆盖度应比二值掩码更贴近 density');
      }
    });

    test('确定性 / 整循环无缝 / 整 tile 漂移有半周期', () {
      // 漂移按整格取模 + 呼吸取整数周期：driftTiles 为偶数、densityCycles 为
      // 偶数时，图案在半个循环后就已回到起点。
      final cfg = tcfg(
          tone: const ScreenToneParams(
              driftTilesX: 2, driftTilesY: 2, densityCycles: 2),
          tier: RenderTier.standard);
      expect(draw(cfg, 0.7).data, equals(draw(cfg, 0.7).data));
      expect(draw(cfg, 0.0).data, equals(draw(cfg, cfg.durationSec).data),
          reason: '漂移必须是整数格，否则循环有接缝');
      for (final t in [0.0, 0.25, 0.7]) {
        expect(
            draw(cfg, t).data, equals(draw(cfg, t + cfg.durationSec / 2).data),
            reason: 't=$t 与半周期后应逐字节相等');
      }
    });

    test('angleDeg 会真正旋转点阵', () {
      // 注意默认 angleDeg 就是 30，必须与 0 度对比才看得出旋转。
      final a = draw(
          tcfg(
              tone: const ScreenToneParams(angleDeg: 0),
              tier: RenderTier.standard),
          0.5);
      final b = draw(
          tcfg(
              tone: const ScreenToneParams(angleDeg: 30),
              tier: RenderTier.standard),
          0.5);
      var diff = 0;
      for (var i = 0; i < a.data.length; i++) {
        if (a.data[i] != b.data[i]) diff++;
      }
      expect(diff, greaterThan(0), reason: 'angleDeg 未参与采样');
    });

    test('screenTone 仅在启用时序列化，JSON 往返保哈希', () {
      final cfg =
          tcfg(tone: const ScreenToneParams(mode: 'cross', spacingPx: 10));
      final j = _decodeJson(cfg.toJsonString());
      expect(j['screenTone']['mode'], 'cross');
      expect(EffectConfig.fromJson(j).configHash, cfg.configHash);
      final off = EffectConfig(effects: const [EffectKind.parallax]);
      expect(off.toJson().containsKey('screenTone'), isFalse,
          reason: '未启用时不得写入 JSON，否则经典指纹会变');
    });

    test('未知 mode 回落 dot', () {
      final j = _decodeJson(
          EffectConfig(effects: const [EffectKind.screenTone]).toJsonString());
      (j['screenTone'] as Map)['mode'] = 'stardust';
      final cfg = EffectConfig.fromJson(j);
      expect(cfg.screenTone.mode, 'dot');
    });
  });

  group('v1.3 漫画动势：mangaShake 震屏', () {
    RgbaImage scene() {
      final img = RgbaImage(width: 96, height: 96);
      for (var y = 0; y < 96; y++) {
        for (var x = 0; x < 96; x++) {
          final lum = (70 + x * 150 ~/ 95).clamp(0, 255);
          img.setPixel(x, y, lum, lum, lum);
        }
      }
      return img;
    }

    final img = scene();
    final layers =
        LayerSplitter(layerCount: 3).split(img, DepthEstimator().estimate(img));

    EffectConfig scfg({
      MangaShakeParams shake = const MangaShakeParams(),
      RenderTier tier = RenderTier.standard,
    }) =>
        EffectConfig(
          effects: const [EffectKind.mangaShake],
          fps: 8,
          durationSec: 2,
          seed: 41,
          mangaShake: shake,
          quality: QualityParams(tier: tier),
        );

    final plainCfg =
        EffectConfig(effects: const [], fps: 8, durationSec: 2, seed: 41);

    RgbaImage draw(EffectConfig cfg, double t) =>
        FrameCompositor(layers, img, cfg).renderFrame(t);

    /// 平均绝对亮度差（×1000）：位移越大差值越大，与「压暗/提亮」无关。
    double meanDelta(RgbaImage f, RgbaImage base) {
      var s = 0;
      for (var i = 0; i < base.pixelCount; i++) {
        s += (f.luminance(i) - base.luminance(i)).abs();
      }
      return s * 1000 / base.pixelCount;
    }

    int changedPixels(RgbaImage f, RgbaImage base) {
      var n = 0;
      for (var i = 0; i < base.pixelCount; i++) {
        if (f.luminance(i) != base.luminance(i)) n++;
      }
      return n;
    }

    // 第 k 个爆点的位移峰值时刻：rattle 每爆点 3 个完整周期 → pos=k+1/12。
    double peakAt(EffectConfig cfg, int k) =>
        (k + 1 / 12.0) * cfg.durationSec / cfg.mangaShake.shakes;

    test('启用后画面改变，且底图平移会提亮也会压暗', () {
      final base = draw(plainCfg, peakAt(plainCfg, 0));
      final f = draw(scfg(shake: const MangaShakeParams(amplitude: 0.05)),
          peakAt(scfg(), 0));
      expect(changedPixels(f, base), greaterThan(1000));
      var lighter = 0;
      for (var i = 0; i < base.pixelCount; i++) {
        if (f.luminance(i) > base.luminance(i)) lighter++;
      }
      // 渐变底图上平移必然一侧变亮、另一侧变暗（只有压暗说明走成了染色而非位移）。
      expect(lighter, greaterThan(0));
    });

    test('amplitude 与 decay 单调控制位移量', () {
      final base = draw(plainCfg, 0.0);
      double at(double amp, {double decay = 0.72}) => meanDelta(
          draw(scfg(shake: MangaShakeParams(amplitude: amp, decay: decay)),
              peakAt(scfg(), 0)),
          base);
      final small = at(0.006), mid = at(0.02), big = at(0.05);
      expect(mid, greaterThan(small), reason: 'amplitude 未放大位移');
      expect(big, greaterThan(mid), reason: 'amplitude 未放大位移');
      // decay 越大收尾越快 → 同一相位上累计位移越小。
      expect(at(0.05, decay: 1.6), lessThan(big), reason: 'decay 未加快衰减');
    });

    test('amplitude=0 逐字节等于不启用震屏', () {
      // 位移为 0 时底图覆盖系数必须恰为 1.0，否则 legacy 回滚承诺会被新分支破坏。
      const zero = MangaShakeParams(amplitude: 0);
      for (final t in [0.0, 0.5, 1.3]) {
        expect(
            draw(scfg(shake: zero), t).data,
            equals(draw(
                    EffectConfig(
                        effects: const [],
                        fps: 8,
                        durationSec: 2,
                        seed: 41,
                        quality:
                            const QualityParams(tier: RenderTier.standard)),
                    t)
                .data));
      }
    });

    test('确定性 / 整循环无缝 / 减弱动态下不动', () {
      final cfg = scfg(shake: const MangaShakeParams(amplitude: 0.05));
      expect(draw(cfg, 0.7).data, equals(draw(cfg, 0.7).data));
      expect(draw(cfg, 0.0).data, equals(draw(cfg, cfg.durationSec).data),
          reason: 'shakes 与 rattle 都是整数周期，首尾必须逐字节一致');
      final rm = EffectConfig(
          effects: const [EffectKind.mangaShake],
          fps: 8,
          durationSec: 2,
          seed: 41,
          mangaShake: const MangaShakeParams(amplitude: 0.05),
          reducedMotion: true);
      expect(draw(rm, 0.5).data, equals(draw(rm, 1.1).data),
          reason: '减弱动态应输出静态单帧');
    });

    test('rotJitDeg 改变爆点方向', () {
      final t = peakAt(scfg(), 1);
      final base = draw(plainCfg, t);
      double d(double jit) => meanDelta(
          draw(scfg(shake: MangaShakeParams(amplitude: 0.05, rotJitDeg: jit)),
              t),
          base);
      expect(d(12), isNot(closeTo(d(0), 1.0)), reason: 'rotJitDeg 未参与方向');
    });

    test('legacy 档同样生效', () {
      final cfg = scfg(
          shake: const MangaShakeParams(amplitude: 0.05),
          tier: RenderTier.legacy);
      final base = draw(
          EffectConfig(
              effects: const [],
              fps: 8,
              durationSec: 2,
              seed: 41,
              quality: const QualityParams(tier: RenderTier.legacy)),
          peakAt(cfg, 0));
      expect(changedPixels(draw(cfg, peakAt(cfg, 0)), base), greaterThan(1000));
    });

    test('mangaShake 仅在启用时序列化，JSON 往返保哈希', () {
      final cfg = scfg(shake: const MangaShakeParams(shakes: 9, decay: 1.1));
      final j = _decodeJson(cfg.toJsonString());
      expect(j['mangaShake']['shakes'], 9);
      expect(EffectConfig.fromJson(j).configHash, cfg.configHash);
      final off = EffectConfig(effects: const [EffectKind.parallax]);
      expect(off.toJson().containsKey('mangaShake'), isFalse,
          reason: '未启用时不得写入 JSON，否则经典指纹会变');
    });
  });

  group('v1.3 漫画动势：impactRings 冲击波环', () {
    RgbaImage scene() {
      final img = RgbaImage(width: 96, height: 96);
      for (var y = 0; y < 96; y++) {
        for (var x = 0; x < 96; x++) {
          final lum = (70 + x * 150 ~/ 95).clamp(0, 255);
          img.setPixel(x, y, lum, lum, lum);
        }
      }
      return img;
    }

    final img = scene();
    final layers =
        LayerSplitter(layerCount: 3).split(img, DepthEstimator().estimate(img));

    EffectConfig rcfg({
      ImpactRingsParams rings = const ImpactRingsParams(),
      RenderTier tier = RenderTier.legacy,
    }) =>
        EffectConfig(
          effects: const [EffectKind.impactRings],
          fps: 8,
          durationSec: 2,
          seed: 41,
          impactRings: rings,
          quality: QualityParams(tier: tier),
        );

    EffectConfig plain(RenderTier tier) => EffectConfig(
        effects: const [],
        fps: 8,
        durationSec: 2,
        seed: 41,
        quality: QualityParams(tier: tier));

    RgbaImage draw(EffectConfig cfg, double t) =>
        FrameCompositor(layers, img, cfg).renderFrame(t);

    /// 相对同档基线的落墨量与方向（环是加亮，shock 的暗边才是压暗）。
    (int, int, int) dirs(RgbaImage f, RgbaImage base) {
      var darker = 0, lighter = 0, faint = 0;
      for (var i = 0; i < base.pixelCount; i++) {
        final d = f.luminance(i) - base.luminance(i);
        if (d == 0) continue;
        if (d < 0) {
          darker++;
        } else {
          lighter++;
        }
        if (d.abs() <= 6) faint++;
      }
      return (darker, lighter, faint);
    }

    test('整周期持续落墨，ring 模式只提亮', () {
      for (final t in [0.0, 0.25, 0.5, 0.87, 1.25]) {
        final s = dirs(draw(rcfg(), t), draw(plain(RenderTier.legacy), t));
        expect(s.$2, greaterThan(500), reason: 't=$t 几乎没有环落笔');
        expect(s.$1, 0, reason: 'ring 模式不该压暗');
      }
    });

    test('rings 增大时可见像素数单调增', () {
      final counts = <int>[];
      for (final n in [1, 2, 3, 5, 8, 12]) {
        var sum = 0;
        for (final t in [0.05, 0.2, 0.35, 0.5, 0.65, 0.8]) {
          final cfg = rcfg(rings: ImpactRingsParams(rings: n));
          sum += dirs(draw(cfg, t), draw(plain(RenderTier.legacy), t)).$2;
        }
        counts.add(sum ~/ 6);
      }
      for (var i = 1; i < counts.length; i++) {
        expect(counts[i], greaterThan(counts[i - 1]),
            reason: '环数增加却未变亮：$counts');
      }
    });

    test('shock 模式在环内侧补压暗描边', () {
      final base = draw(plain(RenderTier.legacy), 0.25);
      final ring = dirs(draw(rcfg(), 0.25), base);
      final shock = dirs(
          draw(rcfg(rings: const ImpactRingsParams(mode: 'shock')), 0.25),
          base);
      expect(ring.$1, 0);
      expect(shock.$1, greaterThan(200), reason: 'shock 暗边未落笔');
      // 暗边盖在亮环内侧会把部分亮像素重新压暗，所以看总落墨量而非提亮数。
      expect(shock.$1 + shock.$2, greaterThan(ring.$1 + ring.$2),
          reason: 'shock 应比 ring 更密');
      expect(shock.$2, greaterThan(200));
    });

    test('legacy 环边二值，standard 有过渡带且更柔和', () {
      const tierL = RenderTier.legacy;
      const tierS = RenderTier.standard;
      final l = dirs(draw(rcfg(tier: tierL), 0.25), draw(plain(tierL), 0.25));
      final s = dirs(draw(rcfg(tier: tierS), 0.25), draw(plain(tierS), 0.25));
      expect(l.$3, 0, reason: 'legacy 不该有部分覆盖像素');
      expect(s.$3, greaterThan(50), reason: 'standard 缺 AA 过渡带');
      expect(s.$2, greaterThan(l.$2), reason: 'standard 边缘应扩出更多弱像素');
    });

    test('opacity=0 与 outerFrac<=innerFrac 都是空操作', () {
      final base = draw(plain(RenderTier.legacy), 0.5);
      expect(draw(rcfg(rings: const ImpactRingsParams(opacity: 0)), 0.5).data,
          equals(base.data));
      expect(
          draw(
                  rcfg(
                      rings: const ImpactRingsParams(
                          innerFrac: 0.5, outerFrac: 0.1)),
                  0.5)
              .data,
          equals(base.data));
    });

    test('确定性 / 整循环无缝 / 减弱动态下仍有静帧', () {
      final cfg = rcfg();
      expect(draw(cfg, 0.7).data, equals(draw(cfg, 0.7).data));
      expect(draw(cfg, 0.0).data, equals(draw(cfg, cfg.durationSec).data),
          reason: 'pulses 是整数周期，首尾必须逐字节一致');
      final rm = EffectConfig(
          effects: const [EffectKind.impactRings],
          fps: 8,
          durationSec: 2,
          seed: 41,
          reducedMotion: true);
      expect(draw(rm, 0.3).data, equals(draw(rm, 1.4).data));
    });

    test('未知 mode 等同 ring', () {
      expect(draw(rcfg(rings: const ImpactRingsParams(mode: 'zz')), 0.25).data,
          equals(draw(rcfg(), 0.25).data));
    });

    test('impactRings 仅在启用时序列化，JSON 往返保哈希', () {
      final cfg = rcfg(
          rings: const ImpactRingsParams(
              rings: 7, thicknessPx: 6.0, mode: 'shock', pulses: 3));
      final j = _decodeJson(cfg.toJsonString());
      expect(j['impactRings']['rings'], 7);
      expect(j['impactRings']['mode'], 'shock');
      expect(EffectConfig.fromJson(j).configHash, cfg.configHash);
      final off = EffectConfig(effects: const [EffectKind.parallax]);
      expect(off.toJson().containsKey('impactRings'), isFalse);
    });
  });

  group('v1.3 漫画动势：brushStreak 飞白笔触', () {
    const size = 96;
    RgbaImage scene() {
      final img = RgbaImage(width: size, height: size);
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final lum = (70 + x * 150 ~/ (size - 1)).clamp(0, 255);
          img.setPixel(x, y, lum, lum, lum);
        }
      }
      return img;
    }

    final img = scene();
    final layers =
        LayerSplitter(layerCount: 3).split(img, DepthEstimator().estimate(img));

    EffectConfig bcfg({
      BrushStreakParams brush = const BrushStreakParams(),
      RenderTier tier = RenderTier.legacy,
    }) =>
        EffectConfig(
          effects: const [EffectKind.brushStreak],
          fps: 8,
          durationSec: 2,
          seed: 41,
          brushStreak: brush,
          quality: QualityParams(tier: tier),
        );

    EffectConfig plain(RenderTier tier) => EffectConfig(
        effects: const [],
        fps: 8,
        durationSec: 2,
        seed: 41,
        quality: QualityParams(tier: tier));

    RgbaImage draw(EffectConfig cfg, double t) =>
        FrameCompositor(layers, img, cfg).renderFrame(t);

    (int, int) dirs(RgbaImage f, RgbaImage base) {
      var darker = 0, lighter = 0;
      for (var i = 0; i < base.pixelCount; i++) {
        final d = f.luminance(i) - base.luminance(i);
        if (d < 0) {
          darker++;
        } else if (d > 0) {
          lighter++;
        }
      }
      return (darker, lighter);
    }

    /// 一条笔划在某行上被啃出几段墨：>1 即说明存在飞白缺口。
    int maxRunsOnALine(EffectConfig cfg, double t, RgbaImage base) {
      final f = draw(cfg, t);
      var best = 0;
      for (var y = 0; y < size; y++) {
        var runs = 0;
        var inRun = false;
        for (var x = 0; x < size; x++) {
          final on = base.luminance(y * size + x) - f.luminance(y * size + x) >
              12; // 深墨，滤掉 AA 弱边
          if (on && !inRun) {
            runs++;
            inRun = true;
          }
          if (!on) inRun = false;
        }
        if (runs > best) best = runs;
      }
      return best;
    }

    test('启用后只压暗（黑墨），整周期都有笔划', () {
      for (final t in [0.1, 0.3, 0.5, 0.72, 0.9]) {
        final s = dirs(draw(bcfg(), t), draw(plain(RenderTier.legacy), t));
        expect(s.$1, greaterThan(800), reason: 't=$t 落墨过少');
        expect(s.$2, 0, reason: '黑笔触不该提亮');
      }
    });

    test('缺口存在性：同一条笔划，gapFreq 决定行内是否被啃断', () {
      // 单条笔划、整笔走完的时刻：低频率 ≈ 实心（每行至多 1 段），
      // 默认频率必须在中段啃出白隙（同一行 ≥2 段）。
      const solid = BrushStreakParams(streaks: 1, gapFreq: 0.02);
      const dry = BrushStreakParams(streaks: 1, gapFreq: 0.11);
      for (final t in [0.45, 0.5, 0.6]) {
        final base = draw(plain(RenderTier.legacy), t);
        expect(maxRunsOnALine(bcfg(brush: solid), t, base), 1,
            reason: 't=$t 近实心笔划被错误切断');
        expect(maxRunsOnALine(bcfg(brush: dry), t, base), greaterThan(1),
            reason: 't=$t 未啃出飞白缺口');
      }
    });

    test('gapFreq 超上限被夹住，避免与段长同相混叠', () {
      final a = bcfg(brush: const BrushStreakParams(gapFreq: 0.25));
      final b = bcfg(brush: const BrushStreakParams(gapFreq: 9.0));
      for (final t in [0.2, 0.5, 0.8]) {
        expect(draw(b, t).data, equals(draw(a, t).data));
      }
    });

    test('streaks / thicknessPx 单调控制落墨量', () {
      for (final ps in [
        [
          const BrushStreakParams(streaks: 1),
          const BrushStreakParams(streaks: 4),
          const BrushStreakParams(streaks: 12),
          const BrushStreakParams(streaks: 24),
        ],
        [
          const BrushStreakParams(thicknessPx: 1),
          const BrushStreakParams(thicknessPx: 3),
          const BrushStreakParams(thicknessPx: 7),
          const BrushStreakParams(thicknessPx: 14),
        ],
      ]) {
        var prev = -1;
        for (final bp in ps) {
          var sum = 0;
          for (final t in [0.1, 0.3, 0.55, 0.8]) {
            sum += dirs(
                    draw(bcfg(brush: bp), t), draw(plain(RenderTier.legacy), t))
                .$1;
          }
          final v = sum ~/ 4;
          expect(v, greaterThan(prev), reason: '$ps 落墨量非单调');
          prev = v;
        }
      }
    });

    test('opacity=0 逐字节不变', () {
      final base = draw(plain(RenderTier.legacy), 0.5);
      expect(draw(bcfg(brush: const BrushStreakParams(opacity: 0)), 0.5).data,
          equals(base.data));
    });

    test('确定性 / 整循环无缝 / 减弱动态下不动', () {
      final cfg = bcfg();
      expect(draw(cfg, 0.7).data, equals(draw(cfg, 0.7).data));
      expect(draw(cfg, 0.0).data, equals(draw(cfg, cfg.durationSec).data),
          reason: 'pulses 是整数周期，首尾必须逐字节一致');
      final rm = EffectConfig(
          effects: const [EffectKind.brushStreak],
          fps: 8,
          durationSec: 2,
          seed: 41,
          reducedMotion: true);
      expect(draw(rm, 0.3).data, equals(draw(rm, 1.4).data));
    });

    test('standard 档笔触边缘有 AA 过渡，比 legacy 更密更柔', () {
      (int, int) stat(RenderTier tier) {
        final f = draw(bcfg(tier: tier), 0.5);
        final b = draw(plain(tier), 0.5);
        var ink = 0, faint = 0;
        for (var i = 0; i < b.pixelCount; i++) {
          final d = (f.luminance(i) - b.luminance(i)).abs();
          if (d == 0) continue;
          ink++;
          if (d <= 6) faint++;
        }
        return (ink, faint);
      }

      final l = stat(RenderTier.legacy);
      final s = stat(RenderTier.standard);
      expect(s.$1, greaterThan(l.$1), reason: 'standard 未扩出 AA 边缘：$l→$s');
      expect(s.$2, greaterThan(l.$2 + 60), reason: 'standard 弱覆盖像素未增多：$l→$s');
    });

    test('brushStreak 仅在启用时序列化，JSON 往返保哈希', () {
      final cfg = bcfg(
          brush: const BrushStreakParams(
              streaks: 5, thicknessPx: 9.5, gapFreq: 0.2, angleDeg: -20));
      final j = _decodeJson(cfg.toJsonString());
      expect(j['brushStreak']['streaks'], 5);
      expect(j['brushStreak']['angleDeg'], -20);
      expect(EffectConfig.fromJson(j).configHash, cfg.configHash);
      final off = EffectConfig(effects: const [EffectKind.parallax]);
      expect(off.toJson().containsKey('brushStreak'), isFalse);
    });
  });

  group('v1.3 自然氛围：flame / smoke / bubbles / leaves / meteors', () {
    const size = 96;
    RgbaImage scene() {
      // 偏暗渐变：加亮型粒子（火星/气泡/流星）与压暗型（叶片）都能测出来。
      final img = RgbaImage(width: size, height: size);
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final lum = (40 + x * 90 ~/ (size - 1)).clamp(0, 255);
          img.setPixel(x, y, lum, lum, lum);
        }
      }
      return img;
    }

    final img = scene();
    final layers =
        LayerSplitter(layerCount: 3).split(img, DepthEstimator().estimate(img));

    const ts = [0.1, 0.35, 0.6, 0.85];

    EffectConfig plain([RenderTier tier = RenderTier.legacy]) => EffectConfig(
        effects: const [],
        fps: 8,
        durationSec: 2,
        seed: 41,
        quality: QualityParams(tier: tier));

    EffectConfig flame(FlameParams p, [RenderTier tier = RenderTier.legacy]) =>
        EffectConfig(
            effects: const [EffectKind.flame],
            fps: 8,
            durationSec: 2,
            seed: 41,
            flame: p,
            quality: QualityParams(tier: tier));

    EffectConfig smoke(SmokeParams p, [RenderTier tier = RenderTier.legacy]) =>
        EffectConfig(
            effects: const [EffectKind.smoke],
            fps: 8,
            durationSec: 2,
            seed: 41,
            smoke: p,
            quality: QualityParams(tier: tier));

    EffectConfig bubbles(BubblesParams p,
            [RenderTier tier = RenderTier.legacy]) =>
        EffectConfig(
            effects: const [EffectKind.bubbles],
            fps: 8,
            durationSec: 2,
            seed: 41,
            bubbles: p,
            quality: QualityParams(tier: tier));

    EffectConfig leaves(LeavesParams p,
            [RenderTier tier = RenderTier.legacy]) =>
        EffectConfig(
            effects: const [EffectKind.leaves],
            fps: 8,
            durationSec: 2,
            seed: 41,
            leaves: p,
            quality: QualityParams(tier: tier));

    EffectConfig meteors(MeteorsParams p,
            [RenderTier tier = RenderTier.legacy]) =>
        EffectConfig(
            effects: const [EffectKind.meteors],
            fps: 8,
            durationSec: 2,
            seed: 41,
            meteors: p,
            quality: QualityParams(tier: tier));

    RgbaImage draw(EffectConfig cfg, double t) =>
        FrameCompositor(layers, img, cfg).renderFrame(t);

    (int, int, int) stat(RgbaImage f, RgbaImage b) {
      var ink = 0, darker = 0, lighter = 0;
      for (var i = 0; i < b.pixelCount; i++) {
        final d = f.luminance(i) - b.luminance(i);
        if (d == 0) continue;
        ink++;
        if (d < 0) {
          darker++;
        } else {
          lighter++;
        }
      }
      return (ink, darker, lighter);
    }

    int avgInk(EffectConfig cfg) {
      var sum = 0;
      for (final t in ts) {
        sum += stat(draw(cfg, t), draw(plain(), t)).$1;
      }
      return sum ~/ ts.length;
    }

    int diffBytes(RgbaImage a, RgbaImage b) {
      var n = 0;
      for (var i = 0; i < a.data.length; i++) {
        if (a.data[i] != b.data[i]) n++;
      }
      return n;
    }

    void strictlyGrowing(List<int> vals, String what) {
      for (var i = 1; i < vals.length; i++) {
        expect(vals[i], greaterThan(vals[i - 1]), reason: '$what 落墨量非单调：$vals');
      }
    }

    test('连续型氛围粒子：整周期落墨，压暗只是零头', () {
      final passing = [
        flame(const FlameParams()),
        smoke(const SmokeParams()),
        bubbles(const BubblesParams()),
      ];
      for (final cfg in passing) {
        for (final t in ts) {
          final s = stat(draw(cfg, t), draw(plain(), t));
          expect(s.$1, greaterThan(500), reason: '${cfg.effects} t=$t 落墨过少');
          // 暖色（cold=ff5a1e）落在中灰列上会让亮度均值微降，属正常色偏移。
          expect(s.$2, lessThan(20),
              reason: '${cfg.effects} t=$t 出现成片压暗：${s.$2}');
        }
      }
      // 叶片有深色叶脉，允许少量压暗，但仍以提亮为主。
      final leaf =
          stat(draw(leaves(const LeavesParams()), 0.35), draw(plain(), 0.35));
      expect(leaf.$1, greaterThan(500));
      expect(leaf.$3, greaterThan(leaf.$2));
    });

    test('粒子数量单调：tongues / puffs / count', () {
      strictlyGrowing(
          [1, 4, 14, 30]
              .map((n) => avgInk(flame(FlameParams(tongues: n))))
              .toList(),
          'flame.tongues');
      strictlyGrowing(
          [1, 6, 16, 32]
              .map((n) => avgInk(smoke(SmokeParams(puffs: n))))
              .toList(),
          'smoke.puffs');
      strictlyGrowing(
          [1, 4, 10, 18, 40]
              .map((n) => avgInk(bubbles(BubblesParams(count: n))))
              .toList(),
          'bubbles.count');
      strictlyGrowing(
          [1, 4, 11, 22, 60]
              .map((n) => avgInk(leaves(LeavesParams(count: n))))
              .toList(),
          'leaves.count');
      strictlyGrowing(
          [1, 5, 12, 20]
              .map((n) => avgInk(meteors(MeteorsParams(count: n))))
              .toList(),
          'meteors.count');
    });

    test('尺寸单调：气泡半径 / 叶片长度 / 流星窗口', () {
      strictlyGrowing(
          [1.5, 4.0, 6.5, 12.0]
              .map((r) => avgInk(bubbles(BubblesParams(sizePx: r, count: 4))))
              .toList(),
          'bubbles.sizePx');
      strictlyGrowing(
          [1.5, 4.0, 6.8, 14.0]
              .map((r) => avgInk(leaves(LeavesParams(sizePx: r, count: 6))))
              .toList(),
          'leaves.sizePx');
      final win = [0.18, 0.6]
          .map((w) => avgInk(meteors(MeteorsParams(windowFrac: w))))
          .toList();
      strictlyGrowing(win, 'meteors.windowFrac');
    });

    test('flame 下暖上冷：根部偏红、尖端转暗', () {
      // 默认 heightFrac 只有 0.18，苗太矮测不出上下色阶，这里拉高到半屏。
      final f = draw(flame(const FlameParams(heightFrac: 0.5)), 0.4);
      final b = draw(plain(), 0.4);
      (int, int, int) warmAvg(int y0, int y1) {
        var r = 0, g = 0, bl = 0, n = 0;
        for (var y = y0; y < y1; y++) {
          for (var x = 0; x < size; x++) {
            final i = (y * size + x) * 4;
            if (f.data[i] == b.data[i] &&
                f.data[i + 1] == b.data[i + 1] &&
                f.data[i + 2] == b.data[i + 2]) {
              continue;
            }
            r += f.data[i];
            g += f.data[i + 1];
            bl += f.data[i + 2];
            n++;
          }
        }
        expect(n, greaterThan(100), reason: 'y=$y0..$y1 无落墨');
        return (r ~/ n, g ~/ n, bl ~/ n);
      }

      final root = warmAvg(size - 14, size);
      final tip = warmAvg(size - 40, size - 22);
      expect(root.$1, greaterThan(root.$2), reason: '根部应偏红：$root');
      expect(root.$2, greaterThan(root.$3), reason: '根部应偏橙：$root');
      expect(root.$1, greaterThan(tip.$1 + 30), reason: '根尖红度未衰减：$root→$tip');
    });

    test('leaves palette 生效，未知色板回落 autumn', () {
      (int, int, int) meanOf(String pal) {
        final f = draw(leaves(LeavesParams(palette: pal)), 0.4);
        final b = draw(plain(), 0.4);
        var r = 0, g = 0, bl = 0, n = 0;
        for (var i = 0; i < b.pixelCount; i++) {
          if (f.luminance(i) == b.luminance(i)) continue;
          r += f.data[i * 4];
          g += f.data[i * 4 + 1];
          bl += f.data[i * 4 + 2];
          n++;
        }
        expect(n, greaterThan(500));
        return (r ~/ n, g ~/ n, bl ~/ n);
      }

      final autumn = meanOf('autumn');
      final spring = meanOf('spring');
      final summer = meanOf('summer');
      expect(autumn.$1, greaterThan(spring.$1), reason: '秋色应更暖：$autumn');
      expect(spring.$2, greaterThan(spring.$1), reason: '春色应偏绿：$spring');
      expect(summer.$2, greaterThan(summer.$1), reason: '夏色应偏绿：$summer');
      expect(meanOf('zz'), equals(autumn), reason: '未知色板未回落 autumn');
      // 翻面圈数只改明暗节奏，不该改变总量级。
      final turns = [0, 2, 5]
          .map((f) => avgInk(leaves(LeavesParams(flipTurns: f))))
          .toList();
      expect(turns.reduce((a, b) => a > b ? a : b),
          lessThan(turns.reduce((a, b) => a < b ? a : b) * 2),
          reason: 'flipTurns 大幅改变了落墨量：$turns');
    });

    test('smoke turbulence 改变横向分布', () {
      final calm = draw(smoke(const SmokeParams(turbulence: 0)), 0.3);
      final gusty = draw(smoke(const SmokeParams(turbulence: 1.2)), 0.3);
      expect(diffBytes(calm, gusty), greaterThan(500),
          reason: 'turbulence 未影响烟团位置');
    });

    test('meteors 是窗口式：存在完全无流星的时刻', () {
      final cfg = meteors(const MeteorsParams());
      var empty = 0;
      for (var i = 0; i < 40; i++) {
        final t = i / 20.0;
        if (stat(draw(cfg, t), draw(plain(), t)).$1 == 0) empty++;
      }
      expect(empty, greaterThan(5), reason: '流星变成常亮了：空窗时刻=$empty/40');
      expect(empty, lessThan(38), reason: '几乎没有流星划过：$empty/40');
      // 屏幕坐标 y 向下：32° 向右下划落，与 148° 的镜像方向必须不同。
      expect(
          diffBytes(draw(meteors(const MeteorsParams()), 0.06),
              draw(meteors(const MeteorsParams(angleDeg: 148)), 0.06)),
          greaterThan(100));
    });

    test('opacity=0 五效都是逐字节空操作', () {
      final t = 0.4;
      final base = draw(plain(), t);
      expect(draw(flame(const FlameParams(opacity: 0)), t).data,
          equals(base.data));
      expect(draw(smoke(const SmokeParams(opacity: 0)), t).data,
          equals(base.data));
      expect(draw(bubbles(const BubblesParams(opacity: 0)), t).data,
          equals(base.data));
      expect(draw(leaves(const LeavesParams(opacity: 0)), t).data,
          equals(base.data));
      expect(draw(meteors(const MeteorsParams(opacity: 0)), t).data,
          equals(base.data));
    });

    test('确定性 / 整循环无缝 / 减弱动态下为静帧', () {
      final all = [
        flame(const FlameParams()),
        smoke(const SmokeParams()),
        bubbles(const BubblesParams()),
        leaves(const LeavesParams()),
        meteors(const MeteorsParams()),
      ];
      for (final cfg in all) {
        final tag = cfg.effects.single.name;
        expect(diffBytes(draw(cfg, 0.7), draw(cfg, 0.7)), 0,
            reason: '$tag 同参两次渲染不一致');
        expect(diffBytes(draw(cfg, 0), draw(cfg, cfg.durationSec)), 0,
            reason: '$tag 首尾不衔接（周期参数必须是整数轮）');
        final rm = EffectConfig(
            effects: [cfg.effects.single],
            fps: 8,
            durationSec: 2,
            seed: 41,
            reducedMotion: true);
        expect(diffBytes(draw(rm, 0.3), draw(rm, 1.4)), 0,
            reason: '$tag 减弱动态下仍在动');
      }
    });

    test('AA 档改变粒子光栅，气泡在 standard 覆盖更密', () {
      final tiers = <(String, EffectConfig Function(RenderTier))>[
        ('flame', (t) => flame(const FlameParams(), t)),
        ('smoke', (t) => smoke(const SmokeParams(), t)),
        ('bubbles', (t) => bubbles(const BubblesParams(), t)),
        ('leaves', (t) => leaves(const LeavesParams(), t)),
      ];
      for (final e in tiers) {
        final l = draw(e.$2(RenderTier.legacy), 0.4);
        final s = draw(e.$2(RenderTier.standard), 0.4);
        expect(diffBytes(l, s), greaterThan(500),
            reason: '${e.$1} 两档光栅完全相同，AA 未接入');
      }
      // 气泡画的是环 + 内填充 + 高光，standard 的 AA 覆盖面明显更宽。
      final base = draw(plain(), 0.4);
      final li = stat(draw(bubbles(const BubblesParams()), 0.4), base).$1;
      final si = stat(
              draw(bubbles(const BubblesParams(), RenderTier.standard), 0.4),
              base)
          .$1;
      expect(si, greaterThan(li * 2), reason: 'standard 未扩出弱覆盖：$li→$si');

      // 流星只在窗口内可见，取一个确有流星的时刻验证两档都落了墨。
      final mL =
          stat(draw(meteors(const MeteorsParams()), 0.45), draw(plain(), 0.45));
      final mS = stat(
          draw(meteors(const MeteorsParams(), RenderTier.standard), 0.45),
          draw(plain(), 0.45));
      expect(mL.$1, greaterThan(0));
      expect(mS.$1, greaterThan(0));
      expect(mS.$1, greaterThan(mL.$1), reason: 'standard 流星头应有 AA 光晕');
    });

    test('五效仅在启用时序列化，JSON 往返保哈希', () {
      final f =
          flame(const FlameParams(tongues: 9, hot: 'ff0000', cold: '0000ff'));
      final jf = _decodeJson(f.toJsonString());
      expect(jf['flame']['tongues'], 9);
      expect(jf['flame']['hot'], 'ff0000');
      expect(EffectConfig.fromJson(jf).configHash, f.configHash);

      final s = smoke(const SmokeParams(puffs: 3, color: '112233'));
      final js = _decodeJson(s.toJsonString());
      expect(js['smoke']['puffs'], 3);
      expect(EffectConfig.fromJson(js).configHash, s.configHash);

      final b = bubbles(const BubblesParams(count: 7, wobblePx: 3.0));
      final jb = _decodeJson(b.toJsonString());
      expect(jb['bubbles']['count'], 7);
      expect(EffectConfig.fromJson(jb).configHash, b.configHash);

      final l = leaves(const LeavesParams(count: 5, palette: 'summer'));
      final jl = _decodeJson(l.toJsonString());
      expect(jl['leaves']['palette'], 'summer');
      expect(EffectConfig.fromJson(jl).configHash, l.configHash);

      final m = meteors(const MeteorsParams(count: 3, angleDeg: 60));
      final jm = _decodeJson(m.toJsonString());
      expect(jm['meteors']['angleDeg'], 60);
      expect(EffectConfig.fromJson(jm).configHash, m.configHash);

      final off = EffectConfig(effects: const [EffectKind.parallax]).toJson();
      for (final key in ['flame', 'smoke', 'bubbles', 'leaves', 'meteors']) {
        expect(off.containsKey(key), isFalse, reason: '$key 未启用也写进了 JSON');
      }
    });
  });

  group('v1.3 情绪编排：moodScript 包络', () {
    const size = 96;
    RgbaImage scene() {
      // 单调横向渐变：同向位移的平均绝对差随位移单调增长，可当尺子用。
      final img = RgbaImage(width: size, height: size);
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final lum = (30 + x * 120 ~/ (size - 1)).clamp(0, 255);
          img.setPixel(x, y, lum, lum, lum);
        }
      }
      return img;
    }

    final img = scene();
    final layers =
        LayerSplitter(layerCount: 3).split(img, DepthEstimator().estimate(img));

    EffectConfig of(List<EffectKind> kinds,
            {MoodScriptParams? mood,
            ParallaxParams? parallax,
            RenderTier tier = RenderTier.legacy}) =>
        EffectConfig(
            effects: kinds,
            fps: 8,
            durationSec: 2,
            seed: 41,
            parallax: parallax,
            moodScript: mood,
            quality: QualityParams(tier: tier));

    RgbaImage draw(EffectConfig cfg, double t) =>
        FrameCompositor(layers, img, cfg).renderFrame(t);

    int diffBytes(RgbaImage a, RgbaImage b) {
      var n = 0;
      for (var i = 0; i < a.data.length; i++) {
        if (a.data[i] != b.data[i]) n++;
      }
      return n;
    }

    /// 相对无动效底图的平均绝对亮度差 ≈ 位移幅度。
    final plain = EffectConfig(fps: 8, durationSec: 2, seed: 41);
    double energy(EffectConfig cfg, double t) {
      final a = draw(cfg, t);
      final b = draw(plain, t);
      var s = 0.0;
      for (var i = 0; i < a.pixelCount; i++) {
        s += (a.luminance(i) - b.luminance(i)).abs();
      }
      return s / a.pixelCount;
    }

    test('四条曲线：乘性因子恒正、整周期首尾相等', () {
      for (final mood in MotionEnvelope.knownMoods) {
        final e = MotionEnvelope.of(mood);
        expect(e.moodUsed, mood);
        expect(e.usedFallback, isFalse, reason: '$mood 被当成未知值');
        final a = e.at(0), b = e.at(0.999999);
        expect(a.motion, closeTo(b.motion, 1e-3));
        expect(a.particles, closeTo(b.particles, 1e-3));
        expect(a.exposure, closeTo(b.exposure, 1e-3));
        for (var i = 0; i <= 100; i++) {
          final f = e.at(i / 100);
          expect(f.motion, inInclusiveRange(0.05, 3.0), reason: '$mood u=$i');
          expect(f.particles, inInclusiveRange(0.05, 3.0));
          expect(f.exposure, inInclusiveRange(0.05, 3.0));
          expect(f.warmth.abs(), lessThan(0.2));
          expect(f.vignette.abs(), lessThan(0.3));
        }
      }
    });

    test('strength=0 退化为恒等因子，未知 mood 回落 calm', () {
      final f = MotionEnvelope.of('tension', strength: 0).at(0.35);
      expect(f.motion, 1.0);
      expect(f.particles, 1.0);
      expect(f.exposure, 1.0);
      expect(f.warmth, 0.0);
      expect(f.vignette, 0.0);

      final calm = MotionEnvelope.of('calm');
      final e = MotionEnvelope.of('  Tsunami  ');
      expect(e.usedFallback, isTrue);
      expect(e.moodUsed, 'calm');
      for (final u in [0.0, 0.2, 0.5, 0.77, 0.99]) {
        expect(e.at(u).motion, calm.at(u).motion);
        expect(e.at(u).vignette, calm.at(u).vignette);
      }
      expect(MotionEnvelope.of('Burst').usedFallback, isFalse,
          reason: '大小写/空格归一后应认得');
    });

    test('cycles 1..4 都保持整周期无缝', () {
      for (var c = 1; c <= 4; c++) {
        final e = MotionEnvelope.of('tension', cycles: c);
        expect(e.at(0).motion, closeTo(e.at(1.0).motion, 1e-9));
        final cfg = of([
          EffectKind.parallax,
          EffectKind.moodScript,
        ],
            mood: MoodScriptParams(mood: 'burst', cycles: c),
            parallax: const ParallaxParams(amplitude: 0.08, periodSec: 2));
        expect(diffBytes(draw(cfg, 0), draw(cfg, cfg.durationSec)), 0,
            reason: 'cycles=$c 首尾不衔接');
      }
    });

    test('moodScript 仅在启用时序列化，JSON 往返保哈希', () {
      final cfg = of([EffectKind.moodScript],
          mood:
              const MoodScriptParams(mood: 'eerie', cycles: 3, strength: 0.4));
      final j = _decodeJson(cfg.toJsonString());
      expect(j['moodScript']['mood'], 'eerie');
      expect(j['moodScript']['cycles'], 3);
      expect(j['moodScript']['strength'], 0.4);
      final back = EffectConfig.fromJson(j);
      expect(back.configHash, cfg.configHash);
      expect(back.warnings, isEmpty);

      final off = _decodeJson(of([EffectKind.parallax]).toJsonString());
      expect(off.containsKey('moodScript'), isFalse,
          reason: '未启用也写进了 JSON，会污染指纹');
    });

    test('warnings：未知 mood 提示，未启用时不打扰', () {
      final w = of([EffectKind.moodScript],
              mood: const MoodScriptParams(mood: 'TSUNAMI'))
          .warnings;
      expect(w, hasLength(1));
      expect(w.single, contains('calm'));
      expect(
          of([EffectKind.moodScript],
                  mood: const MoodScriptParams(mood: 'burst'))
              .warnings,
          isEmpty);
      expect(
          of([EffectKind.parallax], mood: const MoodScriptParams(mood: 'nope'))
              .warnings,
          isEmpty,
          reason: '未启用 moodScript 时不应报警');
    });

    test('台账只在非空时写 warnings 字段', () {
      final dir = Directory.systemTemp.createTempSync('cm_ledger');
      addTearDown(() => dir.deleteSync(recursive: true));
      final led = Ledger(dir.path);
      led.appendJob(
          jobId: 'a', input: 'x.png', configHash: 'h', status: 'success');
      led.appendJob(
          jobId: 'b',
          input: 'x.png',
          configHash: 'h',
          status: 'success',
          warnings: const ['moodScript: 未知 mood "X"，已回落 calm']);
      final lines = File('${dir.path}/ledger.jsonl').readAsLinesSync();
      expect(lines[0].contains('warnings'), isFalse);
      expect(lines[1], contains('"warnings":["moodScript'));

      final reloaded = Ledger(dir.path);
      final rec = reloaded.byId('b')!;
      expect(rec['warnings'], isA<List>());
      expect((rec['warnings'] as List).single, contains('calm'));
    });

    test('未启用与 strength=0 在三个质量档都逐字节不变', () {
      final noMood = EffectKind.values
          .where((k) => k != EffectKind.moodScript)
          .toList(growable: false);
      for (final tier in RenderTier.values) {
        final a = of(noMood, tier: tier);
        final b = of([...noMood, EffectKind.moodScript],
            mood:
                const MoodScriptParams(mood: 'tension', cycles: 2, strength: 0),
            tier: tier);
        for (final t in const [0.0, 0.25, 0.6, 1.1]) {
          expect(diffBytes(draw(a, t), draw(b, t)), 0,
              reason: '${tier.name} 档 t=$t：恒等包络改变了像素');
        }
      }
    });

    test('motion 因子按包络改变视差位移幅度', () {
      // periodSec=1、duration=2 → t 与 t+1 的视差相位完全相同，
      // 两处能量差只能来自包络。verticalRatio=0 关掉纵向项免干扰。
      const big =
          ParallaxParams(amplitude: 0.12, periodSec: 1, verticalRatio: 0);
      final off = of([EffectKind.parallax], parallax: big);
      final tension = of([EffectKind.parallax, EffectKind.moodScript],
          parallax: big, mood: const MoodScriptParams(mood: 'tension'));
      final zero = of([EffectKind.parallax, EffectKind.moodScript],
          parallax: big,
          mood: const MoodScriptParams(mood: 'tension', strength: 0));

      final hi = energy(tension, 0.25); // 包络上升段 0.88
      final lo = energy(tension, 1.25); // 回落段 0.67
      expect(hi, greaterThan(lo * 1.08), reason: '包络未改变位移：$hi vs $lo');
      expect(hi, lessThan(energy(off, 0.25)), reason: 'tension 该段应低于恒等振幅');
      expect(diffBytes(draw(off, 0.25), draw(zero, 0.25)), 0,
          reason: 'strength=0 必须与未启用逐字节一致');

      final burst = of([EffectKind.parallax, EffectKind.moodScript],
          parallax: big, mood: const MoodScriptParams(mood: 'burst'));
      expect(energy(burst, 0.3), greaterThan(energy(off, 0.3) * 1.15),
          reason: 'burst 峰值段应明显放大位移');
    });
  });
}

// ---------- helpers ----------

RgbaImage _gradientImage(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, (x * 3) % 256, (y * 3) % 256, 100);
    }
  }
  return img;
}

RgbaImage _flatWithBlob() {
  final img = RgbaImage(width: 80, height: 80);
  for (var y = 0; y < 80; y++) {
    for (var x = 0; x < 80; x++) {
      img.setPixel(x, y, 235, 240, 245);
    }
  }
  // 中央深色块（前景线索）
  for (var y = 25; y < 55; y++) {
    for (var x = 25; x < 55; x++) {
      img.setPixel(x, y, 30, 28, 36);
    }
  }
  return img;
}

Map<String, dynamic> _decodeJson(String s) {
  final v = jsonDecodePublic(s);
  return (v as Map).cast<String, dynamic>();
}

Matcher throwsConfigException = throwsA(const TypeMatcher<ConfigException>());

/// PNG encode via image package (same path ImageIO uses).
List<int> _pngEncode(RgbaImage img) => pkg.encodePng(_pngToPkg(img)).toList();

pkg.Image _pngToPkg(RgbaImage img) {
  final im = pkg.Image(width: img.width, height: img.height, numChannels: 3);
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final i = (y * img.width + x) * 4;
      im.setPixelRgb(x, y, img.data[i], img.data[i + 1], img.data[i + 2]);
    }
  }
  return im;
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

List<int> _pngChunk(String type, List<int> data) {
  final len = data.length;
  final body = <int>[...type.codeUnits, ...data];
  final crc = _crc32(body);
  return [
    (len >> 24) & 0xff, (len >> 16) & 0xff, (len >> 8) & 0xff, len & 0xff, //
    ...body,
    (crc >> 24) & 0xff, (crc >> 16) & 0xff, (crc >> 8) & 0xff, crc & 0xff,
  ];
}

/// 构造一张声明 w×h 的 PNG：IHDR 合法（CRC 正确），体数据只有 1x1 像素，
/// 或在 IHDR 后直接截断——用于验证解码前的头级像素预算校验。
List<int> _pngWithDeclaredSize(int w, int h, {bool truncate = false}) {
  final ihdr = [
    (w >> 24) & 0xff, (w >> 16) & 0xff, (w >> 8) & 0xff, w & 0xff, //
    (h >> 24) & 0xff, (h >> 16) & 0xff, (h >> 8) & 0xff, h & 0xff,
    8, 6, 0, 0, 0, // bit depth 8 / RGBA / compression / filter / interlace
  ];
  final bytes = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ..._pngChunk('IHDR', ihdr),
  ];
  if (truncate) return bytes;
  final scanline = [0, 255, 128, 64, 255]; // 1x1 RGBA 的 filter 字节 + 像素
  bytes.addAll(_pngChunk('IDAT', ZLibEncoder().convert(scanline)));
  bytes.addAll(_pngChunk('IEND', const []));
  return bytes;
}

/// 构造 VP8X 扩展头的 WebP：仅声明画布尺寸（image 包没有 WebP 编码器，
/// 无法生成可完整解码的样本，但头级校验只需头部成立）。
List<int> _webpWithCanvasSize(int w, int h) {
  final vp8x = <int>[
    0, 0, 0, 0, // flags
    (w - 1) & 0xff, ((w - 1) >> 8) & 0xff, ((w - 1) >> 16) & 0xff, //
    (h - 1) & 0xff, ((h - 1) >> 8) & 0xff, ((h - 1) >> 16) & 0xff,
  ];
  // RIFF 块 = fourcc + 小端长度 + 数据（无 CRC；10 字节长度天然偶对齐）。
  final chunk = <int>[
    ...'VP8X'.codeUnits,
    vp8x.length & 0xff, (vp8x.length >> 8) & 0xff, (vp8x.length >> 16) & 0xff, 0,
    ...vp8x,
  ];
  final riffSize = 4 + chunk.length;
  return [
    ...'RIFF'.codeUnits,
    riffSize & 0xff, (riffSize >> 8) & 0xff, (riffSize >> 16) & 0xff, 0, //
    ...'WEBP'.codeUnits,
    ...chunk,
  ];
}

dynamic jsonDecodePublic(String s) => convert.jsonDecode(s);
// NOTE: 下方不再有代码 —— GIF writer 测试已并入 main() 内的 'StreamingGifBuilder' 组。
