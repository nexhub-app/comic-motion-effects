import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as pkg;
import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// 第四轮 V3：APNG 流式编码器。
///
/// 红线锚点：结构合法（chunk 序列 / CRC / acTL 循环语义）；fdAT 载荷与
/// 既有 PNG 帧的 IDAT 载荷逐字节一致；标准 filter 反演逐帧还原与源帧
/// 像素一致；确定性；默认 outputFormat 行为零变化（apng 为 opt-in 新路径）。
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

  List<int> pngEncode(RgbaImage img) {
    final im =
        pkg.Image(width: img.width, height: img.height, numChannels: 3);
    for (var y = 0; y < img.height; y++) {
      for (var x = 0; x < img.width; x++) {
        final i = (y * img.width + x) * 4;
        im.setPixelRgb(x, y, img.data[i], img.data[i + 1], img.data[i + 2]);
      }
    }
    return pkg.encodePng(im).toList();
  }

  group('APNG：结构与循环语义', () {
    test('chunk 序列、acTL 帧数、fcTL/fdAT 序号连续、CRC 合法', () {
      final frames = [flatFrame(32, 32), flatFrame(32, 32, shift: 5)];
      final apng = encodeApng(frames, fps: 6);
      final chunks = _parseChunks(apng);

      expect(chunks.first.type, 'IHDR');
      expect(chunks[1].type, 'acTL');
      // acTL: numFrames=2, numPlays=0（无限循环）
      final acTL = chunks[1].data;
      expect(_be32(acTL, 0), 2);
      expect(_be32(acTL, 4), 0);
      expect(chunks.last.type, 'IEND');

      // 帧序列：fcTL + fdAT（本编码器每帧恰好 1 个 fdAT）
      var seq = 0;
      var fctlCount = 0;
      var fdatCount = 0;
      for (final c in chunks.skip(2).take(chunks.length - 3)) {
        if (c.type == 'fcTL') {
          fctlCount++;
          expect(_be32(c.data, 0), seq++, reason: 'fcTL 序号必须连续');
          expect(_be32(c.data, 4), 32); // width
          expect(_be32(c.data, 8), 32); // height
          // delay: fps=6 → (100/6).round()=17 cs → num=17 den=100（20-23 字节）
          expect((c.data[20] << 8) | c.data[21], 17);
          expect((c.data[22] << 8) | c.data[23], 100);
          expect(c.data[24], 0, reason: 'dispose = NONE');
          expect(c.data[25], 0, reason: 'blend = SOURCE');
        } else if (c.type == 'fdAT') {
          fdatCount++;
          expect(_be32(c.data, 0), seq++, reason: 'fdAT 序号必须连续');
        }
      }
      expect(fctlCount, 2);
      expect(fdatCount, 2);

      for (final c in chunks) {
        expect(_crc32Of(c), c.crc, reason: 'chunk ${c.type} CRC 必须合法');
      }
    });

    test('单帧 APNG 合法（reducedMotion 场景）', () {
      final apng = encodeApng([flatFrame(16, 16)], fps: 24);
      final chunks = _parseChunks(apng);
      final acTL = chunks[1].data;
      expect(_be32(acTL, 0), 1);
    });

    test('空帧序列拒绝', () {
      expect(() => encodeApng([], fps: 24), throwsStateError);
    });
  });

  group('APNG：逐帧还原与 PNG 一致性', () {
    test('fdAT 载荷 ≡ 既有 PNG 帧编码器的 IDAT 载荷（逐字节）', () {
      final frames = [flatFrame(24, 24), flatFrame(24, 24, shift: 7)];
      final apng = encodeApng(frames, fps: 6);
      final fdat = _parseChunks(apng)
          .where((c) => c.type == 'fdAT')
          .map((c) => c.data.sublist(4))
          .toList();
      for (var i = 0; i < frames.length; i++) {
        final idat = _parseChunks(pngEncode(frames[i]))
            .where((c) => c.type == 'IDAT')
            .map((c) => c.data)
            .expand((d) => d)
            .toList();
        expect(fdat[i], idat, reason: '帧 $i 的压缩数据必须与 PNG 帧逐字节一致');
      }
    });

    test('标准 filter 反演逐帧还原：与源帧像素一致', () {
      final frames = [
        flatFrame(40, 32),
        flatFrame(40, 32, shift: 100),
        flatFrame(40, 32, shift: 200),
      ];
      final apng = encodeApng(frames, fps: 6);
      final fdat = _parseChunks(apng)
          .where((c) => c.type == 'fdAT')
          .map((c) => c.data.sublist(4))
          .toList();
      for (var i = 0; i < frames.length; i++) {
        final scanlines = decodeApngScanlines(
            Uint8List.fromList(fdat[i]), 40, 32);
        var p = 0;
        for (var y = 0; y < 32; y++) {
          for (var x = 0; x < 40; x++) {
            expect(scanlines[p], frames[i].red(y * 40 + x),
                reason: '帧 $i ($x,$y) R 通道不一致');
            expect(scanlines[p + 1], frames[i].green(y * 40 + x));
            expect(scanlines[p + 2], frames[i].blue(y * 40 + x));
            p += 3;
          }
        }
      }
    });
  });

  group('APNG：确定性与体积', () {
    test('同帧序列两次编码逐字节一致', () {
      final frames = [flatFrame(32, 32), flatFrame(32, 32, shift: 5)];
      expect(encodeApng(frames, fps: 6), encodeApng(frames, fps: 6));
    });

    test('平色漫画帧：APNG 体积 < 同帧序列 GIF', () {
      final frames = [flatFrame(64, 64), flatFrame(64, 64, shift: 30)];
      final apng = encodeApng(frames, fps: 6);
      final gif = StreamingGifBuilder(64, 64, fps: 6);
      for (final f in frames) {
        gif.addFrame(f);
      }
      final gifBytes = gif.finish();
      expect(apng.length, lessThan(gifBytes.length),
          reason: '平色画面 APNG(${apng.length}B) 应小于 GIF(${gifBytes.length}B)');
    });
  });

  group('APNG：管线集成（outputFormat: apng）', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cm_apng_test');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    EffectConfig makeCfg({OutputFormat format = OutputFormat.apng}) =>
        EffectConfig(
          fps: 4,
          durationSec: 1,
          maxDimension: 64,
          outputFormat: format,
        );

    Uint8List inputPng() {
      final img = RgbaImage(width: 64, height: 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          img.setPixel(x, y, (x * 3) % 256, (y * 3) % 256, 100);
        }
      }
      return Uint8List.fromList(pngEncode(img));
    }

    test('内存模式：apngBytes 非 null、gifBytes null', () async {
      final input = inputPng();
      final r = await MotionPipeline(makeCfg(), parallel: 1)
          .processBytes(input: input);
      expect(r.gifBytes, isNull);
      expect(r.apngBytes, isNotNull);
      expect(r.apngBytes!.length, greaterThan(0));
    });

    test('磁盘模式：anim.apng 落盘 + outputApng 路径 + params.json', () async {
      final input = inputPng();
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(input);
      final cfg = makeCfg();
      final r = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, '${tmp.path}/out');
      expect(r.outputApng, isNotEmpty);
      expect(r.outputApng.endsWith('/anim.apng'), isTrue);
      expect(File(r.outputApng).existsSync(), isTrue);
      final jobDir = r.outputApng.substring(0, r.outputApng.lastIndexOf('/'));
      expect(File('$jobDir/params.json').existsSync(), isTrue);
      // params.json 里 outputFormat 记为 apng（可回放）。
      final paramsJson =
          (convert.jsonDecode(File('$jobDir/params.json').readAsStringSync())
                  as Map)
              .cast<String, dynamic>();
      expect(paramsJson['outputFormat'], 'apng');
    });

    test('并行与串行 APNG 字节一致（worker PNG 回传通路）', () async {
      final input = inputPng();
      final serial = await MotionPipeline(makeCfg(), parallel: 1)
          .processBytes(input: input);
      final parallel = await MotionPipeline(makeCfg(), parallel: 4)
          .processBytes(input: input);
      expect(parallel.apngBytes, serial.apngBytes,
          reason: 'worker 回传的 PNG 字节与串行同源同编码，APNG 必须逐字节一致');
    });

    test('确定性：两次运行逐字节一致', () async {
      final input = inputPng();
      final pipeline = MotionPipeline(makeCfg(), parallel: 1);
      final a = await pipeline.processBytes(input: input);
      final b = await pipeline.processBytes(input: input);
      expect(a.apngBytes, b.apngBytes);
    });

    test('默认 outputFormat 序列化与 configHash 不受新枚举值影响', () {
      final a = EffectConfig();
      final j = a.toJson();
      expect(j['outputFormat'], 'both');
      expect(EffectConfig.fromJson(j).configHash, a.configHash);
      // apng 档可序列化回放（opt-in 新路径）。
      final b = EffectConfig(outputFormat: OutputFormat.apng);
      expect(EffectConfig.fromJson(b.toJson()).outputFormat,
          OutputFormat.apng);
      expect(EffectConfig.fromJson(b.toJson()).configHash, b.configHash);
    });
  });
}

