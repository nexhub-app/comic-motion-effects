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
  });

  group('图像解码异常处理', () {
    test('空文件被拒', () {
      expect(() => ImageIO.decode(<int>[]), throwsA(isA<ImageDecodeException>()));
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

    test('processFile 输出文件齐全且 params.json 可还原 hash', () {
      final png = _pngEncode(_gradientImage(64, 96));
      final inPath = '${tmp.path}\\in.png';
      File(inPath).writeAsBytesSync(png);
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final r = MotionPipeline(cfg).processFile(inPath, '${tmp.path}\\out');
      expect(File(r.outputGif).existsSync(), isTrue);
      expect(Directory(r.frameDir).existsSync(), isTrue);
      final paramsFile = File(
          '${r.outputGif.substring(0, r.outputGif.lastIndexOf('\\'))}\\params.json');
      expect(paramsFile.existsSync(), isTrue);
      final restored =
          EffectConfig.fromJson(_decodeJson(paramsFile.readAsStringSync()));
      expect(restored.configHash, cfg.configHash);
      expect(r.frameCount, cfg.frameCount);
      expect(r.elapsedMs, greaterThan(0));
    });

    test('批处理失败项不中断且台账记录原因', () {
      // 建一个输入目录: 一张好图 + 一个空文件 + 一个文本文件
      final inDir = Directory('${tmp.path}\\imgs')..createSync();
      File('${inDir.path}\\a.png')
          .writeAsBytesSync(_pngEncode(_gradientImage(48, 48)));
      File('${inDir.path}\\b.png').writeAsBytesSync(<int>[]);
      File('${inDir.path}\\c.png')
          .writeAsBytesSync('plain text, not an image!'.codeUnits);

      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 48);
      final ledger = Ledger('${tmp.path}\\ledger');
      final results = BatchRunner(ledger).runFolder(
          inputDir: inDir.path, outputDir: '${tmp.path}\\out', config: cfg);
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
      final ledger = Ledger('${tmp.path}\\ledger');
      expect(
        () => BatchRunner(ledger).runFolder(
            inputDir: '${tmp.path}\\nope',
            outputDir: '${tmp.path}\\out',
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
          img.setPixel(
              x,
              y,
              x * 255 ~/ (w - 1),
              y * 255 ~/ (h - 1),
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
        EffectConfig(
            effects: kinds, fps: 8, durationSec: 2, seed: seed);

    test('每个新效果：启用后画面改变（非空差异）', () {
      final img = flatImg();
      final layers = layersOf(img);
      final base = FrameCompositor(
              layers, img, cfgWith([EffectKind.parallax]))
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
          final f = FrameCompositor(
                  layers, img, cfgWith([EffectKind.parallax, k]))
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
          EffectConfig(fps: 12, durationSec: 3.0, maxDimension: 640)
              .configHash,
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
      final restored =
          EffectConfig.fromJson(_decodeJson(cfg.toJsonString()));
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
      final base = FrameCompositor(
              layers, img, EffectConfig(fps: 8, durationSec: 2))
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
      final base = FrameCompositor(
              layers, img, cfg12([EffectKind.parallax]))
          .renderFrame(0.4);
      for (final k in v12Kinds) {
        final ts = k == EffectKind.lightning ? [0.02, 0.5] : [0.4];
        var diff = 0;
        for (final t in ts) {
          final f = FrameCompositor(
                  layers, img, cfg12([EffectKind.parallax, k]))
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
      final restored =
          EffectConfig.fromJson(_decodeJson(cfg.toJsonString()));
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

Matcher throwsConfigException =
    throwsA(const TypeMatcher<ConfigException>());

/// PNG encode via image package (same path ImageIO uses).
List<int> _pngEncode(RgbaImage img) {
  final im = pkg.Image(width: img.width, height: img.height, numChannels: 3);
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final i = (y * img.width + x) * 4;
      im.setPixelRgb(x, y, img.data[i], img.data[i + 1], img.data[i + 2]);
    }
  }
  return pkg.encodePng(im).toList();
}

dynamic jsonDecodePublic(String s) => convert.jsonDecode(s);
// NOTE: 下方不再有代码 —— GIF writer 测试已并入 main() 内的 'StreamingGifBuilder' 组。
