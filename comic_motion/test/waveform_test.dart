import 'package:test/test.dart';

import 'package:comic_motion/src/render/waveform.dart';

void main() {
  test('snapWave seamless: f(0)==f(1) and dc-free', () {
    expect(snapWave(0.0), closeTo(snapWave(1.0 - 1e-12), 1e-6));
    var sum = 0.0;
    const n = 512;
    for (var i = 0; i < n; i++) {
      sum += snapWave(i / n);
    }
    expect(sum / n, closeTo(0.0, 1e-3));
  });

  test('snapWave C1 at seam: left/right slopes agree (整数谐波 ⇒ 导数连续)', () {
    const h = 1e-6;
    final right = (snapWave(h) - snapWave(0.0)) / h;
    final left = (snapWave(1.0) - snapWave(1.0 - h)) / h;
    expect(left, closeTo(right, 1e-3));
  });

  test('snapWave asymmetric (rise≠fall around peak)', () {
    final pk = [for (var i = 0; i < 1000; i++) i / 1000]
        .reduce((a, b) => snapWave(a) > snapWave(b) ? a : b);
    expect(
      snapWave((pk - 0.05 + 1) % 1),
      isNot(closeTo(snapWave((pk + 0.05) % 1), 1e-3)),
    );
  });

  test('snapWave peak-normalized: max|f| within [0.97, 1.03]', () {
    // 密扫 [0,1)：真极值 u=0.75 落在 1e-6 网格上，测得 |f| 峰值即归一峰值。
    var maxAbs = 0.0;
    const n = 1000000;
    for (var i = 0; i < n; i++) {
      final v = snapWave(i / n).abs();
      if (v > maxAbs) {
        maxAbs = v;
      }
    }
    expect(maxAbs, inInclusiveRange(0.97, 1.03));
    // 接缝值 = raw(0)/peak = 0.42/1.24。
    expect(snapWave(0.0), closeTo(0.42 / 1.24, 1e-12));
  });

  test('snapWave deterministic; negative/≥1 inputs fold into [0,1)', () {
    expect(snapWave(0.3715), snapWave(0.3715));
    expect(snapWave(-0.3), snapWave(0.7));
    expect(snapWave(1.25), snapWave(0.25));
    expect(snapWave(3.75), snapWave(0.75));
    expect(snapWave(0.0), snapWave(1.0));
  });
}