// ---- 测试工具 ----

class _Chunk {
  _Chunk(this.type, this.data, this.crc);
  final String type;
  final List<int> data;
  final int crc;
}

List<_Chunk> _parseChunks(List<int> bytes) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < 8; i++) {
    expect(bytes[i], signature[i], reason: 'PNG 签名不匹配');
  }
  final chunks = <_Chunk>[];
  var off = 8;
  while (off + 12 <= bytes.length) {
    final len = (bytes[off] << 24) |
        (bytes[off + 1] << 16) |
        (bytes[off + 2] << 8) |
        bytes[off + 3];
    final type = convert.ascii.decode(bytes.sublist(off + 4, off + 8));
    final data = bytes.sublist(off + 8, off + 8 + len);
    final crc =
        (bytes[off + 8 + len] << 24) |
            (bytes[off + 9 + len] << 16) |
            (bytes[off + 10 + len] << 8) |
            bytes[off + 11 + len];
    chunks.add(_Chunk(type, data, crc));
    off += 12 + len;
    if (type == 'IEND') break;
  }
  return chunks;
}

int _be32(List<int> b, int off) =>
    (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

int _crc32Of(_Chunk c) {
  var crc = 0xFFFFFFFF;
  for (final b in convert.ascii.encode(c.type)) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
    }
  }
  for (final b in c.data) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
