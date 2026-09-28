import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as pkg;
import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// 第四轮 V1：交互式视差帧集导出。
///
/// 红线锚点：phase=0 帧 ≡ 无 parallax 配置的 t=0 静帧（逐字节）；
/// 同输入同 config 两次导出逐字节一致；磁盘目录契约可被
/// MotionCacheManager 识别与清理。
void main() {
  // 幅度放大到 0.05，保证 64px 测试图上各相位像素可分辨。
  EffectConfig makeCfg({bool reducedMotion = false}) => EffectConfig(
        fps: 4,
        durationSec: 1,
        maxDimension: 64,
        reducedMotion: reducedMotion,
        parallax: const ParallaxParams(amplitude: 0.05),
      );

  Uint8List samplePng() => _pngEncode(_gradientImage(64, 64));

  group('交互帧集：采样与帧序', () {
    test('steps 帧数与 phase 升序覆盖 [-1, 1]', () async {
      final r = await MotionPipeline(makeCfg(), parallel: 1)
          .exportInteractionFrames(input: samplePng(), steps: 8);
      expect(r.sets.length, 1);
      final s = r.sets.single;
      expect(s.axis, InteractionAxis.horizontal);
      expect(s.pngBytes.length, 8);
      expect(s.phases.first, -1.0);
      expect(s.phases.last, 1.0);
      for (var i = 1; i < s.phases.length; i++) {
        expect(s.phases[i] > s.phases[i - 1], isTrue,
            reason: 'phases 必须严格升序');
      }
      expect(r.width, 64);
      expect(r.height, 64);
    });

    test('steps=2 边界只含两端点；steps<2 拒绝', () async {
      final r = await MotionPipeline(makeCfg(), parallel: 1)
          .exportInteractionFrames(input: samplePng(), steps: 2);
      expect(r.sets.single.phases, [-1.0, 1.0]);
      expect(
        () => MotionPipeline(makeCfg(), parallel: 1)
            .exportInteractionFrames(input: samplePng(), steps: 1),
        throwsArgumentError,
      );
    });

    test('indexForPhase：最近采样点 + 越界钳制', () async {
      final r = await MotionPipeline(makeCfg(), parallel: 1)
          .exportInteractionFrames(input: samplePng(), steps: 5);
      final s = r.sets.single;
      expect(s.indexForPhase(0.0), 2); // [-1, -0.5, 0, 0.5, 1] 的中点
      expect(s.indexForPhase(-1.0), 0);
      expect(s.indexForPhase(1.0), 4);
      expect(s.indexForPhase(99), 4); // 越界钳制
      expect(s.indexForPhase(-99), 0);
    });
  });

  group('交互帧集：语义契约', () {
    test('phase=0 帧与「无 parallax 效果」的 t=0 静帧逐字节一致', () async {
      final png = samplePng();
      final cfg = makeCfg();
      final r = await MotionPipeline(cfg, parallel: 1)
          .exportInteractionFrames(input: png, steps: 5);
      final zero = r.sets.single.pngBytes[2]; // phases[2] == 0.0
      final still = await MotionPipeline(
        cfg.withoutEffect(EffectKind.parallax),
        parallel: 1,
      ).renderStillFrame(input: png, t: 0);
      expect(zero, still,
          reason: '视差 override 在 phase=0 时必须精确等价于无位移，'
              '与去掉 parallax 效果的静帧逐位一致');
    });

    test('相位驱动位移：全部帧两两不同，+1 与 -1 不同', () async {
      final r = await MotionPipeline(makeCfg(), parallel: 1)
          .exportInteractionFrames(input: samplePng(), steps: 5);
      final frames = r.sets.single.pngBytes;
      for (var i = 0; i < frames.length; i++) {
        for (var j = i + 1; j < frames.length; j++) {
          expect(frames[i], isNot(frames[j]),
              reason: 'phase ${r.sets.single.phases[i]}/${r.sets.single.phases[j]} '
                  '帧不应逐字节相同');
        }
      }
    });

    test('reducedMotion：帧集退化为静帧并携带告警', () async {
      final r = await MotionPipeline(makeCfg(reducedMotion: true), parallel: 1)
          .exportInteractionFrames(input: samplePng(), steps: 4);
      expect(r.warnings.join(), contains('reducedMotion'));
      final frames = r.sets.single.pngBytes;
      for (var i = 1; i < frames.length; i++) {
        expect(frames[i], frames[0], reason: '减弱动态下所有相位都是同一静帧');
      }
    });

    test('axis=both：两组一维帧集（水平在前），跨轴帧不同', () async {
      final r = await MotionPipeline(makeCfg(), parallel: 1)
          .exportInteractionFrames(
              input: samplePng(), axis: InteractionAxis.both, steps: 4);
      expect(r.sets.length, 2);
      expect(r.sets[0].axis, InteractionAxis.horizontal);
      expect(r.sets[1].axis, InteractionAxis.vertical);
      for (final s in r.sets) {
        expect(s.pngBytes.length, 4);
      }
      // 水平相位位移与垂直相位位移产生的画面不同（amplitude/verticalRatio>0）。
      for (var i = 0; i < 4; i++) {
        expect(r.sets[0].pngBytes[i], isNot(r.sets[1].pngBytes[i]));
      }
    });
  });

  group('交互帧集：确定性', () {
    test('同输入同 config 两次导出逐字节一致（帧集 + 索引 JSON）', () async {
      final png = samplePng();
      final pipeline = MotionPipeline(makeCfg(), parallel: 1);
      final a = await pipeline.exportInteractionFrames(
          input: png, axis: InteractionAxis.both, steps: 6);
      final b = await pipeline.exportInteractionFrames(
          input: png, axis: InteractionAxis.both, steps: 6);
      expect(a.indexJsonBytes, b.indexJsonBytes);
      for (var si = 0; si < a.sets.length; si++) {
        for (var fi = 0; fi < a.sets[si].pngBytes.length; fi++) {
          expect(a.sets[si].pngBytes[fi], b.sets[si].pngBytes[fi]);
        }
      }
    });
  });

  group('交互帧集：磁盘模式与缓存契约', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cm_interactive_test');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('目录命名 <stem>_<ch8>_<cf8>_interactive，帧与索引齐全', () async {
      final png = samplePng();
      final inPath = '${tmp.path}/page01.png';
      File(inPath).writeAsBytesSync(png);
      final cfg = makeCfg();
      final outDir = '${tmp.path}/out';
      final r = await MotionPipeline(cfg, parallel: 1)
          .exportInteractionFramesFile(inPath, outDir,
              axis: InteractionAxis.both, steps: 4);
      final jobName =
          'page01_${ImageIO.contentHash8(png)}_${cfg.configHash.substring(0, 8)}'
          '_interactive';
      expect(r.outputDir, '$outDir/$jobName');
      final dir = Directory(r.outputDir);
      expect(dir.existsSync(), isTrue);
      expect(File('${r.outputDir}/index.json').existsSync(), isTrue);
      expect(dir.listSync().whereType<File>().length, 2 * 4 + 1,
          reason: '2 轴 × 4 帧 PNG + index.json');

      // 索引 JSON 可解析，帧文件名与磁盘一致。
      final index = (convert.jsonDecode(
              File('${r.outputDir}/index.json').readAsStringSync()) as Map)
          .cast<String, dynamic>();
      expect(index['kind'], 'interactive');
      expect(index['configHash'], cfg.configHash);
      expect(index['contentHash'], ImageIO.contentHash8(png));
      expect(index['width'], r.width);
      expect(index['height'], r.height);
      final sets = (index['sets'] as List).cast<Map>();
      expect(sets.length, 2);
      expect(sets[0]['axis'], 'horizontal');
      expect((sets[0]['frames'] as List).length, 4);
      expect((sets[0]['phases'] as List).first, -1.0);
      for (final f in (sets[0]['frames'] as List)) {
        expect(File('${r.outputDir}/$f').existsSync(), isTrue);
      }
    });

    test('MotionCacheManager 识别导出目录（kind=interactive）并可清理', () async {
      final png = samplePng();
      final inPath = '${tmp.path}/page01.png';
      File(inPath).writeAsBytesSync(png);
      final outDir = '${tmp.path}/out';
      final r = await MotionPipeline(makeCfg(), parallel: 1)
          .exportInteractionFramesFile(inPath, outDir, steps: 4);

      final mgr = MotionCacheManager(outDir);
      final entries = mgr.listEntries();
      expect(entries.length, 1);
      expect(entries.single.kind, 'interactive');
      expect(entries.single.stem, 'page01');
      expect(entries.single.contentHash, ImageIO.contentHash8(png));

      final report = mgr.purgePrefix('page01');
      expect(report.count, 1);
      expect(Directory(r.outputDir).existsSync(), isFalse);
    });

    test('同内容同配置重复落盘命中同目录（缓存语义一致）', () async {
      final png = samplePng();
      final inPath = '${tmp.path}/page01.png';
      File(inPath).writeAsBytesSync(png);
      final outDir = '${tmp.path}/out';
      final pipeline = MotionPipeline(makeCfg(), parallel: 1);
      final a = await pipeline.exportInteractionFramesFile(inPath, outDir,
          steps: 3);
      final b = await pipeline.exportInteractionFramesFile(inPath, outDir,
          steps: 3);
      expect(b.outputDir, a.outputDir);
      expect(Directory(a.outputDir).listSync().length,
          Directory(b.outputDir).listSync().length);
    });
  });

  group('交互帧集：取消 / 超时 / keepPartial', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cm_interactive_cancel');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('派发前取消：零渲染、零文件、E_CANCELLED', () async {
      final png = samplePng();
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final outDir = '${tmp.path}/out';
      final token = MotionCancelToken()..cancel();
      await expectLater(
        MotionPipeline(makeCfg(), parallel: 1, cancelToken: token)
            .exportInteractionFramesFile(inPath, outDir, steps: 4),
        throwsA(isA<MotionCancelledException>()
            .having((e) => e.code, 'code', 'E_CANCELLED')),
      );
      expect(Directory(outDir).existsSync(), isFalse,
          reason: '入口检查先于目录创建，预取消不应产生任何文件');
    });

    test('超时走同一路径：E_TIMEOUT', () async {
      final png = samplePng();
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final outDir = '${tmp.path}/out';
      await expectLater(
        MotionPipeline(makeCfg(), parallel: 1, timeout: Duration.zero)
            .exportInteractionFramesFile(inPath, outDir, steps: 4),
        throwsA(isA<MotionCancelledException>()
            .having((e) => e.code, 'code', 'E_TIMEOUT')),
      );
      expect(Directory(outDir).existsSync(), isFalse);
    });

    test('中途超时：默认清理半成品目录', () async {
      final png = _pngEncode(_gradientImage(512, 512));
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final outDir = '${tmp.path}/out';
      await expectLater(
        MotionPipeline(makeCfg(maxDimension: 512), parallel: 1,
                timeout: const Duration(milliseconds: 1))
            .exportInteractionFramesFile(inPath, outDir, steps: 8),
        throwsA(isA<MotionCancelledException>()
            .having((e) => e.code, 'code', 'E_TIMEOUT')),
      );
      // 清理语义与 pipeline 一致：只删本次 jobDir，父目录保留。
      final leftover = Directory(outDir).existsSync()
          ? Directory(outDir)
              .listSync()
              .whereType<Directory>()
              .where((d) => d.path.endsWith('_interactive'))
              .length
          : 0;
      expect(leftover, 0, reason: '半成品导出目录应被清理（或从未创建）');
    });

    test('keepPartial=true：已写出帧保留，index.json 不出现', () async {
      final png = _pngEncode(_gradientImage(512, 512));
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final outDir = '${tmp.path}/out';
      await expectLater(
        MotionPipeline(makeCfg(maxDimension: 512), parallel: 1,
                timeout: const Duration(milliseconds: 1),
                keepPartial: true)
            .exportInteractionFramesFile(inPath, outDir, steps: 8),
        throwsA(isA<MotionCancelledException>()),
      );
      final dir = Directory('$outDir');
      if (dir.existsSync()) {
        for (final e in dir.listSync(recursive: true)) {
          if (e is File) {
            expect(e.path.contains('index.json'), isFalse,
                reason: '索引只在成功完成时写出');
          }
        }
      }
    });
  });
}

// ---- 测试夹具（与 engine_test.dart 同风格的自足实现）----

RgbaImage _gradientImage(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, (x * 3) % 256, (y * 3) % 256, 100);
    }
  }
  return img;
}

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
