/// APNG（Animated PNG）流式编码器（第四轮 V3）。
///
/// 路线决策（对齐 doc/roadmap.md 的方案对比）：PNG 容器加 acTL/fcTL/fdAT
/// chunk——纯 Dart 可自研（复用既有 PNG 帧编码器的 IDAT 产物，不新写压缩
/// 代码），真彩色无色带、体积通常优于 GIF（漫画平色画面尤其明显），
/// Chrome/Safari/iOS/Firefox 原生支持。animated WebP（image 包 4.10 已带
/// 编码器但整序列驻留内存）与 WebM/MP4（需原生）见 roadmap。
///
/// 流式内存画像：每帧 PNG 由 [ImageIO.encodePngFrame] 编码后立刻解析出
/// IDAT 载荷、重包为 fdAT 并丢弃原栅格——内存 O(单帧)，与 GIF 主干同构。
///
/// 确定性：无随机、无时钟；同帧序列 → 逐字节相同输出。压缩字节直接复用
/// 既有 PNG 路径（同一 image 包编码器），因此 APNG 帧数据与
/// `frames/frame_NNNN.png` 的 IDAT 载荷逐字节一致（测试锁定）。
///
/// 循环语义：acTL numPlays = 0 → 无限循环（与 GIF loopForever 对齐）；
/// 帧延迟与 GIF 同口径 `delayCs = (100/fps).round().clamp(2, 100)`，
/// 即 delay_num = delayCs、delay_den = 100。dispose = NONE、blend =
/// SOURCE（全画布整帧覆盖，不做帧间差分——rect 优化列入 roadmap）。
library;

import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'image_io.dart';
import 'image_model.dart';

/// APNG 流式构建器：逐帧 addFrame，finish 时产出完整 APNG 字节。
///
/// 每帧输入既可以是栅格（[addFrame]，内部走 [ImageIO.encodePngFrame]），
/// 也可以是已编码的 PNG 字节（[addEncodedPngFrame]——管线并行路径下
/// worker 已回传 PNG 字节，直接复用零重复编码）。
class StreamingApngBuilder {
  StreamingApngBuilder(this.width, this.height,
      {required int fps, bool loopForever = true})
      : defaultDelayCs = (100 / fps).round().clamp(2, 100),
        loopForever = loopForever;

  final int width;
  final int height;

  /// 与 GIF StreamingGifBuilder 同口径的默认帧延迟（厘秒）。
  final int defaultDelayCs;
  final bool loopForever;

  final BytesBuilder _body = BytesBuilder();
  int _frames = 0;
  int _sequence = 0;

  int get frameCount => _frames;

  Uint8List _ihdrPayload = Uint8List(0);

  /// 提交一帧（栅格入口）。[delayCs] 可覆盖默认帧延迟（厘秒）。
  void addFrame(RgbaImage frame, {int? delayCs}) {
    if (frame.width != width || frame.height != height) {
      throw ArgumentError(
          '帧尺寸 ${frame.width}x${frame.height} 与编码器 ${width}x$height 不一致');
    }
    addEncodedPngFrame(
        Uint8List.fromList(ImageIO.encodePngFrame(frame)),
        delayCs: delayCs);
  }

  /// 提交一帧（已编码 PNG 入口）：解析 IHDR/IDAT，IDAT 载荷重包为 fcTL +
  /// fdAT。与 [ImageIO.encodePngFrame] 同源的 PNG 字节可零转换复用。
  void addEncodedPngFrame(Uint8List pngBytes, {int? delayCs}) {
    final parsed = _parsePngFrame(pngBytes);
    final ihdr = parsed.ihdr;
    if (_frames == 0) {
      _ihdrPayload = ihdr;
    } else if (!_listEquals(ihdr, _ihdrPayload)) {
      throw ArgumentError('帧 IHDR 与首帧不一致（尺寸/位深/色彩类型必须固定）');
    }
    final cs = (delayCs ?? defaultDelayCs).clamp(1, 0xffff);
    // fcTL：序号 + 区域（全画布）+ 延迟 + dispose=0(NONE) + blend=0(SOURCE)。
    final fcTL = <int>[
      ..._be32(_sequence++),
      ..._be32(width),
      ..._be32(height),
      ..._be32(0), // x offset
      ..._be32(0), // y offset
      cs >> 8, cs & 0xff, // delay_num（大端 16 位）
      100 >> 8, 100 & 0xff, // delay_den = 100
      0, // dispose_op: APNG_DISPOSE_OP_NONE
      0, // blend_op: APNG_BLEND_OP_SOURCE
    ];
    _body.add(_chunk('fcTL', fcTL));
    for (final idat in parsed.idatPayloads) {
      // fdAT = 序号 + 与 IDAT 相同的 zlib 数据流。
      _body.add(_chunk('fdAT', [..._be32(_sequence++), ...idat]));
    }
    _frames++;
  }

  /// 产出完整 APNG 字节（PNG 签名 + IHDR + acTL + 各帧 + IEND）。
  /// numPlays = 0 → 无限循环。
  List<int> finish() {
    if (_frames == 0) throw StateError('No frames to encode');
    final out = BytesBuilder();
    out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    out.add(_chunk('IHDR', _ihdrPayload));
    out.add(_chunk('acTL', [..._be32(_frames), ..._be32(0)]));
    out.add(_body.takeBytes());
    out.add(_chunk('IEND', const []));
    return out.takeBytes();
  }
}

