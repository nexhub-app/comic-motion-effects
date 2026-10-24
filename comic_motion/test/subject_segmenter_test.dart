import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

/// Phase D 单元测试：SubjectMask（阈值化/连通域/碎域过滤）与
/// clampSubjectDepth（域中位数钳制、恒值语义晋升）。
void main() {
  group('SubjectMask.fromProbability', () {
    test('同分辨率阈值化：1.0 区域成域，0.0 为背景', () {
      // 6x6 概率图：(2,2)-(3,3) 为 1.0，其余 0。
      final prob = List<double>.filled(36, 0);
      for (var y = 2; y <= 3; y++) {
        for (var x = 2; x <= 3; x++) {
          prob[y * 6 + x] = 1.0;
        }
      }
      final mask = SubjectMask.fromProbability(
          prob: prob,
          probWidth: 6,
          probHeight: 6,
          width: 6,
          height: 6,
          minBlobArea: 1);
      expect(mask.hasSubjects, isTrue);
      expect(mask.blobs.length, 1);
      expect(mask.blobs[0].rect.x, 2);
      expect(mask.blobs[0].rect.y, 2);
      expect(mask.blobs[0].rect.width, 2);
      expect(mask.blobs[0].rect.height, 2);
      expect(mask.blobs[0].area, 4);
      expect(mask.labelAt(2, 2), 1);
      expect(mask.labelAt(3, 3), 1);
      expect(mask.labelAt(0, 0), 0);
      expect(mask.labelAt(5, 5), 0);
      expect(mask.coverage, closeTo(4 / 36, 1e-9));
      expect(mask.maxBlobFrac, closeTo(4 / 36, 1e-9));
    });

    test('两个独立域分别编号', () {
      final prob = List<double>.filled(36, 0);
      for (var y = 0; y <= 1; y++) {
        for (var x = 0; x <= 1; x++) {
          prob[y * 6 + x] = 1.0; // 域 A：左上 2x2
        }
      }
      prob[4 * 6 + 4] = 1.0;
      prob[5 * 6 + 4] = 1.0; // 域 B：右下竖 2px
      final mask = SubjectMask.fromProbability(
          prob: prob,
          probWidth: 6,
          probHeight: 6,
          width: 6,
          height: 6,
          minBlobArea: 1);
      expect(mask.blobs.length, 2);
      expect(mask.labelAt(0, 0), 1);
      expect(mask.labelAt(4, 4), 2);
      expect(mask.labelAt(4, 5), 2, reason: '域 B 占 (x=4,y=4) 与 (x=4,y=5)');
      expect(mask.labelAt(5, 4), 0);
    });

    test('碎域过滤：低于 minBlobArea 的域被丢弃并重编号', () {
      final prob = List<double>.filled(36, 0);
      for (var y = 0; y <= 1; y++) {
        for (var x = 0; x <= 1; x++) {
          prob[y * 6 + x] = 1.0; // 域 A：4px，保留
        }
      }
      prob[4 * 6 + 4] = 1.0;
      prob[5 * 6 + 4] = 1.0; // 域 B：2px，丢弃
      final mask = SubjectMask.fromProbability(
          prob: prob,
          probWidth: 6,
          probHeight: 6,
          width: 6,
          height: 6,
          minBlobArea: 4);
      expect(mask.blobs.length, 1);
      expect(mask.labelAt(0, 0), 1, reason: '保留域重编号为 1');
      expect(mask.labelAt(4, 4), 0);
    });

    test('minBlobFrac 相对下限：面积不足整域占比的域被丢弃', () {
      final prob = List<double>.filled(36, 0);
      for (var y = 2; y <= 3; y++) {
        for (var x = 2; x <= 3; x++) {
          prob[y * 6 + x] = 1.0; // 4px / 36 ≈ 0.11
        }
      }
      final mask = SubjectMask.fromProbability(
          prob: prob,
          probWidth: 6,
          probHeight: 6,
          width: 6,
          height: 6,
          minBlobFrac: 0.2,
          minBlobArea: 1);
      expect(mask.hasSubjects, isFalse);
      expect(mask.blobs, isEmpty);
      expect(mask.coverage, 0.0);
      expect(mask.maxBlobFrac, 0.0);
    });

    test('概率长度不足：降级为空掩码（不抛）', () {
      final mask = SubjectMask.fromProbability(
          prob: const [0.9, 0.9], probWidth: 4, probHeight: 4,
          width: 4, height: 4);
      expect(mask.hasSubjects, isFalse);
    });

    test('labelAt 越界钳位（防御）', () {
      final mask = SubjectMask.empty(4, 4);
      expect(mask.labelAt(-5, -5), 0);
      expect(mask.labelAt(99, 99), 0);
    });

    test('SubjectMask.empty：无主体统一形态', () {
      final mask = SubjectMask.empty(8, 8);
      expect(mask.hasSubjects, isFalse);
      expect(mask.width, 8);
      expect(mask.height, 8);
      expect(mask.coverage, 0.0);
    });
  });

  group('clampSubjectDepth', () {
    /// 右半 (x≥3) 为 1.0 的 8x8 掩码。
    SubjectMask rightHalfMask() {
      final prob = List<double>.filled(64, 0);
      for (var y = 0; y < 8; y++) {
        for (var x = 3; x < 8; x++) {
          prob[y * 8 + x] = 1.0;
        }
      }
      return SubjectMask.fromProbability(
          prob: prob, probWidth: 8, probHeight: 8, width: 8, height: 8);
    }

    test('主体域深度钳到域内下中位数，域外零修改，返回中位数表', () {
      final dm = DepthMap(8, 8);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          dm.data[y * 8 + x] = x / 7; // 0 .. 1 横向渐变
        }
      }
      final medians = clampSubjectDepth(dm, rightHalfMask());
      // 右半域值 {3/7,4/7,5/7,6/7,1}×8 行 = 40 个采样，下中位 = 5/7。
      expect(medians.length, 1);
      expect(medians[0], closeTo(5 / 7, 1e-9));
      for (var y = 0; y < 8; y++) {
        for (var x = 3; x < 8; x++) {
          expect(dm.data[y * 8 + x], closeTo(5 / 7, 1e-9),
              reason: '主体域统一为中位数 ($x,$y)');
        }
      }
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 3; x++) {
          expect(dm.data[y * 8 + x], closeTo(x / 7, 1e-9),
              reason: '域外保持原值 ($x,$y)');
        }
      }
      expect(dm.constantValued, isFalse,
          reason: 'D5 修订：不再晋升恒值语义（背景带边界保持羽化）');
    });

    test('空掩码：深度图零修改，constantValued 不变', () {
      final dm = DepthMap(4, 4);
      for (var i = 0; i < 16; i++) {
        dm.data[i] = i / 15;
      }
      clampSubjectDepth(dm, SubjectMask.empty(4, 4));
      for (var i = 0; i < 16; i++) {
        expect(dm.data[i], closeTo(i / 15, 1e-12));
      }
      expect(dm.constantValued, isFalse);
    });

    test('掩码域无深度采样命中：零修改、中位数为 null', () {
      // 深度 2x2 → 掩码坐标最近邻落在 (2,2),(2,6),(6,2),(6,6)；
      // 主体域放在 (0,0)-(1,1)，无任何深度像素命中。
      final prob = List<double>.filled(64, 0);
      prob[0] = prob[1] = prob[8] = prob[9] = 1.0;
      final mask = SubjectMask.fromProbability(
          prob: prob,
          probWidth: 8,
          probHeight: 8,
          width: 8,
          height: 8,
          minBlobArea: 1);
      expect(mask.hasSubjects, isTrue);
      final dm = DepthMap(2, 2);
      dm.data[0] = 0.1;
      dm.data[1] = 0.2;
      dm.data[2] = 0.3;
      dm.data[3] = 0.4;
      final medians = clampSubjectDepth(dm, mask);
      expect(medians[0], isNull, reason: '无采样 → 无中位数（split 不覆盖该域）');
      expect(dm.data[0], 0.1);
      expect(dm.data[3], 0.4);
      expect(dm.constantValued, isFalse);
    });

    test('确定性：同输入两次钳制结果一致（深度与中位数表）', () {
      final dmA = DepthMap(8, 8);
      final dmB = DepthMap(8, 8);
      for (var i = 0; i < 64; i++) {
        dmA.data[i] = (i % 13) / 13;
        dmB.data[i] = dmA.data[i];
      }
      final mask = rightHalfMask();
      final mA = clampSubjectDepth(dmA, mask);
      final mB = clampSubjectDepth(dmB, mask);
      for (var i = 0; i < 64; i++) {
        expect(dmB.data[i], dmA.data[i]);
      }
      for (var i = 0; i < mA.length; i++) {
        expect(mB[i], mA[i]);
      }
    });
  });

  group('inpaintSubjectBands', () {
    /// 白底 + 中央黑圆盘（r=15，圆心 (20,20)）的 40x40 页。
    RgbaImage discPage() {
      final img = RgbaImage(width: 40, height: 40);
      for (var y = 0; y < 40; y++) {
        for (var x = 0; x < 40; x++) {
          final dx = x - 20, dy = y - 20;
          img.setPixel(
              x, y, dx * dx + dy * dy <= 225 ? 30 : 255,
              dx * dx + dy * dy <= 225 ? 30 : 255,
              dx * dx + dy * dy <= 225 ? 30 : 255);
        }
      }
      return img;
    }

    SubjectMask discMask() {
      final prob = List<double>.filled(1600, 0);
      for (var y = 0; y < 40; y++) {
        for (var x = 0; x < 40; x++) {
          final dx = x - 20, dy = y - 20;
          if (dx * dx + dy * dy <= 225) prob[y * 40 + x] = 1.0;
        }
      }
      return SubjectMask.fromProbability(
          prob: prob, probWidth: 40, probHeight: 40, width: 40, height: 40);
    }

    test('无主体 / bandPx≤0：原样返回同一实例', () {
      final base = discPage();
      expect(inpaintSubjectBands(base, [SubjectMask.empty(40, 40)],
          const [PixelRect(0, 0, 40, 40)], 8), same(base));
      expect(inpaintSubjectBands(base, [discMask()],
          const [PixelRect(0, 0, 40, 40)], 0), same(base));
    });

    test('边界带被背景延续色替换，深层保持原色，输入不被修改', () {
      final base = discPage();
      final out = inpaintSubjectBands(base, [discMask()],
          const [PixelRect(0, 0, 40, 40)], 6);
      int at(int x, int y) => out.data[(y * 40 + x) * 4];
      // 圆盘边界内 2px（距边界 < bandPx）：补绘成白色背景。
      expect(at(33, 20), 255, reason: '边界带 → 背景延续色');
      expect(at(20, 33), 255);
      // 圆心（距边界 15 > bandPx）：保持原色。
      expect(at(20, 20), 30, reason: '深层保持原像素');
      // 输入不被修改。
      expect(base.data[(20 * 40 + 33) * 4], 30);
    });

    test('确定性：同输入两次补绘结果一致', () {
      final a = inpaintSubjectBands(discPage(), [discMask()],
          const [PixelRect(0, 0, 40, 40)], 6);
      final b = inpaintSubjectBands(discPage(), [discMask()],
          const [PixelRect(0, 0, 40, 40)], 6);
      for (var i = 0; i < a.data.length; i++) {
        expect(b.data[i], a.data[i]);
      }
    });
  });
}
