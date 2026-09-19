import 'dart:io' as io;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'image_model.dart';

/// Image IO facade over the pure-Dart `image` package.
class ImageIO {
  /// Decode from bytes. Throws typed exceptions for bad input.
  static RgbaImage decode(List<int> bytes) {
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
    final im = img.decodeImage(Uint8List.fromList(bytes));
    if (im == null) {
      throw ImageDecodeException('无法解码图片（支持格式：JPEG/PNG/WebP；文件可能已损坏）');
    }
    if (im.width > RgbaImage.maxDimension ||
        im.height > RgbaImage.maxDimension) {
      throw ImageTooLargeException(im.width, im.height);
    }
    return _fromPackage(im);
  }

  /// Decode from file, with size guard before reading (prevents OOM).
  static RgbaImage decodeFile(String path,
      {int maxFileBytes = 64 * 1024 * 1024}) {
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
    return decode(f.readAsBytesSync());
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
      '$dir\\frame_${index.toString().padLeft(4, '0')}.png';

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
      final p = '$dir\\${prefix}_${i.toString().padLeft(4, '0')}.png';
      io.File(p).writeAsBytesSync(img.encodePng(_toPackage(frames[i])));
      paths.add(p);
    }
    return paths;
  }
}
