import 'dart:convert';

import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

/// M2 运动程序单测（`motion_redesign_plan_20261025.md` §3 程序表）：
/// 类别 → 确定性镜头配方、JSON 往返、灭点/主体锚点。
PanelDiagnosis _diag(PanelClass cls, PanelMotionFeatures features,
    {PanelMotionStrategy strategy = PanelMotionStrategy.neutral}) {
  return PanelDiagnosis(cls: cls, clsConf: 0.8, features: features, strategy: strategy);
}

void main() {
  const table = MotionProgramTable();

  group('程序表（方案 §3）', () {
    test('action：pushIn 快推 zoom 1.0→1.10，锚点=灭点', () {
      final d = _diag(PanelClass.action, const PanelMotionFeatures(
          speckDensity: 0, whiteFrac: 0.5, dirCoherence: 0.35, edgeFrac: 0.1,
          convergenceCoh: 0.8, vpX: 0.37, vpY: 0.44));
      final p = table.build(d: d, panel: const PixelRect(0, 0, 200, 150));
      expect(p.camera.type, CameraType.pushIn);
      expect(p.camera.zoom0, 1.0);
      expect(p.camera.zoom1, 1.10);
      expect(p.camera.periodSec, MotionProgramTable.actionPeriodSec);
      expect(p.camera.anchorX, 0.37);
      expect(p.camera.anchorY, 0.44);
    });

    test('closeup：pushIn 慢推 1.0→1.05（8s），锚点=最大主体质心', () {
      // 合成掩码（公共路径）：方块主体 x 50..70、y 30..50。
      final prob = List<double>.filled(100 * 100, 0.0);
      for (var y = 30; y <= 50; y++) {
        for (var x = 50; x <= 70; x++) {
          prob[y * 100 + x] = 1.0;
        }
      }
      final mask = SubjectMask.fromProbability(
          prob: prob, probWidth: 100, probHeight: 100,
          width: 100, height: 100);
      final d = _diag(PanelClass.closeup,
          const PanelMotionFeatures(
              speckDensity: 0, whiteFrac: 0.3, dirCoherence: 0.1,
              edgeFrac: 0.2),
          strategy: const PanelMotionStrategy(
              tempo: kCloseupTempo, subjectBoost: kCloseupBoost));
      final p = table.build(d: d, panel: const PixelRect(0, 0, 100, 100), mask: mask);
      expect(p.camera.type, CameraType.pushIn);
      expect(p.camera.zoom1, closeTo(1.05, 1e-9));
      expect(p.camera.periodSec, MotionProgramTable.closeupPeriodSec);
      expect(p.camera.anchorX, closeTo(0.605, 1e-6),
          reason: 'blob rect 中心 60.5 → 0.605');
      expect(p.camera.anchorY, closeTo(0.405, 1e-6));
    });

    test("atmosphere：drift ±1.5%，锚点中景；narrative：none（E2' 裁决）", () {
      final atmo = table.build(
          d: _diag(PanelClass.atmosphere, const PanelMotionFeatures(
              speckDensity: 0, whiteFrac: 0.9, dirCoherence: 0.05,
              edgeFrac: 0.01)),
          panel: const PixelRect(0, 0, 200, 150));
      expect(atmo.camera.type, CameraType.drift);
      expect(atmo.camera.driftAmp, MotionProgramTable.atmosphereDriftAmp);
      expect(atmo.camera.anchorX, 0.5);
      expect(atmo.camera.anchorY, 0.5);

      final narr = table.build(
          d: _diag(PanelClass.narrative, const PanelMotionFeatures(
              speckDensity: 5, whiteFrac: 0.8, dirCoherence: 0.1,
              edgeFrac: 0.1)),
          panel: const PixelRect(0, 0, 200, 150));
      expect(narr.camera.type, CameraType.none);
    });
  });

  group('JSON 往返（确定性纪律）', () {
    test('MotionProgram toJson/fromJson 逐字段一致', () {
      const p = MotionProgram(
        camera: CameraProgram(
            type: CameraType.pushIn,
            anchorX: 0.37,
            anchorY: 0.44,
            zoom0: 1.0,
            zoom1: 1.1,
            periodSec: 2.0),
        scale: 1.0,
        tempo: 1.5,
        subjectBoost: 1.2,
        effects: ['speedLines'],
        focus: FocusProgram(scaleMul: 1.6, tempoMul: 1.25),
      );
      final back =
          MotionProgram.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.camera.type, p.camera.type);
      expect(back.camera.anchorX, p.camera.anchorX);
      expect(back.camera.anchorY, p.camera.anchorY);
      expect(back.camera.zoom0, p.camera.zoom0);
      expect(back.camera.zoom1, p.camera.zoom1);
      expect(back.camera.periodSec, p.camera.periodSec);
      expect(back.tempo, p.tempo);
      expect(back.subjectBoost, p.subjectBoost);
      expect(back.effects, p.effects);
      expect(back.focus.scaleMul, p.focus.scaleMul);
      expect(back.focus.tempoMul, p.focus.tempoMul);
    });

    test('坏 JSON 回落缺省（永不抛）', () {
      final p = MotionProgram.fromJson(const {});
      expect(p.camera.type, CameraType.none);
      expect(p.tempo, 1.0);
      expect(p.effects, isEmpty);
    });
  });
}
