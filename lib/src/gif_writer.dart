import 'dart:math' as math;
import 'dart:typed_data';

import 'image_model.dart';

/// Streaming GIF89a writer: builds ONE palette via median-cut from the first
/// frame, then quantizes + LZW-encodes each frame on the fly and discards it.
/// Memory stays O(one frame) instead of O(all frames).
///
/// Deterministic: no randomness; identical frames produce identical bytes.
class StreamingGifBuilder {
  StreamingGifBuilder(this.width, this.height,
      {required int fps, bool loopForever = true, bool dither = false})
      : delayCs = (100 / fps).round().clamp(2, 100),
        loopForever = loopForever,
        dither = dither;

  final int width;
  final int height;
  final int delayCs;
  final bool loopForever;

  /// v1.2：Floyd–Steinberg 误差扩散抖动（逐帧、确定性，减轻 256 色色带）。
  final bool dither;

  final BytesBuilder _body = BytesBuilder();
  List<int>? _palette; // 256*3 ints
  Map<int, int> _indexCache = {};
  int _frames = 0;

  int get frameCount => _frames;

  /// Median-cut palette from a deterministic subsample of the first frame.
  void _buildPalette(RgbaImage frame) {
    // Histogram at 5-5-5 granularity over a strided sample.
    final hist = <int, int>{};
    final total = frame.pixelCount;
    final stride = math.max(1, total ~/ 30000);
    for (var i = 0; i < total; i += stride) {
      final o = i * 4;
      final key = (frame.data[o] >> 3) << 10 |
          (frame.data[o + 1] >> 3) << 5 |
          (frame.data[o + 2] >> 3);
      hist[key] = (hist[key] ?? 0) + 1;
    }
    // Boxes of 15-bit color keys; split on longest axis at weighted median.
    var boxes = <_Box>[_Box(hist.keys.toList())];
    while (boxes.length < 256) {
      // pick box with largest volume*count to split
      _Box? best;
      var bestScore = -1;
      var bestIdx = -1;
      for (var bi = 0; bi < boxes.length; bi++) {
        final b = boxes[bi];
        if (b.keys.length < 2) continue;
        final score = b.score(hist);
        if (score > bestScore) {
          bestScore = score;
          best = b;
          bestIdx = bi;
        }
      }
      if (best == null) break;
      final halves = best.split(hist);
      boxes[bestIdx] = halves[0];
      boxes.add(halves[1]);
    }
    final pal = <int>[];
    for (final b in boxes) {
      pal.add(b.avgColor(hist));
    }
    while (pal.length < 256) {
      pal.add(0);
    }
    _palette = pal;
  }

