/// Core image model: an 8-bit RGBA raster used across the engine.
library;

/// RGBA image with row-major storage. Alpha is 255 (opaque) for normal pixels.
class RgbaImage {
  RgbaImage({required this.width, required this.height})
      : data = List<int>.filled(width * height * 4, 0, growable: false);

  final int width;
  final int height;
  final List<int> data; // RGBA, 4 bytes per pixel

  int get pixelCount => width * height;

  bool get isValidSize =>
      width > 0 && height > 0 && width <= maxDimension && height <= maxDimension;

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
    img.data.setAll(0, data);
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

/// Decode failures carry a user-facing reason; batch jobs record them.
class ImageDecodeException implements Exception {
  ImageDecodeException(this.message);
  final String message;

  @override
  String toString() => 'ImageDecodeException: $message';
}

class ImageTooLargeException implements Exception {
  ImageTooLargeException(this.width, this.height);
  final int width;
  final int height;

  @override
  String toString() =>
      'ImageTooLargeException: 图片尺寸 ${width}x$height 超过上限 ${RgbaImage.maxDimension}';
}
