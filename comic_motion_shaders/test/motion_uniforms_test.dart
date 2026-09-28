// W7 uniform 映射逻辑单测（布局契约/钳制/时钟映射）。
// 布局契约：toFloats() 索引序 = assets/shaders/comic_motion.frag 的
// float uniform 声明序（见 README uniform 表）。
import 'package:comic_motion_shaders/comic_motion_shaders.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MotionUniforms.toFloats', () {
    test('长度恒为 kFloatCount 且默认全关', () {
      final f = const MotionUniforms().toFloats();
      expect(f.length, kFloatCount);
      expect(f[MotionUniforms.kIndexParallaxOn], 0.0);
      expect(f[MotionUniforms.kIndexBreathingOn], 0.0);
      expect(f[MotionUniforms.kIndexSweepOn], 0.0);
      expect(f[MotionUniforms.kIndexVignetteOn], 0.0);
    });

    test('开关与参数按布局契约落位', () {
      final f = MotionUniforms(
        parallax: true,
        parallaxDx: 0.02,
        parallaxDy: 0.03,
        depth: const [0, 0.5, 1.0],
        breathing: true,
        zoom: 0.04,
        phase: 0.25,
        sweep: true,
        sweepPosition: 0.7,
        sweepWidth: 0.1,
        sweepIntensity: 0.5,
        vignette: true,
        vignetteStrength: 0.6,
        vignetteSoftness: 0.4,
        canvasWidth: 800,
        canvasHeight: 1200,
      ).toFloats();

      expect(f[MotionUniforms.kIndexParallaxOn], 1.0);
      expect(f[MotionUniforms.kIndexParallaxX], closeTo(0.02, 1e-6));
      expect(f[MotionUniforms.kIndexParallaxY], closeTo(0.03, 1e-6));
      expect(f[MotionUniforms.kIndexDepth0], 0.0);
      expect(f[MotionUniforms.kIndexDepth1], 0.5);
      expect(f[MotionUniforms.kIndexDepth2], 1.0);
      expect(f[MotionUniforms.kIndexDepth3], 0.0); // 不足 4 层补 0
      expect(f[MotionUniforms.kIndexBreathingOn], 1.0);
      expect(f[MotionUniforms.kIndexZoom], closeTo(0.04, 1e-6));
      expect(f[MotionUniforms.kIndexPhase], closeTo(0.25, 1e-6));
      expect(f[MotionUniforms.kIndexSweepOn], 1.0);
      expect(f[MotionUniforms.kIndexSweepPos], closeTo(0.7, 1e-6));
      expect(f[MotionUniforms.kIndexSweepWidth], closeTo(0.1, 1e-6));
      expect(f[MotionUniforms.kIndexSweepIntensity], closeTo(0.5, 1e-6));
      expect(f[MotionUniforms.kIndexVignetteOn], 1.0);
      expect(f[MotionUniforms.kIndexVignetteStrength], closeTo(0.6, 1e-6));
      expect(f[MotionUniforms.kIndexVignetteSoftness], closeTo(0.4, 1e-6));
      expect(f[MotionUniforms.kIndexSizeX], 800.0);
      expect(f[MotionUniforms.kIndexSizeY], 1200.0);
    });

    test('数值钳制：视差/缩放/强度/带宽越界收敛', () {
      final f = MotionUniforms(
        parallax: true,
        parallaxDx: -3,
        parallaxDy: 5,
        breathing: true,
        zoom: 9,
        phase: 7,
        sweep: true,
        sweepPosition: -9,
        sweepWidth: 0,
        sweepIntensity: 4,
        vignette: true,
        vignetteStrength: -1,
        vignetteSoftness: 3,
        canvasWidth: -5,
        canvasHeight: 0,
      ).toFloats();

      expect(f[MotionUniforms.kIndexParallaxX], -1.0);
      expect(f[MotionUniforms.kIndexParallaxY], 1.0);
      expect(f[MotionUniforms.kIndexZoom], 0.5);
      expect(f[MotionUniforms.kIndexPhase], 1.0);
      expect(f[MotionUniforms.kIndexSweepPos], -0.5);
      expect(f[MotionUniforms.kIndexSweepWidth], 1e-4);
      expect(f[MotionUniforms.kIndexSweepIntensity], 1.0);
      expect(f[MotionUniforms.kIndexVignetteStrength], 0.0);
      expect(f[MotionUniforms.kIndexVignetteSoftness], 1.0);
      expect(f[MotionUniforms.kIndexSizeX], 1.0); // 非正尺寸按 1
      expect(f[MotionUniforms.kIndexSizeY], 1.0);
    });

    test('深度数组定长化：截断 + 补 0 + 逐项钳制', () {
      final f = MotionUniforms(
        parallax: true,
        depth: const [0.0, 2.0, 0.5, -0.3, 0.9], // 5 项截到 4，2/-0.3 钳制
      ).toFloats();
      expect(f[MotionUniforms.kIndexDepth0], 0.0);
      expect(f[MotionUniforms.kIndexDepth1], 1.0);
      expect(f[MotionUniforms.kIndexDepth2], 0.5);
      expect(f[MotionUniforms.kIndexDepth3], 0.0);
    });
  });

  group('MotionUniforms.depthFactors', () {
    test('单层/空层全 0（基准层不位移）', () {
      expect(MotionUniforms.depthFactors(1), const [0, 0, 0, 0]);
      expect(MotionUniforms.depthFactors(0), const [0, 0, 0, 0]);
    });

    test('4 层线性铺开 0..1', () {
      final d = MotionUniforms.depthFactors(4);
      expect(d[0], 0.0);
      expect(d[1], closeTo(1 / 3, 1e-9));
      expect(d[2], closeTo(2 / 3, 1e-9));
      expect(d[3], 1.0);
    });

    test('超上限层数按 4 层计算（shader sampler 上限）', () {
      expect(MotionUniforms.depthFactors(9), MotionUniforms.depthFactors(4));
    });
  });

  group('sweepPositionFor（时钟映射）', () {
    const period = Duration(seconds: 2);

    test('t=0 起点为 -half（光带完全在场外）', () {
      expect(
        sweepPositionFor(
            elapsed: Duration.zero, period: period, halfWidth: 0.1),
        closeTo(-0.1, 1e-9),
      );
    });

    test('t=period/2 时中心过场中央', () {
      expect(
        sweepPositionFor(
            elapsed: const Duration(seconds: 1),
            period: period,
            halfWidth: 0.1),
        closeTo(0.5, 1e-9),
      );
    });

    test('t=period 终点为 1+half 后循环（取模回到起点）', () {
      final end = sweepPositionFor(
          elapsed: period, period: period, halfWidth: 0.1);
      expect(end, closeTo(-0.1, 1e-9)); // elapsed % period == 0
    });
  });
}
