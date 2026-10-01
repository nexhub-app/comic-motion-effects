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

/// Gray circular blob of luminance [v] — a weaker sibling of [inkBlob].
void _blob(RgbaImage img, int cx, int cy, int r, int v) {
  for (var y = cy - r; y <= cy + r; y++)
    for (var x = cx - r; x <= cx + r; x++)
      if (x >= 0 && y >= 0 && x < img.width && y < img.height &&
          (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r)
        img.setPixel(x, y, v, v, v);
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

  test('activity stays absolute: near-white noise page max < 0.05', () {
    // Regression guard for R3: activity must be in ABSOLUTE units. A min/max
    // normalization ramp would push this low-contrast field's max toward 1.0
    // (its range exceeds the ramp's 1e-6 flat-field guard), breaking the
    // activity-weighted-particle fallback; <0.05 proves activity stayed
    // absolute. Fixture is a near-white page (base 250) with deterministic
    // ±2 per-pixel jitter (channels stay in [245,252]) — no ink, no RNG.
    final img = RgbaImage(width: 64, height: 64);
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        final jitter = ((x * 3 + y * 7) % 5) - 2; // deterministic, in [-2,2]
        final v = (250 + jitter).clamp(245, 252);
        img.setPixel(x, y, v, v, v);
      }
    }
    final a = const SaliencyAnalyzer().activity(img, 64, 64);
    final maxV = a.reduce((x, y) => x > y ? x : y);
    expect(maxV, lessThan(0.05));
  });

  test('subjectBox encloses the dark blob only', () {
    final img = whitePage(64, 64);
    inkBlob(img, 32, 32, 8);
    final s = const SaliencyAnalyzer();
    final box = s.subjectBox(s.activity(img, 64, 64), 64, 64);
    expect(box.x, lessThanOrEqualTo(25));
    expect(box.y, lessThanOrEqualTo(25));
    expect(box.x + box.width, greaterThanOrEqualTo(40));
    expect(box.y + box.height, greaterThanOrEqualTo(40));
    expect(box.width, lessThan(50));
  });

  test('anchors: two blobs → weight-ordered, darker ranks first', () {
    final img = whitePage(64, 64);
    inkBlob(img, 16, 32, 6); // darker+higher-contrast → higher activity
    _blob(img, 48, 32, 6, 90); // mid gray
    final s = const SaliencyAnalyzer();
    final act = s.activity(img, 64, 64);
    final an = s.anchors(act, 64, 64, s.subjectBox(act, 64, 64));
    expect(an.length, greaterThanOrEqualTo(2));
    expect(an.first.nx, lessThan(0.5));
    expect(an.first.weight, greaterThanOrEqualTo(an[1].weight));
  });
}
