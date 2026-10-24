import 'dart:typed_data';

import 'package:image/image.dart' as pkg;
import 'package:test/test.dart';

import 'package:comic_motion/comic_motion.dart';

/// 与 hold_sec_test.dart 同款的 GIF 块结构遍历（复制自该文件的 _GifScan）。
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
    i += 3 * (2 << (packed & 0x07));
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
        i++;
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
      i++;
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

class _FlatEstimator implements DepthEstimator {
  const _FlatEstimator();
  @override
  DepthMap estimate(RgbaImage img) =>
      DepthMap(img.width, img.height)..constantValued = true; // 全 0 恒值
}

class _RichEstimator implements DepthEstimator {
  const _RichEstimator();
  @override
  DepthMap estimate(RgbaImage img) {
    final d = DepthMap(img.width, img.height)..constantValued = true;
    for (var y = 0; y < d.height; y++) {
      for (var x = 0; x < d.width; x++) {
        d.data[y * d.width + x] = x < d.width ~/ 2 ? 0.1 : 0.9;
      }
    }
    return d;
  }
}

class _CountingGate implements MotionGate {
  int calls = 0;
  @override
  bool shouldAnimate(RgbaImage working, List<DepthMap> depths) {
    calls++;
    return false;
  }
}

EffectConfig _config({double holdSec = 0.0}) =>
    EffectConfig.fromJson(<String, dynamic>{
      'effects': <String>['parallax'],
      'fps': 12,
      'durationSec': 0.5, // 6 动效帧，跑得快
      'maxDimension': 64,
      'layerCount': 3,
      'panelAware': false,
      'outputFormat': 'gif',
      'seed': 7,
      if (holdSec > 0) 'holdSec': holdSec,
    });

void main() {
  test('gate 压制（默认直通）：平坦深度 → 原图字节原样返回 + frameCount 1 + warning', () async {
    final input = Uint8List.fromList(_pngEncode(_gradient(48, 64)));
    final r = await MotionPipeline(_config(),
            depthEstimator: const _FlatEstimator(),
            motionGate: const DepthSpreadGate(minSpread: 0.08))
        .processBytes(input: input);
    expect(r.frameCount, 1);
    expect(r.gifBytes, isNull, reason: '静态直通：不产 GIF');
    expect(r.staticPassthroughBytes, input,
        reason: '原图字节原样返回（零修改、零重编码）');
    expect(r.warnings.join('\n'), contains('motion gate'));
  });

  test('gate 压制（opt-out）：staticPassthrough=false → 旧 1 帧重编码形态', () async {
    final r = await MotionPipeline(_config(),
            staticPassthrough: false,
            depthEstimator: const _FlatEstimator(),
            motionGate: const DepthSpreadGate(minSpread: 0.08))
        .processBytes(input: Uint8List.fromList(_pngEncode(_gradient(48, 64))));
    expect(r.frameCount, 1);
    expect(_scanGif(r.gifBytes!).frames, 1);
    expect(r.staticPassthroughBytes, isNull);
  });

  test('gate 通过：丰富深度 → 全帧输出（6 帧），无 warning', () async {
    final r = await MotionPipeline(_config(),
            depthEstimator: const _RichEstimator(),
            motionGate: const DepthSpreadGate(minSpread: 0.08))
        .processBytes(input: Uint8List.fromList(_pngEncode(_gradient(48, 64))));
    expect(r.frameCount, 6);
    expect(_scanGif(r.gifBytes!).frames, 6);
    expect(r.warnings.where((w) => w.contains('motion gate')), isEmpty);
  });

  test('不传 gate：平坦深度照常全帧（既有路径零变化）', () async {
    final r = await MotionPipeline(_config(),
            depthEstimator: const _FlatEstimator())
        .processBytes(input: Uint8List.fromList(_pngEncode(_gradient(48, 64))));
    expect(r.frameCount, 6);
  });

  test('holdSec 与压制并存：压制优先 → 原图直通（hold 无意义）', () async {
    final r = await MotionPipeline(_config(holdSec: 2.0),
            depthEstimator: const _FlatEstimator(),
            motionGate: const DepthSpreadGate(minSpread: 0.08))
        .processBytes(input: Uint8List.fromList(_pngEncode(_gradient(48, 64))));
    expect(r.frameCount, 1);
    expect(r.staticPassthroughBytes, isNotNull);
  });

  test('holdSec 与 gate 通过并存：6 动效帧 + 1 保持帧，末帧延迟 200cs', () async {
    final r = await MotionPipeline(_config(holdSec: 2.0),
            depthEstimator: const _RichEstimator(),
            motionGate: const DepthSpreadGate(minSpread: 0.08))
        .processBytes(input: Uint8List.fromList(_pngEncode(_gradient(48, 64))));
    final scan = _scanGif(r.gifBytes!);
    expect(scan.frames, 7);
    expect(scan.delays.last, 200);
  });

  test('reducedMotion 时 gate 不被调用（n==1 无评估必要）', () async {
    final gate = _CountingGate();
    final cfg = EffectConfig.fromJson(const <String, dynamic>{
      'effects': <String>['parallax'],
      'fps': 12,
      'durationSec': 0.5,
      'maxDimension': 64,
      'layerCount': 3,
      'panelAware': false,
      'outputFormat': 'gif',
      'seed': 7,
      'reducedMotion': true,
    });
    final r = await MotionPipeline(cfg,
            depthEstimator: const _FlatEstimator(), motionGate: gate)
        .processBytes(input: Uint8List.fromList(_pngEncode(_gradient(48, 64))));
    expect(r.frameCount, 1);
    expect(gate.calls, 0);
  });

  test('gate 不进 configHash（执行期依赖铁律）', () {
    final cfg = _config();
    expect(
        MotionPipeline(cfg, motionGate: const DepthSpreadGate())
            .config
            .configHash,
        MotionPipeline(cfg).config.configHash);
  });
}
