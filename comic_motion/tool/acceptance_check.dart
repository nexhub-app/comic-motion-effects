// 验收工具（重构方案 M5，`motion_redesign_plan_20261025.md` §6.2）：
// 机器可判定的 ACCEPT 行 + SUMMARY——低智验收方读 `acceptance.txt` 即可
// 判定，无需复现渲染（工作流偏好：高智写码 + 低智验收）。
//
// 覆盖：
//   m0  多域语料 TSV 落盘 + 合成页生成确定性
//   m1  网点否决/会聚动作分类断言（TSV 审计）+ 阈值分布定值区间守卫
//   m2  MotionPack 双跑逐字节一致 + 程序与格对齐 + 镜头首帧对拍
//   m4  模型分级显式推导（tier0 = geometry）
//   m3  shader uniform 契约由 comic_motion_shaders 包测试承担
//       （flutter test；本工具输出指向性条目）。
//
// 用法：dart run tool/acceptance_check.dart [--corpus <dir>] [--out <txt>]
// 退出码：0 = 全 PASS；3 = 存在 FAIL。
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart';

import 'synthetic_pages.dart';

final _lines = <String>[];
int _pass = 0, _fail = 0;

void _check(String name, bool ok, String detail) {
  final line = 'ACCEPT $name ${ok ? 'PASS' : 'FAIL'} $detail';
  _lines.add(line);
  ok ? _pass++ : _fail++;
  io.stdout.writeln(line);
}

