/// Core image model: an 8-bit RGBA raster used across the engine.
library;

import 'dart:typed_data';

/// RGBA image with row-major storage. Alpha is 255 (opaque) for normal pixels.
class RgbaImage {
  RgbaImage({required this.width, required this.height})
      : data = Uint8List(width * height * 4);

  /// Wrap an existing RGBA raster (4 bytes per pixel, no copy).
  RgbaImage.fromBytes(
      {required this.width, required this.height, required this.data})
      : assert(data.length == width * height * 4,
            'Raster length ${data.length} does not match ${width}x$height');

  final int width;
  final int height;
  final Uint8List data; // RGBA, 4 bytes per pixel

  int get pixelCount => width * height;

  bool get isValidSize =>
      width > 0 &&
      height > 0 &&
      width <= maxDimension &&
      height <= maxDimension;

  static const int maxDimension = 12000;

  int red(int i) => data[i * 4];
  int green(int i) => data[i * 4 + 1];
  int blue(int i) => data[i * 4 + 2];
  int alpha(int i) => data[i * 4 + 3];

  void setPixel(int x, int y, int r, int g, int b, [int a = 255]) {
    final i = (y * width + x) * 4;
    data[i] = r & 0xff;
    data[i + 1] = g & 0xff;
    data[i + 2] = b & 0xff;
    data[i + 3] = a & 0xff;
  }

  int luminance(int i) {
    final r = data[i * 4], g = data[i * 4 + 1], b = data[i * 4 + 2];
    return (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255);
  }

  RgbaImage clone() {
    final img = RgbaImage(width: width, height: height);
    img.data.setRange(0, data.length, data);
    return img;
  }

  /// In-bounds bilinear sample at floating-point coordinates.
  /// Out-of-range samples clamp to the edge.
  void sampleBilinear(double fx, double fy, List<int> out) {
    final cx = fx.clamp(0.0, (width - 1).toDouble());
    final cy = fy.clamp(0.0, (height - 1).toDouble());
    final x0 = cx.floor(), y0 = cy.floor();
    final x1 = (x0 + 1).clamp(0, width - 1);
    final y1 = (y0 + 1).clamp(0, height - 1);
    final tx = cx - x0, ty = cy - y0;
    for (var c = 0; c < 4; c++) {
      final p00 = data[(y0 * width + x0) * 4 + c].toDouble();
      final p10 = data[(y0 * width + x1) * 4 + c].toDouble();
      final p01 = data[(y1 * width + x0) * 4 + c].toDouble();
      final p11 = data[(y1 * width + x1) * 4 + c].toDouble();
      final top = p00 + (p10 - p00) * tx;
      final bot = p01 + (p11 - p01) * tx;
      out[c] = (top + (bot - top) * ty).round().clamp(0, 255);
    }
  }
}

/// Decode failure with a machine-readable [code] so callers can branch
/// programmatically instead of parsing messages. Codes align with the HTTP
/// API error-code table (docs/api.md in comic_motion_server):
/// `E_DECODE_EMPTY`, `E_DECODE_CORRUPT`, `E_DECODE_NOT_FOUND`.
class ImageDecodeException implements Exception {
  ImageDecodeException(this.message, {this.code = 'E_DECODE_CORRUPT'});

  /// Human-readable English reason; batch jobs record it in the ledger.
  final String message;

  /// Stable error code, e.g. `E_DECODE_EMPTY` for a 0-byte input.
  final String code;

  @override
  String toString() => 'ImageDecodeException [$code]: $message';
}

/// Size rejection with a machine-readable code (`E_TOO_LARGE`).
///
/// Carries both the offending dimensions and — when the rejection happened
/// at the pixel-budget check — the actual pixel count and the budget, so the
/// message is actionable on mobile devices where memory is tight.
class ImageTooLargeException implements Exception {
  ImageTooLargeException(this.width, this.height,
      {this.code = 'E_TOO_LARGE', this.pixelCount, this.maxPixels});
  final int width;
  final int height;

  /// Stable error code; always `E_TOO_LARGE` today.
  final String code;

  /// 实际像素总量。头解析阶段即可精确计算时提供；单边已经超纲、
  /// 乘积可能溢出的腐坏头部下为 null。
  final int? pixelCount;

  /// 像素总量上限。像素预算拒绝时提供，与 [pixelCount] 配对出现。
  final int? maxPixels;

  @override
  String toString() {
    if (maxPixels != null) {
      final count = pixelCount != null ? ' ($pixelCount pixels),' : '';
      return 'ImageTooLargeException [$code]: image ${width}x$height$count '
          'exceeds the pixel budget of $maxPixels '
          '(edge limit ${RgbaImage.maxDimension} is enforced separately)';
    }
    return 'ImageTooLargeException [$code]: image size ${width}x$height '
        'exceeds the limit of ${RgbaImage.maxDimension}px';
  }
}
