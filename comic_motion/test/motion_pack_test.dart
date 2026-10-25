import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';
import 'package:test/test.dart';

/// M2 MotionPack v1 单测（`motion_redesign_plan_20261025.md` §2）：
/// 双跑逐字节一致（packHash 身份）、结构完整、程序与格对齐、镜头首帧对拍、
/// 磁盘落盘结构。
RgbaImage _twoPanelActionPage() {
  // 上格：放射集中线（action → pushIn 程序）；下格：去格点化方向多样文字
  //（narrative → none）。白缝 12px 供分格。
  final img = RgbaImage(width: 300, height: 400);
  for (var y = 0; y < 400; y++) {
    for (var x = 0; x < 300; x++) {
      img.setPixel(x, y, 255, 255, 255);
    }
  }
  const cx = 150.0, cy = 94.0;
  for (var i = 0; i < 48; i++) {
    final ang = 2 * math.pi * i / 48 + 0.13;
    final r0 = 0.4 * 300.0, r1 = 1.6 * 300.0;
    var x = (cx + math.cos(ang) * r0).round();
    var y = (cy + math.sin(ang) * r0).round();
    final x1 = (cx + math.cos(ang) * r1).round();
    final y1 = (cy + math.sin(ang) * r1).round();
    while (true) {
      if (x >= 0 && x < 300 && y >= 0 && y < 188) {
        img.setPixel(x, y, 25, 25, 25);
      }
      if (x == x1 && y == y1) break;
      final ex = (x1 - x).abs(), ey = (y1 - y).abs();
      if (ex == 0 && ey == 0) break;
      if (ex >= ey) {
        x += x1 > x ? 1 : -1;
      } else {
        y += y1 > y ? 1 : -1;
      }
    }
  }
  // 下格文字（确定性行内抖动）。
  var state = 20261025;
  int next(int max) {
    state = (state * 6364136223846793005 + 1442695040888963407) &
        0x7fffffffffffffff;
    return (state >> 33) % max;
  }

  var gy = 212;
  while (gy < 396) {
    var gx = 12 + next(5);
    while (gx < 284) {
      final runLen = 1 + next(4);
      final thick = 2 + next(2);
      final jx = next(3);
      for (var dy = 0; dy < thick; dy++) {
        for (var dx = 0; dx < runLen; dx++) {
          final px = gx + dx + jx, py = gy + dy;
          if (px < 288 && py < 398) img.setPixel(px, py, 30, 30, 30);
        }
      }
      gx += runLen + 3 + next(3);
    }
    gy += 6 + next(4);
  }
  return img;
}

EffectConfig _config() => EffectConfig.fromJson(const <String, dynamic>{
      'effects': <String>['parallax'],
      'fps': 12,
      'durationSec': 0.5,
      'maxDimension': 300,
      'layerCount': 3,
      'panelAware': true,
      'outputFormat': 'gif',
      'seed': 7,
    });

MotionPipeline _pipeline() => MotionPipeline(
      _config(),
      panelStrategyJudge: const HeuristicSceneStrategyJudge(),
    );

