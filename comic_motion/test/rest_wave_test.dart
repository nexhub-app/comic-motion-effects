/// restSnapWave（text sharp v1.10）契约测试：静息归零、无缝循环、峰值归一、
/// 确定性。snapWave 本体契约见 waveform_test.dart（本体零改动）。
import 'dart:math' as math;

import 'package:comic_motion/src/render/waveform.dart';
import 'package:test/test.dart';

void main() {
  group('restSnapWave', () {
    test('静息点精确归零：u == uRest 恒为 0', () {
      for (var i = 0; i < 200; i++) {
        final uRest = i / 199.0;
        expect(restSnapWave(uRest, uRest), 0.0,
            reason: 'uRest=$uRest 处必须精确为 0（首帧=原画的机制保证）');
      }
    });

    test('周期性：u 推进整数圈回到静息值（无缝循环契约）', () {
      for (var i = 0; i < 50; i++) {
        final uRest = i / 50.0;
        for (var k = 1; k <= 3; k++) {
          final u = uRest + k;
          expect(restSnapWave(u, uRest), closeTo(0.0, 1e-12),
              reason: 'uRest=$uRest + $k 圈');
        }
      }
    });

    test('峰值归一：|restSnapWave| ≤ 1（amplitude 语义=峰值像素幅度）', () {
      var peak = 0.0;
      for (var iRest = 0; iRest < 64; iRest++) {
        final uRest = iRest / 64.0;
        for (var i = 0; i < 1024; i++) {
          final v = restSnapWave(i / 1024.0, uRest).abs();
          if (v > peak) peak = v;
        }
      }
      expect(peak, lessThanOrEqualTo(1.0 + 1e-9));
      // 最坏静息点（uRest=直流点 0，base=0.3387）负向满幅应可达 ≈1.0。
      final worst = restSnapWave(0.75, 0.0);
      expect(worst, closeTo(-1.0, 1e-9));
    });

    test('纯函数确定性：同输入同输出', () {
      for (var i = 0; i < 100; i++) {
        final u = i / 97.0, uRest = i / 31.0;
        expect(restSnapWave(u, uRest), restSnapWave(u, uRest));
      }
    });

    test('与 snapWave 同族：形状差一个常数缩放', () {
      // restSnapWave(u, uRest) = (snapWave(u) − snapWave(uRest)) / (1 + |base|)
      for (var i = 0; i < 50; i++) {
        final u = i / 50.0, uRest = 0.3;
        final base = snapWave(uRest);
        final expected = (snapWave(u) - base) / (1.0 + base.abs());
        expect(restSnapWave(u, uRest), closeTo(expected, 1e-15));
      }
    });

    test('t=0 语义：视差通道的 uRest = parity/(2π)（rank·π 相位）', () {
      // rank 0/1/2 的 parity 相位都应静息归零（v1.9 前三档都有 0.3387 直流）。
      for (final rank in [0, 1, 2]) {
        final uRest = rank * math.pi / (2 * math.pi);
        expect(restSnapWave(uRest, uRest), 0.0);
        // 旧路径在静息点的非零值（对照：snapWave 有直流）。
        expect(snapWave(uRest) != 0.0 || rank == 0, isTrue);
      }
    });

    test('kSnapWaveRestOffset = snapWave(0)（文档常数一致性）', () {
      expect(kSnapWaveRestOffset, closeTo(snapWave(0.0), 1e-15));
      expect(kSnapWaveRestOffset, closeTo(0.42 / 1.24, 1e-12));
    });
  });
}
