import 'dart:io' as io;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'image_model.dart';

/// Image IO facade over the pure-Dart `image` package.
class ImageIO {
  /// 解码像素总量默认上限（40M 像素 ≈ 160MB RGBA 栅格）。
  /// 边长上限挡不住「边长合法的方形大图」——12000×12000 解压后约 576MB，
  /// 嵌入移动端直接 OOM，所以按像素总量再设一道闸。调用方可通过
  /// [decode] / [decodeFile] 的 `maxPixels` 参数按设备能力收紧或放宽。
  static const int defaultMaxPixels = 40 * 1000 * 1000;

  /// Decode from bytes. Throws typed exceptions for bad input.
  static RgbaImage decode(List<int> bytes, {int maxPixels = defaultMaxPixels}) {
    if (bytes.isEmpty) {
      throw ImageDecodeException('文件为空（0 字节），不是有效图片');
    }
    // Guard: text files pretending to be images.
    final head = bytes.take(16).toList();
    final printableHead =
        head.every((b) => (b >= 0x09 && b <= 0x0d) || (b >= 0x20 && b < 0x7f));
    if (printableHead && bytes.length > 8) {
      throw ImageDecodeException('文件内容是文本，不是图片（仅支持 JPEG/PNG/WebP）');
    }
    // 头解析即拒：从文件头读出宽高后立刻校验像素总量，在分配整幅
    // 栅格之前拒绝像素炸弹。嗅探不出的格式或损坏头部回落到全解码
    // 路径，由解码结果处的兜底校验拒绝。
    final header = _sniffDimensions(bytes);
    if (header != null) {
      _checkPixelBudget(header.$1, header.$2, maxPixels);
    }
    final im = img.decodeImage(Uint8List.fromList(bytes));
    if (im == null) {
      throw ImageDecodeException('无法解码图片（支持格式：JPEG/PNG/WebP；文件可能已损坏）');
    }
    if (im.width > RgbaImage.maxDimension ||
        im.height > RgbaImage.maxDimension) {
      throw ImageTooLargeException(im.width, im.height);
    }
    if (im.width * im.height > maxPixels) {
      throw ImageTooLargeException(im.width, im.height,
          pixelCount: im.width * im.height, maxPixels: maxPixels);
    }
    return _fromPackage(im);
  }

  /// Decode from file, with size guard before reading (prevents OOM).
  static RgbaImage decodeFile(String path,
      {int maxFileBytes = 64 * 1024 * 1024,
      int maxPixels = defaultMaxPixels}) {
    final f = io.File(path);
    if (!f.existsSync()) {
      throw ImageDecodeException('文件不存在: $path');
    }
    final len = f.lengthSync();
    if (len == 0) {
      throw ImageDecodeException('文件为空（0 字节）: $path');
    }
    if (len > maxFileBytes) {
      throw ImageTooLargeException(len, 0);
    }
    return decode(f.readAsBytesSync(), maxPixels: maxPixels);
  }

  static void _checkPixelBudget(int width, int height, int maxPixels) {
    // 尺寸非法（腐坏头部）不在此处定论，交给全解码路径报损坏。
    if (width <= 0 || height <= 0) return;
    // 短路次序保证乘法只在两维各自不超上限时执行，乘积有界不溢出。
    if (width > maxPixels || height > maxPixels || width * height > maxPixels) {
      final count = width <= maxPixels && height <= maxPixels
          ? width * height
          : null;
      throw ImageTooLargeException(width, height,
          pixelCount: count, maxPixels: maxPixels);
    }
  }

  /// 从文件头直接读出 (宽, 高)，用于在分配整幅栅格前拒绝像素炸弹。
  /// 返回 null 表示头不完整或格式未识别——交给全解码路径处理。
  static (int, int)? _sniffDimensions(List<int> b) {
    try {
      if (b.length >= 24 &&
          b[0] == 0x89 &&
          b[1] == 0x50 &&
          b[2] == 0x4E &&
          b[3] == 0x47) {
        // PNG：8 字节签名 + IHDR 块头（长度 4 + 类型 4），宽高在偏移 16/20。
        return (_beU32(b, 16), _beU32(b, 20));
      }
      if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
        return _jpegDimensions(b);
      }
      if (b.length >= 16 &&
          b[0] == 0x52 &&
          b[1] == 0x49 &&
          b[2] == 0x46 &&
          b[3] == 0x46 &&
          b[8] == 0x57 &&
          b[9] == 0x45 &&
          b[10] == 0x42 &&
          b[11] == 0x50) {
        return _webpDimensions(b);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static int _beU32(List<int> b, int i) =>
      (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

  /// JPEG：沿记号流走到首个 SOF 段（帧头），段内偏移 +5/+7 处是高/宽。
  static (int, int)? _jpegDimensions(List<int> b) {
    const sofMarkers = {
      0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, //
      0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
    };
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) return null;
      final marker = b[i + 1];
      if (marker == 0xFF) {
        i += 1; // 填充字节
        continue;
      }
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2; // 无长度段的独立记号
        continue;
      }
      if (marker == 0xDA) return null; // 进入扫描数据，后面不再有 SOF
      final segLen = (b[i + 2] << 8) | b[i + 3];
      if (segLen < 2) return null;
      if (sofMarkers.contains(marker)) {
        final h = (b[i + 5] << 8) | b[i + 6];
        final w = (b[i + 7] << 8) | b[i + 8];
        return (w, h);
      }
      i += 2 + segLen;
    }
    return null;
  }

