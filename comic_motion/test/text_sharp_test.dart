/// text sharp（v1.10）契约测试：文字掩码检测、整数采样保真、静息帧=原画、
/// 配置往返。全部合成图（斑点/色块），不依赖任何样本页。
import 'dart:convert';
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

RgbaImage _white(int w, int h) {
  final img = RgbaImage(width: w, height: h);
  for (var p = 0; p < w * h; p++) {
    img.data[p * 4] = 255;
    img.data[p * 4 + 1] = 255;
    img.data[p * 4 + 2] = 255;
    img.data[p * 4 + 3] = 255;
  }
  return img;
}

void _dot(RgbaImage img, int x, int y, [int v = 0]) {
  final o = (y * img.width + x) * 4;
  img.data[o] = v;
  img.data[o + 1] = v;
  img.data[o + 2] = v;
  img.data[o + 3] = 255;
}

void _fillRect(RgbaImage img, int x0, int y0, int w, int h, [int v = 0]) {
  for (var y = y0; y < y0 + h; y++) {
    for (var x = x0; x < x0 + w; x++) {
      _dot(img, x, y, v);
    }
  }
}

bool _bit(Uint8List? mask, int w, int h, int x, int y) =>
    mask != null && textMaskBit(mask, w, h, x, y);

EffectConfig _tsConfig({bool textSharp = true, double amplitude = 0.05}) =>
    EffectConfig.fromJson(<String, dynamic>{
      'effects': <String>['parallax'],
      'fps': 12,
      'durationSec': 1.0,
      'layerCount': 2,
      'panelAware': false,
      'parallax': <String, dynamic>{'amplitude': amplitude},
      if (textSharp) 'quality': <String, dynamic>{'textSharp': true},
      'seed': 7,
    });

