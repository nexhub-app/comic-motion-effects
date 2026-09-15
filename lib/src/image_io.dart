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
    final out = RgbaImage(width: im.width, height: im.height);
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        final p = im.getPixel(x, y);
        out.setPixel(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), p.a.toInt());
      }
    }
    return out;
  }

  static img.Image _toPackage(RgbaImage frame) {
    final im =
        img.Image(width: frame.width, height: frame.height, numChannels: 3);
    final data = frame.data;
    for (var y = 0; y < frame.height; y++) {
      for (var x = 0; x < frame.width; x++) {
        final i = (y * frame.width + x) * 4;
        im.setPixelRgb(x, y, data[i], data[i + 1], data[i + 2]);
      }
    }
    return im;
  }

  /// Encode full frame list to an animated GIF.
  static List<int> encodeGifAnimated(List<RgbaImage> frames,
      {int delayCentisecs = 4}) {
    if (frames.isEmpty) throw StateError('没有帧可编码');
    final first = _toPackage(frames.first);
    final anim = img.Image(
        width: first.width, height: first.height, numChannels: 3);
    for (final f in frames) {
      final fr = _toPackage(f);
      final frameImg = img.copyResize(fr,
          width: fr.width,
          height: fr.height,
          interpolation: img.Interpolation.nearest);
      final added = anim.addFrame(frameImg);
      added.frameDuration = delayCentisecs * 10; // ms
    }
    return img.encodeGif(anim).toList();
  }

  /// Encode one frame as PNG bytes (used by streaming frame writer).
  static List<int> encodePngFrame(RgbaImage frame) {
    return img.encodePng(_toPackage(frame)).toList();
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