  /// WebP：按首 chunk 类型（VP8 有损 / VP8L 无损 / VP8X 扩展）分别取宽高。
  static (int, int)? _webpDimensions(List<int> b) {
    final fourcc = String.fromCharCodes(b.sublist(12, 16));
    switch (fourcc) {
      case 'VP8 ':
        // 帧标签 3 字节 + 同步码 0x9D 0x01 0x2A，随后是 14bit 宽、14bit 高。
        if (b.length < 30 ||
            b[23] != 0x9D ||
            b[24] != 0x01 ||
            b[25] != 0x2A) {
          return null;
        }
        return ((b[26] | (b[27] << 8)) & 0x3FFF, (b[28] | (b[29] << 8)) & 0x3FFF);
      case 'VP8L':
        if (b.length < 25 || b[20] != 0x2F) return null;
        final w = (b[21] | ((b[22] & 0x3F) << 8)) + 1;
        final h = ((b[22] >> 6) | (b[23] << 2) | ((b[24] & 0x0F) << 10)) + 1;
        return (w, h);
      case 'VP8X':
        // 4 字节标志后是 24bit 的画布宽-1、高-1（小端）。
        if (b.length < 30) return null;
        return ((b[24] | (b[25] << 8) | (b[26] << 16)) + 1,
            (b[27] | (b[28] << 8) | (b[29] << 16)) + 1);
      default:
        return null;
    }
  }

  static RgbaImage _fromPackage(img.Image im) {
    return RgbaImage.fromBytes(
        width: im.width,
        height: im.height,
        data: im.getBytes(order: img.ChannelOrder.rgba));
  }

  static img.Image _toPackage(RgbaImage frame) {
    final rgb = _toRgbBuffer(frame);
    return img.Image.fromBytes(
        width: frame.width,
        height: frame.height,
        bytes: rgb.buffer,
        numChannels: 3);
  }

  /// 引擎内部栅格是 RGBA，但对外产物（PNG 帧序列 / GIF 帧）一律丢 alpha 走
  /// RGB —— v1.2 即如此，改通道数会让帧序列字节发生变化、破坏可复现契约。
  static Uint8List _toRgbBuffer(RgbaImage frame) {
    final n = frame.pixelCount;
    final out = Uint8List(n * 3);
    final d = frame.data;
    for (var i = 0, s = 0, o = 0; i < n; i++, s += 4, o += 3) {
      out[o] = d[s];
      out[o + 1] = d[s + 1];
      out[o + 2] = d[s + 2];
    }
    return out;
  }

  /// Encode full frame list to an animated GIF.
  static List<int> encodeGifAnimated(List<RgbaImage> frames,
      {int delayCentisecs = 4}) {
    if (frames.isEmpty) throw StateError('没有帧可编码');
    final first = _toPackage(frames.first);
    final anim =
        img.Image(width: first.width, height: first.height, numChannels: 3);
    for (final f in frames) {
      final added = anim.addFrame(_toPackage(f));
      added.frameDuration = delayCentisecs * 10; // ms
    }
    return img.encodeGif(anim).toList();
  }

  /// Encode one frame as PNG bytes (used by streaming frame writer).
  static List<int> encodePngFrame(RgbaImage frame) {
    return img.encodePng(_toPackage(frame)).toList();
  }

  /// 帧序列的统一命名：串行、worker、调色板探针三条路径必须写同一个路径，
  /// 否则并行会产出不同文件名。
  static String pngPathFor(String dir, int index) =>
      '$dir/frame_${index.toString().padLeft(4, '0')}.png';

  static String writePngFrame(String dir, int index, RgbaImage frame) {
    final p = pngPathFor(dir, index);
    io.File(p).writeAsBytesSync(encodePngFrame(frame));
    return p;
  }

  /// Write frames as a PNG sequence; returns file paths written.
  static List<String> writeFrameSequence(List<RgbaImage> frames, String dir,
      {String prefix = 'frame'}) {
    io.Directory(dir).createSync(recursive: true);
    final paths = <String>[];
    for (var i = 0; i < frames.length; i++) {
      final p = '$dir/${prefix}_${i.toString().padLeft(4, '0')}.png';
      io.File(p).writeAsBytesSync(img.encodePng(_toPackage(frames[i])));
      paths.add(p);
    }
    return paths;
  }
}
