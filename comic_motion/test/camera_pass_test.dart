
import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

/// M2 镜头 pass 单测（`render/camera.dart`）：t=0 恒等跳过（首帧对拍
/// 契约）、区域限制、整周期无缝、确定性、snapMask 整纹素语义。
RgbaImage _gradientPage(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, (x * 255 ~/ w), (y * 255 ~/ h), 128);
    }
  }
  return img;
}

CameraRegion _pushIn(PixelRect rect, {double anchorX = 0.5, double anchorY = 0.5}) =>
    CameraRegion(
        rect: rect,
        program: MotionProgram(
            camera: CameraProgram(
                type: CameraType.pushIn, anchorX: anchorX, anchorY: anchorY,
                zoom0: 1.0, zoom1: 1.10, periodSec: 2.0),
            scale: 1, tempo: 1, subjectBoost: 1));

void main() {
  group('镜头 pass（M2）', () {
    test('t=0 恒等：静息帧逐字节不变（首帧对拍契约）', () {
      final page = _gradientPage(200, 120);
      final out = page.clone();
      applyCameraPass(
        frame: out,
        regions: [_pushIn(const PixelRect(0, 0, 200, 120))],
        tSec: 0,
        durationSec: 1.0,
        tier: RenderTier.standard,
      );
      expect(out.data, page.data, reason: 't=0 静息点镜头恒等跳过');
    });

    test('t 中段推镜：帧变化且确定性（同输入两次逐字节）', () {
      final page = _gradientPage(200, 120);
      final a = page.clone();
      final b = page.clone();
      applyCameraPass(
        frame: a,
        regions: [_pushIn(const PixelRect(0, 0, 200, 120))],
        tSec: 0.5,
        durationSec: 1.0,
        tier: RenderTier.standard,
      );
      applyCameraPass(
        frame: b,
        regions: [_pushIn(const PixelRect(0, 0, 200, 120))],
        tSec: 0.5,
        durationSec: 1.0,
        tier: RenderTier.standard,
      );
      expect(a.data, b.data);
      var diff = 0;
      for (var i = 0; i < a.data.length; i++) {
        if (a.data[i] != page.data[i]) diff++;
      }
      expect(diff, greaterThan(0), reason: '推镜中段必须改变画面');
    });

    test('整周期无缝：t=0 与 t=duration 逐字节一致', () {
      final page = _gradientPage(200, 120);
      final a = page.clone();
      final b = page.clone();
      applyCameraPass(
        frame: a,
        regions: [
          CameraRegion(
              rect: const PixelRect(0, 0, 200, 120),
              program: const MotionProgram(
                  camera: CameraProgram(
                      type: CameraType.drift, anchorX: 0.5, anchorY: 0.5,
                      driftAmp: 0.015, periodSec: 0.5),
                  scale: 1, tempo: 1, subjectBoost: 1)),
        ],
        tSec: 1.0, // 恰两个整周期
        durationSec: 1.0,
        tier: RenderTier.standard,
      );
      applyCameraPass(
        frame: b,
        regions: [
          CameraRegion(
              rect: const PixelRect(0, 0, 200, 120),
              program: const MotionProgram(
                  camera: CameraProgram(
                      type: CameraType.drift, anchorX: 0.5, anchorY: 0.5,
                      driftAmp: 0.015, periodSec: 0.5),
                  scale: 1, tempo: 1, subjectBoost: 1)),
        ],
        tSec: 0,
        durationSec: 1.0,
        tier: RenderTier.standard,
      );
      expect(a.data, b.data, reason: 'sin 载体整周期闭合：t=dur 处回到静息');
    });

    test('none 区域不触碰；区域外像素不越界（格级镜头）', () {
      final page = _gradientPage(200, 120);
      final out = page.clone();
      applyCameraPass(
        frame: out,
        regions: [
          const CameraRegion(
              rect: PixelRect(0, 0, 200, 60),
              program: MotionProgram(
                  camera: CameraProgram.none,
                  scale: 1,
                  tempo: 1,
                  subjectBoost: 1)),
        ],
        tSec: 0.5,
        durationSec: 1.0,
        tier: RenderTier.standard,
      );
      expect(out.data, page.data, reason: 'camera none 恒等');
      // 下一格（y 60..120）推镜：只动本格。
      final half = page.clone();
      applyCameraPass(
        frame: half,
        regions: [_pushIn(const PixelRect(0, 60, 200, 60))],
        tSec: 0.5,
        durationSec: 1.0,
        tier: RenderTier.standard,
      );
      var outsideDiff = 0;
      for (var y = 0; y < 60; y++) {
        for (var x = 0; x < 200; x++) {
          final o = (y * 200 + x) * 4;
          if (half.data[o] != page.data[o]) outsideDiff++;
        }
      }
      expect(outsideDiff, 0, reason: '镜头不越出格矩形');
      var insideDiff = 0;
      for (var y = 60; y < 120; y++) {
        for (var x = 0; x < 200; x++) {
          final o = (y * 200 + x) * 4;
          if (half.data[o] != page.data[o]) insideDiff++;
        }
      }
      expect(insideDiff, greaterThan(0));
    });
  });
}
