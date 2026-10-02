import 'dart:math' as math;
import 'dart:typed_data';

import 'effect_config.dart';
import 'image_model.dart';
import 'render/quality.dart';

/// 单帧 GIF 编码器：调色板定板后即为一颗纯函数（帧栅格 → 该帧的 GIF body
/// 片段），不依赖任何跨帧状态。因此可以整份复制进 worker isolate 并行执行，
/// 主 isolate 只按帧序拼接字节。
///
/// 确定性：无随机数；相同帧 + 相同调色板 ⇒ 逐字节相同。
class GifFrameEncoder {
  GifFrameEncoder({
    required this.width,
    required this.height,
    required this.delayCs,
    required List<int> palette,
    required this.dither,
    required this.sierra,
    required this.useLut,
  }) : palette = _toBytes(palette);

  final int width;
  final int height;
  final int delayCs;

  /// 256 色 × 3 通道。
  final Uint8List palette;

  /// 误差扩散抖动（减轻 256 色渐变色带）。
  final bool dither;

  /// sierra 风格核（水平 reach 更远、权重更平缓）取代 floyd；仅 standard+。
  final bool sierra;

  /// standard+ 用 5-5-5 桶惰性 LUT 代替无界 Map 缓存（固定 64KB）。
  final bool useLut;

  final Map<int, int> _indexCache = {};
  final Uint8List _bucketLut = Uint8List(32768);
  final Uint8List _bucketBuilt = Uint8List(32768);

  /// 256 个打包 int（0xRRGGBB）→ 768 字节。
  static Uint8List _toBytes(List<int> packed) {
    final b = Uint8List(256 * 3);
    for (var i = 0; i < 256 && i < packed.length; i++) {
      final o = i * 3;
      b[o] = (packed[i] >> 16) & 0xff;
      b[o + 1] = (packed[i] >> 8) & 0xff;
      b[o + 2] = packed[i] & 0xff;
    }
    return b;
  }

  /// 该帧在 GIF 数据流中的完整片段：图形控制扩展 + 图像描述符 + LZW 子块。
  Uint8List encodeFrameBody(RgbaImage frame) {
    if (frame.width != width || frame.height != height) {
      throw ArgumentError(
          '帧尺寸 ${frame.width}x${frame.height} 与编码器 ${width}x$height 不一致');
    }
    final indexed = quantizeIndices(frame);
    final body = BytesBuilder();
    // Graphic control extension（disposal 0 = 不指定，v1.2 起未变）
    body.add([
      0x21,
      0xF9,
      0x04,
      0x00,
      delayCs & 0xff,
      (delayCs >> 8) & 0xff,
      0x00,
      0x00,
    ]);
    // Image descriptor: separator, left(2), top(2), width(2), height(2), packed
    body.add([
      0x2C,
      0x00, 0x00, // left = 0
      0x00, 0x00, // top = 0
      width & 0xff, (width >> 8) & 0xff,
      height & 0xff, (height >> 8) & 0xff,
      0x00, // no local color table, not interlaced
    ]);
    const minCodeSize = 8;
    body.add([minCodeSize]);
    final lzw = encodeLzw(indexed, minCodeSize);
    var off = 0;
    while (off < lzw.length) {
      final n = math.min(255, lzw.length - off);
      body.add([n]);
      body.add(Uint8List.sublistView(lzw, off, off + n));
      off += n;
    }
    body.add([0x00]); // block terminator
    return body.takeBytes();
  }

  /// 量化到全局调色板索引图（行主序，width × height）。帧间差分（rect 模式）
  /// 在本结果上做——量化是逐帧纯函数（dither 误差扩散逐帧独立），确定性保持。
  Uint8List quantizeIndices(RgbaImage frame) {
    if (frame.width != width || frame.height != height) {
      throw ArgumentError(
          '帧尺寸 ${frame.width}x${frame.height} 与编码器 ${width}x$height 不一致');
    }
    return dither ? _quantizeDithered(frame) : _quantizeNearest(frame);
  }

