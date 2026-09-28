import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as pkg;
import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// 第四轮 V2：入场转场帧序列导出。
///
/// 红线锚点：末帧 = 清晰原图（工作分辨率）逐字节成立；首帧模糊显著；
/// 索引 JSON 播放语义 loop:false / holdOnLast:true；同输入两次导出
/// 逐字节一致；磁盘契约可被 MotionCacheManager 识别与清理。
void main() {
  EffectConfig makeCfg({int maxDimension = 64}) => EffectConfig(
        fps: 4,
        durationSec: 1,
        maxDimension: maxDimension,
      );

  /// 硬边缘色块图：模糊前后差异显著，适合断言模糊度。
  RgbaImage blobImage(int w, int h) {
    final img = RgbaImage(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        img.setPixel(x, y, 235, 240, 245);
      }
    }
    for (var y = 16; y < 48; y++) {
      for (var x = 16; x < 48; x++) {
        img.setPixel(x, y, 30, 28, 36);
      }
    }
    return img;
  }

  Uint8List blobPng() => _pngEncode(blobImage(64, 64));

  group('入场帧序列：帧数与播放语义', () {
    test('默认 12 帧；frames 可调；frames<2 拒绝', () async {
      final r = await MotionPipeline(makeCfg(), parallel: 1)
          .exportEntranceFrames(input: blobPng());
      expect(r.frames.length, 12);
      final r5 = await MotionPipeline(makeCfg(), parallel: 1)
          .exportEntranceFrames(input: blobPng(), frames: 5);
      expect(r5.frames.length, 5);
      expect(
        () => MotionPipeline(makeCfg(), parallel: 1)
            .exportEntranceFrames(input: blobPng(), frames: 1),
        throwsArgumentError,
      );
    });

    test('索引 JSON：kind=entrance、loop:false、holdOnLast:true', () async {
      final r = await MotionPipeline(makeCfg(), parallel: 1)
          .exportEntranceFrames(input: blobPng(), delayMs: 60);
      final index = (convert.jsonDecode(convert.utf8.decode(r.indexJsonBytes))
          as Map)
        .cast<String, dynamic>();
      expect(index['kind'], 'entrance');
      expect(index['loop'], isFalse);
      expect(index['holdOnLast'], isTrue);
      expect(index['delayMs'], 60);
      expect(index['zoomReveal'], isTrue);
      expect((index['frames'] as List).length, 12);
      expect(r.delayMs, 60);
    });
  });

  group('入场帧序列：首末帧语义', () {
    test('末帧与清晰原图逐像素一致（无降采样时 = 源图）', () async {
      final src = blobImage(64, 64);
      final r = await MotionPipeline(makeCfg(), parallel: 1)
          .exportEntranceFrames(input: _pngEncode(src), frames: 6);
      final decoded = pkg.decodePng(r.frames.last)!;
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final px = decoded.getPixel(x, y);
          expect(px.r, src.red(y * 64 + x),
              reason: '末帧必须与清晰原图逐像素一致 ($x,$y)');
          expect(px.g, src.green(y * 64 + x));
          expect(px.b, src.blue(y * 64 + x));
        }
      }
    });

    test('首帧模糊显著（硬边缘色块上平均差远超阈值）', () async {
      final r = await MotionPipeline(makeCfg(), parallel: 1)
          .exportEntranceFrames(input: blobPng(), frames: 6,
              maxBlurRadiusPx: 8);
      final first = pkg.decodePng(r.frames.first)!;
      final last = pkg.decodePng(r.frames.last)!;
      num sum = 0;
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final a = first.getPixel(x, y);
          final b = last.getPixel(x, y);
          sum += (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();
        }
      }
      final mean = sum / (64 * 64 * 3);
      expect(mean, greaterThan(5.0), reason: '首帧模糊度必须显著（mean=$mean）');
    });

    test('缩放浮现：开启与关闭的首帧不同，末帧一致', () async {
      final input = blobPng();
      final withZoom = await MotionPipeline(makeCfg(), parallel: 1)
          .exportEntranceFrames(input: input, frames: 4, maxBlurRadiusPx: 0);
      final noZoom = await MotionPipeline(makeCfg(), parallel: 1)
          .exportEntranceFrames(
              input: input, frames: 4, maxBlurRadiusPx: 0, zoomReveal: false);
      expect(withZoom.frames.first, isNot(noZoom.frames.first),
          reason: 'zoom 1.02 的首帧应与无缩放不同');
      expect(withZoom.frames.last, noZoom.frames.last,
          reason: '两者末帧都是清晰原图');
    });
  });

  group('入场帧序列：确定性', () {
    test('同输入同 config 两次导出逐字节一致（帧 + 索引 JSON）', () async {
      final input = blobPng();
      final pipeline = MotionPipeline(makeCfg(), parallel: 1);
      final a = await pipeline.exportEntranceFrames(input: input, frames: 5);
      final b = await pipeline.exportEntranceFrames(input: input, frames: 5);
      expect(a.indexJsonBytes, b.indexJsonBytes);
      for (var i = 0; i < a.frames.length; i++) {
        expect(a.frames[i], b.frames[i]);
      }
    });
  });

  group('入场帧序列：磁盘模式与缓存契约', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cm_entrance_test');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('目录命名 <stem>_<ch8>_<cf8>_entrance，帧与索引齐全', () async {
      final png = blobPng();
      final inPath = '${tmp.path}/page01.png';
      File(inPath).writeAsBytesSync(png);
      final cfg = makeCfg();
      final outDir = '${tmp.path}/out';
      final r = await MotionPipeline(cfg, parallel: 1)
          .exportEntranceFramesFile(inPath, outDir, frames: 4);
      final jobName =
          'page01_${ImageIO.contentHash8(png)}_${cfg.configHash.substring(0, 8)}'
          '_entrance';
      expect(r.outputDir, '$outDir/$jobName');
      final dir = Directory(r.outputDir);
      expect(dir.existsSync(), isTrue);
      expect(dir.listSync().whereType<File>().length, 4 + 1,
          reason: '4 帧 PNG + index.json');

      final index = (convert.jsonDecode(
              File('${r.outputDir}/index.json').readAsStringSync()) as Map)
          .cast<String, dynamic>();
      expect(index['kind'], 'entrance');
      expect(index['configHash'], cfg.configHash);
      expect(index['contentHash'], ImageIO.contentHash8(png));
      for (final f in (index['frames'] as List)) {
        expect(File('${r.outputDir}/$f').existsSync(), isTrue);
      }

      final entries = MotionCacheManager(outDir).listEntries();
      expect(entries.length, 1);
      expect(entries.single.kind, 'entrance');
      expect(entries.single.stem, 'page01');
      final report = MotionCacheManager(outDir).purgeAll();
      expect(report.count, 1);
      expect(dir.existsSync(), isFalse);
    });
  });

  group('入场帧序列：取消 / 超时 / keepPartial', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cm_entrance_cancel');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('派发前取消：零渲染、零文件、E_CANCELLED', () async {
      final png = blobPng();
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final outDir = '${tmp.path}/out';
      final token = MotionCancelToken()..cancel();
      await expectLater(
        MotionPipeline(makeCfg(), parallel: 1, cancelToken: token)
            .exportEntranceFramesFile(inPath, outDir, frames: 4),
        throwsA(isA<MotionCancelledException>()
            .having((e) => e.code, 'code', 'E_CANCELLED')),
      );
      expect(Directory(outDir).existsSync(), isFalse);
    });

    test('超时走同一路径：E_TIMEOUT', () async {
      final png = blobPng();
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final outDir = '${tmp.path}/out';
      await expectLater(
        MotionPipeline(makeCfg(), parallel: 1, timeout: Duration.zero)
            .exportEntranceFramesFile(inPath, outDir, frames: 4),
        throwsA(isA<MotionCancelledException>()
            .having((e) => e.code, 'code', 'E_TIMEOUT')),
      );
      expect(Directory(outDir).existsSync(), isFalse);
    });

    test('中途超时：默认清理半成品导出目录', () async {
      final png = _pngEncode(blobImage(512, 512));
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final outDir = '${tmp.path}/out';
      await expectLater(
        MotionPipeline(makeCfg(maxDimension: 512), parallel: 1,
                timeout: const Duration(milliseconds: 1))
            .exportEntranceFramesFile(inPath, outDir, frames: 12),
        throwsA(isA<MotionCancelledException>()
            .having((e) => e.code, 'code', 'E_TIMEOUT')),
      );
      final leftover = Directory(outDir).existsSync()
          ? Directory(outDir)
              .listSync()
              .whereType<Directory>()
              .where((d) => d.path.endsWith('_entrance'))
              .length
          : 0;
      expect(leftover, 0, reason: '半成品导出目录应被清理（或从未创建）');
    });

    test('keepPartial=true：已写出帧保留，index.json 不出现', () async {
      final png = _pngEncode(blobImage(512, 512));
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(png);
      final outDir = '${tmp.path}/out';
      await expectLater(
        MotionPipeline(makeCfg(maxDimension: 512), parallel: 1,
                timeout: const Duration(milliseconds: 1), keepPartial: true)
            .exportEntranceFramesFile(inPath, outDir, frames: 12),
        throwsA(isA<MotionCancelledException>()),
      );
      final root = Directory(outDir);
      if (root.existsSync()) {
        for (final e in root.listSync(recursive: true)) {
          if (e is File) {
            expect(e.path.contains('index.json'), isFalse,
                reason: '索引只在成功完成时写出');
          }
        }
      }
    });
  });
}

// ---- 测试夹具 ----

Uint8List _pngEncode(RgbaImage img) =>
    Uint8List.fromList(pkg.encodePng(_pngToPkg(img)).toList());

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