void main() {
  group('detectTextSnapMask', () {
    test('纯白页无文字 → null（通道零成本）', () {
      expect(detectTextSnapMask(_white(64, 48)), isNull);
    });

    test('小暗斑点（文字样）命中 + 膨胀圈', () {
      final img = _white(64, 48);
      // 2×2 字母样斑点，相距 ≥4px（互不连通）。
      for (final (dx, dy) in [(10, 10), (16, 10), (22, 12), (10, 18)]) {
        _fillRect(img, dx, dy, 2, 2);
      }
      final mask = detectTextSnapMask(img);
      expect(mask, isNotNull);
      expect(_bit(mask, 64, 48, 10, 10), isTrue); // 斑点本体
      expect(_bit(mask, 64, 48, 12, 12), isTrue); // 膨胀 2px 圈内
      expect(_bit(mask, 64, 48, 14, 14), isFalse); // 膨胀圈外
    });

    test('实心大色块被排除（面积 > 4096 且填充率高）', () {
      final img = _white(128, 96);
      _fillRect(img, 8, 8, 80, 60); // 4800px² 实心块
      expect(detectTextSnapMask(img), isNull);
    });

    test('大号稀疏笔画（拟声词样）命中：框 ≤200 且填充率 ≤0.6', () {
      final img = _white(300, 200);
      // 外接框 60×40 内画细十字笔画（填充率远低于 0.6）。
      for (var x = 20; x < 80; x++) {
        _fillRect(img, x, 39, 1, 2);
      }
      for (var y = 20; y < 60; y++) {
        _fillRect(img, 49, y, 2, 1);
      }
      final mask = detectTextSnapMask(img);
      expect(mask, isNotNull);
      expect(_bit(mask, 300, 200, 50, 40), isTrue);
    });

    test('确定性：两次检测逐字节一致', () {
      final img = _white(96, 64);
      _fillRect(img, 12, 12, 2, 2);
      _fillRect(img, 30, 20, 3, 1);
      final a = detectTextSnapMask(img)!;
      final b = detectTextSnapMask(img)!;
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i], b[i]);
      }
    });
  });

  group('textSharp 配置', () {
    test('默认关闭：quality 段不序列化（既有 configHash 形状不变）', () {
      final cfg = EffectConfig.fromJson(const {});
      expect(cfg.quality.textSharp, isFalse);
      expect(cfg.quality.isDefault, isTrue);
      expect(cfg.toJsonString().contains('textSharp'), isFalse);
    });

    test('显式开启：写键 + 读回 + configHash 改变', () {
      final on = _tsConfig();
      expect(on.quality.textSharp, isTrue);
      expect(on.quality.isDefault, isFalse);
      final json = on.toJsonString();
      expect(json.contains('"textSharp": true'), isTrue);
      final round = EffectConfig.fromJson(
          (jsonDecode(json) as Map).cast<String, dynamic>());
      expect(round.quality.textSharp, isTrue);
      expect(round.configHash, on.configHash);
      // 哈希即身份：开启与否必须产出不同 configHash。
      expect(on.configHash, isNot(_tsConfig(textSharp: false).configHash));
    });

    test('legacy 档 + textSharp：序列化保留但渲染静默无操作（冻结不接）', () {
      final cfg = EffectConfig.fromJson(<String, dynamic>{
        'quality': <String, dynamic>{'tier': 'legacy', 'textSharp': true},
      });
      expect(cfg.quality.textSharp, isTrue);
      expect(cfg.quality.tier, RenderTier.legacy);
    });
  });

  group('textSharp 渲染契约', () {
    test('重采样器整数采样：掩码命中像素 = 源纹素整像素平移拷贝（无插值灰）',
        () {
      const w = 16, h = 16;
      final src = _white(w, h);
      _fillRect(src, 5, 5, 2, 2); // 黑点
      _fillRect(src, 10, 10, 2, 2); // 黑点 2（未掩码对照区）
      // 掩码：只罩住点 1（含 1px 晕圈）。
      final mask = Uint8List((w * h + 7) >> 3);
      void setBit(int x, int y) {
        final p = y * w + x;
        mask[p >> 3] |= 1 << (p & 7);
      }

      for (var y = 4; y <= 7; y++) {
        for (var x = 4; x <= 7; x++) {
          setBit(x, y);
        }
      }

      // 分数位移：dx=0.5, dy=0.5, scale=1（两轴都是最坏的半纹素相位）。
      // 逆映射：sx = x+0.5、sy = y+0.5 → 最近源纹素 = (x+1, y+1)。
      final dst = RgbaImage(width: w, height: h);
      drawLayer(dst, src.data, w, h, 0.5, 0.5, 1.0, 0.5,
          tier: RenderTier.standard, snapMask: mask);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final nx = x + 1, ny = y + 1; // 最近源纹素（见上式）
          final masked = nx >= 0 &&
              nx < w &&
              ny >= 0 &&
              ny < h &&
              textMaskBit(mask, w, h, nx, ny);
          final o = (y * w + x) * 4;
          if (masked) {
            final so = (ny * w + nx) * 4;
            expect(dst.data[o], src.data[so],
                reason: '掩码命中 ($x,$y)→源($nx,$ny)：必须整纹素拷贝 R');
            expect(dst.data[o + 1], src.data[so + 1], reason: 'G 通道');
            expect(dst.data[o + 2], src.data[so + 2], reason: 'B 通道');
            expect(dst.data[o + 3], src.data[so + 3], reason: 'A 通道');
          }
        }
      }
      // 对照：未掩码的点 2 边缘出现插值中间灰（分数位移下 CR 必然混色）。
      var interpGray = 0;
      for (var y = 9; y <= 13; y++) {
        for (var x = 9; x <= 14; x++) {
          final o = (y * w + x) * 4;
          final v = dst.data[o];
          if (v > 30 && v < 220) interpGray++;
        }
      }
      expect(interpGray, greaterThan(0),
          reason: '对照区必须存在插值灰（证明位移确实是分数、测试有效）');
    });

    test('静息对齐：textSharp-ON 的 t=0 帧与 amplitude-0 帧逐字节一致；'
        'OFF 臂因 snapWave 直流偏置不同（门控生效证据）', () async {
      final img = _white(96, 64);
      for (final (dx, dy) in [(12, 12), (18, 12), (24, 14), (12, 20)]) {
        _fillRect(img, dx, dy, 2, 2);
      }
      final bytes = Uint8List.fromList(ImageIO.encodePngFrame(img));
      Future<Uint8List> frameAt(
          {required bool textSharp, required double amplitude}) async {
        final pipeline = MotionPipeline(
            _tsConfig(textSharp: textSharp, amplitude: amplitude));
        return await pipeline.renderStillFrame(input: bytes, t: 0);
      }

      final zero = await frameAt(textSharp: true, amplitude: 0.0);
      final restOn = await frameAt(textSharp: true, amplitude: 0.05);
      final restOff = await frameAt(textSharp: false, amplitude: 0.05);
      // ON：t=0 位移精确 0 → 与 amplitude-0 帧逐字节一致（含晕圈在内全部
      // 像素，静态合成 ==
      expect(restOn.length, zero.length);
      for (var i = 0; i < zero.length; i++) {
        expect(restOn[i], zero[i], reason: '字节 $i：静息帧必须与零幅度帧一致');
      }
      // OFF：snapWave(0)≈0.3387 直流 → t=0 整层带位移 → 字节不同。
      var byteDiff = 0;
      for (var i = 0; i < zero.length; i++) {
        if (restOff[i] != zero[i]) byteDiff++;
      }
      expect(byteDiff, greaterThan(0),
          reason: 'OFF 臂 t=0 必须带直流位移（否则静息对齐门控没有生效）');
    });
  });
}