/// 便捷入口：一次编码整帧序列（内存 O(帧数)；流式消费请用
/// [StreamingApngBuilder]）。[delaysCs] 提供逐帧延迟（厘秒），缺省用 fps。
List<int> encodeApng(List<RgbaImage> frames,
    {int fps = 24, bool loopForever = true, List<int>? delaysCs}) {
  if (frames.isEmpty) throw StateError('No frames to encode');
  final builder =
      StreamingApngBuilder(frames.first.width, frames.first.height,
          fps: fps, loopForever: loopForever);
  for (var i = 0; i < frames.length; i++) {
    builder.addFrame(frames[i],
        delayCs: delaysCs == null ? null : delaysCs[i.clamp(0, delaysCs.length - 1)]);
  }
  return builder.finish();
}

// ---- 内部实现：PNG 解析与 chunk 封装 ----

class _ParsedPngFrame {
  _ParsedPngFrame(this.ihdr, this.idatPayloads);
  final Uint8List ihdr; // 13 字节 IHDR 载荷
  final List<Uint8List> idatPayloads; // 按序拼接前的各 IDAT 载荷
}

/// 解析单帧 PNG：校验签名，取 IHDR 载荷与全部 IDAT 载荷。
_ParsedPngFrame _parsePngFrame(Uint8List png) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (png.length < 8 + 12) {
    throw ArgumentError('PNG 过短，不是合法帧');
  }
  for (var i = 0; i < 8; i++) {
    if (png[i] != signature[i]) throw ArgumentError('PNG 签名不匹配');
  }
  Uint8List? ihdr;
  final idats = <Uint8List>[];
  var off = 8;
  while (off + 12 <= png.length) {
    final len = (png[off] << 24) |
        (png[off + 1] << 16) |
        (png[off + 2] << 8) |
        png[off + 3];
    final type = String.fromCharCodes(png.sublist(off + 4, off + 8));
    final dataOff = off + 8;
    if (dataOff + len + 4 > png.length) {
      throw ArgumentError('PNG chunk 越界');
    }
    if (type == 'IHDR') {
      ihdr = Uint8List.sublistView(png, dataOff, dataOff + len);
    } else if (type == 'IDAT') {
      idats.add(Uint8List.sublistView(png, dataOff, dataOff + len));
    } else if (type == 'IEND') {
      break;
    }
    off = dataOff + len + 4;
  }
  if (ihdr == null || ihdr.length != 13) {
    throw ArgumentError('PNG 缺少 IHDR');
  }
  if (idats.isEmpty) throw ArgumentError('PNG 缺少 IDAT');
  return _ParsedPngFrame(ihdr, idats);
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<int> _be32(int v) => [
      (v >> 24) & 0xff,
      (v >> 16) & 0xff,
      (v >> 8) & 0xff,
      v & 0xff,
    ];

Uint8List _chunk(String type, List<int> data) {
  if (type.length != 4) throw StateError('chunk type must be 4 chars');
  final out = BytesBuilder();
  out.add(_be32(data.length));
  out.add(type.codeUnits);
  out.add(data);
  final crcInput = <int>[...type.codeUnits, ...data];
  final crc = _crc32(crcInput);
  out.add(_be32(crc));
  return out.takeBytes();
}

/// PNG CRC-32（IEEE 802.3 多项式，逐位实现——每帧只算几次，无需查表）。
int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b & 0xff;
    for (var k = 0; k < 8; k++) {
      crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 测试与嵌入方校验用：把 fdAT/IDAT 的 zlib 数据流还原为 8-bit RGB 像素
/// 行（含 PNG 自适应 filter 反演，类型 0-4）。引擎对外帧一律 RGB 3 通道、
/// 非隔行，本函数只覆盖该口径。
Uint8List decodeApngScanlines(Uint8List compressed, int width, int height) {
  final raw = ZLibCodec().decode(compressed);
  final stride = width * 3;
  final expected = height * (stride + 1);
  if (raw.length != expected) {
    throw ArgumentError(
        '解压长度 ${raw.length} 与 $width x $height RGB 扫描线不符（预期 $expected）');
  }
  final rawBytes =
      raw is Uint8List ? raw : Uint8List.fromList(raw);
  final out = Uint8List(height * stride);
  var prevRow = Uint8List(stride); // 全零首行
  for (var y = 0; y < height; y++) {
    final base = y * (stride + 1);
    final filter = rawBytes[base];
    final row =
        Uint8List.sublistView(rawBytes, base + 1, base + 1 + stride);
    final cur = Uint8List(stride);
    for (var i = 0; i < stride; i++) {
      final left = i >= 3 ? cur[i - 3] : 0;
      final up = prevRow[i];
      final upLeft = i >= 3 ? prevRow[i - 3] : 0;
      int value;
      switch (filter) {
        case 0: // None
          value = row[i];
          break;
        case 1: // Sub
          value = row[i] + left;
          break;
        case 2: // Up
          value = row[i] + up;
          break;
        case 3: // Average
          value = row[i] + ((left + up) >> 1);
          break;
        case 4: // Paeth
          final p = left + up - upLeft;
          final pa = (p - left).abs(), pb = (p - up).abs(), pc = (p - upLeft).abs();
          final pred = (pa <= pb && pa <= pc) ? left : (pb <= pc ? up : upLeft);
          value = row[i] + pred;
          break;
        default:
          throw ArgumentError('未知 PNG filter 类型 $filter');
      }
      cur[i] = value & 0xff;
    }
    out.setRange(y * stride, (y + 1) * stride, cur);
    prevRow = cur;
  }
  return out;
}
