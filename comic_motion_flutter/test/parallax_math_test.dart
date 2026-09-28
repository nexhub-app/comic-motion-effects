// 倾斜相位计算单元测试（纯 Dart 逻辑，无传感器依赖）。
import 'dart:math' as math;

import 'package:comic_motion_flutter/src/parallax_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tiltToPhase', () {
    test('设备竖直（重力全部落在 Z 轴）→ 双轴相位为 0', () {
      final (px, py) = tiltToPhase(ax: 0, ay: 0, az: 9.81, maxTiltRad: 0.3);
      expect(px, 0.0);
      expect(py, 0.0);
    });

    test('向右倾斜（+X 重力分量）→ phaseX 为正', () {
      // ax = az = 1 → roll = atan2(1, 1) = 45°。
      final (px, _) =
          tiltToPhase(ax: 1, ay: 0, az: 1, maxTiltRad: degToRad(45));
      expect(px, closeTo(1.0, 1e-9));
    });

    test('向左倾斜 → phaseX 为负', () {
      final (px, _) =
          tiltToPhase(ax: -1, ay: 0, az: 1, maxTiltRad: degToRad(45));
      expect(px, closeTo(-1.0, 1e-9));
    });

    test('前后倾斜（+Y 分量）→ phaseY 为正，phaseX 为 0', () {
      // ay>0、az>0：pitch = atan2(ay, sqrt(ax²+az²))。
      final (px, py) =
          tiltToPhase(ax: 0, ay: 1, az: 1, maxTiltRad: degToRad(45));
      expect(px, 0.0);
      expect(py, closeTo(1.0, 1e-9));
    });

    test('超出满偏角度 → 钳制到 ±1', () {
      // roll = atan2(10, 1) ≈ 84.3°，远超 15° 满偏。
      final (px, _) =
          tiltToPhase(ax: 10, ay: 0, az: 1, maxTiltRad: degToRad(15));
      expect(px, 1.0);
    });

    test('线性区间内相位与倾斜角成正比', () {
      const maxDeg = 30.0;
      final (px15, _) = tiltToPhase(
        ax: math.sin(degToRad(15)),
        ay: 0,
        az: math.cos(degToRad(15)),
        maxTiltRad: degToRad(maxDeg),
      );
      expect(px15, closeTo(15 / maxDeg, 1e-9));
    });

    test('maxTiltRad <= 0 抛 ArgumentError', () {
      expect(
        () => tiltToPhase(ax: 0, ay: 0, az: 1, maxTiltRad: 0),
        throwsArgumentError,
      );
      expect(
        () => tiltToPhase(ax: 0, ay: 0, az: 1, maxTiltRad: -1),
        throwsArgumentError,
      );
    });
  });

  group('degToRad', () {
    test('常规换算', () {
      expect(degToRad(0), 0.0);
      expect(degToRad(180), closeTo(math.pi, 1e-12));
      expect(degToRad(90), closeTo(math.pi / 2, 1e-12));
    });
  });
}
