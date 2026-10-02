import 'dart:async';
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

    test('new louder defaults', () {
      // §6.1 新默认：ctor 与 fromJson ?? fallback 必须成对一致（R14）。
      expect(ParallaxParams().amplitude, 0.030);
      expect(BreathingParams().amplitude, 0.012);
      expect(MangaShakeParams().amplitude, 0.018);
      expect(HeartbeatParams().intensity, 0.020);
      expect(SlowPushParams().pushFrac, 0.060);
      expect(AmbientParams().opacity, 0.22);

      // fallback-vs-ctor 守卫：只改 ctor 不改 fromJson fallback 时这里会红。
      expect(ParallaxParams.fromJson(const {}).amplitude,
          ParallaxParams().amplitude);
      expect(BreathingParams.fromJson(const {}).amplitude,
          BreathingParams().amplitude);
      expect(MangaShakeParams.fromJson(const {}).amplitude,
          MangaShakeParams().amplitude);
      expect(
          HeartbeatParams.fromJson(const {}).intensity,
          HeartbeatParams().intensity);
      expect(SlowPushParams.fromJson(const {}).pushFrac,
          SlowPushParams().pushFrac);
      expect(
          AmbientParams.fromJson(const {}).opacity, AmbientParams().opacity);

      // 顶层默认 config 透传新默认。
      final cfg = EffectConfig();
      expect(cfg.parallax.amplitude, ParallaxParams().amplitude);
      expect(cfg.breathing.amplitude, BreathingParams().amplitude);
      expect(cfg.mangaShake.amplitude, MangaShakeParams().amplitude);
      expect(cfg.heartbeat.intensity, HeartbeatParams().intensity);
      expect(cfg.slowPush.pushFrac, SlowPushParams().pushFrac);
      expect(cfg.ambient.opacity, AmbientParams().opacity);
    });

    test('坏 JSON 文件抛 ConfigException', () {
      final f = File('.openclaw/tmp/bad_config.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{ not json');
      expect(() => effectConfigFromFile(f.path), throwsConfigException);
    });

    test('不存在的配置文件抛 ConfigException', () {
      expect(() => effectConfigFromFile('Z:/nope/none.json'),
          throwsConfigException);
    });

    test('effect_config.dart 保持纯 Dart（不 import dart:io，为 Web 铺路）', () {
      final src = File('lib/src/effect_config.dart').readAsStringSync();
      expect(src.contains("import 'dart:io'"), isFalse,
          reason: 'effect_config 是序列化 + configHash 的纯数据层，'
              '文件读取走 config_io.dart 的 IO 边界');
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
      final depth = HeuristicDepthEstimator().estimate(img);
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
      final depth = HeuristicDepthEstimator().estimate(img);
      expect(LayerSplitter(layerCount: 2).split(img, depth).length, 2);
      expect(LayerSplitter(layerCount: 4).split(img, depth).length, 4);
    });
  });

  group('v1.3 层掩码质量：双线性深度、羽化、边缘外扩', () {
    final img = _flatWithBlob();
    final depth = HeuristicDepthEstimator(workScale: 0.5).estimate(img);

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
      final depth = HeuristicDepthEstimator().estimate(img);
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
      final depth = HeuristicDepthEstimator().estimate(img);
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
      final depth = HeuristicDepthEstimator().estimate(img);
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
      final png = _pngEncode(_gradientImage(32, 32));
      File('$workDir/in.png').writeAsBytesSync(png);
      final cfg = EffectConfig(fps: 2, durationSec: 1, maxDimension: 32);
      final r = await MotionPipeline(cfg, parallel: 1)
          .processFile('$workDir/in.png', '$workDir/out');
      final jobName =
          'in_${ImageIO.contentHash8(png)}_${cfg.configHash.substring(0, 8)}';
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
      // 12 帧（v1.4 Task 3.6 起 standard 档探针占 6 帧）：必须留足非探针帧，
      // worker 路径才有真实负载可被「parallel>1」这条断言钉住。
      final cfg = EffectConfig(
        fps: 6,
        durationSec: 2,
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

    test('processBytes 与 processFile 产物逐字节一致（GIF + params.json）', () async {
      final png = _pngEncode(_gradientImage(64, 96));
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final disk = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, '${tmp.path}/out');
      final mem = await MotionPipeline(cfg, parallel: 1)
          .processBytes(input: Uint8List.fromList(png));
      expect(mem.gifBytes, isNotNull);
      expect(mem.gifBytes, equals(File(disk.outputGif).readAsBytesSync()),
          reason: '同输入同配置：内存入口与落盘入口必须产出同一份 GIF 字节');
      expect(mem.paramsJsonBytes,
          equals(File(disk.paramsFile).readAsBytesSync()));
      expect(mem.configHash, disk.configHash);
      expect(mem.width, disk.width);
      expect(mem.height, disk.height);
      expect(mem.layerCount, disk.layerCount);
      expect(mem.frameCount, disk.frameCount);
      expect(mem.warnings, disk.warnings);
      expect(mem.elapsedMs, greaterThan(0));
      // params 可还原回同一 config
      final restored = EffectConfig.fromJson(
          _decodeJson(convert.utf8.decode(mem.paramsJsonBytes)));
      expect(restored.configHash, cfg.configHash);
    });

    test('内容指纹：同 stem 不同内容 → 不同产物目录，configHash 不变', () async {
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final inPath = '${tmp.path}/same_stem.png';
      final outDir = '${tmp.path}/fingerprint';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(64, 64)));
      final r1 = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, outDir);
      // 同名覆盖：内容变化（不同尺寸渐变图 → 字节必不同），目录必须随之改变
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(48, 48)));
      final r2 = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, outDir);
      expect(r2.contentHash, isNot(r1.contentHash),
          reason: '同 stem 不同内容 → contentHash 必不同');
      expect(r1.configHash, r2.configHash,
          reason: '内容指纹与配置正交：configHash 不受输入内容影响');
      final dir1 = r1.outputGif.substring(0, r1.outputGif.lastIndexOf('/'));
      final dir2 = r2.outputGif.substring(0, r2.outputGif.lastIndexOf('/'));
      expect(dir2, isNot(dir1), reason: '产物目录随内容变化，不再命中旧缓存');
      expect(Directory(dir1).existsSync(), isTrue,
          reason: '新内容写新目录，旧产物不被覆盖');
      expect(r1.contentHash, matches(RegExp(r'^[0-9a-f]{8}$')));
    });

    test('内容指纹：同内容同配置 → 同目录（命中语义不变），params 回放不受影响', () async {
      final png = _pngEncode(_gradientImage(56, 56));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 56);
      final inPath = '${tmp.path}/stable.png';
      File(inPath).writeAsBytesSync(png);
      final r1 = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, '${tmp.path}/stable_out');
      final r2 = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, '${tmp.path}/stable_out');
      expect(r1.outputGif, r2.outputGif,
          reason: '同内容同配置 → 同目录，嵌入方「目录存在→跳过」语义不变');
      expect(r1.contentHash, r2.contentHash);
      expect(r1.contentHash, ImageIO.contentHash8(png),
          reason: 'result.contentHash 与独立计算的输入字节指纹一致');
      final mem = await MotionPipeline(cfg, parallel: 1)
          .processBytes(input: Uint8List.fromList(png));
      expect(mem.contentHash, r1.contentHash,
          reason: '同内容的落盘/内存入口指纹一致');
      final restored = EffectConfig.fromJson(
          _decodeJson(File(r1.paramsFile).readAsStringSync()));
      expect(restored.configHash, cfg.configHash,
          reason: 'params.json 回放不受内容指纹影响');
      expect(File(r2.outputGif).readAsBytesSync(),
          equals(File(r1.outputGif).readAsBytesSync()),
          reason: '逐字节复现契约不受命名变更影响');
    });

    test('静帧：t=0 与 GIF 首帧同源、确定性复现、t 参数生效', () async {
      final png = _pngEncode(_gradientImage(64, 64));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final p = MotionPipeline(cfg, parallel: 1);
      final still0 = await p.renderStillFrame(input: Uint8List.fromList(png));
      final still0b = await p.renderStillFrame(input: Uint8List.fromList(png));
      expect(still0, equals(still0b), reason: '同输入同 t 逐字节一致');

      // 静帧尺寸 = 工作栅格尺寸
      final stillImg = pkg.decodePng(still0)!;
      expect(stillImg.width, 64);
      expect(stillImg.height, 64);

      // GIF 首帧平均色与静帧一致（GIF 副本经调色板量化，允许小偏差）
      final mem = await p.processBytes(input: Uint8List.fromList(png));
      final f0 = pkg.GifDecoder(mem.gifBytes!).decodeFrame(0)!;
      int avgR(pkg.Image im) {
        var s = 0, n = 0;
        for (var y = 0; y < im.height; y += 4) {
          for (var x = 0; x < im.width; x += 4) {
            final c = im.getPixel(x, y);
            s += c.r.toInt();
            n++;
          }
        }
        return s ~/ n;
      }

      expect((avgR(f0) - avgR(stillImg)).abs(), lessThanOrEqualTo(3),
          reason: 'GIF 首帧与静帧同源（量化仅引入小偏差）');

      // t 参数生效：末帧时刻的静帧与 t=0 不同
      final stillLast = await p.renderStillFrame(
          input: Uint8List.fromList(png), t: (cfg.frameCount - 1) / cfg.fps);
      expect(stillLast, isNot(still0));
      // 文件入口与字节入口同源
      final inPath = '${tmp.path}/still.png';
      File(inPath).writeAsBytesSync(png);
      expect(await p.renderStillFrameFile(inPath), equals(still0));
    });

    test('includeFirstFrame：复用探针帧，两模式与后台入口一致', () async {
      final png = _pngEncode(_gradientImage(64, 96));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final inPath = '${tmp.path}/cover_in.png';
      File(inPath).writeAsBytesSync(png);

      final disk = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, '${tmp.path}/cover_out',
              includeFirstFrame: true);
      expect(disk.firstFramePng, isNotNull);
      // 与落盘的 frame_0000.png 完全一致（同一帧同一 PNG 编码器）
      expect(disk.firstFramePng,
          equals(File('${disk.frameDir}/frame_0000.png').readAsBytesSync()));

      // 内存模式与落盘模式一致
      final mem = await MotionPipeline(cfg, parallel: 1)
          .processBytes(input: Uint8List.fromList(png), includeFirstFrame: true);
      expect(mem.firstFramePng, equals(disk.firstFramePng));

      // 与 renderStillFrame(t=0) 同帧同字节
      final still = await MotionPipeline(cfg, parallel: 1)
          .renderStillFrame(input: Uint8List.fromList(png));
      expect(disk.firstFramePng, equals(still));

      // 后台入口透传（跨 isolate 后字节一致）
      final bg = await processFileInBackground(inPath, '${tmp.path}/cover_bg',
          config: cfg, parallel: 1, includeFirstFrame: true);
      expect(bg.firstFramePng, equals(disk.firstFramePng));

      // 未请求时为零成本（字段为 null）
      final plain =
          await MotionPipeline(cfg, parallel: 1).processBytes(input: Uint8List.fromList(png));
      expect(plain.firstFramePng, isNull);
    });

    test('静帧受 cancelToken / timeout 管控（E_CANCELLED / E_TIMEOUT）', () async {
      final png = _pngEncode(_gradientImage(32, 32));
      final cancelled = MotionPipeline(
          EffectConfig(fps: 2, durationSec: 1, maxDimension: 32),
          parallel: 1,
          cancelToken: MotionCancelToken()..cancel());
      await expectLater(
          cancelled.renderStillFrame(input: Uint8List.fromList(png)),
          throwsA(isA<MotionCancelledException>()));
      final timedOut = MotionPipeline(
          EffectConfig(fps: 2, durationSec: 1, maxDimension: 32),
          parallel: 1,
          timeout: const Duration(milliseconds: 0));
      await expectLater(
          timedOut.renderStillFrame(input: Uint8List.fromList(png)),
          throwsA(isA<MotionCancelledException>()));
    });

    test('processBytes 并行路径与串行路径字节一致', () async {
      final png = _pngEncode(_gradientImage(96, 64));
      final cfg = EffectConfig(
        fps: 6,
        durationSec: 1,
        maxDimension: 96,
        effects: const [
          EffectKind.parallax,
          EffectKind.breathing,
          EffectKind.ambient,
          EffectKind.rain,
        ],
      );
      final serial = await MotionPipeline(cfg, parallel: 1)
          .processBytes(input: Uint8List.fromList(png));
      final workers = await MotionPipeline(cfg, parallel: 3)
          .processBytes(input: Uint8List.fromList(png));
      expect(workers.gifBytes, equals(serial.gifBytes));
    });

    test('processBytes：outputFormat=frames 时 gifBytes 为 null', () async {
      final png = _pngEncode(_gradientImage(48, 48));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 48,
          outputFormat: OutputFormat.frames);
      final mem = await MotionPipeline(cfg, parallel: 1)
          .processBytes(input: Uint8List.fromList(png));
      expect(mem.gifBytes, isNull,
          reason: '内存模式不落 PNG 帧序列；frames-only 即无 GIF 字节');
      expect(mem.paramsJsonBytes, isNotEmpty);
      expect(mem.frameCount, cfg.frameCount);
    });

    test('processBytes：空输入抛 ImageDecodeException（同一解码路径）', () {
      expect(
        () => MotionPipeline(EffectConfig(fps: 2))
            .processBytes(input: Uint8List(0)),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('派发前取消：零渲染、零文件、进度零回调', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(48, 48)));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 48);
      final token = MotionCancelToken()..cancel();
      final progressEvents = <int>[];
      await expectLater(
        MotionPipeline(cfg,
                parallel: 1,
                cancelToken: token,
                onProgress: (_, __) => progressEvents.add(1))
            .processFile(inPath, '${tmp.path}/out'),
        throwsA(isA<MotionCancelledException>()),
      );
      expect(progressEvents, isEmpty, reason: '派发前取消不得有任何渲染');
      expect(Directory('${tmp.path}/out').existsSync(), isFalse,
          reason: '未进入渲染主干不应创建输出目录');
    });

    test('processBytes 同样响应取消', () async {
      final token = MotionCancelToken()..cancel();
      await expectLater(
        MotionPipeline(EffectConfig(fps: 2), cancelToken: token)
            .processBytes(input: Uint8List.fromList(_pngEncode(_gradientImage(32, 32)))),
        throwsA(isA<MotionCancelledException>()),
      );
    });

    test('中途取消（串行）：半成品默认清理，目录无残留', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(64, 64)));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final token = MotionCancelToken();
      final jobDir = '${tmp.path}/out/in_${ImageIO.contentHash8(_pngEncode(_gradientImage(64, 64)))}_${cfg.configHash.substring(0, 8)}';
      await expectLater(
        MotionPipeline(cfg,
                parallel: 1,
                cancelToken: token,
                onProgress: (done, total) {
                  if (done >= 1) token.cancel(); // 首帧回包后取消
                })
            .processFile(inPath, '${tmp.path}/out'),
        throwsA(isA<MotionCancelledException>()),
      );
      expect(Directory(jobDir).existsSync(), isFalse,
          reason: '默认清理：半成品目录（GIF/params/帧 PNG）应被移除');
    });

    test('中途取消：keepPartial=true 保留已产出帧，GIF 不落盘', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(64, 64)));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final token = MotionCancelToken();
      final jobDir = '${tmp.path}/out/in_${ImageIO.contentHash8(_pngEncode(_gradientImage(64, 64)))}_${cfg.configHash.substring(0, 8)}';
      await expectLater(
        MotionPipeline(cfg,
                parallel: 1,
                keepPartial: true,
                cancelToken: token,
                onProgress: (done, total) {
                  if (done >= 1) token.cancel();
                })
            .processFile(inPath, '${tmp.path}/out'),
        throwsA(isA<MotionCancelledException>()),
      );
      expect(File('$jobDir/frames/frame_0000.png').existsSync(), isTrue,
          reason: 'keepPartial：已写出的探针帧保留');
      expect(File('$jobDir/anim.gif').existsSync(), isFalse,
          reason: 'GIF 未完成，不应存在半截文件');
      expect(File('$jobDir/params.json').existsSync(), isFalse);
    });

    test('中途取消（worker 路径）：异常上抛、worker 池释放、无残留文件', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(64, 64)));
      final cfg = EffectConfig(
          fps: 6, durationSec: 1, maxDimension: 64,
          outputFormat: OutputFormat.gif);
      final token = MotionCancelToken();
      final jobDir = '${tmp.path}/out/in_${ImageIO.contentHash8(_pngEncode(_gradientImage(64, 64)))}_${cfg.configHash.substring(0, 8)}';
      await expectLater(
        MotionPipeline(cfg,
                parallel: 3,
                cancelToken: token,
                onProgress: (done, total) {
                  if (done >= 1) token.cancel();
                })
            .processFile(inPath, '${tmp.path}/out'),
        throwsA(isA<MotionCancelledException>()),
      );
      expect(Directory(jobDir).existsSync(), isFalse,
          reason: 'worker 路径取消后同样清理半成品');
    });

    test('超时走同一取消路径，异常 code 为 E_TIMEOUT', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(512, 512)));
      final cfg = EffectConfig(fps: 24, durationSec: 4, maxDimension: 512);
      final sw = Stopwatch()..start();
      Object? caught;
      try {
        await MotionPipeline(cfg, parallel: 1,
                timeout: const Duration(milliseconds: 100))
            .processFile(inPath, '${tmp.path}/out');
      } catch (e) {
        caught = e;
      }
      sw.stop();
      expect(caught, isA<MotionCancelledException>(),
          reason: '96 帧 512px 渲染远超 100ms，必须超时');
      final e = caught as MotionCancelledException;
      expect(e.code, 'E_TIMEOUT');
      expect(e.message, contains('timed out'));
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)),
          reason: '超时应在渲染主干早期生效，而非等全部帧渲染完');
    });

    test('progress 计数正确：含探针帧，单调递增至 framesTotal', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(64, 64)));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final events = <int>[];
      final r = await MotionPipeline(cfg, parallel: 1,
              onProgress: (done, total) => events.add(done))
          .processFile(inPath, '${tmp.path}/out');
      expect(events, isNotEmpty);
      expect(events.first, 1, reason: '首帧（探针帧 0）回包即计数');
      for (var i = 1; i < events.length; i++) {
        expect(events[i], greaterThanOrEqualTo(events[i - 1]));
      }
      expect(events.last, cfg.frameCount);
      expect(r.frameCount, cfg.frameCount);
    });

    test('取消后同一 pipeline 可再次正常渲染', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(48, 48)));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 48);
      final token = MotionCancelToken()..cancel();
      final pipeline = MotionPipeline(cfg, parallel: 1, cancelToken: token);
      await expectLater(pipeline.processFile(inPath, '${tmp.path}/o1'),
          throwsA(isA<MotionCancelledException>()));
      // 同一 pipeline、新 token：恢复正常
      final fresh = MotionCancelToken();
      final pipeline2 = MotionPipeline(cfg, parallel: 1, cancelToken: fresh);
      final r = await pipeline2.processFile(inPath, '${tmp.path}/o2');
      expect(File(r.outputGif).existsSync(), isTrue);
    });

    test('后台 processFile 产物与同步版逐字节一致，进度回传主 isolate', () async {
      final png = _pngEncode(_gradientImage(64, 96));
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final sync = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, '${tmp.path}/bg_sync');
      final events = <int>[];
      final bg = await processFileInBackground(inPath, '${tmp.path}/bg_async',
          config: cfg,
          parallel: 1,
          onProgress: (done, total) => events.add(done));
      expect(File(bg.outputGif).readAsBytesSync(),
          equals(File(sync.outputGif).readAsBytesSync()),
          reason: '后台入口与同步入口共享同一渲染路径');
      expect(events, isNotEmpty);
      expect(events.last, cfg.frameCount, reason: '进度应跨 isolate 回传');
    });

    test('后台 processBytes 与内存版字节一致', () async {
      final png = Uint8List.fromList(_pngEncode(_gradientImage(64, 96)));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final sync = await MotionPipeline(cfg, parallel: 1)
          .processBytes(input: png);
      final bg = await processBytesInBackground(input: png, config: cfg, parallel: 1);
      expect(bg.gifBytes, equals(sync.gifBytes));
      expect(bg.configHash, sync.configHash);
    });

    test('后台中途取消：E_CANCELLED 上抛到调用方', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(64, 64)));
      // 18 帧（v1.4 Task 3.6 起 standard 档 6 探针会一口气渲染掉小场景的
      // 全部帧）：留足探针之后的帧，首个进度回传后取消才能落在渲染中途，
      // 而不是任务已完成。
      final cfg = EffectConfig(fps: 6, durationSec: 3, maxDimension: 64);
      final token = MotionCancelToken();
      final jobDir = '${tmp.path}/bg_cancel/in_${ImageIO.contentHash8(_pngEncode(_gradientImage(64, 64)))}_${cfg.configHash.substring(0, 8)}';
      await expectLater(
        processFileInBackground(inPath, '${tmp.path}/bg_cancel',
            config: cfg,
            parallel: 2,
            cancelToken: token,
            onProgress: (done, total) {
              if (done >= 1) token.cancel(); // 主 isolate 收到进度后取消
            }),
        throwsA(isA<MotionCancelledException>()),
      );
      expect(Directory(jobDir).existsSync(), isFalse,
          reason: '后台取消同样默认清理半成品');
    });

    test('后台异常原样重抛：错误码与类型不丢', () async {
      await expectLater(
        processBytesInBackground(
            input: Uint8List.fromList(<int>[]), // 空输入 → E_DECODE_EMPTY
            config: EffectConfig(fps: 2)),
        throwsA(isA<ImageDecodeException>()),
      );
      try {
        await processBytesInBackground(
            input: Uint8List.fromList(<int>[]),
            config: EffectConfig(fps: 2));
      } on ImageDecodeException catch (e) {
        expect(e.code, 'E_DECODE_EMPTY');
      }
    });

    test('后台入口：启动前已取消的令牌立即生效', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(32, 32)));
      final token = MotionCancelToken()..cancel();
      await expectLater(
        processFileInBackground(inPath, '${tmp.path}/bg_precancel',
            config: EffectConfig(fps: 2, maxDimension: 32), cancelToken: token),
        throwsA(isA<MotionCancelledException>()),
      );
    });

    test('MotionPipelineGuard：并发 acquire 排队，release 后放行', () async {
      MotionPipelineGuard.configure(maxConcurrent: 1);
      final order = <String>[];
      final firstInside = Completer<void>();
      final f1 = MotionPipelineGuard.run(() async {
        order.add('a-in');
        firstInside.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('a-out');
      });
      final f2 = MotionPipelineGuard.run(() async {
        order.add('b-in');
      });
      await firstInside.future;
      expect(MotionPipelineGuard.activeCount, 1);
      expect(MotionPipelineGuard.queueLength, 1, reason: '第二个任务应排队等待');
      await f1;
      await f2;
      expect(order, ['a-in', 'a-out', 'b-in'],
          reason: 'maxConcurrent=1 时严格串行');
    });

    test('MotionPipelineGuard：maxConcurrent=2 允许两个任务并行', () async {
      MotionPipelineGuard.configure(maxConcurrent: 2);
      final bothInside = Completer<void>();
      var inside = 0;
      await Future.wait([
        MotionPipelineGuard.run(() async {
          inside++;
          if (inside == 2) bothInside.complete();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }),
        MotionPipelineGuard.run(() async {
          inside++;
          if (inside == 2) bothInside.complete();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }),
      ]);
      expect(bothInside.isCompleted, isTrue, reason: '两个任务应同时持槽');
      MotionPipelineGuard.configure(maxConcurrent: 1); // 还原默认
    });

    test('MotionPipelineGuard：body 抛取消异常也释放槽位', () async {
      MotionPipelineGuard.configure(maxConcurrent: 1);
      await expectLater(
        MotionPipelineGuard.run(() async {
          throw MotionCancelledException('cancelled by caller');
        }),
        throwsA(isA<MotionCancelledException>()),
      );
      expect(MotionPipelineGuard.activeCount, 0, reason: '取消路径必须释放槽位');
      // 释放后新任务立即可进
      var ran = false;
      await MotionPipelineGuard.run(() async => ran = true);
      expect(ran, isTrue);
    });

    test('MotionPipelineGuard：无 acquire 时 release 抛 StateError', () {
      expect(() => MotionPipelineGuard.release(), throwsStateError);
    });

    test('顶层便捷参数与既有字段等价：同序列化同 configHash', () {
      // 等价性矩阵：顶层便捷参数 ↔ 既有嵌套字段，逐字节一致
      final pairs = <EffectConfig, EffectConfig>{
        EffectConfig(dither: true):
            EffectConfig(quality: QualityParams(dither: true)),
        EffectConfig(dither: true, qualityTier: RenderTier.standard):
            EffectConfig(
                quality: QualityParams(
                    dither: true, tier: RenderTier.standard)),
        EffectConfig(amplitude: 0.03):
            EffectConfig(parallax: ParallaxParams(amplitude: 0.03)),
        EffectConfig(directionDeg: 45):
            EffectConfig(parallax: ParallaxParams(directionDeg: 45)),
        EffectConfig(amplitude: 0.02, directionDeg: 30):
            EffectConfig(
                parallax:
                    ParallaxParams(amplitude: 0.02, directionDeg: 30.0)),
        // 一处设齐（fps/duration/maxDimension/dither/tier/amplitude/direction）
        EffectConfig(
          fps: 12,
          durationSec: 2.5,
          maxDimension: 800,
          dither: true,
          qualityTier: RenderTier.standard,
          amplitude: 0.02,
          directionDeg: 45,
        ): EffectConfig(
            fps: 12,
            durationSec: 2.5,
            maxDimension: 800,
            quality: QualityParams(dither: true, tier: RenderTier.standard),
            parallax: ParallaxParams(amplitude: 0.02, directionDeg: 45.0)),
      };
      pairs.forEach((flat, nested) {
        expect(flat.toJson(), nested.toJson(),
            reason: '顶层便捷参数必须与既有字段序列化逐字节一致');
        expect(flat.configHash, nested.configHash, reason: 'hash 必须一致');
      });
    });

    test('默认路径：新默认整段省略 quality，便捷参数与嵌套参数仍等价（R32/R26）', () {
      final base = EffectConfig();
      // null 便捷参数与全默认同路径
      expect(EffectConfig(dither: null, amplitude: null).configHash,
          base.configHash);
      // R32：哨兵与构造默认同源 ⇒ 默认档（standard/sierra/true）命中省略，
      // 默认 JSON 不再带 quality 键。
      expect(base.toJson().containsKey('quality'), isFalse,
          reason: '默认配置必须整段省略 quality（R32）');
      // 便捷参数与显式嵌套参数序列化一致（相对契约，不落在绝对指纹上）
      final explicit = EffectConfig()
        ..quality = const QualityParams(dither: false);
      expect(EffectConfig(dither: false).toJson(), explicit.toJson());
      expect(EffectConfig(dither: false).configHash, explicit.configHash);
      // 往返稳定：哈希即身份
      expect(EffectConfig.fromJson(base.toJson()).configHash, base.configHash);
      // 显式旧默认组合（legacy/floyd/false）现在**写出整段**（R32 的反向半）：
      // 回滚意图必须可持久化，不能靠省略键表达。
      final legacySentinel = EffectConfig()
        ..quality = const QualityParams(
            dither: false, ditherMode: 'floyd', tier: RenderTier.legacy);
      expect(
          legacySentinel.toJson()['quality'],
          {'dither': false, 'ditherMode': 'floyd', 'tier': 'legacy'});
      expect(
          EffectConfig.fromJson(legacySentinel.toJson()).configHash,
          legacySentinel.configHash,
          reason: '回滚配置往返必须保哈希（否则「省略=默认」的旧歧义回来了）');
      // 非默认便捷参数（显式降到 legacy 档）才写 quality 段
      expect(EffectConfig(qualityTier: RenderTier.legacy).toJson()['quality'],
          isNotNull);
      // 等于默认的非 null 便捷参数（dither:true）与不传等价 ⇒ 仍整段省略
      expect(EffectConfig(dither: true).toJson().containsKey('quality'), isFalse);
    });

    test('顶层便捷参数不绕过 fail-fast；建议范围越界不抛', () {
      // 结构性参数照旧 fail-fast
      expect(() => EffectConfig(dither: true, fps: 0), throwsConfigException);
      expect(() => EffectConfig(amplitude: 1, layerCount: 9),
          throwsConfigException);
      // amplitude/directionDeg 是建议范围：越界映射但不抛（既有 clamp 语义）
      final wide = EffectConfig(amplitude: 99);
      expect(wide.parallax.amplitude, 99);
      expect(EffectConfig.fromJson(wide.toJson()).configHash,
          wide.configHash);
    });

    test('效果选择 API：增删改查任意组合，原 config 不被修改', () {
      final base = EffectConfig(); // [parallax, breathing, ambient]
      final baseHash = base.configHash;
      final baseEffects = List<EffectKind>.from(base.effects);

      // withEffect：追加、不重复
      final withRain = base.withEffect(EffectKind.rain);
      expect(withRain.effects, contains(EffectKind.rain));
      expect(withRain.effects.length, baseEffects.length + 1);
      expect(withRain.withEffect(EffectKind.rain).effects.length,
          baseEffects.length + 1, reason: '重复启用不重复追加');
      expect(withRain.configHash, isNot(baseHash));

      // withoutEffect：移除
      final noParallax = base.withoutEffect(EffectKind.parallax);
      expect(noParallax.effects, isNot(contains(EffectKind.parallax)));
      expect(noParallax.effects.length, baseEffects.length - 1);
      // 移除未启用的效果 = 等价新实例
      expect(base.withoutEffect(EffectKind.rain).configHash, baseHash);

      // withEffects：全量替换
      final replaced = base.withEffects([EffectKind.rain, EffectKind.snow]);
      expect(replaced.effects, [EffectKind.rain, EffectKind.snow]);

      // clearEffects：全关 = 静帧
      final still = base.clearEffects();
      expect(still.effects, isEmpty);

      // 链式：一处设齐 + 选效果（任务书示例）
      final chained = EffectConfig(
        fps: 12,
        durationSec: 2.5,
        maxDimension: 800,
        dither: true,
        effects: [EffectKind.rain],
      ).withoutEffect(EffectKind.fog);
      expect(chained.fps, 12);
      expect(chained.quality.dither, isTrue);
      expect(chained.effects, [EffectKind.rain]);

      // 不可变语义：原 config 全程未被修改
      expect(base.effects, baseEffects);
      expect(base.configHash, baseHash);

      // 效果组合与直接构造等价
      final built = EffectConfig(
          effects: [EffectKind.parallax, EffectKind.breathing,
              EffectKind.ambient, EffectKind.rain]);
      expect(withRain.configHash, built.configHash);
      expect(withRain.toJson(), built.toJson());
    });

    test('estimateCost：1080p 典型场景覆盖 bench 实测区间', () {
      // 被测契约：估算**区间必须罩住实测**，且模型必须区分档位
      // （v1.4 Task 3.6/R27 把默认档翻到 standard ⇒ 旧区间的 legacy 锚点失效）。
      final cfg = EffectConfig(fps: 24, durationSec: 4, maxDimension: 1600);
      final est = estimateCost(cfg, sourceWidth: 1920, sourceHeight: 1080);
      expect(est.workingWidth, 1600, reason: '最长边降到 maxDimension');
      expect(est.workingHeight, 900);
      expect(est.frameCount, 96);
      // v1.4 Task 3.6 重锚定的实测来源（本机 18 核、parallel=8、jit 预热后二跑）：
      //  A. tool/bench.dart（sample_images/01_portrait.png 900×1300，写
      //     build/bench/bench_report.json）：
      //      draft_480p legacy 227ms / 453.0MB；typical_1080p legacy 2228ms /
      //      572.0MB；standard_1080p 4212ms / 675.6MB；preview_1600 legacy
      //      4451ms / 675.6MB；parallel=1 扫档 standard_1080p 18527ms。
      //     ⇒ spec §7 P3「typical_1080p ≤ 5s」在新默认（standard）下实测 4.21s
      //     仍然成立（六探针已计入这次实测）。
      //  B. 本用例场景的专用锚定跑（把同一张样图烘成 1920×1080 ⇒ 工作栅格恰为
      //     1600×900，与 estimateCost 的模型一致）：standard（新默认，6 探针）
      //     **7041ms**，显式 legacy 同工作量 **4249ms**。
      // 内存：模型档位无关（每 worker 一整套层栅格），锚点取 A 的两端实测。
      expect(est.minPeakMemoryMb <= 572, isTrue,
          reason: '下界不得高过 1080p 实测 RSS（572MB）');
      expect(est.maxPeakMemoryMb >= 675, isTrue,
          reason: '上界必须覆盖 1600 档实测 RSS（675.6MB）');
      // 耗时（standard 臂）：实测 7041ms 必须落在区间内。
      expect(est.minDurationMs <= 7041, isTrue,
          reason: '下界（桌面多核理想）不得高过 standard 实测 7041ms');
      expect(est.maxDurationMs >= 7041, isTrue,
          reason: '上界（低端单核近似）必须罩住 standard 实测 7041ms');
      // 档位区分：同一工作量的显式 legacy 区间必须整体低于 standard，
      // 否则模型根本没在区分两档（翻默认 = 白翻）。
      final legacyEst = estimateCost(
          EffectConfig(
              fps: 24,
              durationSec: 4,
              maxDimension: 1600,
              quality: const QualityParams(tier: RenderTier.legacy)),
          sourceWidth: 1920,
          sourceHeight: 1080);
      expect(legacyEst.minDurationMs, lessThan(est.minDurationMs),
          reason: 'standard 下界必须高于 legacy（AA 光栅 + 面积平均更贵）');
      expect(legacyEst.maxDurationMs, lessThan(est.maxDurationMs),
          reason: 'standard 上界必须高于 legacy');
      // 比值锚定 ns/帧像素：standard 22 vs legacy 12 ⇒ 1.83×，
      // 低于 1.5× 说明档位系数被抹平（真门，非放宽）。
      expect(est.minDurationMs / legacyEst.minDurationMs,
          greaterThanOrEqualTo(1.5),
          reason: 'standard 下界应显著高于 legacy 下界');
      // legacy 臂自己的实测（B：4249ms）也必须落在 legacy 区间内。
      expect(legacyEst.minDurationMs <= 4249, isTrue);
      expect(legacyEst.maxDurationMs >= 4249, isTrue);
      expect(est.note, contains('empirical'));
      expect(est.toJson()['maxPeakMemoryMb'], isNotNull);
    });

    test('estimateCost：无源尺寸保守正方形；reducedMotion 单帧更快', () {
      final cfg = EffectConfig(fps: 12, durationSec: 2, maxDimension: 800);
      final est = estimateCost(cfg);
      expect(est.workingWidth, 800);
      expect(est.workingHeight, 800);
      final still = estimateCost(EffectConfig(
          fps: 12, durationSec: 2, maxDimension: 800, reducedMotion: true));
      expect(still.frameCount, 1);
      expect(still.maxDurationMs, lessThan(est.maxDurationMs));
      // 小源图不放大
      final small = estimateCost(cfg, sourceWidth: 320, sourceHeight: 240);
      expect(small.workingWidth, 320);
      expect(small.workingHeight, 240);
    });

    test('参数目录：完整、去重、默认值与真实配置一致', () {
      final names = kRenderParamSpecs.map((s) => s.name).toList();
      expect(names.length, kRenderParamSpecs.length, reason: '名称去重');
      expect(
          names,
          containsAll([
            'fps', 'durationSec', 'maxDimension', 'layerCount', 'maxFrames',
            'seed', 'dither', 'qualityTier', 'outputFormat', 'amplitude',
            'directionDeg', 'effects',
          ]));
      final base = EffectConfig();
      Object? specOf(String n) =>
          kRenderParamSpecs.firstWhere((s) => s.name == n).defaultValue;
      expect(specOf('fps'), base.fps);
      expect(specOf('durationSec'), base.durationSec);
      expect(specOf('maxDimension'), base.maxDimension);
      expect(specOf('layerCount'), base.layerCount);
      expect(specOf('maxFrames'), base.maxFrames);
      expect(specOf('seed'), base.seed);
      expect(specOf('dither'), base.quality.dither);
      expect(specOf('qualityTier'), base.quality.tier);
      expect(specOf('outputFormat'), base.outputFormat);
      expect(specOf('amplitude'), base.parallax.amplitude);
      expect(specOf('directionDeg'), base.parallax.directionDeg);
      expect(specOf('effects'), base.effects.map((e) => e.name).toList());
      // 便捷参数标注映射目标
      final dither =
          kRenderParamSpecs.firstWhere((s) => s.name == 'dither');
      expect(dither.mapsTo, 'quality.dither');
      // strictRange 参数与构造器 fail-fast 一致
      expect(kRenderParamSpecs.firstWhere((s) => s.name == 'fps').strictRange,
          isTrue);
      // 效果目录 32 种且与枚举一致
      expect(kEffectNames.length, EffectKind.values.length);
      expect(kEffectNames, EffectKind.values.map((e) => e.name).toList());
    });

    test('StripSplitter 切片边界：整除 / 非整除大尾片 / 小尾片并入', () {
      const splitter = StripSplitter(); // 9:16
      // 宽 90 → 整片高 = 90*16/9 = 160
      // 整除：480 = 3×160
      final exact = splitter.plan(90, 480);
      expect(exact.map((s) => [s.yStart, s.yEnd]), [
        [0, 160],
        [160, 320],
        [320, 480],
      ]);
      // 非整除小尾片：500 → 余 20 < 160/3，并入前一片
      final merged = splitter.plan(90, 500);
      expect(merged.map((s) => [s.yStart, s.yEnd]), [
        [0, 160],
        [160, 320],
        [320, 500],
      ]);
      // 非整除大尾片：560 → 余 80 ≥ 160/3，独立成片
      final kept = splitter.plan(90, 560);
      expect(kept.map((s) => [s.yStart, s.yEnd]), [
        [0, 160],
        [160, 320],
        [320, 480],
        [480, 560],
      ]);
      // 重叠：相邻片共享区域恰好 = overlapPx
      final overlapped = const StripSplitter(overlapPx: 20).plan(90, 480);
      expect(overlapped.length, 3);
      for (var i = 1; i < overlapped.length; i++) {
        expect(overlapped[i - 1].yEnd - overlapped[i].yStart, 20);
      }
      expect(overlapped.first.yStart, 0);
      expect(overlapped.last.yEnd, 480);
      expect(overlapped.map((s) => s.height).every((h) => h > 0), isTrue);
    });

    test('processStrip：逐片独立渲染、命名与 hash 独立、安全集无告警', () async {
      final inPath = '${tmp.path}/strip.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(64, 960)));
      final cfg = EffectConfig(
          fps: 2, durationSec: 1, maxDimension: 64,
          effects: [EffectKind.rain, EffectKind.vignette]);
      final r = await processStrip(inPath, '${tmp.path}/strip_out',
          config: cfg, parallel: 1);
      expect(r.slices, isNotEmpty);
      expect(r.warnings, isEmpty, reason: '安全集内效果不应有实验性告警');
      final stem = 'strip';
      for (final s in r.slices) {
        final dir =
            '${tmp.path}/strip_out/${stem}_slice${s.slice.index.toString().padLeft(3, '0')}_${s.result.contentHash}_${cfg.configHash.substring(0, 8)}';
        expect(Directory(dir).existsSync(), isTrue,
            reason: '每片独立目录 <stem>_slice<NNN>_<contentHash8>_<configHash8>');
        expect(s.result.contentHash, matches(RegExp(r'^[0-9a-f]{8}$')),
            reason: '片级 contentHash 为 8 位十六进制');
        expect(File(s.result.outputGif).existsSync(), isTrue);
        final params =
            EffectConfig.fromJson(_decodeJson(File(s.result.paramsFile).readAsStringSync()));
        expect(params.configHash, cfg.configHash,
            reason: '片级 configHash 独立成立（同配置同 hash）');
        expect(s.slice.yStart, lessThan(s.slice.yEnd));
      }
      // 片序覆盖：相邻片窗口衔接连续
      for (var i = 1; i < r.slices.length; i++) {
        expect(r.slices[i].slice.yStart, r.slices[i - 1].slice.yEnd,
            reason: '无重叠时切片窗口应无缝衔接');
      }
      // GIF 确定性：同输入重跑逐字节一致
      final again = await processStrip(inPath, '${tmp.path}/strip_out2',
          config: cfg, parallel: 1);
      for (var i = 0; i < r.slices.length; i++) {
        expect(
            File(again.slices[i].result.outputGif).readAsBytesSync(),
            equals(File(r.slices[i].result.outputGif).readAsBytesSync()),
            reason: 'strip 第 $i 片重跑必须逐字节一致');
      }
    });

    test('processStrip：白名单外效果允许使用但告警实验性', () async {
      final inPath = '${tmp.path}/strip.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(32, 200)));
      final cfg = EffectConfig(
          fps: 2, durationSec: 1, maxDimension: 32,
          effects: [EffectKind.parallax, EffectKind.rain]);
      final r = await processStrip(inPath, '${tmp.path}/strip_warn',
          config: cfg, parallel: 1);
      expect(r.warnings, isNotEmpty);
      expect(r.warnings.join(), contains('experimental'));
      expect(r.warnings.join(), contains('parallax'));
      expect(r.slices, isNotEmpty);
      expect(r.slices.first.result.outputGif, isNotEmpty);
    });

    test('Animated WebP：解码成功且取首帧（image 包行为契约，升级时预警）', () {
      // 实测（image 4.10.1）：animated WebP 不报错——解码动画并取首帧像素，
      // 其余帧被丢弃。此测试锁住该行为；若 image 包升级后行为变化，此处
      // 首先暴露（README 输入格式矩阵据此声明）。
      final eng = ImageIO.decode(_animatedWebpBytes(32, 32));
      expect(eng.width, 32);
      expect(eng.height, 32);
      expect(eng.data[0], 255, reason: '首帧为纯红');
      expect(eng.data[1], 0);
      expect(eng.data[2], 0);
    });

    test('Animated GIF：同样解码成功且取首帧（实测 image 4.10.1）', () {
      final red = pkg.Image(width: 16, height: 16);
      pkg.fillRect(red, x1: 0, y1: 0, x2: 15, y2: 15,
          color: pkg.ColorRgba8(255, 0, 0, 255));
      final blue = pkg.Image(width: 16, height: 16);
      pkg.fillRect(blue, x1: 0, y1: 0, x2: 15, y2: 15,
          color: pkg.ColorRgba8(0, 0, 255, 255));
      final anim = pkg.Image(width: 16, height: 16)
        ..addFrame(red)
        ..addFrame(blue);
      final eng = ImageIO.decode(pkg.encodeGif(anim).toList());
      expect(eng.width, 16);
      expect(eng.height, 16);
    });

    test('AVIF/HEIF 容器被拒：E_DECODE_CORRUPT（不支持，提示转码）', () {
      // ftyp 盒的 ISOM 容器头（HEIF/AVIF 同族），无 JPEG/PNG/WebP 签名
      final fake = <int>[
        0, 0, 0, 0x18, ...'ftypavif'.codeUnits, 0, 0, 0, 0,
        ...'mif1avif'.codeUnits, 0, 0, 0, 8, ...'meta'.codeUnits,
      ];
      try {
        ImageIO.decode(fake);
        fail('should have thrown');
      } on ImageDecodeException catch (e) {
        expect(e.code, 'E_DECODE_CORRUPT');
      }
    });

    test('E_TOO_LARGE：条漫形态的报错提示使用 strip 模式', () {
      final tall = _gradientImage(100, 10000); // h > 2w
      expect(
        () => ImageIO.decode(_pngEncode(tall), maxPixels: 500000),
        throwsA(
          predicate((e) =>
              e is ImageTooLargeException &&
              e.code == 'E_TOO_LARGE' &&
              e.toString().contains('processStrip')),
        ),
      );
      // 非条漫形态不带该提示
      final square = _gradientImage(1000, 1000);
      try {
        ImageIO.decode(_pngEncode(square), maxPixels: 500000);
        fail('should have thrown');
      } on ImageTooLargeException catch (e) {
        expect(e.toString().contains('processStrip'), isFalse);
      }
    });

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

    test('台账可关闭：null ledger 批处理照常工作且不落盘', () async {
      final inDir = Directory('${tmp.path}/imgs_nl')..createSync();
      File('${inDir.path}/a.png')
          .writeAsBytesSync(_pngEncode(_gradientImage(32, 32)));
      final results = await BatchRunner(null).runFolder(
          inputDir: inDir.path,
          outputDir: '${tmp.path}/out_nl',
          config: EffectConfig(fps: 2, durationSec: 1, maxDimension: 32));
      expect(results.single.ok, isTrue);
      final anyLedger = Directory('${tmp.path}')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.contains('ledger'))
          .isEmpty;
      expect(anyLedger, isTrue, reason: '嵌入场景不应产生无限增长的台账文件');
    });

    test('台账按 maxBytes 轮转：旧档改名 .1，查询覆盖当前档', () {
      final ledger = Ledger('${tmp.path}/ledger_rot', maxBytes: 400);
      for (var i = 0; i < 6; i++) {
        ledger.appendJob(
            jobId: 'j$i',
            input: 'in_$i.png',
            configHash: 'hash-$i',
            status: 'success',
            error: 'padding padding padding padding padding');
      }
      expect(File('${tmp.path}/ledger_rot/ledger.jsonl.1').existsSync(),
          isTrue, reason: '超过 maxBytes 应轮转出归档');
      expect(ledger.query(jobId: 'j0'), isEmpty,
          reason: '轮转后查询只覆盖当前档');
      expect(ledger.query(jobId: 'j5').length, 1);
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

  group('MotionCacheManager 缓存管理', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cm_cache_test');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    /// 造一个（可能合法的）缓存条目目录：files 为 相对名 → 字节数。
    void touchDir(String path, Map<String, int> files) {
      Directory(path).createSync(recursive: true);
      files.forEach((name, size) {
        File('$path/$name').writeAsBytesSync(List.filled(size, 0xAB));
      });
    }

    test('解析：两种契约形态识别，非法条目一律跳过', () {
      final root = '${tmp.path}/cache';
      touchDir('$root/page01_abcd1234_11223344',
          {'anim.gif': 100, 'params.json': 10});
      touchDir('$root/long_stem_slice000_deadbeef_55667788', {'anim.gif': 200});
      touchDir('$root/page02_11223344_abcd1234', {'anim.gif': 40});
      touchDir('$root/page03_abcd1234_-606ca22', {'anim.gif': 5});
      File('$root/stray.txt').writeAsStringSync('keep me');
      touchDir('$root/unknown_dir', {'x.bin': 999});
      touchDir('$root/tooshort_12345678', {'f': 1}); // 只有 cf8 一段
      touchDir('$root/badch_zzzzzzzz_11223344', {'f': 1}); // ch8 非 hex

      final mgr = MotionCacheManager(root);
      final entries = mgr.listEntries();
      expect(entries.length, 4, reason: '仅契约条目被识别');

      final single = entries.singleWhere((e) => e.stem == 'page01');
      expect(single.contentHash, 'abcd1234');
      expect(single.configHash, '11223344');
      expect(single.sliceIndex, isNull);
      expect(single.byteSize, 110);
      expect(single.isSlice, isFalse);
      expect(File(single.directory).parent.path.endsWith('cache'), isTrue);

      // 负值 configHash 的字面形态（- + 7 hex）按原样识别
      final neg = entries.singleWhere((e) => e.stem == 'page03');
      expect(neg.configHash, '-606ca22');

      final slice = entries.singleWhere((e) => e.sliceIndex != null);
      expect(slice.stem, 'long_stem', reason: 'stem 含下划线时正确回溯');
      expect(slice.sliceIndex, 0);
      expect(slice.contentHash, 'deadbeef');
      expect(slice.configHash, '55667788');
      expect(slice.byteSize, 200);

      expect(mgr.entryCount(), 4);
      expect(mgr.totalSize(), 110 + 200 + 40 + 5);
      // 非契约文件与目录原样保留
      expect(File('$root/stray.txt').existsSync(), isTrue);
      expect(Directory('$root/unknown_dir').existsSync(), isTrue);
      expect(Directory('$root/tooshort_12345678').existsSync(), isTrue);
      expect(Directory('$root/badch_zzzzzzzz_11223344').existsSync(), isTrue);
    });

    test('purgeLRU：olderThan / maxEntries / maxBytes 边界', () {
      final root = '${tmp.path}/lru';
      String entry(String stem, String ch, int bytes) {
        final dir = '$root/${stem}_${ch}_11223344';
        touchDir(dir, {'anim.gif': bytes});
        final f = File('$dir/anim.gif');
        final ages = {'e1': 10, 'e2': 5, 'e3': 1};
        final ageHours = ages[stem]!;
        f.setLastModifiedSync(
            DateTime.now().subtract(Duration(hours: ageHours)));
        return dir;
      }

      entry('e1', 'aaaaaaaa', 100); // 最旧
      entry('e2', 'bbbbbbbb', 200);
      entry('e3', 'cccccccc', 300); // 最新

      // olderThan：只删 5 小时前的 e1
      final r1 = MotionCacheManager(root)
          .purgeLRU(olderThan: const Duration(hours: 6));
      expect(r1.count, 1);
      expect(r1.purged.single.stem, 'e1');
      expect(r1.freedBytes, 100);
      expect(Directory('$root/e1_aaaaaaaa_11223344').existsSync(), isFalse);

      // maxEntries：保留最新 2 条，再删最旧的 e2
      entry('e1', 'aaaaaaaa', 100); // 重建
      final r2 = MotionCacheManager(root).purgeLRU(maxEntries: 2);
      expect(r2.count, 1);
      expect(r2.purged.single.stem, 'e1', reason: '按新到旧保留 2 条，最旧者淘汰');
      expect(Directory('$root/e2_bbbbbbbb_11223344').existsSync(), isTrue);

      // maxBytes：500 字节预算恰好保留 e3(300)+e2(200)，删 e1(100)
      entry('e1', 'aaaaaaaa', 100);
      final r3 = MotionCacheManager(root).purgeLRU(maxBytes: 500);
      expect(r3.count, 1);
      expect(r3.purged.single.stem, 'e1');
      expect(r3.freedBytes, 100);
      expect(MotionCacheManager(root).totalSize(), 500);

      // 三条件组合：全部清空（olderThan 覆盖所有 + maxEntries=0）
      final r4 = MotionCacheManager(root)
          .purgeLRU(maxEntries: 0, olderThan: const Duration(seconds: 1));
      expect(r4.count, 2);
      expect(MotionCacheManager(root).entryCount(), 0);
    });

    test('purgePrefix / purgeAll：片级条目同 stem 清理，非法条目保留', () {
      final root = '${tmp.path}/purge';
      touchDir('$root/chap01_aaaaaaaa_11223344', {'anim.gif': 10});
      touchDir('$root/chap01_slice000_bbbbbbbb_11223344', {'anim.gif': 20});
      touchDir('$root/chap01_slice001_bbbbbbbb_11223344', {'anim.gif': 30});
      touchDir('$root/chap02_cccccccc_11223344', {'anim.gif': 40});
      touchDir('$root/keepme_dir', {'f': 1});
      File('$root/keepme.txt').writeAsStringSync('x');

      final mgr = MotionCacheManager(root);
      final r = mgr.purgePrefix('chap01');
      expect(r.count, 3, reason: '同 stem 的单图与全部片级条目一并清理');
      expect(r.freedBytes, 60);
      expect(Directory('$root/chap02_cccccccc_11223344').existsSync(), isTrue);
      expect(Directory('$root/keepme_dir').existsSync(), isTrue);
      expect(File('$root/keepme.txt').existsSync(), isTrue);

      final rAll = mgr.purgeAll();
      expect(rAll.count, 1);
      expect(rAll.purged.single.stem, 'chap02');
      expect(MotionCacheManager(root).entryCount(), 0);
      expect(Directory('$root/keepme_dir').existsSync(), isTrue,
          reason: 'purgeAll 绝不触碰非契约条目');
    });

    test('与管线集成：同内容单条目，内容变化后新旧条目并存可清', () async {
      final root = '${tmp.path}/cache_e2e';
      final inPath = '${tmp.path}/in.png';
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(64, 64)));
      final r1 = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, root);
      var entries = MotionCacheManager(root).listEntries();
      expect(entries.length, 1);
      expect(entries.single.stem, 'in');
      expect(entries.single.contentHash, r1.contentHash);
      expect(entries.single.configHash, cfg.configHash.substring(0, 8));

      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(48, 48)));
      final r2 = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, root);
      entries = MotionCacheManager(root).listEntries();
      expect(entries.length, 2, reason: '同 stem 不同内容 → 两个条目并存');
      final report = MotionCacheManager(root).purgePrefix('in');
      expect(report.count, 2);
      expect(report.freedBytes,
          entries.fold<int>(0, (s, e) => s + e.byteSize));
      expect(MotionCacheManager(root).entryCount(), 0);
      expect(r1.contentHash, isNot(r2.contentHash));
    });
  });

  group('帧流回调 onFrame', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cm_frame_test');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('回调计数 = 帧数、严格按帧号有序、探针帧计入，PNG 与落盘帧同字节',
        () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(64, 96)));
      final cfg = EffectConfig(
          fps: 4, durationSec: 1, maxDimension: 64,
          quality: QualityParams(tier: RenderTier.standard));
      final indices = <int>[];
      final pngs = <int, Uint8List>{};
      final progress = <int>[];
      final r = await MotionPipeline(cfg, parallel: 3, onFrame: (i, png) {
        indices.add(i);
        pngs[i] = png;
      }, onProgress: (done, total) => progress.add(done))
          .processFile(inPath, '${tmp.path}/of_out');
      expect(indices, [for (var i = 0; i < cfg.frameCount; i++) i],
          reason: '一帧恰好一次、严格升序（v1.4 六探针帧也在其中）');
      for (final i in indices) {
        expect(pngs[i],
            equals(File(ImageIO.pngPathFor(r.frameDir, i)).readAsBytesSync()),
            reason: '回调 PNG 与落盘 frame_NNNN.png 同源同字节');
      }
      // 与 onProgress 并存：进度最终到满帧
      expect(progress.last, cfg.frameCount);
      // PNG 可解码且不超过工作分辨率上限
      final img = pkg.decodePng(pngs[0]!)!;
      expect(img.width, lessThanOrEqualTo(64));
    });

    test('内存模式与落盘模式的帧流字节一致（gif-only 落盘无帧目录）', () async {
      final png = _pngEncode(_gradientImage(48, 48));
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final cfg = EffectConfig(
          fps: 4, durationSec: 1, maxDimension: 48,
          outputFormat: OutputFormat.gif);
      final diskPngs = <int, Uint8List>{};
      await MotionPipeline(cfg, parallel: 1, onFrame: (i, p) => diskPngs[i] = p)
          .processFile(inPath, '${tmp.path}/gif_only');
      expect(diskPngs, isNotEmpty);

      final memPngs = <int, Uint8List>{};
      await MotionPipeline(cfg, parallel: 1, onFrame: (i, p) => memPngs[i] = p)
          .processBytes(input: Uint8List.fromList(png));
      expect(memPngs.keys.toList(), diskPngs.keys.toList());
      for (final i in diskPngs.keys) {
        expect(memPngs[i], equals(diskPngs[i]),
            reason: '帧流回调的 PNG 字节跨模式逐字节一致');
      }
    });

    test('回调内取消：立即停止后续回调，管线抛 E_CANCELLED', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(64, 64)));
      final cfg = EffectConfig(fps: 6, durationSec: 1, maxDimension: 64);
      final token = MotionCancelToken();
      final indices = <int>[];
      await expectLater(
        MotionPipeline(cfg,
                parallel: 1,
                cancelToken: token,
                onFrame: (i, png) {
                  indices.add(i);
                  if (i == 0) token.cancel();
                })
            .processFile(inPath, '${tmp.path}/cancel_out'),
        throwsA(isA<MotionCancelledException>()),
      );
      expect(indices, [0], reason: '取消点之后（含已在途帧）不再触发回调');
    });

    test('后台入口：onFrame 桥接回调用方 isolate，顺序与计数保持', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(64, 96)));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final indices = <int>[];
      await processFileInBackground(inPath, '${tmp.path}/bg_of',
          config: cfg, parallel: 2, onFrame: (i, png) => indices.add(i));
      expect(indices, [for (var i = 0; i < cfg.frameCount; i++) i],
          reason: '后台桥接后回调在调用方 isolate 依帧序触发');
    });
  });

  group('GIF 帧间差分 encoding.diffMode', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cm_diff_test');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    /// GIF89a 规范合成裁判（disposal 0/1：画布跨帧保留、矩形贴盖）。
    /// image 包 `decode()` 的合成对子矩形帧不可靠（remap/alpha 路径缺陷，
    /// 既有测试因此只用 decodeFrame）——这里用 decodeFrame 取裸帧
    /// （gif_check.dart 同款思路），按规范自己合成，none / rect 两侧同法。
    /// 返回逐帧 RGB 画布快照。
    List<List<List<int>>> compositeGif(pkg.GifDecoder dec) {
      final info = dec.info!;
      final canvas = List.generate(
          info.height, (_) => List.generate(info.width, (_) => <int>[0, 0, 0]));
      final out = <List<List<int>>>[];
      for (var i = 0; i < info.numFrames; i++) {
        final desc = info.frames[i];
        final fim = dec.decodeFrame(i)!;
        expect(fim.width, desc.width, reason: '第 $i 帧解码尺寸 = 描述符矩形');
        for (var y = 0; y < desc.height; y++) {
          for (var x = 0; x < desc.width; x++) {
            final c = fim.getPixel(x, y);
            canvas[desc.y + y][desc.x + x] = <int>[
              c.r.toInt(), c.g.toInt(), c.b.toInt(),
            ];
          }
        }
        out.add([for (final row in canvas) [for (final p in row) ...p]]);
      }
      return out;
    }

    test('配置面：条件序列化、hash 往返、未知值回落 none', () {
      final base = EffectConfig();
      expect(base.toJson().containsKey('encoding'), isFalse,
          reason: '默认 none 整段不序列化，既有指纹不变');
      expect(EffectConfig(encoding: const EncodingParams()).configHash,
          base.configHash);
      final rect =
          EffectConfig(encoding: const EncodingParams(diffMode: 'rect'));
      expect(rect.toJson()['encoding'], {'diffMode': 'rect'});
      expect(rect.configHash, isNot(base.configHash),
          reason: 'rect 改变编码产物，必须进指纹');
      expect(EffectConfig.fromJson(rect.toJson()).configHash, rect.configHash);
      expect(EffectConfig.fromJson(rect.toJson()).encoding.diffMode, 'rect');
      expect(
          EffectConfig.fromJson(
                  {'encoding': {'diffMode': 'typo'}}).encoding.diffMode,
          'none',
          reason: '未知 diffMode 与 ditherMode 同语义回落默认');
    });

    test('none 为默认：显式 none 与缺省的 GIF 逐字节一致（红线）', () async {
      final png = _pngEncode(_gradientImage(64, 96));
      final a = await MotionPipeline(
              EffectConfig(fps: 4, durationSec: 1, maxDimension: 64),
              parallel: 1)
          .processBytes(input: Uint8List.fromList(png));
      final b = await MotionPipeline(
          EffectConfig(
              fps: 4, durationSec: 1, maxDimension: 64,
              encoding: const EncodingParams()),
          parallel: 1)
          .processBytes(input: Uint8List.fromList(png));
      expect(b.gifBytes, equals(a.gifBytes),
          reason: 'diffMode 缺省与显式 none 必须同字节');
    });

    test('rect：标准解码器逐帧合成还原与 none 完全一致（串行 + worker 路径）',
        () async {
      final png = _pngEncode(_gradientImage(96, 96));
      EffectConfig cfg({bool rect = false}) => EffectConfig(
            fps: 4, durationSec: 1, maxDimension: 96,
            encoding: rect
                ? const EncodingParams(diffMode: 'rect')
                : const EncodingParams(),
          );

      for (final spec in [
        {'parallel': 1, 'tier': RenderTier.legacy},
        {'parallel': 3, 'tier': RenderTier.standard},
      ]) {
        final tier = spec['tier'] as RenderTier;
        final noneCfg = cfg()
          ..quality = QualityParams(tier: tier);
        final rectCfg = cfg(rect: true)
          ..quality = QualityParams(tier: tier);
        final none = await MotionPipeline(noneCfg,
                parallel: spec['parallel'] as int)
            .processBytes(input: Uint8List.fromList(png));
        final rect = await MotionPipeline(rectCfg,
                parallel: spec['parallel'] as int)
            .processBytes(input: Uint8List.fromList(png));
        expect(rect.gifBytes, isNotNull);

        final compNone = compositeGif(pkg.GifDecoder(none.gifBytes!));
        final compRect = compositeGif(pkg.GifDecoder(rect.gifBytes!));
        expect(compNone.length, noneCfg.frameCount);
        expect(compRect.length, compNone.length,
            reason: 'tier=$tier rect 模式帧数一致（1x1 占位帧也算一帧）');
        for (var i = 0; i < compNone.length; i++) {
          expect(compRect[i], equals(compNone[i]),
              reason: 'tier=$tier 第 $i 帧：rect 合成结果与 none 逐像素一致');
        }
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('rect：体积小于全量编码（同帧重复 → 变化矩形 1x1 占位）', () {
      const w = 64, h = 64;
      final f = RgbaImage(width: w, height: h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          f.setPixel(x, y, x * 255 ~/ (w - 1), y * 255 ~/ (h - 1), 128);
        }
      }
      final bNone = StreamingGifBuilder(w, h, fps: 5);
      for (var i = 0; i < 4; i++) {
        bNone.addFrame(f);
      }
      final bRect = StreamingGifBuilder(w, h, fps: 5, rectDiff: true);
      for (var i = 0; i < 4; i++) {
        bRect.addFrame(f);
      }
      final noneBytes = Uint8List.fromList(bNone.finish());
      final rectBytes = Uint8List.fromList(bRect.finish());
      expect(bRect.frameCount, 4, reason: '无变化帧仍占一帧（时序不丢）');
      expect(rectBytes.length, lessThan(noneBytes.length),
          reason: '变化矩形远小于全画布 LZW');
      // 静态画面：rect 规范合成逐帧与 none 一致
      final compNone = compositeGif(pkg.GifDecoder(noneBytes));
      final compRect = compositeGif(pkg.GifDecoder(rectBytes));
      expect(compRect.length, compNone.length);
      for (var i = 0; i < compNone.length; i++) {
        expect(compRect[i], equals(compNone[i]), reason: '第 $i 帧一致');
      }
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
      final depth = HeuristicDepthEstimator().estimate(img);
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

  group('v1.4 Task 3.2：相邻深度层反相视差（层间相对位移可见）', () {
    // 合成场景走真实包管线：DepthMap → LayerSplitter(layerCount:3) →
    // FrameCompositor.renderFrame。三个深度带（远/中/近）各有一根同列同宽、
    // 异色的竖条，条中心恰在缩放枢轴（w/2）上——cover 放大只作用在枢轴两侧
    // 对称位置，质心位移即该层的水平视差位移本身。
    // 判别逻辑：峰值帧 t=period/4（sin(π/2+li·π) = +1/−1/+1）下相邻层必须
    // 反向摆动；旧相位 li*0.35（sin(π/2+{0,0.35,0.7}) = 1/0.939/0.765 同号）
    // 三层同向，本组的反号断言在旧代码下必红，这正是判别式。
    const w = 300, h = 300;
    const amp = 0.1; // 峰值位移满幅 = amp*w = 30px（far 7.5 / mid 15 / near 22.5）
    const period = 3.0;

    RgbaImage bandBarScene() {
      final img = RgbaImage(width: w, height: h);
      for (var y = 0; y < h; y++) {
        final g = y < 126 ? 210 : (y < 210 ? 200 : 190);
        for (var x = 0; x < w; x++) {
          img.setPixel(x, y, g, g, g);
        }
      }
      for (var y = 84; y < 116; y++) {
        for (var x = 134; x < 166; x++) {
          img.setPixel(x, y, 235, 25, 35); // far 层红条
        }
      }
      for (var y = 180; y < 210; y++) {
        for (var x = 134; x < 166; x++) {
          img.setPixel(x, y, 30, 200, 60); // mid 层绿条
        }
      }
      for (var y = 240; y < 290; y++) {
        for (var x = 134; x < 166; x++) {
          img.setPixel(x, y, 40, 70, 235); // near 层蓝条
        }
      }
      return img;
    }

    // 深度场按行分带：far(0..125)=0.05、mid(126..209)=0.45、
    // near(210..299) 梯度 0.85..1.0。带占比 42%/28%/30% 使
    // t1=max(q(0.35),0.30)=0.30、t2=q(0.72)≈0.86 都落在带间空隙，
    // 三层在各自扫描行上全不透明（legacy 档掩码）。
    DepthMap bandDepth() {
      final dm = DepthMap(w, h);
      for (var y = 0; y < h; y++) {
        final d = y < 126
            ? 0.05
            : (y < 210 ? 0.45 : 0.85 + 0.15 * (y - 210) / 89);
        for (var x = 0; x < w; x++) {
          dm.set(x, y, d);
        }
      }
      return dm;
    }

    // 扫描行上命中色条谓词的质心列（灰底 r==g==b，任何主色谓词恒不命中）。
    double barCentroid(
        RgbaImage f, int row, bool Function(int r, int g, int b) hit) {
      var sum = 0, n = 0;
      for (var x = 0; x < w; x++) {
        final o = (row * w + x) * 4;
        if (hit(f.data[o], f.data[o + 1], f.data[o + 2])) {
          sum += x;
          n++;
        }
      }
      expect(n, greaterThan(0), reason: 'row=$row 应能定位色条');
      return sum / n;
    }

    bool isRed(int r, int g, int b) => r > 150 && g < 90 && b < 90;
    bool isGreen(int r, int g, int b) => g > 150 && r < 90 && b < 90;
    bool isBlue(int r, int g, int b) => b > 150 && r < 90 && g < 120;

    final cfg = EffectConfig(
      effects: [EffectKind.parallax],
      fps: 8,
      durationSec: period,
      parallax: ParallaxParams(amplitude: amp, periodSec: period),
    );
    final img = bandBarScene();
    final layers = LayerSplitter(layerCount: 3).split(img, bandDepth());

    test('峰值帧相邻层反向摆动：far/mid/near 质心位移反号且相对位移翻倍', () {
      // 本判别式**本质上只在纯正弦成立**：它取 t=0 作「位移恰为 0」的基线帧
      // （sin(0+li·π)=0），再取 t=period/4 的峰值帧，才有下面那些像素级理论值
      // （far ~7.5 / mid ~15 / near ~22.5）。Task 3.6 把默认档升到 standard 后
      // 载体换成 snapWave，而 snapWave(0)=0.3387≠0 ⇒ 基线假设失效。
      // 因此这里显式钉 legacy 档，钉的是「正弦载体的峰值/零位基线」这一半契约；
      // 新默认（standard + snapWave）的同一反相判别由本组末尾
      // 「标准档同款判别式」那条测试覆盖（R28），覆盖没有掉。
      final sineCfg = EffectConfig(
        effects: const [EffectKind.parallax],
        fps: 8,
        durationSec: period,
        parallax: ParallaxParams(amplitude: amp, periodSec: period),
        quality: const QualityParams(tier: RenderTier.legacy),
      );
      final comp = FrameCompositor(layers, img, sineCfg);
      final base = comp.renderFrame(0.0); // phase=0：位移为 0 的基线
      final peak = comp.renderFrame(period / 4); // phase=π/2：正弦峰值

      final dFar = barCentroid(peak, 100, isRed) - barCentroid(base, 100, isRed);
      final dMid =
          barCentroid(peak, 195, isGreen) - barCentroid(base, 195, isGreen);
      final dNear =
          barCentroid(peak, 270, isBlue) - barCentroid(base, 270, isBlue);

      // 每层都真实移动（远超质心量化噪声）。
      expect(dFar.abs(), greaterThan(4.0), reason: 'far 层应有 ~7.5px 位移');
      expect(dMid.abs(), greaterThan(8.0), reason: 'mid 层应有 ~15px 位移');
      expect(dNear.abs(), greaterThan(14.0), reason: 'near 层应有 ~22.5px 位移');

      // 判别式：相邻层反相 → 位移反号。旧 li*0.35 相位下峰值帧三层同向
      //（sin(π/2+0.35)=0.939、sin(π/2+0.7)=0.765，与 sin(π/2)=1 同号），
      // 本断言在旧代码下必红——这正是相对判别式。
      expect(dFar.sign, -dMid.sign, reason: 'far 与 mid 应反向摆动');
      expect(dMid.sign, -dNear.sign, reason: 'mid 与 near 应反向摆动');

      // 相邻层相对位移：反相 = (m0+m1)·ampW（理论 0.75·ampW / 1.25·ampW），
      // 同相（旧）上限 ≈ |m0−m1·cos(0.35)|·ampW = 0.22·ampW、
      // |m1·cos(0.35)−m2·cos(0.7)|·ampW ≈ 0.10·ampW → 断言 ≥2× 旧值，
      // 即规格 §6.1「相邻层 phase+π，相对位移翻倍可见」。
      final ampW = amp * w;
      expect((dFar - dMid).abs(), greaterThanOrEqualTo(0.44 * ampW));
      expect((dMid - dNear).abs(), greaterThanOrEqualTo(0.22 * ampW));
      // 反相近似完美：相对位移 ≈ 两位移绝对值之和（同相时 ≈ 之差）。
      expect((dFar - dMid).abs(),
          greaterThan(0.85 * (dFar.abs() + dMid.abs())));
      expect((dMid - dNear).abs(),
          greaterThan(0.85 * (dMid.abs() + dNear.abs())));
    });

    test('反相仍确定性：同配置两次渲染同帧逐字节一致', () {
      final c1 = FrameCompositor(layers, img, cfg);
      final c2 = FrameCompositor(layers, img, cfg);
      expect(c1.renderFrame(period / 4).data, c2.renderFrame(period / 4).data);
    });

    test('反相不破坏无缝循环：t=0 与 t=periodSec 首尾帧逐字节一致', () {
      final comp = FrameCompositor(layers, img, cfg);
      expect(
        comp.renderFrame(0.0).data,
        comp.renderFrame(period).data,
        reason: 'li·π 是常数相位偏置，整周期后 sin 相位回到起点',
      );
    });

    test('交互式视差覆盖契约不变：phase=0 与无 parallax 逐字节一致', () {
      // 本任务只改时间驱动 else 分支；parallaxOverride 分支的 phase=0
      // 零位移字节锁定必须保持绿色。
      final noP = FrameCompositor(layers, img, EffectConfig(
        effects: const [],
        fps: 8,
        durationSec: period,
      ));
      final ref = noP.renderFrame(0.0);
      final comp = FrameCompositor(layers, img, cfg);
      comp.parallaxOverride = const ParallaxOverride(phaseX: 0.0, phaseY: 0.0);
      expect(comp.renderFrame(0.0).data, ref.data);
    });

    // 列质心：在固定列上向下扫描、命中色条谓词的 y 均值（barCentroid 的
    // 纵向对偶，用于测竖向位移）。灰底 r==g==b 恒不命中任何主色谓词。
    double barCentroidCol(
        RgbaImage f, int col, bool Function(int r, int g, int b) hit) {
      var sum = 0, n = 0;
      for (var y = 0; y < h; y++) {
        final o = (y * w + col) * 4;
        if (hit(f.data[o], f.data[o + 1], f.data[o + 2])) {
          sum += y;
          n++;
        }
      }
      expect(n, greaterThan(0), reason: 'col=$col 应能定位色条');
      return sum / n;
    }

    test('竖向判别式：directionDeg=90 下相邻层竖向反向摆动（dy 项被激活）', () {
      // directionDeg=90 → dyDir=sin(π/2)=1、dxDir=cos(π/2)≈0：层位移纯竖向，
      // 这才真正触达 frame_compositor.dart 视差 else 分支的竖向 snapDy 项
      // （默认 0 时 dyDir=0，dy 项恒 0、从不被本组水平用例覆盖）。
      const col = 150; // 三根色条同列，均在缩放枢轴所在列上
      // R28（Task 3.6 翻默认档）：同一组断言在两档载体上各跑一遍。
      //  · legacy 载体是纯正弦 ⇒ 仍取原 t=0 ↔ t=period/2 这一对（下面
      //    0.783/1.567 的核验算术只对这一对成立）。
      //  · standard（Task 3.6 起为新默认）载体是 snapWave：t=0 恰落在波形平台区，
      //    far 层差分只剩 3.0px（正好等于阈值）⇒ 重挑时刻 t=period/6 ↔
      //    period/6+period/2（仍相差半周期，u 恰 +0.5 ⇒ li·π 反相步进保证相邻层
      //    反号），实测 {4.0, −4.5, 15.0}。断言与阈值一字未放宽。
      for (final arm in [
        (tier: RenderTier.legacy, tLo: 0.0),
        (tier: RenderTier.standard, tLo: period / 6),
      ]) {
        final cfgV = EffectConfig(
          effects: [EffectKind.parallax],
          fps: 8,
          durationSec: period,
          parallax: ParallaxParams(
              amplitude: amp, periodSec: period, directionDeg: 90),
          quality: QualityParams(tier: arm.tier),
        );
        final compV = FrameCompositor(layers, img, cfgV);
        // R19 竖向基底 = dyCycles/duration·2π（cycles=1 时 dyCycles=1），
        // 取相差半周期（π 相位推进）的一对帧：li·π 反相步进保证
        // sin(dyPhase+li·π+0.9) 在相邻层反号，差分后位移方向亦反号。
        // t=0 竖向位移非零（sin(0.9)≠0），故不做「零位移基线」假设——只测差分。
        final a = compV.renderFrame(arm.tLo);
        final b = compV.renderFrame(arm.tLo + period / 2);
        final dFar =
            barCentroidCol(b, col, isRed) - barCentroidCol(a, col, isRed);
        final dMid =
            barCentroidCol(b, col, isGreen) - barCentroidCol(a, col, isGreen);
        final dNear =
            barCentroidCol(b, col, isBlue) - barCentroidCol(a, col, isBlue);

        // 每层都发生可见竖向摆动（远超质心量化噪声）。
        expect(dFar.abs(), greaterThan(3.0), reason: '${arm.tier.name} far 层应有竖向位移');
        expect(dMid.abs(), greaterThan(3.0), reason: '${arm.tier.name} mid 层应有竖向位移');
        expect(dNear.abs(), greaterThan(3.0), reason: '${arm.tier.name} near 层应有竖向位移');

        // 判别式（算术可核验，sin 以弧度计）：R19 后竖向基底
        // dyPhase(t) = 2π·t·dyCycles/duration，本配置 cycles=1 → dyCycles=1、
        // duration=period=3，故 dyPhase(0)=0、dyPhase(period/2)=π。
        //   t=0:        sin(li·π+0.9) ≈ {+0.783, −0.783, +0.783}
        //   t=period/2: sin(π+li·π+0.9) = −sin(li·π+0.9) ≈ {−0.783, +0.783, −0.783}
        // → 三层差分 ≈ {−1.567, +1.567, −1.567}：相邻层竖向摆动方向相反
        //（far/mid 反、mid/near 反）。
        // standard 臂上同样的反号来自 snapWave 的 1、3 次奇谐波（半周期反瓣），
        // 2 次谐波项 0.42·sin(2w+π/2) 半周期不变号但幅值小于奇谐波之和 ⇒ 反号保持，
        // 实测差分 {4.0, −4.5, 15.0} 与 legacy 臂 {4.0, −5.0, 14.5} 同号形。
        // 对照旧竖向项 sin(phase·0.8 + li·0.5 + 0.9)（3.2 前的反相步进 + 非整
        // 0.8 倍率；phase=2π·t/periodSec）：
        //   t=0:        sin(li·0.5+0.9) ≈ {+0.783, +0.985, +0.946}（三者同号）
        //   t=period/2: sin(0.8π+li·0.5+0.9) ≈ {−0.268, −0.697, −0.955}
        // → 差分 ≈ {−1.052, −1.683, −1.902} 全同号，far/mid、mid/near 都同向
        // → 本反号断言在旧代码下必红（真判别式）。
        expect(dFar.sign, -dMid.sign, reason: '${arm.tier.name} far 与 mid 应竖向反向摆动');
        expect(dMid.sign, -dNear.sign, reason: '${arm.tier.name} mid 与 near 应竖向反向摆动');

        // 相邻层竖向相对分离 ≈ 两位移绝对值之和（反相特征，同相仅为之差），
        // 与水平判别式同一「超出同相基线」的表达。
        expect((dFar - dMid).abs(), greaterThan(0.85 * (dFar.abs() + dMid.abs())),
            reason: '${arm.tier.name} far/mid 分离不足反相特征');
        expect((dMid - dNear).abs(),
            greaterThan(0.85 * (dMid.abs() + dNear.abs())),
            reason: '${arm.tier.name} mid/near 分离不足反相特征');
      }
      // 注：R19 竖向基底已改为 dyCycles 整周期，dyDir≠0 时竖向也整周期闭合
      //（见 3.5 组的竖向无缝 test）；本 test 每档取相差半周期（π 相位推进）
      // 的一对帧做差分判别。
    });

    test('标准档同款判别式：standard 层相邻层水平反向摆动（Task 3.6 默认档）', () {
      // 与首个水平判别式同场景，渲染档切到 standard，使反相性质在 Task 3.6
      // 将要设为默认的档位上也被锁住。
      // Task 3.4（R17）改判：standard 载体已是 snapWave 且 snapWave(0)=0.3387
      // ≠0，t=0 帧不再「位移为 0」，旧的「t=0 基线 vs t=period/4」差分对偶层
      // 只剩 −0.016·amp 的亚像素差（far 质心位移实测 0.0）。改取相差半周期
      // （u 恰 +0.5）的一对时刻 t=period/4 与 3period/4：snapWave(v+0.5) 与
      // snapWave(v) 的层间差分对偶数/奇数 li 恒反号（实测 ±1.3226·amp·mult），
      // 反相判别性质保持，反号/分离断言逐字保留。
      final cfgStd = EffectConfig(
        effects: [EffectKind.parallax],
        fps: 8,
        durationSec: period,
        parallax: ParallaxParams(amplitude: amp, periodSec: period),
        quality: QualityParams(tier: RenderTier.standard),
      );
      final comp = FrameCompositor(layers, img, cfgStd);
      final lo = comp.renderFrame(period / 4); // u = 0.25 + li/2
      final hi = comp.renderFrame(3 * period / 4); // u = 0.75 + li/2（反相半周期）

      final dFar = barCentroid(hi, 100, isRed) - barCentroid(lo, 100, isRed);
      final dMid =
          barCentroid(hi, 195, isGreen) - barCentroid(lo, 195, isGreen);
      final dNear =
          barCentroid(hi, 270, isBlue) - barCentroid(lo, 270, isBlue);

      expect(dFar.abs(), greaterThan(4.0));
      expect(dMid.abs(), greaterThan(8.0));
      expect(dNear.abs(), greaterThan(14.0));

      expect(dFar.sign, -dMid.sign, reason: 'far 与 mid 应反向摆动');
      expect(dMid.sign, -dNear.sign, reason: 'mid 与 near 应反向摆动');

      final ampW = amp * w;
      expect((dFar - dMid).abs(), greaterThanOrEqualTo(0.44 * ampW));
      expect((dMid - dNear).abs(), greaterThanOrEqualTo(0.22 * ampW));
      expect((dFar - dMid).abs(),
          greaterThan(0.85 * (dFar.abs() + dMid.abs())));
      expect((dMid - dNear).abs(),
          greaterThan(0.85 * (dMid.abs() + dNear.abs())));
    });
  });

  group('v1.4 Task 3.5：periodSec 整数周期对齐（R18/R19）', () {
    // 复用 3.2 同场景 fixture 的 LayerSplitter + 色条判别模式。
    const w35 = 300, h35 = 300;
    const amp35 = 0.1; // 峰值满幅 = amp*w = 30px
    const dur35 = 3.0;  // durationSec=3
    const badPeriod = 6.0; // mis-aligned: 3/6=0.5→cycles=1→aligned=3.0

    RgbaImage bandBarScene35() {
      final img = RgbaImage(width: w35, height: h35);
      for (var y = 0; y < h35; y++) {
        final g = y < 126 ? 210 : (y < 210 ? 200 : 190);
        for (var x = 0; x < w35; x++) {
          img.setPixel(x, y, g, g, g);
        }
      }
      for (var y = 84; y < 116; y++) {
        for (var x = 134; x < 166; x++) {
          img.setPixel(x, y, 235, 25, 35); // far 层红条
        }
      }
      for (var y = 180; y < 210; y++) {
        for (var x = 134; x < 166; x++) {
          img.setPixel(x, y, 30, 200, 60); // mid 层绿条
        }
      }
      for (var y = 240; y < 290; y++) {
        for (var x = 134; x < 166; x++) {
          img.setPixel(x, y, 40, 70, 235); // near 层蓝条
        }
      }
      return img;
    }

    DepthMap bandDepth35() {
      final dm = DepthMap(w35, h35);
      for (var y = 0; y < h35; y++) {
        final d = y < 126
            ? 0.05
            : (y < 210 ? 0.45 : 0.85 + 0.15 * (y - 210) / 89);
        for (var x = 0; x < w35; x++) {
          dm.set(x, y, d);
        }
      }
      return dm;
    }

    double centroid35(
        RgbaImage f, int row, bool Function(int r, int g, int b) hit) {
      var sum = 0, n = 0;
      for (var x = 0; x < w35; x++) {
        final o = (row * w35 + x) * 4;
        if (hit(f.data[o], f.data[o + 1], f.data[o + 2])) {
          sum += x;
          n++;
        }
      }
      // 与 3.2 的 barCentroid/barCentroidCol 同一写法：命中数为 0 必须直接红，
      // 否则「色条被裁掉」会被 150.0 这类哨兵值伪装成一次有效测量。
      expect(n, greaterThan(0), reason: 'row=$row 应能定位色条');
      return sum / n;
    }

    bool isRed35(int r, int g, int b) => r > 150 && g < 90 && b < 90;
    bool isGreen35(int r, int g, int b) => g > 150 && r < 90 && b < 90;

    final img35 = bandBarScene35();
    final layers35 = LayerSplitter(layerCount: 3).split(img35, bandDepth35());

    test('cycleCount: 整数倍周期原样通过', () {
      expect(MotionMath.cycleCount(3.0, 3.0), 1);
      expect(MotionMath.cycleCount(6.0, 3.0), 2);
      expect(MotionMath.cycleCount(3.0, 1.5), 2);
    });

    test('cycleCount: 6/3→1→aligned=3.0 (duration 3, period 6)', () {
      expect(MotionMath.cycleCount(3.0, 6.0), 1);
      expect(MotionMath.alignedPeriodSec(3.0, 6.0), 3.0);
    });

    test('cycleCount: 4/3→1→aligned=3.0 (duration 3, period 4)', () {
      expect(MotionMath.cycleCount(3.0, 4.0), 1);
      expect(MotionMath.alignedPeriodSec(3.0, 4.0), 3.0);
    });

    test('cycleCount: 8/3→3→aligned≈2.667 (duration 8, period 3)', () {
      expect(MotionMath.cycleCount(8.0, 3.0), 3);
      expect(MotionMath.alignedPeriodSec(8.0, 3.0), closeTo(8.0 / 3, 1e-10));
    });

    test('cycleCount: degenerate inputs guard to 1, never 0', () {
      expect(MotionMath.cycleCount(0.0, 3.0), 1);
      expect(MotionMath.cycleCount(3.0, 0.0), 1);
      expect(MotionMath.cycleCount(-1.0, 3.0), 1);
      expect(MotionMath.cycleCount(3.0, -1.0), 1);
      expect(MotionMath.cycleCount(double.nan, 3.0), 1);
      expect(MotionMath.cycleCount(3.0, double.nan), 1);
      expect(MotionMath.cycleCount(double.infinity, 3.0), 1);
      expect(MotionMath.cycleCount(3.0, double.infinity), 1);
      // alignedPeriodSec 的「never-0」对偶契约（review M10）：消费点是
      // 2π·t/alignedPeriod，返回 0 会变成 Infinity→NaN，因此 duration 非正/
      // 非有限时落到 1.0 秒兜底（每秒一个整周期）。durationSec 在 EffectConfig
      // 构造时已校验为正，这条分支只防御外部 JSON 或直接调用。
      expect(MotionMath.alignedPeriodSec(3.0, 0.0), 3.0);
      expect(MotionMath.alignedPeriodSec(0.0, 6.0), 1.0);
      expect(MotionMath.alignedPeriodSec(double.nan, 6.0), 1.0);
      expect(MotionMath.alignedPeriodSec(double.infinity, 6.0), 1.0);
      for (final d in [0.0, -1.0, double.nan, double.infinity]) {
        final p = MotionMath.alignedPeriodSec(d, 6.0);
        expect(p, greaterThan(0.0), reason: 'duration=$d 不应产出 0 周期');
        expect(p.isFinite, isTrue, reason: 'duration=$d 不应产出非有限周期');
      }
    });

    test('全遍历判别式：mis-aligned(3/6)配置每层水平位移到达正负两极', () {
      // duration=3, periodSec=6 → 对齐后 cycles=1, alignedPeriod=3
      // 在全循环期间水平位移必须到达正、负两个极值（半周期下不触发负极值）。
      final cfg = EffectConfig(
        effects: [EffectKind.parallax],
        fps: 24,
        durationSec: dur35,
        parallax: ParallaxParams(amplitude: amp35, periodSec: badPeriod),
      );
      final comp = FrameCompositor(layers35, img35, cfg);
      final baseline = centroid35(comp.renderFrame(0.0), 195, isGreen35);
      final baselineFar = centroid35(comp.renderFrame(0.0), 100, isRed35);

      // 采样整条 duration，追踪 mid 层位移（相对 t=0）
      double minShift = 0, maxShift = 0;
      double minFar = 0, maxFar = 0;
      for (var t = 0.0; t <= dur35; t += dur35 / 24) {
        final c = centroid35(comp.renderFrame(t), 195, isGreen35);
        final shift = c - baseline;
        if (shift < minShift) minShift = shift;
        if (shift > maxShift) maxShift = shift;
        // far 层（row 100 红条，mult 最小 → 满幅 ≈ 30×0.25=7.5px）：同一
        // 判别式的第二层证据，同时让 isRed35 谓词真正被使用（analyze 干净）。
        final cf = centroid35(comp.renderFrame(t), 100, isRed35);
        final sf = cf - baselineFar;
        if (sf < minFar) minFar = sf;
        if (sf > maxFar) maxFar = sf;
      }

      // 对齐后到达正负两极：|mid 位移峰值| ≈ amp·w·mult_mid = 0.1*300*0.625 = 18.75
      // 断言两者符号相反，且幅度各超过满幅的 50%。
      expect(maxShift, greaterThan(5.0),
          reason: '对齐后正向极值应明显（期望 ~18px）');
      expect(minShift, lessThan(-5.0),
          reason: '对齐后负向极值应明显（期望 ~-18px）');
      // far 层满幅 7.5px：两极各 >2.5px 就意味着「不是单符号扫掠」——
      // BASE 的 ½ 周期扫掠只能给出单符号，这两条同样把它钉红。
      expect(maxFar, greaterThan(2.5), reason: 'far 层应到达正向极值');
      expect(minFar, lessThan(-2.5), reason: 'far 层应到达负向极值');
    });

    test('视差水平无缝：mis-aligned(3/4) renderFrame(0)==renderFrame(duration)',
        () {
      // duration=3, periodSec=4: 3/4=0.75→cycles=1→aligned=3.0.
      // 未对齐时 t=3 phase=3π/2, sin(3π/2+li·π)≠0 (≠ sin(li·π) at t=0)
      // 对齐后 t=3 phase=2π, sin(2π+li·π)=sin(li·π)=0 → 无缝。
      final cfg = EffectConfig(
        effects: [EffectKind.parallax],
        fps: 24,
        durationSec: dur35,
        parallax: ParallaxParams(amplitude: amp35, periodSec: 4.0),
      );
      final comp = FrameCompositor(layers35, img35, cfg);
      expect(
        comp.renderFrame(0.0).data,
        comp.renderFrame(dur35).data,
        reason: 'R18 对齐后整数周期 ⇒ 首尾帧逐字节一致',
      );
    });

    test('视差竖向无缝（R19）：directionDeg=90, mis-aligned(3/6)', () {
      final cfg = EffectConfig(
        effects: [EffectKind.parallax],
        fps: 24,
        durationSec: dur35,
        parallax:
            ParallaxParams(amplitude: amp35, periodSec: badPeriod, directionDeg: 90),
      );
      final comp = FrameCompositor(layers35, img35, cfg);
      expect(
        comp.renderFrame(0.0).data,
        comp.renderFrame(dur35).data,
        reason: 'R19 竖向整周期 ⇒ 首尾帧逐字节一致',
      );
    });

    // review M11：上面两条 seam test 没设 quality，只跑 legacy 档，R19 的
    // snapWave 竖向分支（frame_compositor 的 `_aa ? snapWave(...)` 操作数选择）
    // 只是被传递性地覆盖到。Task 3.6 要把 standard 设为默认档，这里两档各留
    // 一条同场景 seam test（先显式 pin，默认翻转后断言本身不变）。
    test('视差水平无缝（standard 档）：mis-aligned(3/4) 首尾帧一致', () {
      final cfg = EffectConfig(
        effects: [EffectKind.parallax],
        fps: 24,
        durationSec: dur35,
        parallax: ParallaxParams(amplitude: amp35, periodSec: 4.0),
        quality: QualityParams(tier: RenderTier.standard),
      );
      final comp = FrameCompositor(layers35, img35, cfg);
      expect(
        comp.renderFrame(0.0).data,
        comp.renderFrame(dur35).data,
        reason: 'R18 对齐 + standard 档 snapWave ⇒ 首尾帧逐字节一致',
      );
    });

    test('视差竖向无缝（R19, standard 档）：directionDeg=90, mis-aligned(3/6)',
        () {
      final cfg = EffectConfig(
        effects: [EffectKind.parallax],
        fps: 24,
        durationSec: dur35,
        parallax:
            ParallaxParams(amplitude: amp35, periodSec: badPeriod, directionDeg: 90),
        quality: QualityParams(tier: RenderTier.standard),
      );
      final comp = FrameCompositor(layers35, img35, cfg);
      expect(
        comp.renderFrame(0.0).data,
        comp.renderFrame(dur35).data,
        reason: 'R19 竖向整周期 + standard 档 snapWave ⇒ 首尾帧逐字节一致',
      );
    });

    test('呼吸无缝：duration=3/periodSec=4, renderFrame(0)==renderFrame(3)', () {
      final cfg = EffectConfig(
        effects: [EffectKind.breathing],
        fps: 24,
        durationSec: 3.0,
        breathing: BreathingParams(amplitude: 0.012, periodSec: 4.0),
      );
      final flatImg = RgbaImage(width: 64, height: 64);
      for (var i = 0; i < 64 * 64; i++) {
        flatImg.data[i * 4] = 128;
        flatImg.data[i * 4 + 1] = 128;
        flatImg.data[i * 4 + 2] = 128;
        flatImg.data[i * 4 + 3] = 255;
      }
      final flatLayers =
          LayerSplitter(layerCount: 3).split(flatImg, DepthMap(64, 64));
      final comp = FrameCompositor(flatLayers, flatImg, cfg);
      expect(
        comp.renderFrame(0.0).data,
        comp.renderFrame(3.0).data,
        reason: 'R18 对齐呼吸周期到 duration 整数分频 ⇒ 首尾无缝',
      );
    });

    test('预设数据同步守卫：pinned 值不低于 §6.1 新默认值的 80% 下限', () {
      // 规格 §6.1 抬高了六个默认值；presets/*.json 由 tool/generate_showcase.dart
      // 生成，一旦生成器仍 pin 旧值就会覆盖 Task 3.1 的 louder defaults。
      //
      // review I2：断言**不变量**（>= 下限），而不是逐个比对旧的精确值。
      // 旧表里 mangaShake 0.006 / slowPush 0.035 是 Dart 默认值，而 presets 实际
      // pin 过 0.007/0.008/0.009 与 0.030，parallax/breathing 也漏掉
      // 0.010/0.014/0.016 与 0.005/0.007/0.008 这些 ±20% 变体 ⇒ exact-match 只拦
      // 得住一部分 stale 重发。下限取「新默认值 × 0.8」：0.8 是生成器为每个 demo
      // 保留的 ±20% 变化带（addendum R21），而六个 v1.4 前的旧默认值全部落在
      // 该下限之下（parallax 0.012<0.024、breathing 0.006<0.0096、ambient
      // 0.16<0.176、mangaShake 0.009<0.0144、heartbeat 0.012<0.016、slowPush
      // 0.035<0.048），因此 stale 重发会红。
      //
      // 残留盲区（re-review check #1，记账给 3.7）：breathing 旧变体 0.010 恰好
      // 等于合法新值 0.010（旧 0.005 × 2.0），任何 `>= 下限` 形态的断言都分不开
      // 两者 ⇒ 单点回退这 2 个 breathing 文件不会被本守卫拦住。整批 stale 重发
      // 仍会在其余五个键上红。要闭合它只能改生成数据（本轮禁止），或按 3.7 的
      // 重钉决策把六个键统一为新默认值。
      const floors = <String, double>{
        'parallax.amplitude': 0.024, // 0.030 × 0.8
        'breathing.amplitude': 0.0096, // 0.012 × 0.8
        'ambient.opacity': 0.176, // 0.22 × 0.8
        'mangaShake.amplitude': 0.0144, // 0.018 × 0.8
        'heartbeat.intensity': 0.016, // 0.020 × 0.8
        'slowPush.pushFrac': 0.048, // 0.060 × 0.8
      };

      double? pinned(Map<String, dynamic> j, String dottedKey) {
        final dot = dottedKey.indexOf('.');
        final seg = j[dottedKey.substring(0, dot)];
        if (seg is! Map) return null; // 未 pin：继承默认值，交给引擎
        final v = seg[dottedKey.substring(dot + 1)];
        return v is num ? v.toDouble() : null;
      }

      final dir = Directory('presets');
      expect(dir.existsSync(), isTrue, reason: 'presets/ 目录必须存在');
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()..sort((a, b) => a.path.compareTo(b.path));
      expect(files.length, greaterThanOrEqualTo(38),
          reason: '至少 38 个预设（含新生成的 stale 修复文件）');

      for (final f in files) {
        final j = convert.jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final name = f.uri.pathSegments.last;
        for (final e in floors.entries) {
          final v = pinned(j, e.key);
          if (v == null) continue;
          expect(v, greaterThanOrEqualTo(e.value),
              reason: '$name: ${e.key}=$v 低于 §6.1 下限 ${e.value}'
                  '（stale 重发把值退回 v1.4 前的旧默认了吗？）');
        }
      }
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
      final depth = HeuristicDepthEstimator().estimate(img);
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
        // R32：dither:true 已等于默认 ⇒ 整段省略；这里要钉「非默认才写段」，
        // 所以取一个真正非默认的 quality（关抖动）。
        quality: QualityParams(dither: false),
      );
      final j = cfg.toJson();
      expect(j.containsKey('fog'), isTrue);
      expect(j.containsKey('snow'), isFalse, reason: '未启用不序列化');
      expect((j['quality'] as Map)['dither'], isFalse);
      // R32/R26：新默认（standard+sierra+dither）就是省略哨兵本身 ⇒ 默认配置
      // 整段不写 quality 键（缺键兜底与哨兵同源，往返无损）。
      expect(EffectConfig().toJson().containsKey('quality'), isFalse);
      // 反向半：显式 v1.2 旧默认组合现在**写出整段**（回滚可持久化）。
      final legacySentinel = EffectConfig()
        ..quality = const QualityParams(
            dither: false, ditherMode: 'floyd', tier: RenderTier.legacy);
      expect(
          legacySentinel.toJson()['quality'],
          {'dither': false, 'ditherMode': 'floyd', 'tier': 'legacy'},
          reason: 'legacy 必须能从 JSON 显式表达（spec §6.4「legacy 仍供显式选择」）');
      final restored = EffectConfig.fromJson(_decodeJson(cfg.toJsonString()));
      expect(restored.configHash, cfg.configHash);
      expect(restored.fog.blobs, 10);
      expect(restored.quality.dither, isFalse);
      // 回滚配置的往返同样无损（这一半在 R24 哨兵设计下是丢的）。
      final backLegacy =
          EffectConfig.fromJson(_decodeJson(legacySentinel.toJsonString()));
      expect(backLegacy.quality.tier, RenderTier.legacy);
      expect(backLegacy.configHash, legacySentinel.configHash);
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

    test('v1.4 默认不写 quality 段；显式 legacy 写出整段、单键降级逐键省略（R32/R26）',
        () {
      // R32：默认 = 哨兵 ⇒ 段不出现；「段不出现」从此唯一地意味着新默认，
      // 而 legacy 只能靠显式写出表达（这正是 R24 哨兵设计丢掉的那一半）。
      expect(EffectConfig().toJson().containsKey('quality'), isFalse,
          reason: '新默认 standard+sierra+dither 命中省略哨兵 ⇒ 不写段');
      expect(EffectConfig().quality.tier, RenderTier.standard);
      final legacySentinel = EffectConfig()
        ..quality = const QualityParams(
            dither: false, ditherMode: 'floyd', tier: RenderTier.legacy);
      expect(
          legacySentinel.toJson()['quality'],
          {'dither': false, 'ditherMode': 'floyd', 'tier': 'legacy'},
          reason: '整套旧默认现在必须写出（回滚路径可持久化）');
      // 只改一个键 ⇒ 只写那一个键（等于自己默认的键仍省略）。这不再退回
      // 「缺键即 legacy」的旧歧义，因为缺键兜底 == 该键默认：下面直接验。
      final d = EffectConfig()..quality = const QualityParams(dither: false);
      expect(d.toJson()['quality'], {'dither': false});
      final back = EffectConfig.fromJson(_decodeJson(d.toJsonString()));
      expect(back.quality.dither, isFalse);
      expect(back.quality.ditherMode, 'sierra', reason: '缺 ditherMode 键 ⇒ 该键默认');
      expect(back.quality.tier, RenderTier.standard, reason: '缺 tier 键 ⇒ 该键默认');
      expect(back.configHash, d.configHash);
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
      // R32：tier/ditherMode 等于自己的默认 ⇒ 省略；mipLevels/edgeStretchPx
      // 非默认 ⇒ 逐键写出。dither 恒写（段只在非默认时出现）。
      expect(j.containsKey('tier'), isFalse, reason: 'tier==默认就不写（R32）');
      expect(j.containsKey('ditherMode'), isFalse);
      expect(j['dither'], isTrue);
      expect(j['mipLevels'], 1);
      expect(j['edgeStretchPx'], 0);
      final back = EffectConfig.fromJson(_decodeJson(cfg.toJsonString()));
      expect(back.configHash, cfg.configHash);
      expect(back.quality.tier, RenderTier.standard);
      expect(back.quality.ditherMode, 'sierra');
      expect(back.quality.edgeStretchPx, 0);

      // 混档（R24 哨兵设计下有损的那一类）现在也走同一条契约：写出 tier、
      // 省略等于默认的键，重解析逐字段复原。
      final mixed = EffectConfig(fps: 12, durationSec: 3, maxDimension: 640)
        ..quality = const QualityParams(
            dither: true, ditherMode: 'sierra', tier: RenderTier.legacy);
      expect(mixed.toJson()['quality'], {'dither': true, 'tier': 'legacy'});
      final mixedBack = EffectConfig.fromJson(_decodeJson(mixed.toJsonString()));
      expect(mixedBack.quality.tier, RenderTier.legacy);
      expect(mixedBack.quality.ditherMode, 'sierra');
      expect(mixedBack.configHash, mixed.configHash,
          reason: '混档往返必须保哈希（R32 前这里会静默变 standard）');
    });

    test('quality 段缺省 dither 时与构造默认一致（R24 锁步：缺键 ⇒ 新默认 true）', () {
      final back = EffectConfig.fromJson(_decodeJson(
          '{"effects":["parallax","breathing"],"quality":{"tier":"standard"}}'));
      // v1.4：缺键兜底与构造默认锁步 ⇒ 不再静默关抖动
      expect(back.quality.dither, isTrue);
      expect(back.quality.ditherMode, 'sierra');
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
          () => effectConfigFromFile(badFile.path),
          throwsA(isA<ConfigException>()
              .having((e) => e.code, 'code', 'E_BAD_CONFIG')));
      // worker 崩溃码
      expect(EngineWorkerException(3, 'x').code, 'E_WORKER_CRASH');
    });

    test('越界质量参数被钳制、未知 tier 回落 legacy、未知 ditherMode 回落新默认 sierra', () {
      final q = QualityParams.fromJson({
        'tier': 'ultra',
        'ditherMode': 'blue-noise',
        'mipLevels': 9,
        'edgeStretchPx': -4,
      });
      // tier 键存在但未知名 ⇒ RenderTier.parse 的既有 sanitise（legacy）不变；
      // ditherMode 未知名 ⇒ R24 兜底翻到新默认 sierra（仅显式 'floyd' 走 floyd）。
      expect(q.tier, RenderTier.legacy);
      expect(q.ditherMode, 'sierra');
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
          .split(img, HeuristicDepthEstimator().estimate(img));
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
        LayerSplitter(layerCount: 3).split(img, HeuristicDepthEstimator().estimate(img));

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
      // 往返用新默认档（standard）：quality 段命中省略哨兵 ⇒ 不写键，
      // 缺键兜底 == 构造默认 == 哨兵（R32）⇒ 往返逐字段复原。
      final cfg = fcfg(
          focus: const FocusLinesParams(mode: 'both', lines: 40),
          tier: RenderTier.standard);
      final j = _decodeJson(cfg.toJsonString());
      expect(j['focusLines']['mode'], 'both');
      expect(EffectConfig.fromJson(j).configHash, cfg.configHash);
      // R32 反向半：整套旧默认（legacy/floyd/false）现在**写出** quality 段并
      // 无损往返。R24 的旧断言（整段省略 ⇒ 重解析成 standard）会静默抹掉回滚，
      // 那正是本轮修掉的缺陷，这里改为钉住「回滚可持久化」。
      final legacyArm = fcfg(focus: const FocusLinesParams(mode: 'both', lines: 40))
        ..quality = const QualityParams(
            dither: false, ditherMode: 'floyd', tier: RenderTier.legacy);
      expect(
          legacyArm.toJson()['quality'],
          {'dither': false, 'ditherMode': 'floyd', 'tier': 'legacy'});
      final legacyBack =
          EffectConfig.fromJson(_decodeJson(legacyArm.toJsonString()));
      expect(legacyBack.quality.tier, RenderTier.legacy);
      expect(legacyBack.configHash, legacyArm.configHash,
          reason: 'legacy 回滚配置往返必须保哈希（R32）');
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
        LayerSplitter(layerCount: 3).split(img, HeuristicDepthEstimator().estimate(img));
    final flat = flatScene();
    final flatLayers = LayerSplitter(layerCount: 3)
        .split(flat, HeuristicDepthEstimator().estimate(flat));

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
      // 往返用新默认档（standard）：quality 段被省略、缺键兜底同源 ⇒ 无损（R32）。
      final cfg = tcfg(
          tone: const ScreenToneParams(mode: 'cross', spacingPx: 10),
          tier: RenderTier.standard);
      final j = _decodeJson(cfg.toJsonString());
      expect(j['screenTone']['mode'], 'cross');
      expect(EffectConfig.fromJson(j).configHash, cfg.configHash);
      // R32：整套旧默认（legacy/floyd/false）现在写出 quality 段并可无损往返
      //（旧断言「整段省略」等于把回滚意图丢掉，本轮改为钉住可持久化）。
      final legacyArm =
          tcfg(tone: const ScreenToneParams(mode: 'cross', spacingPx: 10))
            ..quality = const QualityParams(
                dither: false, ditherMode: 'floyd', tier: RenderTier.legacy);
      expect(
          legacyArm.toJson()['quality'],
          {'dither': false, 'ditherMode': 'floyd', 'tier': 'legacy'});
      final legacyBack =
          EffectConfig.fromJson(_decodeJson(legacyArm.toJsonString()));
      expect(legacyBack.quality.tier, RenderTier.legacy);
      expect(legacyBack.configHash, legacyArm.configHash,
          reason: 'legacy 回滚配置往返必须保哈希（R32）');
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
        LayerSplitter(layerCount: 3).split(img, HeuristicDepthEstimator().estimate(img));

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
        LayerSplitter(layerCount: 3).split(img, HeuristicDepthEstimator().estimate(img));

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
      // Task 3.4（R17）改判：旧断言 s.$2 > l.$2 依赖「standard 与 legacy 包络
      // 相同，只是边缘多过渡带」。standard 包络现为整流 snapWave × sin(π·ph)
      // 窗——负瓣（ph≈0.55~1）env=0，环整体落墨更少，这是规格要的快起慢落，
      // 不是 AA 缺失。过渡带判据改钉「弱像素只在 standard 存在」：l.$3 恒 0，
      // s.$3 显著大于 l.$3，且 standard 仍有实际落墨（s.$2 > 0）。
      expect(s.$2, greaterThan(0), reason: 'standard 不该整帧空墨');
      expect(s.$3, greaterThan(l.$3), reason: 'standard 边缘应扩出过渡带弱像素');
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
      final rings = const ImpactRingsParams(
          rings: 7, thicknessPx: 6.0, mode: 'shock', pulses: 3);
      // 往返用新默认档（standard）：quality 段省略、缺键兜底同源 ⇒ 无损（R32）。
      final cfg = rcfg(rings: rings, tier: RenderTier.standard);
      final j = _decodeJson(cfg.toJsonString());
      expect(j['impactRings']['rings'], 7);
      expect(j['impactRings']['mode'], 'shock');
      expect(EffectConfig.fromJson(j).configHash, cfg.configHash);
      // R32：旧默认整套（legacy/floyd/false）现在写出段且无损往返。
      final legacyArm = rcfg(rings: rings)
        ..quality = const QualityParams(
            dither: false, ditherMode: 'floyd', tier: RenderTier.legacy);
      expect(
          legacyArm.toJson()['quality'],
          {'dither': false, 'ditherMode': 'floyd', 'tier': 'legacy'});
      final legacyBack =
          EffectConfig.fromJson(_decodeJson(legacyArm.toJsonString()));
      expect(legacyBack.quality.tier, RenderTier.legacy);
      expect(legacyBack.configHash, legacyArm.configHash,
          reason: 'legacy 回滚配置往返必须保哈希（R32）');
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
        LayerSplitter(layerCount: 3).split(img, HeuristicDepthEstimator().estimate(img));

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
      final brush = const BrushStreakParams(
          streaks: 5, thicknessPx: 9.5, gapFreq: 0.2, angleDeg: -20);
      // 往返用新默认档（standard）：quality 段省略、缺键兜底同源 ⇒ 无损（R32）。
      final cfg = bcfg(brush: brush, tier: RenderTier.standard);
      final j = _decodeJson(cfg.toJsonString());
      expect(j['brushStreak']['streaks'], 5);
      expect(j['brushStreak']['angleDeg'], -20);
      expect(EffectConfig.fromJson(j).configHash, cfg.configHash);
      // R32：旧默认整套（legacy/floyd/false）现在写出段且无损往返。
      final legacyArm = bcfg(brush: brush)
        ..quality = const QualityParams(
            dither: false, ditherMode: 'floyd', tier: RenderTier.legacy);
      expect(
          legacyArm.toJson()['quality'],
          {'dither': false, 'ditherMode': 'floyd', 'tier': 'legacy'});
      final legacyBack =
          EffectConfig.fromJson(_decodeJson(legacyArm.toJsonString()));
      expect(legacyBack.quality.tier, RenderTier.legacy);
      expect(legacyBack.configHash, legacyArm.configHash,
          reason: 'legacy 回滚配置往返必须保哈希（R32）');
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
        LayerSplitter(layerCount: 3).split(img, HeuristicDepthEstimator().estimate(img));

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
      // R32/R26：往返用新默认档（standard ⇒ quality 段省略）配置，缺键兜底与
      // 省略哨兵同源 ⇒ 逐字段无损；混档（tier=legacy 且其余为新默认）现在也
      // 写出 tier 键、同样无损，见下方 mixedLegacy。
      final f = flame(
          const FlameParams(tongues: 9, hot: 'ff0000', cold: '0000ff'),
          RenderTier.standard);
      final jf = _decodeJson(f.toJsonString());
      expect(jf['flame']['tongues'], 9);
      expect(jf['flame']['hot'], 'ff0000');
      expect(EffectConfig.fromJson(jf).configHash, f.configHash);

      final s = smoke(const SmokeParams(puffs: 3, color: '112233'), RenderTier.standard);
      final js = _decodeJson(s.toJsonString());
      expect(js['smoke']['puffs'], 3);
      expect(EffectConfig.fromJson(js).configHash, s.configHash);

      final b = bubbles(const BubblesParams(count: 7, wobblePx: 3.0), RenderTier.standard);
      final jb = _decodeJson(b.toJsonString());
      expect(jb['bubbles']['count'], 7);
      expect(EffectConfig.fromJson(jb).configHash, b.configHash);

      final l = leaves(const LeavesParams(count: 5, palette: 'summer'), RenderTier.standard);
      final jl = _decodeJson(l.toJsonString());
      expect(jl['leaves']['palette'], 'summer');
      expect(EffectConfig.fromJson(jl).configHash, l.configHash);

      final m = meteors(const MeteorsParams(count: 3, angleDeg: 60), RenderTier.standard);
      final jm = _decodeJson(m.toJsonString());
      expect(jm['meteors']['angleDeg'], 60);
      expect(EffectConfig.fromJson(jm).configHash, m.configHash);

      // R32 反向半：整套旧默认（legacy/floyd/false）不再命中省略哨兵 ⇒ 写出
      // quality 段，并且**无损往返**（R24 的哨兵设计下它整段省略、重解析成
      // standard，回滚意图在一次 JSON 往返里静默消失）。
      final legacySentinel = smoke(const SmokeParams(puffs: 3, color: '112233'))
        ..quality = const QualityParams(
            dither: false, ditherMode: 'floyd', tier: RenderTier.legacy);
      expect(
          legacySentinel.toJson()['quality'],
          {'dither': false, 'ditherMode': 'floyd', 'tier': 'legacy'});
      final legacyBack =
          EffectConfig.fromJson(_decodeJson(legacySentinel.toJsonString()));
      expect(legacyBack.quality.tier, RenderTier.legacy);
      expect(legacyBack.quality.ditherMode, 'floyd');
      expect(legacyBack.configHash, legacySentinel.configHash,
          reason: 'v1.2 回滚配置往返必须保哈希（R32）');
      // 混档（tier=legacy 而其余为新默认）同样是可表达、可往返的形状。
      final mixedLegacy = smoke(const SmokeParams(puffs: 3, color: '112233'));
      expect(mixedLegacy.toJson()['quality'], {'dither': true, 'tier': 'legacy'});
      expect(EffectConfig.fromJson(_decodeJson(mixedLegacy.toJsonString()))
          .configHash, mixedLegacy.configHash);

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
        LayerSplitter(layerCount: 3).split(img, HeuristicDepthEstimator().estimate(img));

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
    final plain = EffectConfig(
        fps: 8, durationSec: 2, seed: 41, effects: const []);
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
      // R32/R26：往返用新默认档（standard）配置 ⇒ quality 段省略、缺键兜底
      // 与哨兵同源，往返逐字段无损。
      final cfg = of([EffectKind.moodScript],
          mood:
              const MoodScriptParams(mood: 'eerie', cycles: 3, strength: 0.4),
          tier: RenderTier.standard);
      final j = _decodeJson(cfg.toJsonString());
      expect(j['moodScript']['mood'], 'eerie');
      expect(j['moodScript']['cycles'], 3);
      expect(j['moodScript']['strength'], 0.4);
      final back = EffectConfig.fromJson(j);
      expect(back.configHash, cfg.configHash);
      expect(back.warnings, isEmpty);
      // 默认档配置不再写出 quality 键（R32 的省略半）。
      expect(j.containsKey('quality'), isFalse);

      // 哨兵形状路径（R32 改写）：整套旧默认（legacy/floyd/false）现在**写出**
      // quality 段并无损往返。旧断言是「整段省略」，而省略意味着新默认 ⇒
      // 回滚配置自己都会被读成 standard，本轮把它改成钉「回滚可持久化」。
      final legacySentinel = of([EffectKind.moodScript],
          mood: const MoodScriptParams(mood: 'eerie', cycles: 3, strength: 0.4))
        ..quality = const QualityParams(
            dither: false, ditherMode: 'floyd', tier: RenderTier.legacy);
      expect(
          legacySentinel.toJson()['quality'],
          {'dither': false, 'ditherMode': 'floyd', 'tier': 'legacy'});
      final legacyBack =
          EffectConfig.fromJson(_decodeJson(legacySentinel.toJsonString()));
      expect(legacyBack.quality.tier, RenderTier.legacy);
      expect(legacyBack.configHash, legacySentinel.configHash,
          reason: 'v1.2 回滚配置往返必须保哈希（R32）');

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

  // ---- Task 2.1：focusLines / impactRings 自动锚定到内容焦点 ----
  group('Task 2.1: content-aware focal for focusLines/impactRings', () {
    const size = 96;

    // 高对比横向渐变渲染面（70..220），让黑/白落墨处处可测。
    RgbaImage surface() {
      final img = RgbaImage(width: size, height: size);
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final lum = (70 + x * 150 ~/ 95).clamp(0, 255);
          img.setPixel(x, y, lum, lum, lum);
        }
      }
      return img;
    }

    // 白纸 + 左上角墨团：analyze 应给出靠近 (0.25,0.25) 的最高权重 anchor。
    RgbaImage blobPage() {
      final img = RgbaImage(width: size, height: size);
      for (var i = 0; i < img.pixelCount; i++) {
        img.setPixel(i % size, i ~/ size, 240, 240, 240);
      }
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final dx = x - 24, dy = y - 24;
          if (dx * dx + dy * dy <= 10 * 10) img.setPixel(x, y, 20, 20, 20);
        }
      }
      return img;
    }

    final surfaceImg = surface();
    final surfaceLayers = LayerSplitter(layerCount: 3)
        .split(surfaceImg, HeuristicDepthEstimator().estimate(surfaceImg));

    final map = const SaliencyAnalyzer(workScale: 1.0).analyze(blobPage());

    // 归一化点 → 像素计数半径内相对 base 的“变暗/变亮”像素数。
    int darkerNear(RgbaImage f, RgbaImage base, double nx, double ny, int r) {
      final cx = nx * size, cy = ny * size;
      var n = 0;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final dx = x + 0.5 - cx, dy = y + 0.5 - cy;
          if (dx * dx + dy * dy > r * r) continue;
          final i = y * size + x;
          if (f.luminance(i) < base.luminance(i)) n++;
        }
      }
      return n;
    }

    int brighterNear(RgbaImage f, RgbaImage base, double nx, double ny, int r) {
      final cx = nx * size, cy = ny * size;
      var n = 0;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final dx = x + 0.5 - cx, dy = y + 0.5 - cy;
          if (dx * dx + dy * dy > r * r) continue;
          final i = y * size + x;
          if (f.luminance(i) > base.luminance(i)) n++;
        }
      }
      return n;
    }

    // anchor 靠近左上角，明确偏离画幅中心。
    test('fixture: blob page yields a top-left highest-weight anchor', () {
      expect(map.anchors, isNotEmpty);
      expect(map.anchors.first.nx, lessThan(0.4));
      expect(map.anchors.first.ny, lessThan(0.4));
    });

    RgbaImage baseAt(EffectConfig plain, double t) =>
        FrameCompositor(surfaceLayers, surfaceImg, plain).renderFrame(t);

    EffectConfig plainFl() => EffectConfig(
        effects: const [], fps: 8, durationSec: 2, seed: 41);
    EffectConfig flCfg({FocusLinesParams focus = const FocusLinesParams(),
      bool contentAware = false}) =>
        EffectConfig(
            effects: const [EffectKind.focusLines],
            fps: 8,
            durationSec: 2,
            seed: 41,
            contentAware: contentAware,
            focusLines: focus);

    const flProbe = FocusLinesParams(innerFrac: 0.22, lines: 60);

    RgbaImage drawFl(EffectConfig cfg, double t, {AnchorMap? anchors}) =>
        FrameCompositor(surfaceLayers, surfaceImg, cfg, anchors: anchors)
            .renderFrame(t);

    test('focusLines 追踪主体而非画幅中心', () {
      const t = 0.5;
      final base = baseAt(plainFl(), t);
      final ax = map.anchors.first.nx, ay = map.anchors.first.ny;
      final on = drawFl(flCfg(focus: flProbe, contentAware: true), t,
          anchors: map); // 焦点 → anchor，anchor 处留空圈（不落墨）
      final off =
          drawFl(flCfg(focus: flProbe), t, anchors: map); // 焦点 → 中心（默认）

      // anchor 处：ON 是留空圈（几乎不变暗），OFF 落墨（明显变暗）。
      expect(darkerNear(off, base, ax, ay, 8), greaterThan(20),
          reason: '焦点在中心时 anchor 邻域应被集中线覆盖');
      expect(darkerNear(on, base, ax, ay, 8), lessThan(4),
          reason: '焦点移到 anchor 后其邻域应成为留空圈');
      // 中心处：ON 落墨，OFF 是留空圈。
      expect(darkerNear(on, base, 0.5, 0.45, 8), greaterThan(20),
          reason: '焦点离开后中心应被集中线覆盖');
      expect(darkerNear(off, base, 0.5, 0.45, 8), lessThan(4),
          reason: '焦点在中心时其邻域应是留空圈');
    });

    RgbaImage drawRc(EffectConfig cfg, double t, {AnchorMap? anchors}) =>
        FrameCompositor(surfaceLayers, surfaceImg, cfg, anchors: anchors)
            .renderFrame(t);

    EffectConfig plainRc() => EffectConfig(
        effects: const [], fps: 8, durationSec: 2, seed: 41);
    EffectConfig rcCfg({ImpactRingsParams rings = const ImpactRingsParams(),
      bool contentAware = false}) =>
        EffectConfig(
            effects: const [EffectKind.impactRings],
            fps: 8,
            durationSec: 2,
            seed: 41,
            contentAware: contentAware,
            impactRings: rings);

    const rcProbe =
        ImpactRingsParams(innerFrac: 0.2, outerFrac: 0.95, rings: 4);

    test('impactRings 追踪主体而非画幅中心', () {
      final ax = map.anchors.first.nx, ay = map.anchors.first.ny;
      // 环随时间外扩，跨多帧累计落墨来定位焦点留空圈。
      var offAtAnchor = 0, onAtAnchor = 0, offAtCenter = 0, onAtCenter = 0;
      for (final t in [0.1, 0.3, 0.5, 0.7, 0.9]) {
        final base = baseAt(plainRc(), t);
        final on = drawRc(rcCfg(rings: rcProbe, contentAware: true), t,
            anchors: map);
        final off = drawRc(rcCfg(rings: rcProbe), t, anchors: map);
        onAtAnchor += brighterNear(on, base, ax, ay, 6);
        offAtAnchor += brighterNear(off, base, ax, ay, 6);
        onAtCenter += brighterNear(on, base, 0.5, 0.5, 6);
        offAtCenter += brighterNear(off, base, 0.5, 0.5, 6);
      }
      expect(offAtAnchor, greaterThan(20),
          reason: '焦点在中心时 anchor 邻域应有环经过');
      expect(onAtAnchor, lessThan(offAtAnchor ~/ 4),
          reason: '焦点移到 anchor 后其邻域应留空');
      expect(onAtCenter, greaterThan(20),
          reason: '焦点离开后中心邻域应有环经过');
      expect(offAtCenter, lessThan(onAtCenter ~/ 4),
          reason: '焦点在中心时其邻域应留空');
    });

    test('contentAware off 与无 anchor 逐字节一致（回归基线）', () {
      const t = 0.5;
      final withMap =
          drawFl(flCfg(focus: flProbe), t, anchors: map); // off（默认 contentAware=false）
      final classic = drawFl(flCfg(focus: flProbe), t); // 完全不传 anchors
      expect(withMap.data, equals(classic.data),
          reason: '焦点未消费时 map 传入与否必须逐字节相同');
      final ringWith = drawRc(rcCfg(rings: rcProbe), t, anchors: map);
      final ringClassic = drawRc(rcCfg(rings: rcProbe), t);
      expect(ringWith.data, equals(ringClassic.data));
    });

    test('显式非默认 focal 覆盖 anchor', () {
      const t = 0.5;
      final base = baseAt(plainFl(), t);
      const pinned = FocusLinesParams(focalX: 0.8, innerFrac: 0.22, lines: 60);
      final pinnedOnCa =
          drawFl(flCfg(focus: pinned, contentAware: true), t, anchors: map);
      final pinnedNoCa = drawFl(flCfg(focus: pinned), t, anchors: map);
      // caller pinned → 走 params 路径，与 contentAware 无关，逐字节一致。
      expect(pinnedOnCa.data, equals(pinnedNoCa.data));
      // 焦点落在 (0.8,0.45)：该处应是留空圈；anchor 处应落墨（焦点未取 anchor）。
      expect(darkerNear(pinnedOnCa, base, 0.8, 0.45, 8), lessThan(4),
          reason: 'pin 焦点处应留空');
      expect(
          darkerNear(pinnedOnCa, base, map.anchors.first.nx, map.anchors.first.ny, 8),
          greaterThan(20),
          reason: 'anchor 不该成为焦点');
    });

    test('空 anchor 回落到默认中心且不抛异常', () {
      const t = 0.5;
      final empty = AnchorMap(size, size, Float64List(size * size),
          const PixelRect(0, 0, size, size), const [], const []);
      final onEmpty =
          drawFl(flCfg(focus: flProbe, contentAware: true), t, anchors: empty);
      final classic = drawFl(flCfg(focus: flProbe), t);
      expect(onEmpty.data, equals(classic.data),
          reason: '空 anchors 必须回落到 params 默认焦点');
      final ringEmpty =
          drawRc(rcCfg(rings: rcProbe, contentAware: true), t, anchors: empty);
      expect(ringEmpty.data, equals(drawRc(rcCfg(rings: rcProbe), t).data));
    });

    test('未新增 focalAuto 字段：默认 configHash 锁定、序列化无该键', () {
      expect(EffectConfig().configHash, '-477687d5e8bded5f',
          reason: '默认指纹不得移动（Task 3.7 门禁）');
      final jsonFl = convert.jsonEncode(flCfg(focus: const FocusLinesParams(),
          contentAware: true).toJson());
      final jsonRc = convert.jsonEncode(rcCfg(rings: const ImpactRingsParams(),
          contentAware: true).toJson());
      expect(jsonFl.contains('focalAuto'), isFalse);
      expect(jsonRc.contains('focalAuto'), isFalse);
    });

    test('worker/pipeline 路径：contentAware on 确定且 on!=off（消费 anchor）',
        () async {
      final bytes = Uint8List.fromList(ImageIO.encodePngFrame(blobPage()));
      Map<String, dynamic> cfgJson(bool ca) => <String, dynamic>{
            'effects': ['focusLines'],
            'fps': 8,
            'durationSec': 1.0,
            'maxDimension': 96,
            'outputFormat': 'gif',
            'seed': 7,
            'focusLines': {'innerFrac': 0.22, 'lines': 60},
            // 3.6b 前提修复：缺键自 R30/R36 起兜底为 true，「不写 = off」不再
            // 成立 ⇒ off 臂必须**显式写** false，本条 on!=off 的对照才仍是 on
            // vs off（断言一字未动）。
            'contentAware': ca,
          };
      final on = EffectConfig.fromJson(cfgJson(true));
      final off = EffectConfig.fromJson(cfgJson(false));
      final a = (await MotionPipeline(on).processBytes(input: bytes)).gifBytes!;
      final b = (await MotionPipeline(on).processBytes(input: bytes)).gifBytes!;
      final o = (await MotionPipeline(off).processBytes(input: bytes)).gifBytes!;
      expect(a, equals(b), reason: 'contentAware on 双跑逐字节确定（真实 worker 路径）');
      expect(a, isNot(equals(o)),
          reason: 'focusLines 现消费 anchor，on 应区别于 off');
    });
  });

  group('v1.4 Task 3.6：默认档 standard + sierra 抖动（R24/R26）', () {
    test('QualityParams 新默认 = dither/sierra/standard，哨兵与新默认锁步（R32）',
        () {
      // Step 1（RED）：翻默认前此三条必红。
      const q = QualityParams();
      expect(q.dither, isTrue);
      expect(q.ditherMode, 'sierra');
      expect(q.tier, RenderTier.standard);
      // 不动的字段（R24 只点名三键）。
      expect(q.mipLevels, 2);
      expect(q.edgeStretchPx, 6);
      // R32：省略哨兵与构造默认同源 ⇒ 新默认命中 isDefault ⇒ 默认 JSON 不写
      // quality 段（默认不写 = 缺键兜底 = 构造默认，三者同一个对象，往返无损）。
      // 旧 R24 设计在这里断言 isFalse（哨兵留在 legacy/floyd/false），那正是
      // 「完整 v1.2 回滚配置命中哨兵、一次往返被抹成新默认」的缺陷源头。
      expect(q.isDefault, isTrue);
      // 反向：旧默认组合不再命中哨兵（legacy 必须能显式写进 JSON）。
      expect(
          const QualityParams(
                  dither: false, ditherMode: 'floyd', tier: RenderTier.legacy)
              .isDefault,
          isFalse,
          reason: 'v1.2 回滚配置非默认 ⇒ 整段写出（R32）');
    });

    test('默认配置不写 quality 段；显式 legacy 回滚写出 tier:legacy（R32）', () {
      expect(EffectConfig().toJson().containsKey('quality'), isFalse,
          reason: '新默认命中省略哨兵 ⇒ 默认 JSON 不带 quality 键（R32）');
      final legacy = EffectConfig(
          quality: const QualityParams(
              dither: false, ditherMode: 'floyd', tier: RenderTier.legacy));
      expect(
          legacy.toJson()['quality'],
          {'dither': false, 'ditherMode': 'floyd', 'tier': 'legacy'},
          reason: '反向半：显式 legacy 回滚必须整段写出，否则 legacy 从 JSON 不可达');
      // 两半合起来才是「无损」：默认与回滚各自往返回自己（见 R32 组门）。
      expect(EffectConfig.fromJson(EffectConfig().toJson()).configHash,
          EffectConfig().configHash);
      expect(EffectConfig.fromJson(legacy.toJson()).configHash,
          legacy.configHash);
    });

    test('R24 lockstep 不变量：quality-less JSON == 构造默认；往返哈希稳定', () {
      // 「同一份 JSON 只有一种渲染行为」——缺键兜底与构造默认必须逐字段相等，
      // 否则 configHash 不再标识渲染路径（哈希即身份）。
      final back = EffectConfig.fromJson({'effects': ['rain']}).quality;
      const def = QualityParams();
      expect(back.dither, def.dither);
      expect(back.ditherMode, def.ditherMode);
      expect(back.tier, def.tier);
      expect(back.mipLevels, def.mipLevels);
      expect(back.edgeStretchPx, def.edgeStretchPx);

      final x = EffectConfig();
      final j1 = _decodeJson(x.toJsonString());
      final y = EffectConfig.fromJson(j1);
      expect(y.configHash, x.configHash);
      expect(_decodeJson(y.toJsonString()), j1,
          reason: 'toJson→fromJson→toJson 逐字节稳定（缺键兜底=构造默认）');

      // 显式降级键仍被尊重（R24：tier 走 containsKey 而非 parse(null) 暗兜）。
      expect(
          EffectConfig.fromJson({
            'quality': {'tier': 'legacy'}
          }).quality.tier,
          RenderTier.legacy);
      expect(
          EffectConfig.fromJson({
            'quality': {'ditherMode': 'floyd'}
          }).quality.ditherMode,
          'floyd');
      expect(
          EffectConfig.fromJson({
            'quality': {'dither': false}
          }).quality.dither,
          isFalse);
    });

    test('sierra 默认真的落到编码轴：fromConfig 等于显式 standard+sierra', () {
      RgbaImage grad() {
        final img = RgbaImage(width: 40, height: 24);
        for (var y = 0; y < 24; y++) {
          for (var x = 0; x < 40; x++) {
            final v = x * 255 ~/ 39;
            img.setPixel(x, y, v, 255 - v, 128);
          }
        }
        return img;
      }

      Uint8List encode(StreamingGifBuilder b) {
        b.addFrame(grad());
        return Uint8List.fromList(b.finish());
      }

      final fromCfg =
          encode(StreamingGifBuilder.fromConfig(EffectConfig(), 40, 24));
      final explicit = encode(StreamingGifBuilder(40, 24,
          fps: 24,
          dither: true,
          ditherMode: 'sierra',
          tier: RenderTier.standard));
      final floyd = encode(StreamingGifBuilder(40, 24,
          fps: 24,
          dither: true,
          ditherMode: 'floyd',
          tier: RenderTier.standard));
      expect(fromCfg, equals(explicit),
          reason: '默认 quality（standard+sierra+dither）必须与显式同参逐字节同板同码');
      expect(fromCfg, isNot(equals(floyd)),
          reason: '默认若仍走 floyd/无抖动，sierra 默认就没落地');
      // 可解码性不破（编码轴是行为门，不是只读字段的摆设）。
      expect(pkg.GifDecoder(fromCfg).info!.numFrames, 1);
    });

    test('paletteProbeIndices：6 帧均匀铺开、含首末、单调、小 n 去重后仍 ≥1（R27）',
        () {
      // 形状门（§2.4 的「管线级断言」）：探针集合含 0 与 n-1、索引单调不降、
      // 小 n 的重复下标去重后仍覆盖首末且 ≥1。
      List<int> dedup(List<int> ks) {
        final seen = <int>{};
        final out = <int>[];
        for (final k in ks) {
          if (seen.add(k)) out.add(k);
        }
        return out;
      }

      expect(dedup(paletteProbeIndices(1)), [0]);
      expect(dedup(paletteProbeIndices(2)), [0, 1]);
      final p8 = paletteProbeIndices(8);
      for (var i = 1; i < p8.length; i++) {
        expect(p8[i] >= p8[i - 1], isTrue, reason: '索引必须单调不降');
        expect(p8[i] >= 0 && p8[i] < 8, isTrue, reason: '下标越界：$p8');
      }
      expect(p8.first, 0);
      expect(p8.last, 7, reason: '末帧必须被探针覆盖');
      expect(dedup(paletteProbeIndices(96)).length, 6, reason: '常规 n 下恰 6 帧');
      // 判别式：n=8 时旧 3 探针集合是 {0, 4, 7}；新集合必须包含至少一个
      // 旧集合之外的帧（否则 3→6 只是口号）。
      final old3 = {0, 8 ~/ 2, 7};
      expect(dedup(p8).toSet().difference(old3), isNotEmpty,
          reason: '6 探针必须比旧 3 探针真的多覆盖帧');
      // 确定性：纯函数两次调用逐字节一致（无 Random/时钟/跨帧状态）。
      expect(paletteProbeIndices(96), paletteProbeIndices(96));
    });

    test('探针 3→6 的调色板行为门：只在中段帧出现的亮墨色进得了 256 色板', () {
      // §6.4 目的本身：加粗墨线（饱和亮色）只出现在某一帧时，旧 3 探针
      // {0, n~/2, n-1} 采不到它 → 被 256 色量化吞掉；6 探针采到 → 进板。
      // 这是双向判别：同一场景，3 探针（旧）必红、6 探针（新）必绿。
      const n = 8, wd = 24, ht = 24;
      const inkR = 255, inkG = 40, inkB = 0; // 渐变底里没有的饱和墨橙
      // 底色：中性灰度渐变（R==G==B），与墨橙相距甚远。
      RgbaImage base() {
        final img = RgbaImage(width: wd, height: ht);
        for (var y = 0; y < ht; y++) {
          for (var x = 0; x < wd; x++) {
            final v = 40 + x * 160 ~/ (wd - 1);
            img.setPixel(x, y, v, v, v);
          }
        }
        return img;
      }

      final frames = [for (var k = 0; k < n; k++) base()];
      // 亮色只出现在帧 3：n=8 时它不在旧 3 探针 {0,4,7}，在 6 探针集合内。
      for (var y = 6; y < 18; y++) {
        for (var x = 6; x < 18; x++) {
          frames[3].setPixel(x, y, inkR, inkG, inkB);
        }
      }

      Uint8List encode(List<int> probes) {
        final b = StreamingGifBuilder(wd, ht,
            fps: 8, dither: false, tier: RenderTier.standard);
        b.primePalette([for (final k in probes) frames[k]]);
        for (final f in frames) {
          b.addFrame(f);
        }
        return Uint8List.fromList(b.finish());
      }

      // dither=false：量化是纯最近色 ⇒ 「板上有没有这个色」直接可读，
      // 抖动扩散与探针覆盖是正交的两件事，这里只钉后者。
      final six = encode(paletteProbeIndices(n));
      final px6 = pkg.GifDecoder(six).decodeFrame(3)!.getPixel(12, 12);
      expect((px6.r.toInt() - inkR).abs(), lessThanOrEqualTo(48),
          reason: '6 探针采到帧 3，墨橙应几乎原色进板：$px6');
      expect((px6.g.toInt() - inkG).abs(), lessThanOrEqualTo(48));
      expect((px6.b.toInt() - inkB).abs(), lessThanOrEqualTo(48));

      final three = encode([0, n ~/ 2, n - 1]); // 旧 3 探针集合
      final px3 = pkg.GifDecoder(three).decodeFrame(3)!.getPixel(12, 12);
      expect((px3.r.toInt() - inkR).abs() + (px3.g.toInt() - inkG).abs(),
          greaterThan(96),
          reason: '旧 3 探针采不到帧 3，墨橙必须被量化吞掉（负向判别）');

      // 确定性：同探针集两跑逐字节一致。
      expect(encode(paletteProbeIndices(n)), equals(six));
    });

    test('管线接线行为门：默认档 GIF 字节 == 六探针重编码，且 != 旧三探针编码（R27）',
        () async {
      // 上面两条钉的是「探针集合本身」；本条钉 **管线真的把这份集合喂给了
      // primePalette**：把 MotionPipeline 真实渲染出的帧序列取回来，用同一份
      // StreamingGifBuilder.fromConfig 分别按 6 探针 / 旧 3 探针重编码，
      // 要求管线产物与 6 探针逐字节相同、与 3 探针确实不同。
      // ⇒ 谁把 pipeline.dart 的探针循环改回 [0, n~/2, n-1]，这条立刻红。
      final tmp = Directory.systemTemp.createTempSync('cm_probe_wiring');
      try {
        final inPath = '${tmp.path}/in.png';
        File(inPath).writeAsBytesSync(_pngEncode(_gradientImage(96, 72)));
        // 12 帧：6 探针 = {0,2,4,7,9,11}，旧 3 探针 = {0,6,11} —— 两者互差四帧。
        final cfg = EffectConfig(
            fps: 6,
            durationSec: 2,
            maxDimension: 96,
            outputFormat: OutputFormat.gif);
        final frames = <int, RgbaImage>{};
        final r = await MotionPipeline(cfg,
                parallel: 1, onFrame: (i, png) => frames[i] = ImageIO.decode(png))
            .processFile(inPath, '${tmp.path}/out');
        final n = cfg.frameCount;
        expect(n, 12);
        expect(frames.keys.toSet(), {for (var k = 0; k < n; k++) k},
            reason: '帧流回调必须覆盖全部帧');
        final wd = frames[0]!.width, ht = frames[0]!.height;

        Uint8List reencode(List<int> probes) {
          // 与 pipeline.dart 同一构造入口 ⇒ 唯一变量就是探针集合。
          final b = StreamingGifBuilder.fromConfig(cfg, wd, ht);
          b.primePalette([for (final k in probes) frames[k]!]);
          for (var k = 0; k < n; k++) {
            b.addFrame(frames[k]!);
          }
          return Uint8List.fromList(b.finish());
        }

        final six = reencode(paletteProbeIndices(n));
        final three = reencode([0, n ~/ 2, n - 1]);
        // 判别力前提：这个场景对探针集合必须真的敏感，否则「等于 six」是巧合。
        expect(three, isNot(equals(six)),
            reason: '场景对 3/6 探针不敏感 ⇒ 本门失去判别力，换场景');
        expect(File(r.outputGif).readAsBytesSync(), equals(six),
            reason: '管线索引进板的帧集合必须就是 paletteProbeIndices(n)');
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  // ---------- Task 3.6 修复轮：R32 序列化哨兵锁步 ----------
  //
  // 「等于默认就不写」这个条件序列化习语，只有在
  //   省略哨兵 == 缺键兜底 == 构造默认
  // 三者锁步时才成立。R24 只翻了后两组、把哨兵留在 legacy/floyd/false，于是
  // JSON 双向有损：
  //   1. 混档配置（如 tier=legacy 而其余为新默认）在 legacy 哨兵处被省略 tier
  //      ⇒ 重解析成 standard ⇒ configHash 与渲染字节一起变；
  //   2. 更严重：**完整的 v1.2 回滚配置**（legacy/floyd/false/2/6）恰好命中
  //      isDefault ⇒ 整段 quality 不写 ⇒ 重解析成新默认 standard/sierra/true，
  //      一次 toJson→fromJson（服务端 API、预设再导出、withEffect 链）就静默
  //      抹掉回滚意图，RenderTier.legacy 从 JSON 根本不可持久化。
  // R32 把哨兵翻到新默认（tier 默认 standard、ditherMode 默认 sierra、
  // dither 默认 true；mipLevels 2 / edgeStretchPx 6 本来就是自己的默认），
  // 于是「默认 ⇒ 整段省略」「回滚 ⇒ 整段写出且逐键无损」。下面三组门在修复前
  // 必红（见报告的红输出），修复后必绿。
  group('v1.4 Task 3.6 修复轮 R32：哨兵=兜底=构造默认，quality JSON 双向无损', () {
    // 逐键默认（与 QualityParams 构造默认一一对应，故意写死字面量：
    // 这里若与实现漂移，本组的门就该红，而不是跟着实现走）。
    const defDither = true;
    const defDitherMode = 'sierra';
    const defTier = RenderTier.standard;
    const defMip = 2;
    const defStretch = 6;

    const cases = <String, QualityParams>{
      // 新默认：命中哨兵 ⇒ 整段省略，重解析仍等于构造默认。
      'default(standard/sierra/dither)':
          QualityParams(dither: true, ditherMode: 'sierra', tier: defTier),
      // 完整 v1.2/v1.3 回滚配置：必须写出整段（R32 的核心正例）。
      'v1.2 rollback(legacy/floyd/no-dither)':
          QualityParams(
              dither: false, ditherMode: 'floyd', tier: RenderTier.legacy),
      // 混档三例：旧实现（哨兵停在 legacy/floyd/false）全部有损。
      'mixed legacy+sierra':
          QualityParams(dither: true, ditherMode: 'sierra', tier: RenderTier.legacy),
      'mixed standard+floyd+no-dither':
          QualityParams(dither: false, ditherMode: 'floyd', tier: RenderTier.standard),
      'mixed standard+floyd':
          QualityParams(dither: true, ditherMode: 'floyd', tier: RenderTier.standard),
      'mixed standard/sierra/no-dither':
          QualityParams(dither: false, ditherMode: 'sierra', tier: RenderTier.standard),
      // 连 mipLevels/edgeStretchPx 一起降级：每键只在自己等于默认时省略。
      'rollback + mip1 + stretch0': QualityParams(
          dither: false,
          ditherMode: 'floyd',
          tier: RenderTier.legacy,
          mipLevels: 1,
          edgeStretchPx: 0),
      // 只动哨兵邻键（dither 恒写、tier/ditherMode 条件写）的边界。
      'default but mip1': QualityParams(mipLevels: 1),
    };

    for (final e in cases.entries) {
      test('R32 往返无损（逐字段 + configHash）：${e.key}', () {
        final q = e.value;
        final cfg = EffectConfig(quality: q);
        final j = cfg.toJson();
        // 整段省略 ⟺ isDefault（两者不得各判一次）。
        expect(j.containsKey('quality'), isNot(q.isDefault),
            reason: '省略判定必须就是 toJson 的省略条件：$q');
        final seg = j['quality'] as Map?;
        if (seg != null) {
          // dither 是布尔键 ⇒ 段一旦写出就恒写（默认值 $defDither 由本条锚定，
          // 不允许「缺 dither 键」这种要靠兜底才能读回的形状）。
          expect(seg.containsKey('dither'), isTrue, reason: 'dither 恒写');
          expect(seg['dither'], q.dither);
          expect(defDither, isTrue, reason: 'R32 锚点：dither 的默认值就是 true');
          // 逐键：仅当该键等于**自己的默认**才省略。
          expect(seg.containsKey('ditherMode'), q.ditherMode != defDitherMode,
              reason: 'ditherMode 省略条件漂移：${q.ditherMode}');
          expect(seg.containsKey('tier'), q.tier != defTier,
              reason: 'tier 省略条件漂移：${q.tier.name}');
          expect(seg.containsKey('mipLevels'), q.mipLevels != defMip);
          expect(seg.containsKey('edgeStretchPx'), q.edgeStretchPx != defStretch);
        }
        // 写→读必须逐字段复原（哈希即身份）。
        final back = EffectConfig.fromJson(_decodeJson(cfg.toJsonString()));
        expect(back.quality.dither, q.dither, reason: 'dither 往返丢失');
        expect(back.quality.ditherMode, q.ditherMode, reason: 'ditherMode 往返丢失');
        expect(back.quality.tier, q.tier, reason: 'tier 往返丢失（R32 主案）');
        expect(back.quality.mipLevels, q.mipLevels);
        expect(back.quality.edgeStretchPx, q.edgeStretchPx);
        expect(back.configHash, cfg.configHash,
            reason: '一次 JSON 往返就改 configHash = 同一份 JSON 有两种渲染行为');
        expect(back.toJson(), j, reason: '往返后序列化形状必须不动');
      });
    }

    test('R32 形状：默认整段省略，显式 legacy 回滚写出 tier:legacy 且仍可解析', () {
      expect(const QualityParams().isDefault, isTrue,
          reason: 'R32：isDefault 必须认新默认（standard/sierra/true/2/6）');
      expect(EffectConfig().toJson().containsKey('quality'), isFalse,
          reason: '默认配置不再写 quality 段');

      final rollback = EffectConfig(
          quality: const QualityParams(
              dither: false, ditherMode: 'floyd', tier: RenderTier.legacy));
      expect(
          rollback.toJson()['quality'],
          {'dither': false, 'ditherMode': 'floyd', 'tier': 'legacy'},
          reason: 'v1.2 回滚配置必须逐字可持久化（spec §6.4「legacy 仍供显式选择」）');
      // 两个方向都得能表达：默认与回滚的 JSON/哈希不能撞车。
      expect(rollback.configHash, isNot(EffectConfig().configHash),
          reason: '回滚与默认同哈希 ⇒ 回滚意图不可表达');
      expect(
          EffectConfig.fromJson(_decodeJson(rollback.toJsonString())).quality.tier,
          RenderTier.legacy,
          reason: '回滚 JSON 重解析必须是 legacy（读路径同样锁步）');
      expect(
          EffectConfig.fromJson(_decodeJson(rollback.toJsonString())).configHash,
          rollback.configHash);
    });

    test('R32 显式 null 键按缺省处理；非空未知名仍 sanitize 成 legacy', () {
      // null 与缺键同义（都是「没说过」）⇒ 落到新默认，绝不落到 legacy。
      final nul = QualityParams.fromJson({
        'tier': null,
        'ditherMode': null,
        'dither': null,
      });
      expect(nul.tier, RenderTier.standard, reason: '显式 null tier 不得暗兜 legacy');
      expect(nul.ditherMode, 'sierra');
      expect(nul.dither, isTrue);
      // 整段为 null 的 quality 键：等价缺段 ⇒ 构造默认。
      expect(EffectConfig.fromJson({'quality': <String, dynamic>{}}).quality,
          isNot(isNull));
      expect(EffectConfig.fromJson({'quality': null}).quality.tier,
          RenderTier.standard);
      // 既有 sanitise 契约不动：非空的未知**名字**仍回落 legacy。
      expect(QualityParams.fromJson({'tier': 'ultra'}).tier, RenderTier.legacy);
      expect(QualityParams.fromJson({'tier': ''}).tier, RenderTier.legacy,
          reason: '空串是一个未知名（走 parse sanitise），不是「缺键」');
      expect(QualityParams.fromJson({'ditherMode': 'blue-noise'}).ditherMode,
          'sierra', reason: '未知 ditherMode ⇒ 新默认（R24 兜底方向不变）');
    });

    test('R32 便捷参数：qualityTier=null/dither=null 不写段，显式 legacy 写段', () {
      expect(EffectConfig(dither: null, qualityTier: null)
          .toJson()
          .containsKey('quality'), isFalse);
      expect(EffectConfig(qualityTier: RenderTier.legacy).configHash,
          EffectConfig(
                  quality: const QualityParams(tier: RenderTier.legacy))
              .configHash,
          reason: '顶层便捷参数与嵌套参数必须逐字节等价（R5 契约在 R32 后仍成立）');
      final j = EffectConfig(qualityTier: RenderTier.legacy).toJson()['quality']
          as Map;
      expect(j['tier'], 'legacy');
      // 显式 dither:true（= 默认）与不传便捷参数等价 ⇒ 仍整段省略。
      expect(EffectConfig(dither: true).toJson().containsKey('quality'), isFalse);
      expect(EffectConfig(dither: true).configHash, EffectConfig().configHash);
    });
  });

  // ---------- Task 3.6b：contentAware 默认 false→true（R30/R36） ----------
  //
  // 与 R32 同一习语：「等于默认就不写」只有在
  //   构造默认 == 缺键兜底 == 省略哨兵
  // 三者锁步时才是无损序列化。Task 3.6b 把 contentAware 的默认翻到 true，
  // 三处必须同 commit 同向翻转，否则：
  //   1. 只翻构造默认 ⇒ 显式 false 的回滚配置命中旧哨兵被省略 ⇒ 重解析成
  //      true ⇒ 一次 toJson→fromJson 就静默抹掉回滚意图（R32 的事故重演）；
  //   2. 只翻兜底不翻哨兵 ⇒ 默认 JSON 多写 'contentAware': true ⇒ 默认配置
  //      的序列化形状/configHash 被改动，旧客户端键集漂移。
  // R36：不引入任何 tier 门控——落位（WHERE）与渲染档（WHICH pixel algorithm）
  // 正交（R8 对 panelAware 的同款裁决），SaliencyAnalyzer 内部零 tier 引用。
  group('v1.4 Task 3.6b：contentAware 哨兵=兜底=构造默认=true（R30/R36，R32 习语）', () {
    // 锚点：故意写死字面量（与 R32 组同一口径）——这里若与实现漂移，本组的
    // 门就该红，而不是跟着实现走。
    const defContentAware = true;

    test('3.6b 默认 true：构造默认 == 省略哨兵 ⇒ 默认 JSON 不写 contentAware 键', () {
      expect(EffectConfig().contentAware, defContentAware,
          reason: '构造默认必须等于本组锚点（true）');
      expect(EffectConfig().contentAware, isTrue,
          reason: 'R30/R36：默认开启内容感知落位（投诉 #2 的开箱修复）');
      // 省略条件与锚点锁步：等于 defContentAware 就不写。
      expect(EffectConfig().toJson().containsKey('contentAware'),
          EffectConfig().contentAware != defContentAware,
          reason: '默认命中省略哨兵 ⇒ 默认 JSON 键集与翻转前逐字节相同（旧客户端兼容）');
      expect(EffectConfig().toJson().containsKey('contentAware'), isFalse,
          reason: '默认 JSON 必须不写键');
      expect(
          EffectConfig.fromJson({'effects': ['rain']}).contentAware, isTrue,
          reason: '缺键兜底必须等于新默认（三源锁步的第二源）');
    });

    test('3.6b 显式 false 回滚：写出键、往返保 false、保 configHash', () {
      final rollback = EffectConfig(contentAware: false);
      expect(rollback.toJson()['contentAware'], false,
          reason: 'R32 教训：回滚意图一旦不写，缺键兜底成 true 就静默翻转用户配置');
      final back =
          EffectConfig.fromJson(_decodeJson(rollback.toJsonString()));
      expect(back.contentAware, isFalse, reason: '往返丢失回滚意图');
      expect(back.configHash, rollback.configHash,
          reason: '一次 JSON 往返就改 configHash = 同一份 JSON 有两种渲染行为');
      expect(back.toJson(), rollback.toJson(), reason: '往返后序列化形状必须不动');
      // 默认与回滚的 JSON/哈希不得撞车（否则回滚不可表达）。
      expect(rollback.configHash, isNot(EffectConfig().configHash),
          reason: '回滚与默认同哈希 ⇒ 回滚意图不可表达');
    });

    test('3.6b 双向形状：{"contentAware": false} 进出无损；显式 true == 新默认', () {
      // 省略条件逐案例对上锚点：写键 ⟺ 值 != defContentAware。
      for (final v in [true, false]) {
        final probe = EffectConfig(contentAware: v);
        expect(probe.toJson().containsKey('contentAware'),
            v != defContentAware,
            reason: '省略哨兵漂移：contentAware=$v');
      }
      // 外部字面回滚（服务端 API / 用户手写 JSON 的形状）。
      final j = EffectConfig.fromJson({'effects': ['rain'], 'contentAware': false});
      expect(j.contentAware, isFalse);
      expect(j.toJson()['contentAware'], false, reason: '回滚键必须原样写回');
      expect(EffectConfig.fromJson(j.toJson()).configHash, j.configHash);
      // 显式 true 与新默认逐字节等价 ⇒ 不写键、同哈希（既有 contentAware:
      // true 测试零编辑仍绿的前提）。
      final on = EffectConfig(contentAware: true);
      expect(on.toJson().containsKey('contentAware'), isFalse);
      expect(on.configHash, EffectConfig().configHash);
      expect(on.toJson(), EffectConfig().toJson());
      expect(EffectConfig.fromJson(_decodeJson(on.toJsonString())).configHash,
          on.configHash);
    });

    test('3.6b 兜底语义：显式 null 键 = 缺键 ⇒ 新默认；false/非 bool 仍落 false', () {
      expect(EffectConfig.fromJson({'contentAware': null}).contentAware, isTrue,
          reason: 'null = 「没说过」 ⇒ 落新默认，绝不静默落 false');
      expect(EffectConfig.fromJson({'contentAware': true}).contentAware, isTrue);
      expect(EffectConfig.fromJson({'contentAware': false}).contentAware, isFalse);
      // sanitize 语义与翻转前一致：非 true 的非 bool 值仍按 false 处理。
      expect(EffectConfig.fromJson({'contentAware': 'yes'}).contentAware, isFalse);
      expect(EffectConfig.fromJson({'contentAware': 1}).contentAware, isFalse);
    });

    test('3.6b copy/链式路径保留 contentAware（effect_config.dart:1563 契约）', () {
      expect(EffectConfig().copy().contentAware, isTrue,
          reason: 'copy 必须携带新默认');
      expect(EffectConfig(contentAware: false).copy().contentAware, isFalse,
          reason: 'copy 不得把显式回滚洗成默认');
      expect(
          EffectConfig(contentAware: false)
              .withEffect(EffectKind.rain)
              .contentAware,
          isFalse);
      expect(EffectConfig().clearEffects().contentAware, isTrue);
    });

    test('3.6b 默认 JSON 键集不动 ⇒ 默认 configHash 不因本次翻转移动', () {
      // 本次只翻默认「值」+ 哨兵方向；默认配置序列化的字节形状是逐字节冻结的
      // （绝对字面量归 3.7 重锚定，这里钉的是「3.6b 自身不移动默认哈希」）。
      expect(EffectConfig().toJson().containsKey('contentAware'), isFalse);
      expect(EffectConfig(contentAware: true).toJson(), EffectConfig().toJson());
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

/// 手工构造 Animated WebP（VP8X 动画标志 + ANIM + 两个 ANMF/VP8L 子块），
/// 首帧纯红、次帧纯蓝，用于锁定「解码取首帧」的行为契约。
Uint8List _animatedWebpBytes(int w, int h) {
  final red = pkg.Image(width: w, height: h);
  pkg.fillRect(red, x1: 0, y1: 0, x2: w - 1, y2: h - 1,
      color: pkg.ColorRgba8(255, 0, 0, 255));
  final blue = pkg.Image(width: w, height: h);
  pkg.fillRect(blue, x1: 0, y1: 0, x2: w - 1, y2: h - 1,
      color: pkg.ColorRgba8(0, 0, 255, 255));
  final frame0 = _vp8lPayload(pkg.encodeWebP(red).toList());
  final frame1 = _vp8lPayload(pkg.encodeWebP(blue).toList());

  final vp8x = <int>[
    0x02, // animation flag
    0, 0, 0,
    (w - 1) & 0xff, ((w - 1) >> 8) & 0xff, ((w - 1) >> 16) & 0xff,
    (h - 1) & 0xff, ((h - 1) >> 8) & 0xff, ((h - 1) >> 16) & 0xff,
  ];
  final out = <int>[...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits];
  out.addAll(_webpChunk('VP8X', vp8x));
  out.addAll(_webpChunk('ANIM', <int>[0, 0, 0, 0, 0, 0])); // bg + loop=∞
  for (final f in [frame0, frame1]) {
    final anmfPayload = <int>[
      0, 0, 0, // x
      0, 0, 0, // y
      (w - 1) & 0xff, ((w - 1) >> 8) & 0xff, ((w - 1) >> 16) & 0xff,
      (h - 1) & 0xff, ((h - 1) >> 8) & 0xff, ((h - 1) >> 16) & 0xff,
      100, 0, 0, // duration ms
      0x00, // alpha blend, keep
    ];
    out.addAll(
        _webpChunk('ANMF', [...anmfPayload, ..._webpChunk('VP8L', f)]));
  }
  final riffSize = out.length - 8;
  out[4] = riffSize & 0xff;
  out[5] = (riffSize >> 8) & 0xff;
  out[6] = (riffSize >> 16) & 0xff;
  out[7] = (riffSize >> 24) & 0xff;
  return Uint8List.fromList(out);
}

/// 单帧无损 WebP → VP8L 子块 payload（含 0x2F 签名）。
Uint8List _vp8lPayload(List<int> webp) {
  final b = Uint8List.fromList(webp);
  final size = b[16] | (b[17] << 8) | (b[18] << 16) | (b[19] << 24);
  return Uint8List.sublistView(b, 20, 20 + size);
}

List<int> _webpChunk(String fourcc, List<int> payload) {
  final out = <int>[
    ...fourcc.codeUnits,
    payload.length & 0xff,
    (payload.length >> 8) & 0xff,
    (payload.length >> 16) & 0xff,
    (payload.length >> 24) & 0xff,
    ...payload,
  ];
  if (payload.length.isOdd) out.add(0);
  return out;
}
