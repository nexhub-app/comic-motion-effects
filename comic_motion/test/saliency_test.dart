import 'package:test/test.dart';
import 'package:comic_motion/comic_motion.dart';

RgbaImage whitePage(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var i = 0; i < img.pixelCount; i++) img.setPixel(i % w, i ~/ w, 250, 250, 250);
  return img;
}
void inkBlob(RgbaImage img, int cx, int cy, int r) {
  for (var y = cy - r; y <= cy + r; y++)
    for (var x = cx - r; x <= cx + r; x++)
      if (x >= 0 && y >= 0 && x < img.width && y < img.height &&
          (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r)
        img.setPixel(x, y, 20, 20, 20);
}

void main() {
  test('activity peaks on dark ink blob, low on blank margin', () {
    final img = whitePage(64, 64);
    inkBlob(img, 32, 32, 8);
    final a = const SaliencyAnalyzer().activity(img, 64, 64);
    double at(int x, int y) => a[y * 64 + x];
    expect(at(32, 32), greaterThan(0.35));
    expect(at(2, 2), lessThan(at(32, 32) * 0.4));
  });

  test('activity stays absolute: all-white blank page max < 0.05', () {
    // Regression guard for R3: activity must be in ABSOLUTE units. A min/max
    // normalization ramp would amplify blank-page noise to the full 0..1
    // range (max ~1.0) and break the activity-weighted-particle fallback.
    final img = RgbaImage(width: 64, height: 64);
    for (var i = 0; i < img.pixelCount; i++) {
      img.setPixel(i % 64, i ~/ 64, 255, 255, 255);
    }
    final a = const SaliencyAnalyzer().activity(img, 64, 64);
    final maxV = a.reduce((x, y) => x > y ? x : y);
    expect(maxV, lessThan(0.05));
  });
}