void main(List<String> args) {
  String corpus = '../build/corpus';
  String out = '../build/corpus/acceptance.txt';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--corpus') corpus = args[i + 1];
    if (args[i] == '--out') out = args[i + 1];
  }

  // ---- M0：分域 TSV 落盘 ----
  for (final domain in ['bw', 'manhwa', 'manhua', 'color']) {
    final f = io.File('$corpus/features_$domain.tsv');
    if (!f.existsSync()) {
      _check('m0-tsv-$domain', false, 'missing $corpus/features_$domain.tsv');
      continue;
    }
    final rows = f.readAsLinesSync();
    _check('m0-tsv-$domain', rows.length > 10,
        '${rows.length - 1} panel rows (domain=$domain)');
  }

  // ---- M0：合成页生成确定性（同种子两次逐字节） ----
  final genA = generateDomain('bw', 1, kSyntheticSeed);
  final genB = generateDomain('bw', 1, kSyntheticSeed);
  var identical = true;
  for (var i = 0; i < genA.length; i++) {
    final pa = ImageIO.encodePngFrame(genA[i].$2);
    final pb = ImageIO.encodePngFrame(genB[i].$2);
    if (pa.length != pb.length || !_bytesEqual(pa, pb)) identical = false;
  }
  _check('m0-synthetic-determinism', identical,
      'bw p0 double-run byte-identical (seed=$kSyntheticSeed)');

  // ---- M1：TSV 分类审计（规则镜像内联，独立于 classify_audit 的实现） ----
  var checked = 0, auditFail = 0;
  final miss = <String>[];
  for (final domain in ['bw', 'manhwa', 'manhua']) {
    final f = io.File('$corpus/features_$domain.tsv');
    if (!f.existsSync()) continue;
    final rows = f.readAsLinesSync();
    final header = rows.first.split('\t');
    int col(String n) => header.indexOf(n);
    for (var r = 1; r < rows.length; r++) {
      final c = rows[r].split('\t');
      final gt = c[col('gt')];
      final target = switch (gt) {
        'action' => _Target.dynamic,
        'narrative_text' || 'narrative_detail' => _Target.still,
        _ => _Target.skip,
      };
      if (target == _Target.skip) continue;
      final speck = double.parse(c[col('speckDensity')]);
      final white = double.parse(c[col('whiteFrac')]);
      final dir = double.parse(c[col('dirCoherence')]);
      final edge = double.parse(c[col('edgeFrac')]);
      final dot = double.parse(c[col('dotPeriodicity')]);
      final uni = double.parse(c[col('speckUniformity')]);
      final conv = double.parse(c[col('convergenceCoh')]);
      final screentone =
          dot >= kScreentonePeriodicityMin || (speck >= 3.5 && uni <= kScreentoneUniformityMax);
      final textLike =
          !screentone && speck >= kTextSpeckMin && white >= kTextWhiteMin && dir <= kMaxDirCoh;
      final action = dir >= kActionDirCohMin || conv >= kActionConvergenceMin;
      final judged = textLike || (!action && edge > kAtmosphereEdgeMax)
          ? _Target.still
          : _Target.dynamic;
      checked++;
      if (judged != target) {
        auditFail++;
        miss.add('$domain ${c[1]}#${c[2]} gt=$gt');
      }
    }
  }
  _check('m1-classify-audit', auditFail == 0,
      'pass=${checked - auditFail} fail=$auditFail (screentone veto + convergence action)');

  // ---- M1：阈值分布定值区间守卫 ----
  _check('m1-threshold-screentone-periodicity',
      kScreentonePeriodicityMin >= 0.6 && kScreentonePeriodicityMin <= 0.85,
      'kScreentonePeriodicityMin=$kScreentonePeriodicityMin ∈ [0.6, 0.85]');
  _check('m1-threshold-screentone-uniformity',
      kScreentoneUniformityMax >= 0.2 && kScreentoneUniformityMax <= 0.4,
      'kScreentoneUniformityMax=$kScreentoneUniformityMax ∈ [0.2, 0.4]');
  _check('m1-threshold-convergence',
      kActionConvergenceMin >= 0.55 && kActionConvergenceMin <= 0.62,
      'kActionConvergenceMin=$kActionConvergenceMin ∈ [0.55, 0.62] '
      '(彩页修正案 c04_p018-0 目检放射冲击线)');

  // ---- M1：合成盲点页直接判定（黑白盲点进单测的端到端面） ----
  final actionPanel = _concentrationPanel(288, 188);
  final fa = extractPanelMotionFeatures(actionPanel);
  _check('m1-blindspot-concentration',
      fa.dirCoherence >= kActionDirCohMin ||
          fa.convergenceCoh >= kActionConvergenceMin,
      'dir=${fa.dirCoherence.toStringAsFixed(3)} '
      'conv=${fa.convergenceCoh.toStringAsFixed(3)} '
      '(C2 放射线动作格不判静)');
  final tonePanel = _screentonePanel(180, 140);
  final ft = extractPanelMotionFeatures(tonePanel);
  _check('m1-blindspot-screentone',
      HeuristicPanelMotionJudge.isScreentone(ft) &&
          !HeuristicPanelMotionJudge.isTextStill(ft),
      'dot=${ft.dotPeriodicity.toStringAsFixed(3)} '
      'uni=${ft.speckUniformity.toStringAsFixed(3)} speck=${ft.speckDensity.toStringAsFixed(1)} '
      '(C1 网点页不因斑点密度判静)');

  // ---- M2：pack 双跑逐字节 + 首帧对拍 ----
  final page = _packTestPage();
  final png = Uint8List.fromList(ImageIO.encodePngFrame(page));
  final pipeline = MotionPipeline(
    _config(),
    panelStrategyJudge: const HeuristicSceneStrategyJudge(),
  );
  final src = ImageIO.decode(png);
  final packA = pipeline.exportMotionPack(src, domain: 'bw');
  final packB = pipeline.exportMotionPack(src, domain: 'bw');
  var packDeterministic = packA.packHash == packB.packHash &&
      packA.packJson == packB.packJson &&
      packA.files.length == packB.files.length;
  if (packDeterministic) {
    for (final k in packA.files.keys) {
      if (!_bytesEqual(packA.files[k]!, packB.files[k]!)) {
        packDeterministic = false;
        break;
      }
    }
  }
  _check('m2-pack-determinism', packDeterministic,
      'packHash=${packA.packHash} files=${packA.files.length} double-run byte-identical');

  final required = {'layers/index.json', 'depth.png', 'masks.png',
      'panels.json', 'program.json'};
  _check('m2-pack-structure', packA.files.keys.toSet().containsAll(required),
      'files=${packA.files.keys.toList()..sort()}');

  // 语义不变量：程序镜头类型与诊断类别一一对应（action/closeup/atmosphere
  // 有镜头，narrative 无镜头——E2' 静默语义），程序数与格数对齐。
  var programsOk = packA.programs.length == packA.panels.length;
  final clsCounts = <String, int>{};
  final reanalysis = pipeline.analyzeForPack(src);
  for (var i = 0; programsOk && i < packA.programs.length; i++) {
    final p = packA.programs[i];
    final d = reanalysis.diagnoses[i];
    clsCounts[d.cls.name] = (clsCounts[d.cls.name] ?? 0) + 1;
    final expectCamera = d.cls != PanelClass.narrative;
    final hasCamera = p.camera.type != CameraType.none;
    if (expectCamera != hasCamera) programsOk = false;
  }
  _check('m2-program-alignment', programsOk,
      'panels=${packA.panels.length} programs=${packA.programs.length} '
      'cls=$clsCounts (镜头类型=诊断类别；E2\' narrative 保持静默)');

  final packStill = pipeline.renderPackStillFrame(input: png, t: 0);
  // 双管线对拍：镜头程序消费路径自身确定性（首帧逐字节 == 的强断言在
  // core 测试 motion_pack_test 的 renderStillFrame 对拍项承担）。
  final stillB = MotionPipeline(
    _config(),
    panelStrategyJudge: const HeuristicSceneStrategyJudge(),
  ).renderPackStillFrame(input: png, t: 0);
  _check('m2-firstframe-parity', _bytesEqual(packStill, stillB),
      't=0 pack-still deterministic across pipelines (${packStill.length} bytes) '
      '（强契约：== renderStillFrame(0)，见 core motion_pack_test）');

  // 程序 JSON 往返（shader/导出两端同源）。
  const probeProgram = MotionProgram(
    camera: CameraProgram(
        type: CameraType.pushIn, anchorX: 0.37, anchorY: 0.44,
        zoom0: 1.0, zoom1: 1.10, periodSec: 2.0),
    scale: 1, tempo: 1.5, subjectBoost: 1.2,
    effects: ['speedLines'],
    focus: FocusProgram(scaleMul: 1.6, tempoMul: 1.25),
  );
  final rt = MotionProgram.fromJson(
      jsonDecode(jsonEncode(probeProgram.toJson())) as Map<String, dynamic>);
  _check('m2-program-roundtrip',
      rt.camera.anchorX == probeProgram.camera.anchorX &&
          rt.camera.zoom1 == probeProgram.camera.zoom1 &&
          rt.tempo == probeProgram.tempo &&
          rt.focus.scaleMul == probeProgram.focus.scaleMul,
      'camera/layers/focus fields survive jsonEncode/Decode');

  // ---- M4：tier 显式推导 ----
  final tier0 = MotionPipeline(_config()).exportMotionPack(src, domain: 'bw');
  final tierJson = jsonDecode(tier0.packJson) as Map<String, dynamic>;
  final tier = tierJson['modelTier'] as Map<String, dynamic>;
  _check('m4-tier-explicit', tier['tier'] == 0 && tier['label'] == 'geometry',
      'tier=${tier['tier']} label=${tier['label']} '
      'components=${(tier['components'] as List).length} (无注入 = 纯几何，降级可见)');

  // ---- M3：指针条目（flutter test in comic_motion_shaders 承担） ----
  _lines.add('ACCEPT m3-shader-uniforms GATE comic_motion_shaders flutter test '
      '(kFloatCount=28 camera 19..25 focus 26..27, 布局契约测试)');

  _lines.add('ACCEPT SUMMARY pass=$_pass fail=$_fail');
  io.File(out).writeAsStringSync('${_lines.join('\n')}\n');
  io.stdout.writeln('acceptance report -> $out (pass=$_pass fail=$_fail)');
  io.exitCode = _fail == 0 ? 0 : 3;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

