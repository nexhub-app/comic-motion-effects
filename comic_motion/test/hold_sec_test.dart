import 'dart:io';

import 'package:image/image.dart' as pkg;
import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// 极小 GIF 结构遍历：按块结构走（不做字节模式扫描，避免 LZW 数据里的
/// 0x21 0xF9 序列造成假阳性）。返回帧数与每帧 GCE delay（厘秒）。
class _GifScan {
  _GifScan(this.frames, this.delays);
  final int frames;
  final List<int> delays;
}

_GifScan _scanGif(List<int> b) {
  var i = 10;
  final packed = b[i++];
  i += 2; // bg, aspect
  if (packed & 0x80 != 0) {
    i += 3 * (2 << (packed & 0x07)); // 全局色表
  }
  var frames = 0;
  final delays = <int>[];
  while (i < b.length) {
    final marker = b[i++];
    if (marker == 0x3B) break;
    if (marker == 0x21) {
      final label = b[i++];
      if (label == 0xF9) {
        final len = b[i++];
        delays.add(b[i + 1] | (b[i + 2] << 8));
        i += len;
        i++; // block terminator
      } else {
        while (b[i] != 0) {
          i += b[i] + 1;
        }
        i++;
      }
      continue;
    }
    if (marker == 0x2C) {
      frames++;
      final imgPacked = b[i + 8];
      i += 9;
      if (imgPacked & 0x80 != 0) {
        i += 3 * (2 << (imgPacked & 0x07));
      }
      i++; // LZW min code size
      while (b[i] != 0) {
        i += b[i] + 1;
      }
      i++;
      continue;
    }
    throw StateError('未知块标记 0x${marker.toRadixString(16)} @$i');
  }
  return _GifScan(frames, delays);
}

int _apngFrameCount(List<int> b) {
  const acTL = [0x61, 0x63, 0x54, 0x4C];
  for (var i = 0; i < b.length - 8; i++) {
    if (b[i] == acTL[0] && b[i + 1] == acTL[1] && b[i + 2] == acTL[2] && b[i + 3] == acTL[3]) {
      return (b[i + 4] << 24) | (b[i + 5] << 16) | (b[i + 6] << 8) | b[i + 7];
    }
  }
  throw StateError('acTL not found');
}

RgbaImage _gradient(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, (x * 3) % 256, (y * 3) % 256, 100);
    }
  }
  return img;
}

List<int> _pngEncode(RgbaImage img) {
  final p = pkg.Image(width: img.width, height: img.height);
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final o = (y * img.width + x) * 4;
      p.setPixelRgba(x, y, img.data[o], img.data[o + 1], img.data[o + 2],
          img.data[o + 3]);
    }
  }
  return pkg.encodePng(p).toList();
}

void main() {
  group('EffectConfig.holdSec 序列化', () {
    test('默认 0 不写键（configHash 键集与旧版逐字节一致）', () {
      final a = EffectConfig();
      expect(a.holdSec, 0.0);
      expect(a.toJson().containsKey('holdSec'), isFalse);
      expect(
          EffectConfig.fromJson(a.toJson()).configHash, a.configHash);
    });

    test('显式 holdSec 序列化、往返无损、hash 随值变化', () {
      final a = EffectConfig(holdSec: 4.0);
      expect(a.toJson()['holdSec'], 4.0);
      final b = EffectConfig.fromJson(a.toJson());
      expect(b.holdSec, 4.0);
      expect(b.configHash, a.configHash);
      expect(a.configHash, isNot(EffectConfig().configHash));

      final c = EffectConfig.fromJson(EffectConfig(holdSec: 6.5).toJson());
      expect(c.holdSec, 6.5);
    });

    test('负值 fail-fast', () {
      expect(() => EffectConfig(holdSec: -0.5),
          throwsA(isA<ConfigException>()));
    });
  });

  group('StreamingGifBuilder 静息保持帧', () {
    RgbaImage _frame(int v) {
      final img = RgbaImage(width: 8, height: 8);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          img.setPixel(x, y, v, 100, 100);
        }
      }
      return img;
    }

    test('全帧模式：hold 帧 GCE delay = holdCs，内容同首帧', () {
      final gif = StreamingGifBuilder(8, 8, fps: 4);
      gif.addFrame(_frame(10));
      gif.addFrame(_frame(200));
      gif.addHoldFrame(_frame(10), holdCs: 400);
      final scan = _scanGif(gif.finish());
      expect(scan.frames, 3);
      expect(scan.delays, [25, 25, 400]);
    });

    test('rect 差分模式：hold 帧 delay 同样生效', () {
      final gif = StreamingGifBuilder(8, 8, fps: 4, rectDiff: true);
      gif.addFrame(_frame(10));
      gif.addFrame(_frame(200));
      gif.addHoldFrame(_frame(10), holdCs: 400);
      final scan = _scanGif(gif.finish());
      expect(scan.frames, 3);
      expect(scan.delays, [25, 25, 400]);
    });
  });

  group('管线静息保持', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cm_hold_test');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('holdSec>0：GIF = 动效帧 + 1 静息保持帧，保持帧 delay = holdSec', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradient(64, 96)));
      final cfg = EffectConfig(
          fps: 4, durationSec: 1, maxDimension: 64, holdSec: 0.5);
      final r = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, '${tmp.path}/out');
      final bytes = File(r.outputGif).readAsBytesSync();
      final scan = _scanGif(bytes);
      expect(scan.frames, cfg.frameCount + 1);
      expect(scan.delays.last, 50);
      expect(scan.delays.sublist(0, cfg.frameCount), everyElement(25));
    });

    test('默认（holdSec=0）：GIF 帧数与 delay 不变', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradient(64, 96)));
      final cfg = EffectConfig(fps: 4, durationSec: 1, maxDimension: 64);
      final r = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, '${tmp.path}/out');
      final scan = _scanGif(File(r.outputGif).readAsBytesSync());
      expect(scan.frames, cfg.frameCount);
      expect(scan.delays, everyElement(25));
    });

    test('holdSec>0：APNG 帧数同步 +1', () async {
      final inPath = '${tmp.path}/in.png';
      File(inPath).writeAsBytesSync(_pngEncode(_gradient(64, 96)));
      final cfg = EffectConfig(
          fps: 4,
          durationSec: 1,
          maxDimension: 64,
          holdSec: 0.5,
          outputFormat: OutputFormat.apng);
      final r = await MotionPipeline(cfg, parallel: 1)
          .processFile(inPath, '${tmp.path}/out');
      final bytes = File(r.outputApng).readAsBytesSync();
      expect(_apngFrameCount(bytes), cfg.frameCount + 1);
    });
  });
}
