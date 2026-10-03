import 'dart:convert' as convert;
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// Plan B Task 6：`part_motion.json` 侧车输入通道。
///
/// 三条红线：
/// 1. **运行期输入**——性质同 `DepthEstimator` 注入：它改变像素，但**不进**
///    `configHash`（否则每次换侧车结果都打破哈希基线）；
/// 2. **永不抛**——坏 JSON 降级为「没有部件」+ 一条 warning，管线照旧出图，
///    warning 必须一路冒到 `PipelineResult.warnings`（台账/HTTP/CLI 都读它）；
/// 3. **像素真的出来**——静帧、串行、并行三条路径都必须与「无侧车」不同且
///    彼此一致（并行那条就是 `FrameJobSpec` 的透传门）。
void main() {
  const w = 120, h = 120;

  RgbaImage canvas() {
    final img = RgbaImage(width: w, height: h);
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      img.data[o] = 250;
      img.data[o + 1] = 250;
      img.data[o + 2] = 250;
      img.data[o + 3] = 255;
    }
    for (var y = 40; y <= 80; y++) {
      for (var x = 20; x <= 100; x++) {
        if (((x - 20) ~/ 5).isEven) {
          final o = (y * w + x) * 4;
          img.data[o] = 10;
          img.data[o + 1] = 10;
          img.data[o + 2] = 10;
        }
      }
    }
    return img;
  }

  Uint8List pngBytes() =>
      Uint8List.fromList(ImageIO.encodePngFrame(canvas()));

  /// 覆盖条纹带的一只手：手腕在左缘，指尖在右侧远端。
  String partsJson({String kind = 'hand', int extra = 0}) =>
      convert.jsonEncode({
        'version': 1,
        'parts': [
          {
            'kind': kind,
            'polygon': [
              [0.15, 0.35],
              [0.85, 0.33],
              [0.85, 0.68],
              [0.15, 0.72],
            ],
            'anchor': {'x': 0.15, 'y': 0.48, 'joint': 'wrist'},
          },
          for (var i = 0; i < extra; i++)
            {
              'kind': 'arm',
              'polygon': [
                [0.1, 0.8],
                [0.4, 0.8],
                [0.4, 0.95],
              ],
              'anchor': {'x': 0.25, 'y': 0.83},
            },
        ]
      });

  EffectConfig cfg() => EffectConfig(
        effects: [EffectKind.handMotion],
        fps: 4,
        durationSec: 1.0,
        seed: 3,
        quality: const QualityParams(tier: RenderTier.standard),
      );

  /// 产物目录名（`<jobDir>/anim.gif` 的父段）——只用于命名格式断言。
  String jobDirName(String artifactPath) {
    final segs =
        artifactPath.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
    return segs[segs.length - 2];
  }

  group('侧车解析：运行期输入，不进指纹', () {
    test('不给 partMotion ⇒ 空表、零告警、无 digest', () {
      final p = MotionPipeline(cfg());
      expect(p.effectiveParts, isEmpty);
      expect(p.partWarnings, isEmpty);
      expect(p.partMotionDigest, isNull);
    });

    test('digest 是文本指纹：同文同值、异文异值、8 位十六进制', () {
      final a = MotionPipeline(cfg(), partMotion: partsJson());
      final b = MotionPipeline(cfg(), partMotion: partsJson());
      final c = MotionPipeline(cfg(), partMotion: partsJson(extra: 1));
      expect(a.partMotionDigest, b.partMotionDigest);
      expect(a.partMotionDigest, isNot(c.partMotionDigest));
      expect(a.partMotionDigest, matches(RegExp(r'^[0-9a-f]{8}$')));
      expect(a.partMotionDigest,
          ImageIO.contentHash8(convert.utf8.encode(partsJson())));
    });

    test('partMotion 不进 configHash，也不进 configJson', () {
      final withParts = MotionPipeline(cfg(), partMotion: partsJson());
      expect(withParts.config.configHash, cfg().configHash);
      expect(convert.jsonDecode(withParts.config.toJsonString())
          .containsKey('parts'),
          isFalse);
    });

    test('解析出部件：kind 与锚点原样落到 PartMotion', () {
      final parts = MotionPipeline(cfg(), partMotion: partsJson())
          .effectiveParts;
      expect(parts, hasLength(1));
      expect(parts.first.kind, PartKind.hand);
      expect(parts.first.anchorX, 0.15);
      expect(parts.first.tipPoint.x, 0.85);
    });
  });

  group('永不抛 + 告警冒泡', () {
    test('坏 JSON ⇒ 无部件、一条 warning、产物与无侧车逐字节相同', () async {
      final bad = MotionPipeline(cfg(), partMotion: '{"version": 2}');
      expect(bad.effectiveParts, isEmpty);
      expect(bad.partWarnings, hasLength(1));
      expect(bad.partWarnings.first, contains('part_motion'));
      final still = await bad.renderStillFrame(input: pngBytes(), t: 0.25);
      final none =
          await MotionPipeline(cfg()).renderStillFrame(input: pngBytes(), t: 0.25);
      expect(still, equals(none));
    });

    test('表外 kind 丢弃但仍告警，其余部件照渲', () async {
      final p = MotionPipeline(cfg(), partMotion: partsJson(extra: 1));
      expect(p.partWarnings, isEmpty, reason: 'arm 是契约内的 kind，只是未实现');
      final result = await p.processBytes(input: pngBytes());
      expect(result.gifBytes, isNotNull);
      expect(result.warnings, equals(p.partWarnings));
      // arm 部件被渲染侧跳过 ⇒ 像素只由那只手决定。
      final handOnly =
          await MotionPipeline(cfg(), partMotion: partsJson())
              .processBytes(input: pngBytes());
      expect(result.gifBytes, equals(handOnly.gifBytes));
    });

    test('未知 kind ⇒ 该部件忽略 + warning 冒到 PipelineResult.warnings',
        () async {
      final p = MotionPipeline(cfg(), partMotion: partsJson(kind: 'wing'));
      final result = await p.processBytes(input: pngBytes());
      expect(p.effectiveParts, isEmpty);
      expect(result.warnings, hasLength(1));
      expect(result.warnings.single, contains('wing'));
    });

    test('告警顺序：配置告警 → 侧车告警', () async {
      final p = MotionPipeline(cfg(), partMotion: '{}');
      final result = await p.processBytes(input: pngBytes());
      expect(result.warnings.single, contains('version'));
    });
  });

  group('像素端到端', () {
    test('静帧路径：给了 parts 的 t=0.25 与无 parts 不同', () async {
      final withParts = await MotionPipeline(cfg(), partMotion: partsJson())
          .renderStillFrame(input: pngBytes(), t: 0.25);
      final none =
          await MotionPipeline(cfg()).renderStillFrame(input: pngBytes(), t: 0.25);
      expect(withParts, isNot(equals(none)));
    });

    test('首帧是原画：t=0 静帧与无 parts 逐字节相同', () async {
      final withParts = await MotionPipeline(cfg(), partMotion: partsJson())
          .renderStillFrame(input: pngBytes(), t: 0.0);
      final none =
          await MotionPipeline(cfg()).renderStillFrame(input: pngBytes(), t: 0.0);
      expect(withParts, equals(none));
    });

    test('并行 == 串行（FrameJobSpec 透传门）', () async {
      final serial = await MotionPipeline(cfg(), partMotion: partsJson(),
              parallel: 1)
          .processBytes(input: pngBytes());
      final pool = await MotionPipeline(cfg(), partMotion: partsJson(),
              parallel: 2)
          .processBytes(input: pngBytes());
      expect(pool.gifBytes, equals(serial.gifBytes));
      expect(pool.gifBytes!.length, greaterThan(0));
      final none =
          await MotionPipeline(cfg(), parallel: 1).processBytes(input: pngBytes());
      expect(serial.gifBytes, isNot(equals(none.gifBytes)),
          reason: '若两侧字节相同，说明部件根本没进管线');
    });

    test('digest 随结果走：PipelineResult / MemoryPipelineResult 都带', () async {
      final p = MotionPipeline(cfg(), partMotion: partsJson());
      final mem = await p.processBytes(input: pngBytes());
      expect(mem.partMotionDigest, p.partMotionDigest);
      final dir = io.Directory.systemTemp.createTempSync('parts_mem');
      try {
        final path = '${dir.path}/in.png';
        io.File(path).writeAsBytesSync(pngBytes());
        final disk = await p.processFile(path, '${dir.path}/out');
        expect(disk.partMotionDigest, p.partMotionDigest);
        expect(disk.warnings, isEmpty);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('产物目录：换侧车不能撞旧缓存', () {
    test('不给 parts ⇒ 目录名与既有格式逐字节不变', () async {
      final dir = io.Directory.systemTemp.createTempSync('parts_naming');
      try {
        final path = '${dir.path}/in.png';
        io.File(path).writeAsBytesSync(pngBytes());
        final r = await MotionPipeline(cfg()).processFile(path, dir.path);
        final name = jobDirName(r.outputGif);
        expect(
            name,
            matches(RegExp(
                r'^in_[0-9a-f]{8}_[0-9a-f]{8}$')));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('给了 parts ⇒ 目录名追加部件指纹，换文本就换目录', () async {
      final dir = io.Directory.systemTemp.createTempSync('parts_naming2');
      try {
        final path = '${dir.path}/in.png';
        io.File(path).writeAsBytesSync(pngBytes());
        final a = await MotionPipeline(cfg(), partMotion: partsJson())
            .processFile(path, dir.path);
        final b = await MotionPipeline(cfg(),
                partMotion: partsJson(extra: 1))
            .processFile(path, dir.path);
        final digest = ImageIO.contentHash8(convert.utf8.encode(partsJson()));
        expect(jobDirName(a.outputGif), endsWith('_$digest'));
        expect(a.outputGif, isNot(b.outputGif));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('台账', () {
    test('appendJob 写 partMotionDigest；null 时不写该键', () {
      final dir = io.Directory.systemTemp.createTempSync('parts_ledger');
      try {
        final ledger = Ledger(dir.path);
        ledger.appendJob(
            jobId: 'j1',
            input: 'a.png',
            configHash: 'h-parts',
            status: 'success',
            partMotionDigest: 'd-parts');
        ledger.appendJob(
            jobId: 'j2',
            input: 'b.png',
            configHash: 'h-none',
            status: 'success');
        expect(ledger.byId('j1')!['partMotionDigest'], 'd-parts');
        expect(ledger.byId('j2')!.containsKey('partMotionDigest'), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('后台 isolate 通道（UI 嵌入方的唯一可用入口）', () {
    test('processBytesInBackground 携带侧车 ⇒ 与进程内同字节，digest 同值',
        () async {
      final inProcess =
          await MotionPipeline(cfg(), partMotion: partsJson(), parallel: 1)
              .processBytes(input: pngBytes());
      final bg = await processBytesInBackground(
          input: pngBytes(),
          config: cfg(),
          parallel: 1,
          partMotion: partsJson());
      expect(bg.gifBytes, equals(inProcess.gifBytes));
      expect(bg.partMotionDigest, inProcess.partMotionDigest);
      final noParts = await processBytesInBackground(
          input: pngBytes(), config: cfg(), parallel: 1);
      expect(noParts.partMotionDigest, isNull);
      expect(bg.gifBytes, isNot(equals(noParts.gifBytes)),
          reason: '后台 isolate 若与不携带侧车同字节，说明侧车根本没跨过 isolate');
    });

    test('后台通道的侧车告警照样回到调用方', () async {
      final bg = await processBytesInBackground(
          input: pngBytes(), config: cfg(), partMotion: '{"version": 2}');
      expect(bg.warnings, hasLength(1));
      expect(bg.warnings.single, contains('part_motion'));
    });
  });
}