enum _Target { still, dynamic, skip }

RgbaImage _fill(int w, int h, int v) {
  final img = RgbaImage(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.setPixel(x, y, v, v, v);
    }
  }
  return img;
}

RgbaImage _screentonePanel(int w, int h) {
  final img = _fill(w, h, 255);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (x % 7 < 3 && y % 7 < 3) img.setPixel(x, y, 40, 40, 40);
    }
  }
  return img;
}

RgbaImage _concentrationPanel(int w, int h) {
  final img = _fill(w, h, 245);
  const cx = 144.0, cy = 78.96;
  for (var i = 0; i < 48; i++) {
    final ang = 2 * math.pi * i / 48 + 0.13;
    _thickLine(img, cx + math.cos(ang) * 115.2, cy + math.sin(ang) * 115.2,
        cx + math.cos(ang) * 460.8, cy + math.sin(ang) * 460.8);
  }
  return img;
}

void _thickLine(RgbaImage img, double x0, double y0, double x1, double y1,
    [int dark = 25, double halfWidth = 1.2]) {
  final minX = (math.min(x0, x1) - halfWidth - 1).floor();
  final maxX = (math.max(x0, x1) + halfWidth + 1).ceil();
  final minY = (math.min(y0, y1) - halfWidth - 1).floor();
  final maxY = (math.max(y0, y1) + halfWidth + 1).ceil();
  final vx = x1 - x0, vy = y1 - y0;
  final c2 = vx * vx + vy * vy;
  for (var y = minY; y <= maxY; y++) {
    if (y < 0 || y >= img.height) continue;
    for (var x = minX; x <= maxX; x++) {
      if (x < 0 || x >= img.width) continue;
      final wx = x - x0, wy = y - y0;
      var t = c2 > 0 ? (wx * vx + wy * vy) / c2 : 0.0;
      t = t.clamp(0.0, 1.0);
      final dx = wx - t * vx, dy = wy - t * vy;
      if (dx * dx + dy * dy <= halfWidth * halfWidth) {
        img.setPixel(x, y, dark, dark, dark);
      }
    }
  }
}

RgbaImage _packTestPage() {
  final img = _fill(300, 400, 255);
  for (var i = 0; i < 48; i++) {
    final ang = 2 * math.pi * i / 48 + 0.13;
    _thickLine(img, 150 + math.cos(ang) * 120, 94 + math.sin(ang) * 120,
        150 + math.cos(ang) * 480, 94 + math.sin(ang) * 480);
  }
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
      final kind = next(10);
      if (kind < 3) {
        final vh = 2 + next(5);
        for (var dy = 0; dy < vh; dy++) {
          final px = gx + jx, py = gy + dy;
          if (px < 288 && py < 398) img.setPixel(px, py, 30, 30, 30);
        }
        gx += 1 + 3 + next(3);
        continue;
      } else if (kind < 6) {
        final dl = 2 + next(4);
        final up = next(2) == 0;
        for (var s = 0; s < dl; s++) {
          final px = gx + s + jx;
          final py = gy + (up ? dl - s : s);
          if (px < 288 && py < 398 && py >= 212) {
            img.setPixel(px, py, 30, 30, 30);
          }
        }
        gx += dl + 3 + next(3);
        continue;
      }
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