  int _nearest(int r, int g, int b) {
    final key = (r << 16) | (g << 8) | b;
    final cached = _indexCache[key];
    if (cached != null) return cached;
    final pal = _palette!;
    var best = 0, bestDist = 1 << 30;
    for (var i = 0; i < pal.length; i++) {
      final pr = pal[i] >> 16 & 0xff;
      final pg = pal[i] >> 8 & 0xff;
      final pb = pal[i] & 0xff;
      final dr = pr - r, dg = pg - g, db = pb - b;
      final d = dr * dr + dg * dg + db * db;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    if (_indexCache.length < 200000) _indexCache[key] = best;
    return best;
  }

  /// 最近色量化（原 v1.1 路径，dither=false 时使用）。
  Uint8List _quantizeNearest(RgbaImage frame) {
    final indexed = Uint8List(frame.pixelCount);
    final d = frame.data;
    for (var i = 0; i < frame.pixelCount; i++) {
      final o = i * 4;
      indexed[i] = _nearest(d[o], d[o + 1], d[o + 2]);
    }
    return indexed;
  }

  /// Floyd–Steinberg 误差扩散量化（确定性：误差传播不含随机数）。
  /// 内存 O(两行)，逐帧独立无跨帧污染。
  Uint8List _quantizeDithered(RgbaImage frame) {
    final wd = width, ht = height;
    // 两行误差缓冲（当前行 cur，下一行 nxt），每通道 int
    var cur = List<int>.filled((wd + 2) * 3, 0);
    var nxt = List<int>.filled((wd + 2) * 3, 0);
    final indexed = Uint8List(frame.pixelCount);
    final d = frame.data;
    for (var y = 0; y < ht; y++) {
      for (var x = 0; x < wd; x++) {
        final o = (y * wd + x) * 4;
        final bi = (x + 1) * 3;
        final r0 = (d[o] + cur[bi]).clamp(0, 255);
        final g0 = (d[o + 1] + cur[bi + 1]).clamp(0, 255);
        final b0 = (d[o + 2] + cur[bi + 2]).clamp(0, 255);
        final idx = _nearest(r0, g0, b0);
        indexed[y * wd + x] = idx;
        // 反量化回色值，计算误差
        final pal = _palette!;
        final pr = pal[idx] >> 16 & 0xff;
        final pg = pal[idx] >> 8 & 0xff;
        final pb = pal[idx] & 0xff;
        final er = r0 - pr, eg = g0 - pg, eb = b0 - pb;
        // Floyd–Steinberg 分布：右 7/16，左下 3/16，下 5/16，右下 1/16
        if (x + 1 < wd) {
          cur[bi + 3] += er * 7 ~/ 16;
          cur[bi + 4] += eg * 7 ~/ 16;
          cur[bi + 5] += eb * 7 ~/ 16;
        }
        if (y + 1 < ht) {
          if (x > 0) {
            nxt[bi - 3] += er * 3 ~/ 16;
            nxt[bi - 2] += eg * 3 ~/ 16;
            nxt[bi - 1] += eb * 3 ~/ 16;
          }
          nxt[bi] += er * 5 ~/ 16;
          nxt[bi + 1] += eg * 5 ~/ 16;
          nxt[bi + 2] += eb * 5 ~/ 16;
          if (x + 1 < wd) {
            nxt[bi + 3] += er ~/ 16;
            nxt[bi + 4] += eg ~/ 16;
            nxt[bi + 5] += eb ~/ 16;
          }
        }
      }
      final tmp = cur;
      cur = nxt;
      nxt = tmp;
      nxt.fillRange(0, nxt.length, 0);
    }
    return indexed;
  }

  void addFrame(RgbaImage frame) {
    if (frame.width != width || frame.height != height) {
      throw ArgumentError(
          '帧尺寸 ${frame.width}x${frame.height} 与编码器 ${width}x${height} 不一致');
    }
    if (_palette == null) {
      _buildPalette(frame);
    }
    final indexed = dither
        ? _quantizeDithered(frame)
        : _quantizeNearest(frame);
    // Graphic control extension
    _body.add([0x21, 0xF9, 0x04, 0x00, delayCs & 0xff, (delayCs >> 8) & 0xff, 0x00, 0x00]);
    // Image descriptor: separator, left(2), top(2), width(2), height(2), packed
    _body.add([
      0x2C,
      0x00, 0x00, // left = 0
      0x00, 0x00, // top = 0
      width & 0xff, (width >> 8) & 0xff,
      height & 0xff, (height >> 8) & 0xff,
      0x00, // no local color table, not interlaced
    ]);
    final minCodeSize = 8;
    _body.add([minCodeSize]);
    final lzw = _lzw(indexed, minCodeSize);
    // sub-block chunking
    var off = 0;
    while (off < lzw.length) {
      final n = math.min(255, lzw.length - off);
      _body.add([n]);
      _body.add(Uint8List.sublistView(lzw, off, off + n));
      off += n;
    }
    _body.add([0x00]); // block terminator
    _frames++;
  }

  List<int> finish() {
    if (_frames == 0) throw StateError('没有帧可编码');
    final out = BytesBuilder();
    out.add([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]); // GIF89a
    out.add([width & 0xff, (width >> 8) & 0xff, height & 0xff, (height >> 8) & 0xff]);
    out.add([0xF7, 0x00, 0x00]); // GCT, 256 colors, bg=0, aspect=0
    for (final c in _palette!) {
      out.add([(c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff]);
    }
    if (loopForever) {
      out.add([0x21, 0xFF, 0x0B]);
      out.add('NETSCAPE2.0'.codeUnits);
      out.add([0x03, 0x01, 0x00, 0x00, 0x00]);
    }
    out.add(_body.takeBytes());
    out.add([0x3B]); // trailer
    return out.takeBytes();
  }

  /// Standard variable-width GIF LZW over a Uint8List of indices.
  static Uint8List _lzw(Uint8List pixels, int minCodeSize) {
    final clearCode = 1 << minCodeSize;
    final eoiCode = clearCode + 1;
    var codeSize = minCodeSize + 1;
    var nextCode = eoiCode + 1;
    final dict = <int, int>{};

    final out = BytesBuilder();
    var bitBuf = 0, bitCount = 0;
    void emit(int code) {
      bitBuf |= code << bitCount;
      bitCount += codeSize;
      while (bitCount >= 8) {
        out.addByte(bitBuf & 0xff);
        bitBuf >>= 8;
        bitCount -= 8;
      }
    }

    emit(clearCode);
    var prefixCode = -1;
    for (final px in pixels) {
      if (prefixCode < 0) {
        prefixCode = px;
        continue;
      }
      final combined = (prefixCode << 8) | px;
      final hit = dict[combined];
      if (hit != null) {
        prefixCode = hit;
      } else {
        emit(prefixCode);
        // 升位检查必须在赋值之前：当「即将分配的码」等于 1<<codeSize 时，
        // 后续码需要多一位。与 image 包/libgif 解码器（++runningCode > maxCode1
        // 时升位，滞后一个码）严格对齐。放在赋值之后会提前一个码升位导致位流错位。
        if (nextCode == (1 << codeSize) && codeSize < 12) {
          codeSize++;
        }
        dict[combined] = nextCode++;
        if (nextCode >= 4096) {
          emit(clearCode);
          dict.clear();
          codeSize = minCodeSize + 1;
          nextCode = eoiCode + 1;
        }
        prefixCode = px;
      }
    }
    if (prefixCode >= 0) emit(prefixCode);
    emit(eoiCode);
    if (bitCount > 0) out.addByte(bitBuf & 0xff);
    return out.takeBytes();
  }
}

class _Box {
  _Box(this.keys);

  final List<int> keys; // 15-bit color keys

  int _channelOf(int key, int ch) => (key >> (10 - ch * 5)) & 0x1f;

  int score(Map<int, int> hist) {
    // volume proxy: range of keys * weighted count
    var minR = 31, maxR = 0, minG = 31, maxG = 0, minB = 31, maxB = 0;
    var count = 0;
    for (final k in keys) {
      final c = hist[k] ?? 0;
      count += c;
      final r = _channelOf(k, 0), g = _channelOf(k, 1), b = _channelOf(k, 2);
      if (r < minR) minR = r;
      if (r > maxR) maxR = r;
      if (g < minG) minG = g;
      if (g > maxG) maxG = g;
      if (b < minB) minB = b;
      if (b > maxB) maxB = b;
    }
    final vol = (maxR - minR + 1) * (maxG - minG + 1) * (maxB - minB + 1);
    return vol * count;
  }

  List<_Box> split(Map<int, int> hist) {
    // find longest axis
    var minC = [31, 31, 31], maxC = [0, 0, 0];
    for (final k in keys) {
      for (var ch = 0; ch < 3; ch++) {
        final v = _channelOf(k, ch);
        if (v < minC[ch]) minC[ch] = v;
        if (v > maxC[ch]) maxC[ch] = v;
      }
    }
    var axis = 0, span = -1;
    for (var ch = 0; ch < 3; ch++) {
      if (maxC[ch] - minC[ch] > span) {
        span = maxC[ch] - minC[ch];
        axis = ch;
      }
    }
    final sorted = List<int>.from(keys)
      ..sort((a, b) => _channelOf(a, axis).compareTo(_channelOf(b, axis)));
    // split at weighted median
    final total = sorted.fold<int>(0, (s, k) => s + (hist[k] ?? 0));
    var acc = 0;
    var cut = sorted.length ~/ 2;
    for (var i = 0; i < sorted.length; i++) {
      acc += hist[sorted[i]] ?? 0;
      if (acc >= total ~/ 2) {
        cut = i + 1;
        break;
      }
    }
    cut = cut.clamp(1, sorted.length - 1);
    final result = <_Box>[
      _Box(sorted.sublist(0, cut)),
      _Box(sorted.sublist(cut))
    ];
    return result;
  }

  int avgColor(Map<int, int> hist) {
    var sr = 0, sg = 0, sb = 0, n = 0;
    for (final k in keys) {
      final c = hist[k] ?? 0;
      n += c;
      sr += _channelOf(k, 0) * c;
      sg += _channelOf(k, 1) * c;
      sb += _channelOf(k, 2) * c;
    }
    if (n == 0) return 0;
    final r = ((sr ~/ n) << 3) + 4;
    final g = ((sg ~/ n) << 3) + 4;
    final b = ((sb ~/ n) << 3) + 4;
    return (r.clamp(0, 255) << 16) | (g.clamp(0, 255) << 8) | b.clamp(0, 255);
  }
}