void main() {
  final pagePng =
      Uint8List.fromList(ImageIO.encodePngFrame(_twoPanelActionPage()));

  group('MotionPack v1（M2）', () {
    test('双跑逐字节一致（packHash 身份 = 确定性）', () {
      final src = ImageIO.decode(pagePng);
      final a = _pipeline().exportMotionPack(src, domain: 'bw');
      final b = _pipeline().exportMotionPack(src, domain: 'bw');
      expect(a.packHash, b.packHash);
      expect(a.packHash.length, 16);
      expect(a.packJson, b.packJson);
      expect(a.files.keys.toSet(), b.files.keys.toSet());
      for (final k in a.files.keys) {
        expect(a.files[k], b.files[k], reason: '$k 逐字节一致');
      }
    });

    test('结构完整：pack.json/panels/program/layers/depth/masks', () {
      final src = ImageIO.decode(pagePng);
      final pack = _pipeline().exportMotionPack(src, domain: 'bw');
      final keys = pack.files.keys.toSet();
      expect(keys.contains('layers/index.json'), isTrue);
      expect(keys.any((k) => k.startsWith('layers/layer_')), isTrue);
      expect(keys.contains('depth.png'), isTrue);
      expect(keys.contains('masks.png'), isTrue);
      expect(keys.contains('panels.json'), isTrue);
      expect(keys.contains('program.json'), isTrue);

      final packJson = jsonDecode(pack.packJson) as Map<String, dynamic>;
      expect(packJson['kind'], 'motion_pack');
      expect(packJson['version'], kMotionPackVersion);
      expect(packJson['packHash'], pack.packHash);
      expect(packJson['domain'], 'bw');
      expect((packJson['modelTier'] as Map)['tier'], isA<int>());
      // 无时间戳（确定性红线）。
      expect(packJson.containsKey('createdAt'), isFalse);
      expect(packJson.containsKey('timestamp'), isFalse);

      final panels =
          jsonDecode(utf8.decode(pack.files['panels.json']!)) as Map<String, dynamic>;
      expect((panels['panels'] as List).length, pack.panels.length);
      final program =
          jsonDecode(utf8.decode(pack.files['program.json']!)) as Map<String, dynamic>;
      expect((program['programs'] as List).length, pack.panels.length);
    });

    test('程序与格对齐：集中线格 → pushIn 程序；文字格 → none', () {
      final src = ImageIO.decode(pagePng);
      final pack = _pipeline().exportMotionPack(src, domain: 'bw');
      expect(pack.panels.length, greaterThanOrEqualTo(2), reason: '多格页');
      expect(pack.programs.length, pack.panels.length, reason: '程序与格一一对齐');
      final actionIdx =
          pack.programs.indexWhere((p) => p.camera.type == CameraType.pushIn);
      final noneIdx =
          pack.programs.indexWhere((p) => p.camera.type == CameraType.none);
      expect(actionIdx, greaterThanOrEqualTo(0), reason: '集中线格配推镜');
      expect(noneIdx, greaterThanOrEqualTo(0),
          reason: "E2' 静默语义：文字格无镜头");
      expect(actionIdx, isNot(noneIdx));
      final cam = pack.programs[actionIdx].camera;
      expect(cam.zoom0, 1.0);
      expect(cam.zoom1, 1.10);
      // 灭点锚点在格内（归一化坐标）。
      expect(cam.anchorX, inInclusiveRange(0.0, 1.0));
      expect(cam.anchorY, inInclusiveRange(0.0, 1.0));
    });

    test('首帧对拍：renderPackStillFrame(0) == renderStillFrame(0)（逐字节）',
        () async {
      final pipeline = _pipeline();
      final packStill = pipeline.renderPackStillFrame(input: pagePng, t: 0);
      final plainStill = await pipeline.renderStillFrame(input: pagePng, t: 0);
      expect(packStill, plainStill,
          reason: 't=0 镜头恒等跳过 → 首帧 = 无镜头静帧（契约锁定）');
      // t 中段：镜头生效（与无镜头帧不同）。
      final mid = pipeline.renderPackStillFrame(input: pagePng, t: 0.25);
      final plainMid = await pipeline.renderStillFrame(input: pagePng, t: 0.25);
      var diff = 0;
      for (var i = 0; i < mid.length; i++) {
        if (mid[i] != plainMid[i]) diff++;
      }
      expect(diff, greaterThan(0), reason: '推镜中段改变画面（程序消费生效）');
    });

    test('磁盘落盘：目录 = <stem>_<packHash12>，清单文件齐备', () {
      final outDir = 'build/pack_test_out';
      io.Directory(outDir).createSync(recursive: true);
      final tmp = '$outDir/_tmp_page.png';
      io.File(tmp).writeAsBytesSync(pagePng);
      final result = _pipeline().exportMotionPackFile(tmp, outDir, domain: 'bw');
      io.File(tmp).deleteSync();
      expect(result.dir, isNotEmpty);
      expect(result.dir.endsWith(result.packHash.substring(0, 12)), isTrue);
      final listed = io.Directory(result.dir)
          .listSync(recursive: true)
          .whereType<io.File>()
          .map((f) => f.path.substring(result.dir.length + 1).replaceAll('\\', '/'))
          .toSet();
      expect(listed.contains('pack.json'), isTrue);
      for (final f in result.files.keys) {
        expect(listed.contains(f), isTrue, reason: '$f 已落盘');
      }
    });

    test('M4 模型分级：tier 随注入接缝显式推导（降级可见）', () {
      final src = ImageIO.decode(pagePng);
      // tier 0：无注入（纯几何）。
      final t0 =
          MotionPipeline(_config()).exportMotionPack(src, domain: 'bw');
      expect((jsonDecode(t0.packJson) as Map)['modelTier']['tier'], 0);
      // tier 2：注入非启发式深度估算器（组件清单非空 = 可审计）。
      final t2 = MotionPipeline(_config(), depthEstimator: const _FlatDepth())
          .exportMotionPack(src, domain: 'bw');
      final t2json = jsonDecode(t2.packJson) as Map;
      expect(t2json['modelTier']['tier'], 2);
      expect((t2json['modelTier']['components'] as List), isNotEmpty);
    });
  });
}

/// 恒值深度估算器（M4 tier 推导测试假件：非 HeuristicDepthEstimator）。
class _FlatDepth extends DepthEstimator {
  const _FlatDepth();

  @override
  DepthMap estimate(RgbaImage img) {
    final d = DepthMap(img.width, img.height);
    for (var i = 0; i < img.width * img.height; i++) {
      d.data[i] = 0.5;
    }
    return d;
  }
}