  int _searchExact(int r, int g, int b) {
    final pal = palette;
    var best = 0, bestDist = 1 << 30;
    for (var i = 0; i < 256; i++) {
      final o = i * 3;
      final dr = pal[o] - r, dg = pal[o + 1] - g, db = pal[o + 2] - b;
      final d = dr * dr + dg * dg + db * db;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  /// legacy 路径：按精确 RGB 键的 Map 缓存（与 v1.2 一致）。
  int _nearestExact(int r, int g, int b) {
    final key = (r << 16) | (g << 8) | b;
    final cached = _indexCache[key];
    if (cached != null) return cached;
    final best = _searchExact(r, g, b);
    if (_indexCache.length < 200000) _indexCache[key] = best;
    return best;
  }

  /// standard+ 路径：5-5-5 桶惰性 LUT。同桶像素共享一次搜索（取桶中心色），
  /// 最多 32768 次搜索后全部命中定长表，无 Map 装箱与无界增长。
  int _nearestLut(int r, int g, int b) {
    final key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3);
    if (_bucketBuilt[key] == 0) {
      _bucketBuilt[key] = 1;
      _bucketLut[key] =
          _searchExact((r & 0xf8) | 4, (g & 0xf8) | 4, (b & 0xf8) | 4);
    }
    return _bucketLut[key];
  }

  /// 最近色量化（dither=false 时使用）。
  Uint8List _quantizeNearest(RgbaImage frame) {
    final nearest = useLut ? _nearestLut : _nearestExact;
    final indexed = Uint8List(frame.pixelCount);
    final d = frame.data;
    for (var i = 0; i < frame.pixelCount; i++) {
      final o = i * 4;
      indexed[i] = nearest(d[o], d[o + 1], d[o + 2]);
    }
    return indexed;
  }

  /// 误差扩散核：`[dx, dy, 权重]` 三元组，分母固定 16（整数运算，无浮点漂移）。
  /// Floyd–Steinberg 与 v1.2 的手写展开逐字节一致。
  static const List<int> _floydTaps = [1, 0, 7, -1, 1, 3, 0, 1, 5, 1, 1, 1];

  /// 两行 Sierra 风格核：水平 reach 到 +2 列、权重更平缓，色带更柔和（standard+）。
  static const List<int> _sierraTaps = [
    1, 0, 4, //
    2, 0, 3, //
    -1, 1, 2, //
    0, 1, 4, //
    1, 1, 2, //
    2, 1, 1, //
  ];

  /// 误差扩散抖动量化（确定性：误差传播不含随机数）。
  /// 内存 O(两行)，逐帧独立无跨帧污染。
  Uint8List _quantizeDithered(RgbaImage frame) {
    final wd = width, ht = height;
    final taps = sierra ? _sierraTaps : _floydTaps;
    final nTaps = taps.length ~/ 3;
    final nearest = useLut ? _nearestLut : _nearestExact;
    final pal = palette;
    final indexed = Uint8List(frame.pixelCount);
    final d = frame.data;
    // 两行误差缓冲（当前行 cur，下一行 nxt），每通道 int。基址偏移 2 格、右侧
    // 留 5 格余量，使 dx=-1 与 reach 到 +2 列的核都不越界。
    var cur = List<int>.filled((wd + 5) * 3, 0);
    var nxt = List<int>.filled((wd + 5) * 3, 0);
    for (var y = 0; y < ht; y++) {
      final rowBase = y * wd * 4;
      final lastRow = y + 1 >= ht;
      for (var x = 0; x < wd; x++) {
        final o = rowBase + x * 4;
        final bi = (x + 2) * 3;
        final r0 = (d[o] + cur[bi]).clamp(0, 255);
        final g0 = (d[o + 1] + cur[bi + 1]).clamp(0, 255);
        final b0 = (d[o + 2] + cur[bi + 2]).clamp(0, 255);
        final idx = nearest(r0, g0, b0);
        indexed[y * wd + x] = idx;
        // 反量化回色值，计算误差
        final po = idx * 3;
        final er = r0 - pal[po];
        final eg = g0 - pal[po + 1];
        final eb = b0 - pal[po + 2];
        for (var k = 0; k < nTaps; k++) {
          final dx = taps[k * 3], dy = taps[k * 3 + 1], wgt = taps[k * 3 + 2];
          final tx = x + dx;
          if (tx < 0 || tx >= wd) continue;
          if (dy != 0 && lastRow) continue;
          final buf = dy == 0 ? cur : nxt;
          final to = (tx + 2) * 3;
          buf[to] += er * wgt ~/ 16;
          buf[to + 1] += eg * wgt ~/ 16;
          buf[to + 2] += eb * wgt ~/ 16;
        }
      }
      final tmp = cur;
      cur = nxt;
      nxt = tmp;
      nxt.fillRange(0, nxt.length, 0);
    }
    return indexed;
  }

  /// Standard variable-width GIF LZW over a Uint8List of indices.
  static Uint8List encodeLzw(Uint8List pixels, int minCodeSize) {
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

/// standard+ 档的调色板探针帧下标（v1.4 Task 3.6 / R27：3 帧 → 6 帧）。
///
/// 均匀铺开 `[0, n~/5, 2n~/5, 3n~/5, 4n~/5, n-1]`，让只在个别时刻出现的
/// 饱和亮色（加粗墨线、闪光帧）有更多机会进 256 色板（§6.4「不被量化吞」）。
/// 确定性：纯函数、无随机无时钟；返回序单调不降，小 n 会出现重复下标，由
/// 调用方的插入序 Map（`putIfAbsent`）天然去重 ⇒ `primePalette` 入参顺序
/// 依旧确定。legacy 档（wantsProbes=false）的单探针 `[0]` 分支不经此函数。
List<int> paletteProbeIndices(int n) => [
      0,
      n ~/ 5,
      (2 * n) ~/ 5,
      (3 * n) ~/ 5,
      (4 * n) ~/ 5,
      n - 1,
    ];

/// Streaming GIF89a writer: builds ONE palette via median-cut, then quantizes +
/// LZW-encodes each frame on the fly and discards it.
/// Memory stays O(one frame) instead of O(all frames).
///
/// Determinism: no randomness; identical frames produce identical bytes.
/// [RenderTier.legacy] reproduces the v1.2 path byte-for-byte (first-frame
/// palette + exact nearest colour with a Map cache + Floyd–Steinberg).
class StreamingGifBuilder {
  StreamingGifBuilder(this.width, this.height,
      {required int fps,
      bool loopForever = true,
      bool dither = false,
      String ditherMode = 'floyd',
      RenderTier tier = RenderTier.legacy,
      bool rectDiff = false})
      : delayCs = (100 / fps).round().clamp(2, 100),
        loopForever = loopForever,
        dither = dither,
        sierra = dither && ditherMode == 'sierra' && tier.atLeastStandard,
        tier = tier,
        rectDiff = rectDiff;

  factory StreamingGifBuilder.fromConfig(
          EffectConfig config, int width, int height) =>
      StreamingGifBuilder(width, height,
          fps: config.fps,
          dither: config.quality.dither,
          ditherMode: config.quality.ditherMode,
          tier: config.quality.tier,
          rectDiff: config.encoding.diffMode == 'rect');

  final int width;
  final int height;
  final int delayCs;
  final bool loopForever;

  /// 误差扩散抖动（减轻 256 色渐变色带）。
  final bool dither;

  /// sierra 核（更柔和）取代 floyd 的 4 抽点；仅 standard+ 生效。
  final bool sierra;

  final RenderTier tier;

  /// 帧间差分（rect 模式，T5）：只编码相邻帧的变化矩形。差分在主 isolate
  /// 按帧序进行（worker 只做量化回传索引图），确定性由按序汇聚保证。
  final bool rectDiff;

  /// 管线用：standard+ 档在流式提交前先给六帧探针建调色板（v1.4 R27，
  /// 下标见 [paletteProbeIndices]；legacy 档仍是 v1.2 的首帧建板）。
  bool get wantsProbes => tier.atLeastStandard;

  final BytesBuilder _body = BytesBuilder();
  List<int>? _palette; // 256 个打包 0xRRGGBB
  GifFrameEncoder? _enc;
  int _frames = 0;
  Uint8List? _prevIndexed; // rect 模式：上一帧的量化索引图

  int get frameCount => _frames;
  bool get hasPalette => _palette != null;

  /// 定板后的 256 色打包调色板（0xRRGGBB），供 worker 侧重建单帧编码器。
  List<int>? get palettePacked => _palette;

  /// 多帧探针建板（standard+）：直方图跨帧累加，避免首帧以外的动效亮色挤不进
  /// 256 色。单探针时与 v1.2 逐字节一致。
  void primePalette(List<RgbaImage> probes) {
    if (_palette != null || probes.isEmpty) return;
    _buildPaletteFrom(probes);
  }

  /// Median-cut palette from a deterministic subsample of the given frames.
  void _buildPaletteFrom(List<RgbaImage> frames) {
    // Histogram at 5-5-5 granularity over a strided sample.
    final hist = <int, int>{};
    for (final frame in frames) {
      final total = frame.pixelCount;
      final stride = math.max(1, total ~/ 30000);
      for (var i = 0; i < total; i += stride) {
        final o = i * 4;
        final key = (frame.data[o] >> 3) << 10 |
            (frame.data[o + 1] >> 3) << 5 |
            (frame.data[o + 2] >> 3);
        hist[key] = (hist[key] ?? 0) + 1;
      }
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

  /// 定板后导出单帧编码器：主 isolate 与每个 worker 各持一份（各自的缓存只
  /// 影响速度，不影响字节）。
  GifFrameEncoder newFrameEncoder() {
    final existing = _enc;
    if (existing != null) return existing;
    final pal = _palette;
    if (pal == null) throw StateError('Palette has not been primed');
    return _enc = GifFrameEncoder(
      width: width,
      height: height,
      delayCs: delayCs,
      palette: pal,
      dither: dither,
      sierra: sierra,
      useLut: tier.atLeastStandard,
    );
  }

  void addFrame(RgbaImage frame) {
    if (_palette == null) primePalette([frame]);
    if (rectDiff) {
      // rect 模式统一走差分入口（含首帧全画布），保证 _prevIndexed 状态连贯。
      addIndexedFrame(newFrameEncoder().quantizeIndices(frame));
      return;
    }
    _body.add(newFrameEncoder().encodeFrameBody(frame));
    _frames++;
  }

  /// 按序拼接 worker 产出的帧片段（与 [addFrame] 的字节完全一致）。
  void addEncodedBody(Uint8List body) {
    if (!hasPalette) throw StateError('Palette has not been primed');
    _body.add(body);
    _frames++;
  }

  /// rect 模式专用：提交一帧的量化索引图，与上一帧比较后只编码变化矩形
  /// （首帧全画布）。必须按帧序调用（差分状态在构建器内）。
  ///
  /// - 全零差异帧以 1x1 矩形占位：GIF 帧延迟驱动动画时序，帧不能缺席；
  ///   1x1 写入的索引与画布现存值一致，视觉上是无操作。
  /// - 图形控制扩展 disposal 置 1（do-not-dispose）：解码器保留画布，
  ///   矩形帧按「上一画布 + 本矩形」合成；循环回到首帧（全画布）时自然覆盖。
  void addIndexedFrame(Uint8List indexed) {
    if (!hasPalette) throw StateError('Palette has not been primed');
    if (indexed.length != width * height) {
      throw ArgumentError('索引图长度 ${indexed.length} 与画布不符');
    }
    var left = 0, top = 0, w = width, h = height;
    final prev = _prevIndexed;
    if (prev != null && rectDiff) {
      var minX = width, minY = height, maxX = -1, maxY = -1;
      for (var y = 0; y < height; y++) {
        final base = y * width;
        for (var x = 0; x < width; x++) {
          if (indexed[base + x] != prev[base + x]) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
          }
        }
      }
      if (maxX >= 0) {
        left = minX;
        top = minY;
        w = maxX - minX + 1;
        h = maxY - minY + 1;
      } else {
        left = 0;
        top = 0;
        w = 1;
        h = 1;
      }
    }
    _body.add(_encodeRectBody(indexed, left, top, w, h));
    _prevIndexed = Uint8List.fromList(indexed);
    _frames++;
  }

  /// 矩形帧片段：GCE（disposal 1）+ 图像描述符（left/top/w/h）+ 子矩形 LZW。
  /// 子矩形取行主序索引，调色板沿用全局板（无局部色表，与全帧路径一致）。
  Uint8List _encodeRectBody(Uint8List indexed, int left, int top, int w, int h) {
    final body = BytesBuilder();
    body.add([
      0x21,
      0xF9,
      0x04,
      0x04, // disposal = 1 (do not dispose), 无透明色
      delayCs & 0xff,
      (delayCs >> 8) & 0xff,
      0x00,
      0x00,
    ]);
    body.add([
      0x2C,
      left & 0xff, (left >> 8) & 0xff,
      top & 0xff, (top >> 8) & 0xff,
      w & 0xff, (w >> 8) & 0xff,
      h & 0xff, (h >> 8) & 0xff,
      0x00, // no local color table, not interlaced
    ]);
    const minCodeSize = 8;
    body.add([minCodeSize]);
    final rect = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      rect.setRange(y * w, (y + 1) * w, indexed, (top + y) * width + left);
    }
    final lzw = GifFrameEncoder.encodeLzw(rect, minCodeSize);
    var off = 0;
    while (off < lzw.length) {
      final n = math.min(255, lzw.length - off);
      body.add([n]);
      body.add(Uint8List.sublistView(lzw, off, off + n));
      off += n;
    }
    body.add([0x00]); // block terminator
    return body.takeBytes();
  }

  List<int> finish() {
    if (_frames == 0) throw StateError('No frames to encode');
    final out = BytesBuilder();
    out.add([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]); // GIF89a
    out.add([
      width & 0xff,
      (width >> 8) & 0xff,
      height & 0xff,
      (height >> 8) & 0xff,
    ]);
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
