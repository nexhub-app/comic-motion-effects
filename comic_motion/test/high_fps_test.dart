import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// W3：高帧率预渲染档位 —— APNG exact 帧延迟 + rect 区域帧差分。
///
/// 红线锚点：exact 延迟 fcTL 精确表达 1/fps（60fps = 16.67ms）；默认 cs
/// 口径逐字节不变（den=100）；区域帧 dispose=NONE 跨帧合成还原与源帧一致；
/// 管线端到端 rect ≤ full 体积、确定性；configHash 条件序列化（默认指纹
/// 不变）。
void main() {
  RgbaImage flatFrame(int w, int h, {int shift = 0}) {
    final img = RgbaImage(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        img.setPixel(x, y, (x * 3 + shift) % 256, (y * 5 + shift) % 256, 100);
      }
    }
    return img;
  }

  group('APNG exact 帧延迟', () {
    test('exact 模式 fcTL 写 1/fps 精确分数（60fps = 16.67ms）', () {
      final b = StreamingApngBuilder(16, 16, fps: 60, exactDelay: true);
      b.addFrame(flatFrame(16, 16));
      b.addFrame(flatFrame(16, 16, shift: 3));
      final chunks = _parseChunks(Uint8List.fromList(b.finish()));
      final fctls = chunks.where((c) => c.type == 'fcTL').toList();
      expect(fctls, hasLength(2));
      for (final c in fctls) {
        final num = _be16(c.data, 20);
        final den = _be16(c.data, 22);
        expect(num, 1, reason: 'exact 模式 delay_num 恒为 1');
        expect(den, 60, reason: 'delay_den = fps，精确表达 1/60s = 16.67ms');
      }
    });

    test('默认 cs 口径不变：den=100、num=(100/fps).round()（60fps→2cs）', () {
      final b = StreamingApngBuilder(16, 16, fps: 60);
      b.addFrame(flatFrame(16, 16));
      final chunks = _parseChunks(Uint8List.fromList(b.finish()));
      final fcTL = chunks.firstWhere((c) => c.type == 'fcTL');
      expect(_be16(fcTL.data, 20), (100 / 60).round());
      expect(_be16(fcTL.data, 22), 100);
      // 与 encodeApng 便捷入口同口径（v1.3 逐字节契约锚点）。
      final legacy = encodeApng([flatFrame(16, 16)], fps: 60);
      final legacyFcTL =
          _parseChunks(Uint8List.fromList(legacy)).firstWhere((c) => c.type == 'fcTL');
      expect(_be16(legacyFcTL.data, 20), _be16(fcTL.data, 20));
      expect(_be16(legacyFcTL.data, 22), _be16(fcTL.data, 22));
    });

    test('exact 与厘秒覆盖互斥：exact 模式下 delayCs 不生效', () {
      final b = StreamingApngBuilder(16, 16, fps: 60, exactDelay: true);
      b.addFrame(flatFrame(16, 16));
      b.addEncodedPngFrame(
          Uint8List.fromList(ImageIO.encodePngFrame(flatFrame(16, 16, shift: 3))),
          delayCs: 50);
      final fctls = _parseChunks(Uint8List.fromList(b.finish())).where((c) => c.type == 'fcTL');
      for (final c in fctls) {
        expect(_be16(c.data, 20), 1);
        expect(_be16(c.data, 22), 60);
      }
    });
  });

  group('APNG rect 区域帧', () {
    test('fcTL 区域与偏移正确；dispose=NONE / blend=SOURCE', () {
      final b = StreamingApngBuilder(32, 32, fps: 60, exactDelay: true);
      b.addFrame(flatFrame(32, 32));
      b.addRectFrame(flatFrame(32, 32, shift: 7),
          region: const PixelRect(4, 6, 12, 9));
      final fctls = _parseChunks(Uint8List.fromList(b.finish()))
          .where((c) => c.type == 'fcTL').toList();
      expect(fctls, hasLength(2));
      final full = fctls[0].data;
      expect(_be32(full, 4), 32);
      expect(_be32(full, 8), 32);
      expect(_be32(full, 12), 0);
      expect(_be32(full, 16), 0);
      final region = fctls[1].data;
      expect(_be32(region, 4), 12);
      expect(_be32(region, 8), 9);
      expect(_be32(region, 12), 4); // x offset
      expect(_be32(region, 16), 6); // y offset
      expect(region[24], 0, reason: 'dispose_op NONE：区域保留供跨帧合成');
      expect(region[25], 0, reason: 'blend_op SOURCE：区域直接覆盖');
    });

    test('首帧必须全画布', () {
      final b = StreamingApngBuilder(16, 16, fps: 60);
      expect(() => b.addRectFrame(flatFrame(16, 16), region: const PixelRect(0, 0, 4, 4)),
          throwsArgumentError);
    });
    test('区域帧跨帧合成后与源帧逐像素一致（dispose=NONE 语义）', () {
      const w = 48, h = 48;
      final frame0 = flatFrame(w, h);
      final frame1 = flatFrame(w, h, shift: 9);
      const region = PixelRect(8, 16, 17, 25);
      final b = StreamingApngBuilder(w, h, fps: 60, exactDelay: true);
      b.addFrame(frame0);
      b.addRectFrame(frame1, region: region);
      final chunks = _parseChunks(Uint8List.fromList(b.finish()));
      final fctls = chunks.where((c) => c.type == 'fcTL').toList();
      expect(fctls, hasLength(2));

      // 逐帧解码：fcTL 后首个 fdAT 载荷（本编码器每帧 1 个 fdAT）。
      Uint8List decodeFrame(_Chunk fcTL) {
        final idx = chunks.indexOf(fcTL);
        final fdAT = chunks[idx + 1];
        expect(fdAT.type, 'fdAT');
        final payload = Uint8List.fromList(fdAT.data.sublist(4));
        final rw = _be32(fcTL.data, 4);
        final rh = _be32(fcTL.data, 8);
        return decodeApngScanlines(payload, rw, rh);
      }

      final scan0 = decodeFrame(fctls[0]);
      final regionFcTL = fctls[1];
      final scanRegion = decodeFrame(regionFcTL);

      // 画布 = 帧 0 全画布；区域帧 SOURCE 覆盖其矩形。
      final canvas = Uint8List(w * h * 3);
      canvas.setAll(0, scan0);
      final rx = _be32(regionFcTL.data, 12);
      final ry = _be32(regionFcTL.data, 16);
      final rw = _be32(regionFcTL.data, 4);
      final rh = _be32(regionFcTL.data, 8);
      for (var y = 0; y < rh; y++) {
        canvas.setRange(((ry + y) * w + rx) * 3, ((ry + y) * w + rx + rw) * 3,
            scanRegion, y * rw * 3);
      }

      // 画布逐像素与期望比对：区域内 = 源帧；区域外 = 帧 0 保留。
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final inside = x >= rx && x < rx + rw && y >= ry && y < ry + rh;
          final src = inside ? frame1 : frame0;
          final i = (y * w + x) * 4;
          final o = (y * w + x) * 3;
          expect([canvas[o], canvas[o + 1], canvas[o + 2]],
              [src.data[i], src.data[i + 1], src.data[i + 2]],
              reason: '($x,$y) ${inside ? "区域内=源帧" : "区域外=帧0保留"}');
        }
      }
    });

    test('无变化帧以 1x1 占位保住帧时序', () {
      final f = flatFrame(16, 16);
      final b = StreamingApngBuilder(16, 16, fps: 60, exactDelay: true);
      b.addFrame(f);
      b.addRectFrame(f, region: const PixelRect(0, 0, 0, 0)); // 无变化
      expect(b.frameCount, 2);
      final fctls = _parseChunks(Uint8List.fromList(b.finish())).where((c) => c.type == 'fcTL').toList();
      expect(_be32(fctls[1].data, 4), 1);
      expect(_be32(fctls[1].data, 8), 1);
    });
  });

  group('管线端到端（apng rect / exact）', () {
    test('rect 体积 ≤ full；帧数正确；确定性；params.json 记录新参数', () async {
      final tmp = 'build/w3_test_out';
      Directory(tmp).createSync(recursive: true);
      Map<String, dynamic> cfgJson(String diff) => <String, dynamic>{
            'effects': ['lightSweep'],
            'fps': 60,
            'durationSec': 1.0,
            'maxDimension': 180,
            'outputFormat': 'apng',
            'seed': 7,
            'encoding': {'diffMode': diff, 'apngDelay': 'exact'},
          };

      final full = await MotionPipeline(EffectConfig.fromJson(cfgJson('none')))
          .processFile('sample_images/02_action.png', '$tmp/full');
      final rect = await MotionPipeline(EffectConfig.fromJson(cfgJson('rect')))
          .processFile('sample_images/02_action.png', '$tmp/rect');
      final fullBytes = File(full.outputApng).lengthSync();
      final rectBytes = File(rect.outputApng).lengthSync();
      expect(rect.frameCount, greaterThanOrEqualTo(1));
      expect(rectBytes, lessThanOrEqualTo(fullBytes),
          reason: 'lightSweep 局部动效 rect 体积不应超过全量');
      expect(full.configJson, contains('"apngDelay": "exact"'));

      // 确定性：同 config 重跑逐字节一致。
      final rect2 = await MotionPipeline(EffectConfig.fromJson(cfgJson('rect')))
          .processFile('sample_images/02_action.png', '$tmp/rect2');
      expect(File(rect2.outputApng).readAsBytesSync(),
          File(rect.outputApng).readAsBytesSync());
    });
  });

  group('configHash 稳定性（W3 条件序列化）', () {
    test('默认 encoding 不写入 JSON；exact/rect 条件写入', () {
      final plain = EffectConfig.fromJson({'effects': ['rain']}).toJson();
      expect(plain.containsKey('encoding'), isFalse,
          reason: '默认 cs/none 不写入 → 旧 configHash 逐字节不变');
      final exact =
          EffectConfig.fromJson({'encoding': {'apngDelay': 'exact'}}).toJson();
      expect((exact['encoding'] as Map)['apngDelay'], 'exact');
      final rect =
          EffectConfig.fromJson({'encoding': {'diffMode': 'rect'}}).toJson();
      expect((rect['encoding'] as Map)['diffMode'], 'rect');
      // 非法值容错归一为默认。
      final bad =
          EffectConfig.fromJson({'encoding': {'apngDelay': 'weird'}}).toJson();
      expect(bad.containsKey('encoding'), isFalse);
    });
  });
}

// ---- 测试工具 ----

class _Chunk {
  _Chunk(this.type, this.data);
  final String type;
  final Uint8List data;
}

List<_Chunk> _parseChunks(Uint8List png) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < 8; i++) {
    expect(png[i], signature[i]);
  }
  final out = <_Chunk>[];
  var off = 8;
  while (off + 12 <= png.length) {
    final len = (png[off] << 24) | (png[off + 1] << 16) | (png[off + 2] << 8) | png[off + 3];
    final type = String.fromCharCodes(png.sublist(off + 4, off + 8));
    if (type == 'IEND') break;
    out.add(_Chunk(type, Uint8List.sublistView(png, off + 8, off + 8 + len)));
    off += 12 + len;
  }
  return out;
}

int _be32(Uint8List d, int o) =>
    (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];

int _be16(Uint8List d, int o) => (d[o] << 8) | d[o + 1];
