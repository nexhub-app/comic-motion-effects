/// 动效画面判断（v1.9 → M1 几何扩展）：按画面内容裁决「这一格该不该动」。
///
/// 与 [MotionGate]（页级、深度平坦度）互补：本判断是**格级、内容语义**——
/// 对话气泡文字主导的格不该动（视差会把人物/文字割裂），速度线/集中线
/// 成族的动作格该动。接口返回逐格幅度乘数（0 = 静止，1 = 满幅），由管线
/// 映射到层、经 `FrameCompositor.layerMotionScales` 收缩视差。
///
/// 内置 [HeuristicPanelMotionJudge] 的三条件规则与常量来自 30 页参考样本
/// 47 格的**分布勘察**（阈值取分布自然谷/语义护栏，不对任何单页调参）：
/// - 文字斑点密度 p：主质量 ≤2.79，上尾（题字/全文字页）≥4.48，自然谷
///   2.8–4.4 → 取谷中段 3.5；
/// - 方向笔触一致性：主质量 ≤0.240，上尾（效果线/长直边）≥0.30，自然谷
///   0.24–0.30 → 取谷中段 0.27（上栏：速度线成族则不可判静）；
/// - 近白占比：分布连续无谷 → 不作判别特征，只作 0.12 的低栏语义护栏
///   （气泡白底可见性；低于此为墨线/网点主导，文字斑点不可信）。
///
/// M1 几何扩展（`motion_redesign_plan_20261025.md` §4.1，修调研 §8.2 实测
/// 坐实的两处域失效，特征与阈值全部纯几何零 AI、分布定值）：
/// - **C1 网点否决**：黑白网点域实测 speckDensity 56.6（阈值 3.5 的 16 倍）
///   ——网点点阵被数成文字笔画。新增 `dotPeriodicity`（暗像素网格自相关
///   峰值）与 `speckUniformity`（斑点面积 std/mean）两特征：网点=高周期性
///   ∧高尺寸均匀性，文字=两者皆低。三条件加「网点否决」：网点格不得因
///   斑点密度判静（`isScreentone`）。
/// - **C2 会聚检测**：放射集中线的方向均匀分布全 12 bin（实测 dirCoh
///   0.236 < 动作阈值 0.30）→ 平行族盲点。新增 `convergenceCoh`：强边缘
///   梯度相对候选灭点的「横向对齐」占比（梯度 ⊥ 笔画轴 ⇒ 笔画轴指向
///   灭点）；`action = dirCoh ≥ θa ∨ convergenceCoh ≥ θc`。灭点坐标
///   `vpX/vpY` 顺作镜头程序推镜锚点（一特征两用）。
///
/// 保守语义「模糊→静」（E2' 用户裁决）：三条件 AND + 网点否决，任一不
/// 满足即动。外部 AI 逐格裁决走 `scene.json` 侧车（`scene_sidecar.dart`），
/// 命中格覆盖启发式。
library;

import 'dart:math' as math;


import 'apng_writer.dart' show PixelRect;
import 'image_model.dart';
import 'subject_segmenter.dart' show SubjectMask;

/// 文字斑点密度阈值（斑点数/千像素）：≥ 此值视为文字主导候选。
const double kTextSpeckMin = 3.5;

/// 近白占比下限（语义护栏）：低于此值墨线/网点主导，文字斑点不可信。
const double kTextWhiteMin = 0.12;

/// 方向笔触一致性上限：高于此值存在方向笔触族（速度线/集中线/长直边），
/// 不可判静。
const double kMaxDirCoh = 0.27;

/// 网点周期性下限（C1 网点否决，M1）：暗像素网格自相关峰值 ≥ 此值判网点。
/// 分布定值依据见 `build/corpus/distribution_report.txt`（M0 勘察）：黑白
/// 网点域（点阵 2px/周期 6px）峰值 ≈0.95+，彩页 47 格主质量 ≤0.35、
/// 文字格 ≤0.65（行距整齐的文字伪峰）→ 取谷 0.72。
const double kScreentonePeriodicityMin = 0.72;

/// 网点判定所需最少斑点数（均匀性分支护栏）：小格子少量斑点不足以构成
/// 「尺寸均匀的点阵」证据。
const int kScreentoneSpeckMin = 24;

/// 斑点尺寸均匀性上限（C1 网点否决均匀性分支）：斑点面积 std/mean 低于
/// 此值 = 等尺寸点阵（网点）。分布定值（M0 勘察 build/corpus）：网点域
/// ≤0.10（等径点阵），合成/真实文字 ≥0.31/≥0.77（笔画尺寸异质）→ 取
/// 谷 0.30。
const double kScreentoneUniformityMax = 0.30;

/// 会聚一致性阈值（C2 放射集中线，M1）：强边缘相对最优灭点的横向对齐
/// 占比 ≥ 此值判动作格。分布定值（M0 勘察 build/corpus）：合成集中线格
/// ≥0.616（Bresenham 线族）；真实彩页上尾——c04_p018 格 0 检出 0.62
///（人工目检确认该格有放射冲击线，旧启发式 dirCoh 盲点判静——**C2 修正
/// 而非回归**），非动作格上尾 0.5382 → 取谷 0.58。
const double kActionConvergenceMin = 0.58;

/// 会聚灭点搜索的横向容差（弧度正弦口径）：梯度与「指向灭点方向」的
/// 夹角 ≥72°（|dot| ≤ sin18°）计为对齐——梯度 ⊥ 笔画轴、笔画轴指向
/// 灭点的几何口径。
const double kConvergenceSinTol = 0.309;

/// 会聚灭点粗搜网格边界（归一化格坐标）：灭点常在格外（集中线从格外
/// 涌入），搜索范围扩到 [−0.6, 1.6]²。
const double _vpLo = -0.6, _vpHi = 1.6;
const int _vpSteps = 23; // (hi-lo)/step+1, step=0.1
const int _maxEdgeSamples = 1800; // 灭点搜索的边缘采样上限（确定性抽样）
const double _vpBorderMargin = 4.0; // 距格边此距离内的边缘不参与（格框伪会聚）

/// 单格画面特征（工作分辨率口径；与校准探针逐行同源）。
class PanelMotionFeatures {
  const PanelMotionFeatures({
    required this.speckDensity,
    required this.whiteFrac,
    required this.dirCoherence,
    required this.edgeFrac,
    this.speckCount = 0,
    this.speckUniformity = 0.0,
    this.dotPeriodicity = 0.0,
    this.convergenceCoh = 0.0,
    this.vpX = 0.5,
    this.vpY = 0.5,
  });

  /// 小暗连通域密度（斑点数/千像素）——文字笔画的结构代理。
  final double speckDensity;

  /// 近白（亮度 ≥245）像素占比——气泡白底可见性。
  final double whiteFrac;

  /// 强边缘方向直方图 top-bin 质量/强边缘总数——方向笔触族信号。
  final double dirCoherence;

  /// 强边缘像素占比（辅助观测，不参与判定）。
  final double edgeFrac;

  /// 计入斑点密度的小暗连通域个数（网点否决均匀性分支的量级护栏）。
  final int speckCount;

  /// 斑点面积 std/mean（M1）：等尺寸点阵 ≈0，笔画群（文字）≥0.5。
  final double speckUniformity;

  /// 暗像素网格自相关峰值（M1）：min(横向, 纵向) 最优滞后匹配率——
  /// 点阵 ≈0.95+，文字（间距不齐）≤0.65。
  final double dotPeriodicity;

  /// 会聚一致性（M1）：强边缘相对最优灭点的横向对齐占比——放射集中线
  /// ≈0.85+，平行线/普通格 ≤ 基线。
  final double convergenceCoh;

  /// 最优灭点（归一化格坐标，M1）：动作格镜头程序的推镜锚点。
  /// 无会聚结构时取格中心。
  final double vpX;
  final double vpY;
}

int _lum(RgbaImage img, int o) =>
    (img.data[o] * 2 + img.data[o + 1] * 3 + img.data[o + 2]) ~/ 6;

/// 提取单格特征。输入为该格的子图（调用方裁剪）；纯函数，同输入同输出。
PanelMotionFeatures extractPanelMotionFeatures(RgbaImage panel) {
  final w = panel.width, h = panel.height;
  final n = w * h;
  var white = 0;
  final isDark = List<bool>.filled(n, false);
  final darkIdx = <int>[];
  for (var y = 0; y < h; y++) {
    var o = y * w * 4;
    for (var x = 0; x < w; x++, o += 4) {
      final l = _lum(panel, o);
      if (l >= 245) white++;
      if (l <= 96) {
        isDark[y * w + x] = true;
        darkIdx.add(y * w + x);
      }
    }
  }

  // Sobel 强边缘 + 12 bin 无方向直方图（0..π），跳过 1px 边框。
  // M1：边缘样本（位置 + 单位梯度）延迟收集——先做连通域拿到「大域」
  // 标记，灭点搜索只用长笔画（线族）的边缘像素（网点小点的边缘会把
  // 采样池淹没，见网点+集中线叠加夹具的教训）。
  const tau = 120;
  final hist = List<int>.filled(12, 0);
  var edgeCount = 0;
  final exX = <double>[], exY = <double>[], exU = <double>[], exV = <double>[];
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final o00 = ((y - 1) * w + x - 1) * 4;
      final o10 = ((y - 1) * w + x) * 4;
      final o20 = ((y - 1) * w + x + 1) * 4;
      final o01 = (y * w + x - 1) * 4;
      final o21 = (y * w + x + 1) * 4;
      final o02 = ((y + 1) * w + x - 1) * 4;
      final o12 = ((y + 1) * w + x) * 4;
      final o22 = ((y + 1) * w + x + 1) * 4;
      final gx = -_lum(panel, o00) - 2 * _lum(panel, o01) - _lum(panel, o02) +
          _lum(panel, o20) + 2 * _lum(panel, o21) + _lum(panel, o22);
      final gy = -_lum(panel, o00) - 2 * _lum(panel, o10) - _lum(panel, o20) +
          _lum(panel, o02) + 2 * _lum(panel, o12) + _lum(panel, o22);
      final mag = gx.abs() + gy.abs();
      if (mag >= tau) {
        edgeCount++;
        final theta = (math.atan2(gy.toDouble(), gx.toDouble()) + math.pi) %
            math.pi;
        hist[(theta / math.pi * 12).floor().clamp(0, 11)]++;
        exX.add(x.toDouble());
        exY.add(y.toDouble());
        exU.add(gx / mag);
        exV.add(gy / mag);
      }
    }
  }
  final topBin = hist.reduce(math.max);
  final dirCoh = edgeCount == 0 ? 0.0 : topBin / edgeCount;

  // 小暗连通域（4 邻接，面积 2..48 计数）：文字斑点。M1 记录面积分布供
  // 尺寸均匀性特征，并标记点径级像素（面积 ≤16）供网点周期性自相关使用
  // （文字叠加稀释防护：分母限制在点径级像素上）。
  final visited = List<bool>.filled(n, false);
  final stack = <int>[];
  var specks = 0;
  final areas = <int>[];
  final speckPix = List<bool>.filled(n, false);
  for (var i = 0; i < n; i++) {
    if (!isDark[i] || visited[i]) continue;
    var area = 0;
    var overflow = false;
    final member = <int>[];
    stack.add(i);
    visited[i] = true;
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      area++;
      member.add(p);
      if (area > 48) overflow = true; // 色块/线稿连通域，不是文字斑点
      final px = p % w, py = p ~/ w;
      if (px > 0 && isDark[p - 1] && !visited[p - 1]) {
        visited[p - 1] = true;
        stack.add(p - 1);
      }
      if (px < w - 1 && isDark[p + 1] && !visited[p + 1]) {
        visited[p + 1] = true;
        stack.add(p + 1);
      }
      if (py > 0 && isDark[p - w] && !visited[p - w]) {
        visited[p - w] = true;
        stack.add(p - w);
      }
      if (py < h - 1 && isDark[p + w] && !visited[p + w]) {
        visited[p + w] = true;
        stack.add(p + w);
      }
    }
    if (!overflow && area >= 2) {
      specks++;
      areas.add(area);
      if (area <= 16) {
        for (final p in member) {
          speckPix[p] = true;
        }
      }
    }
  }

  // 大域标记：独立做一遍 **8 连通**洪泛（面积 >16 = 线族/长笔画/色块）。
  // 4 连通会把 1px 斜线碎成单像素（对角步进），线族的几何连续性在 8
  // 连通下才成立；斑点/文字语义保持 4 连通口径不变。
  final large8 = List<bool>.filled(n, false);
  {
    final visited8 = List<bool>.filled(n, false);
    final stack8 = <int>[];
    for (var i = 0; i < n; i++) {
      if (!isDark[i] || visited8[i]) continue;
      var area = 0;
      final member = <int>[];
      stack8.add(i);
      visited8[i] = true;
      while (stack8.isNotEmpty) {
        final p = stack8.removeLast();
        area++;
        member.add(p);
        final px = p % w, py = p ~/ w;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = px + dx, ny = py + dy;
            if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
            final q = ny * w + nx;
            if (isDark[q] && !visited8[q]) {
              visited8[q] = true;
              stack8.add(q);
            }
          }
        }
      }
      if (area > 16) {
        for (final p in member) {
          large8[p] = true;
        }
      }
    }
  }

  // 灭点采样资格：**细笔画空旷边缘**——
  // (a) 邻近 8 连通大域（线族/长笔画的连续性；4 连通碎化 1px 斜线）；
  // (b) 3×3 局部暗像素 ≤4（笔画在空旷处的边缘；网点簇/实心域/线点相触
  //     处的密集墨边缘不参与——并入线族的点边缘是叠加夹具稀释会聚分的
  //     根因，其梯度对任意灭点都是噪声）。
  bool vpSampleEligible(int p) {
    final px = p % w, py = p ~/ w;
    var darkCnt = 0;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final nx = px + dx, ny = py + dy;
        if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
        if (isDark[ny * w + nx]) darkCnt++;
      }
    }
    if (darkCnt > 4) return false;
    if (large8[p]) return true;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = px + dx, ny = py + dy;
        if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
        if (large8[ny * w + nx]) return true;
      }
    }
    return false;
  }

  // M1 网点周期性：暗像素网格自相关峰值。对滞后 L ∈ [2, min(24, 边/4)]，
  // matchH(L) = 暗像素中向右平移 L 仍为暗的占比，matchV 同理向下；
  // dotPeriodicity = max_L min(matchH, matchV)——点阵在两轴同时高（旋转
  // 点阵的轴向滞后仍与格点重合），文字行距伪峰只出现在单轴或低值。
  // 分母优先取点径级像素（网点抗文字稀释）；点径级像素不足（粗网点相触
  // 连成大连通域等）时回落全暗像素。
  var dotPeriodicity = 0.0;
  var latticeIdx = <int>[];
  var latticeTotal = 0;
  for (var i = 0; i < n; i++) {
    if (speckPix[i]) latticeIdx.add(i);
  }
  latticeTotal = latticeIdx.length;
  if (latticeTotal < 40) {
    latticeIdx = darkIdx;
    latticeTotal = darkIdx.length;
  }
  if (latticeTotal > 0 && w >= 8 && h >= 8) {
    final maxLag = math.min(24, math.min(w, h) >> 2);
    for (var lag = 2; lag <= maxLag; lag++) {
      var mh = 0, mv = 0;
      for (final p in latticeIdx) {
        final px = p % w, py = p ~/ w;
        if (px + lag < w && isDark[p + lag]) mh++;
        if (py + lag < h && isDark[p + lag * w]) mv++;
      }
      final pair = math.min(mh / latticeTotal, mv / latticeTotal);
      if (pair > dotPeriodicity) dotPeriodicity = pair;
    }
  }

  // M1 斑点尺寸均匀性：std/mean（点阵 ≈0，笔画群 ≥0.5）。
  var speckUniformity = 0.0;
  if (areas.length >= 2) {
    var sum = 0, sumSq = 0;
    for (final a in areas) {
      sum += a;
      sumSq += a * a;
    }
    final mean = sum / areas.length;
    final variance = sumSq / areas.length - mean * mean;
    if (mean > 0) {
      speckUniformity = math.sqrt(math.max(0.0, variance)) / mean;
    }
  }

  // M1 会聚检测：候选灭点粗搜（23×23 归一化网格 [−0.6,1.6]²）+ 局部精化。
  // 口径：梯度 ⊥ 笔画轴、笔画轴指向灭点 ⇒ 边缘样本的梯度与「指向灭点
  // 方向」近正交（|dot| ≤ sin18°）计为会聚支持。采样限制在**大域边缘**
  // （长笔画线族）——网点小点/文字碎片的边缘不参与（既防稀释也防噪声）；
  // 格框伪会聚由边界预留压制（见常量文档）。
  var convergenceCoh = 0.0;
  var vpX = 0.5, vpY = 0.5;
  final sampleCount = exX.length;
  if (sampleCount >= 24) {
    // 确定性抽样：均匀步长取至多 _maxEdgeSamples 个大域样本。
    final stride = sampleCount > _maxEdgeSamples
        ? (sampleCount / _maxEdgeSamples).ceil()
        : 1;
    final sx = <double>[], sy = <double>[], su = <double>[], sv = <double>[];
    final margin = _vpBorderMargin;
    for (var i = 0; i < sampleCount; i += stride) {
      final x = exX[i], y = exY[i];
      if (x < margin || y < margin || x >= w - margin || y >= h - margin) {
        continue;
      }
      if (!vpSampleEligible(y.toInt() * w + x.toInt())) continue;
      sx.add(x);
      sy.add(y);
      su.add(exU[i]);
      sv.add(exV[i]);
    }
    final m = sx.length;
    if (m >= 24) {
      // 候选为归一化坐标，样本为像素坐标——打分前换算到像素空间。
      double scoreAt(double vpx, double vpy) {
        final vx = vpx * w, vy = vpy * h;
        var hits = 0;
        for (var i = 0; i < m; i++) {
          final dx = vx - sx[i], dy = vy - sy[i];
          final len = math.sqrt(dx * dx + dy * dy);
          if (len < 1e-6) continue;
          final dot = (su[i] * dx + sv[i] * dy) / len;
          if (dot.abs() <= kConvergenceSinTol) hits++;
        }
        return hits / m;
      }

      var best = -1.0, bx = 0.0, by = 0.0;
      for (var gy = 0; gy < _vpSteps; gy++) {
        final vpy = _vpLo + (_vpHi - _vpLo) * gy / (_vpSteps - 1);
        for (var gx = 0; gx < _vpSteps; gx++) {
          final vpx = _vpLo + (_vpHi - _vpLo) * gx / (_vpSteps - 1);
          final s = scoreAt(vpx, vpy);
          if (s > best) {
            best = s;
            bx = vpx;
            by = vpy;
          }
        }
      }
      // 局部精化：±0.1 归一化步长 0.025（9×9）。
      const step = 0.025;
      for (var dy = -4; dy <= 4; dy++) {
        for (var dx = -4; dx <= 4; dx++) {
          final vpx = bx + dx * step;
          final vpy = by + dy * step;
          final s = scoreAt(vpx, vpy);
          if (s > best) {
            best = s;
            bx = vpx;
            by = vpy;
          }
        }
      }
      convergenceCoh = best;
      vpX = bx.clamp(0.0, 1.0).toDouble();
      vpY = by.clamp(0.0, 1.0).toDouble();
    }
  }

  return PanelMotionFeatures(
    speckDensity: specks * 1000.0 / n,
    whiteFrac: white / n,
    dirCoherence: dirCoh,
    edgeFrac: edgeCount / n,
    speckCount: specks,
    speckUniformity: speckUniformity,
    dotPeriodicity: dotPeriodicity,
    convergenceCoh: convergenceCoh,
    vpX: vpX,
    vpY: vpY,
  );
}

/// 格级动效判断接缝（运行期依赖，不进 EffectConfig、不参与 configHash）。
/// 返回与 [panels] 等长的幅度乘数表（每项 ∈ [0,1]，0 = 该格静止）。
abstract class PanelMotionJudge {
  const PanelMotionJudge();

  /// [working] 为工作分辨率底图；[panels] 为工作分辨率画布坐标格矩形
  /// （单格路径 = 恰一个整页矩形）。实现必须纯函数、确定性。
  List<double> panelScales(RgbaImage working, List<PixelRect> panels);
}

RgbaImage _cropPanel(RgbaImage working, PixelRect r) {
  final sub = RgbaImage(width: r.width, height: r.height);
  for (var y = 0; y < r.height; y++) {
    sub.data.setRange(y * r.width * 4, (y + 1) * r.width * 4, working.data,
        ((r.y + y) * working.width + r.x) * 4);
  }
  return sub;
}

/// 内置启发式：文字主导格（密集文字斑点 ∧ 白底可见 ∧ 无方向笔触族）→ 0，
/// 否则 1。三条件 AND = 「模糊→动」：只压有明确静态证据的格。
class HeuristicPanelMotionJudge extends PanelMotionJudge {
  const HeuristicPanelMotionJudge();

  @override
  List<double> panelScales(RgbaImage working, List<PixelRect> panels) {
    return [
      for (final r in panels) _scaleOf(_cropPanel(working, r)),
    ];
  }

  double _scaleOf(RgbaImage panel) {
    final f = extractPanelMotionFeatures(panel);
    final still = isTextStill(f);
    return still ? 0.0 : 1.0;
  }

  /// 网点判定（C1 否决，M1）：周期性峰值达阈值（点阵格，含点相触连成
  /// 大连通域的粗网点——CC 特征失效时自相关仍然命中），或斑点量足且
  /// 尺寸高度均匀（非整周期排布的网点）。命中格不得因斑点密度判静。
  static bool isScreentone(PanelMotionFeatures f) =>
      f.dotPeriodicity >= kScreentonePeriodicityMin ||
      (f.speckCount >= kScreentoneSpeckMin &&
          f.speckUniformity <= kScreentoneUniformityMax);

  /// 文字格判定（M1 加网点否决）：三条件 AND，网点格被否决。
  static bool isTextStill(PanelMotionFeatures f) =>
      !isScreentone(f) &&
      f.speckDensity >= kTextSpeckMin &&
      f.whiteFrac >= kTextWhiteMin &&
      f.dirCoherence <= kMaxDirCoh;
}

/// 格级动效策略（Phase E 画面自适应）：幅度 × 节奏 × 主体增强。
///
/// - [scale]：该格视差幅度乘数 ∈ [0,1]（0 = 静止），语义同
///   [PanelMotionJudge] 的逐格裁决；
/// - [tempo]：该格节奏乘数（>1 加快、<1 放慢；整数周期数口径，无缝循环
///   契约不破）。同格所有层必须同 tempo（管线保证），防层间相位漂移；
/// - [subjectBoost]：该格主体层的额外幅度乘数（>1 = 人物冲出画面感，
///   对标撕漫）。只乘在含主体 blob 的层上（管线构造性检测），配合相位
///   跟随读作「领跑」而非脱节。
class PanelMotionStrategy {
  const PanelMotionStrategy({
    this.scale = 1.0,
    this.tempo = 1.0,
    this.subjectBoost = 1.0,
  });

  static const PanelMotionStrategy neutral = PanelMotionStrategy();

  final double scale;
  final double tempo;
  final double subjectBoost;
}

/// 策略判断接缝（Phase E，运行期依赖，不进 EffectConfig/configHash）。
/// 返回与 [panels] 等长的策略表；[subjects] 与 panels 对齐（分割器未注入
/// 时为逐格空掩码，掩码统计特征在该情形下不可用）。
/// 实现必须纯函数、确定性。
abstract class PanelStrategyJudge {
  const PanelStrategyJudge();

  List<PanelMotionStrategy> panelStrategies(
      RgbaImage working, List<PixelRect> panels, List<SubjectMask> subjects);
}

/// 动作格阈值：方向笔触一致性 ≥ 此值（scene_motion 文档记录的上尾起点
/// 0.30，分布谷上沿）——速度线/集中线成族的动作格，节奏加快。
const double kActionDirCohMin = 0.30;

/// 动作格节奏乘数。
const double kActionTempo = 1.5;

/// 特写格阈值：最大主体域占格面积比 ≥ 此值。分布定稿（2026-10-24，30 页
/// 46 格 u2netp 掩码统计，build/depth_probe/mask_stats.tsv）：0.00–0.20
/// 26 格（无主体/小主体），**0.20–0.30 自然谷**，0.30–0.45 主体面板 7 格，
/// 0.45+ 特写 7 格 → 取谷中段 0.25。
const double kCloseupBlobMin = 0.25;

/// 特写格节奏乘数（放慢：特写镜头慢推感）与主体增强乘数。
const double kCloseupTempo = 0.75;
const double kCloseupBoost = 1.2;

/// 氛围格阈值：强边缘占比 ≤ 此值（近空/天空/大场面渐变格）。分布定稿
/// （2026-10-24，scene_features.tsv 47 格非文字非动作格）：≤0.03 主质量
/// 2 格（近空面板），0.10 起为叙事/人物簇（8 格 0.10–0.17、其余 ≥0.20），
/// **谷 0.03–0.10 取 0.05**。
const double kAtmosphereEdgeMax = 0.05;

/// 氛围格幅度与节奏乘数（呼吸感：中等幅度、放慢）。
const double kAtmosphereScale = 0.6;
const double kAtmosphereTempo = 0.75;

/// 面板画面类别（Phase E'：小模型分类的目标语义，顺序固定——与
/// OnnxClipPanelClassifier 的提示词表一一对应）。
enum PanelClass { action, atmosphere, closeup, narrative }

/// 面板小模型分类接缝（运行期依赖，不进 EffectConfig/configHash）。
/// 返回与 [PanelClass.values] 等长的分数表（任意实数尺度，只有序与差
/// 有意义）；空表 = 不可用（调用方回落启发式）。实现必须纯函数、
/// **永不抛**（失败返回空表，渲染不中断）。
abstract class PanelClassifier {
  const PanelClassifier();

  List<double> scores(RgbaImage panel);
}

/// 分类器置信边界（top1 − top2 ≥ 此值才覆盖启发式）。余弦相似度尺度。
/// 2026-10-24 探针定值（负结果留档）：CLIP ViT-B/32 **fp32**（Xenova）+
/// 动漫语汇提示词在漫画页/格上的 top1−top2 实测 0.000–0.007（top1 排序
/// 方向部分正确但置信是噪声级——漫画对该模型是分布外域，与量化无关：
/// int8/QDQ 版同量级且 QDQ 嵌入失真余弦 0.706）→ 0.02 意味着该模型
/// **不会覆盖启发式**（安全无操作）；此边界是为未来漫画域模型（微调
/// 分类器/漫画 CLIP）预留的质量门槛，不因弱模型降标（降标 = 让噪声
/// 决定动效）。
const double kClassifierMargin = 0.02;

/// 分类器增强的策略判断器（Phase E'，用户裁决「识别不准处接入小模型」）：
/// 注入的 [classifier] 置信（top1−top2 ≥ [margin]）时按 [PanelClass] 档
/// **覆盖**启发式（含启发式判静但模型确信有张力的格——这正是识别不准
/// 的主诉）；不置信/不可用回落 [primary]（模糊→启发式档，保守语义保持）。
class ClassifierPanelStrategyJudge extends PanelStrategyJudge {
  const ClassifierPanelStrategyJudge({
    this.primary = const HeuristicSceneStrategyJudge(),
    required this.classifier,
    this.margin = kClassifierMargin,
  });

  final PanelStrategyJudge primary;
  final PanelClassifier classifier;
  final double margin;

  @override
  List<PanelMotionStrategy> panelStrategies(
      RgbaImage working, List<PixelRect> panels, List<SubjectMask> subjects) {
    final fallback = primary.panelStrategies(working, panels, subjects);
    return [
      for (var i = 0; i < panels.length; i++)
        _override(
            _cropPanel(working, panels[i]), classifier, margin,
            i < fallback.length ? fallback[i] : PanelMotionStrategy.neutral),
    ];
  }

  static PanelMotionStrategy _override(RgbaImage panel,
      PanelClassifier classifier, double margin, PanelMotionStrategy fb) {
    final scores = classifier.scores(panel);
    if (scores.length != PanelClass.values.length) return fb;
    var top = 0, second = 1;
    if (scores[second] > scores[top]) {
      top = 1;
      second = 0;
    }
    for (var i = 2; i < scores.length; i++) {
      if (scores[i] > scores[top]) {
        second = top;
        top = i;
      } else if (scores[i] > scores[second]) {
        second = i;
      }
    }
    if (scores[top] - scores[second] < margin) return fb;
    switch (PanelClass.values[top]) {
      case PanelClass.action:
        return PanelMotionStrategy(tempo: kActionTempo);
      case PanelClass.atmosphere:
        return PanelMotionStrategy(
            scale: kAtmosphereScale, tempo: kAtmosphereTempo);
      case PanelClass.closeup:
        return PanelMotionStrategy(
            tempo: kCloseupTempo, subjectBoost: kCloseupBoost);
      case PanelClass.narrative:
        return const PanelMotionStrategy(scale: 0.0);
    }
  }
}

/// 逐格诊断（M2 MotionPack 的 panels.json 载荷）：分档类别 + 启发式置信
/// + 判定用特征 + 生效策略。clsConf ∈ [0,1] 是**决策距阈值比**（判定特征
/// 越过其阈值的倍数，钳到 1）——启发式没有概率语义，记录的是确定性证据
/// 强度；小模型分类器接入后由其 softmax 语义另行覆盖。
class PanelDiagnosis {
  const PanelDiagnosis({
    required this.cls,
    required this.clsConf,
    required this.features,
    required this.strategy,
  });

  final PanelClass cls;
  final double clsConf;
  final PanelMotionFeatures features;
  final PanelMotionStrategy strategy;
}

/// 内置张力分档判断器（Phase E；M1 扩动作判据）。**用户裁决（2026-10-24）：
/// 默认静止，只有氛围与张力描绘才需要动态效果**——保守语义自 v1.9 的
/// 「模糊→动」翻转为「模糊→静」，细节密集的叙事格不再被视差切片。
/// 分档（阈值全部分布定值，禁止逐页标注调参）：
/// - 文字格 → scale 0（v1.9 三条件 + M1 网点否决：网点格不因斑点密度判静）；
/// - 张力·动作格（平行速度线族 ∨ 放射集中线族）→ tempo 1.5；
/// - 张力·特写格（主体域占格大）→ tempo 0.75 + subjectBoost 1.2；
/// - 氛围格（近空/渐变大场面）→ scale 0.6 + tempo 0.75；
/// - **其余（叙事/细节格）→ scale 0（默认静止）**。
class HeuristicSceneStrategyJudge extends PanelStrategyJudge {
  const HeuristicSceneStrategyJudge();

  @override
  List<PanelMotionStrategy> panelStrategies(
      RgbaImage working, List<PixelRect> panels, List<SubjectMask> subjects) {
    return [
      for (var i = 0; i < panels.length; i++)
        _diagnose(
          _cropPanel(working, panels[i]),
          i < subjects.length ? subjects[i] : SubjectMask.empty(1, 1),
        ).strategy,
    ];
  }

  /// 逐格诊断（M2 pack 生产入口）：分档 + 类别 + 置信一次性产出，
  /// 与 [panelStrategies] 同一判定路径（策略恒等）。
  List<PanelDiagnosis> diagnose(
      RgbaImage working, List<PixelRect> panels, List<SubjectMask> subjects) {
    return [
      for (var i = 0; i < panels.length; i++)
        _diagnose(
          _cropPanel(working, panels[i]),
          i < subjects.length ? subjects[i] : SubjectMask.empty(1, 1),
        ),
    ];
  }

  PanelDiagnosis _diagnose(RgbaImage panel, SubjectMask mask) {
    final f = extractPanelMotionFeatures(panel);
    // 文字样三条件（未否决=真文字格；被网点否决=网点底假文字信号——
    // 两者语义都按叙事静格处理，类别记 narrative）。
    final textLike = f.speckDensity >= kTextSpeckMin &&
        f.whiteFrac >= kTextWhiteMin &&
        f.dirCoherence <= kMaxDirCoh;
    if (textLike) {
      return PanelDiagnosis(
        cls: PanelClass.narrative,
        clsConf: math.min(1.0, f.speckDensity / kTextSpeckMin),
        features: f,
        strategy: const PanelMotionStrategy(scale: 0.0),
      );
    }
    // 张力·动作：平行速度线族（dirCoh）∨ 放射集中线族（M1 会聚）。
    final dirAct = f.dirCoherence >= kActionDirCohMin;
    final convAct = f.convergenceCoh >= kActionConvergenceMin;
    if (dirAct || convAct) {
      final ratio = math.max(
        f.dirCoherence / kActionDirCohMin,
        f.convergenceCoh / kActionConvergenceMin,
      );
      return PanelDiagnosis(
        cls: PanelClass.action,
        clsConf: math.min(1.0, ratio),
        features: f,
        strategy: PanelMotionStrategy(tempo: kActionTempo),
      );
    }
    // 张力·特写：大特写本身是戏剧张力（主体领跑）。
    if (mask.hasSubjects && mask.maxBlobFrac >= kCloseupBlobMin) {
      return PanelDiagnosis(
        cls: PanelClass.closeup,
        clsConf: math.min(1.0, mask.maxBlobFrac / kCloseupBlobMin),
        features: f,
        strategy: PanelMotionStrategy(
            tempo: kCloseupTempo, subjectBoost: kCloseupBoost),
      );
    }
    // 氛围：近空/渐变大场面（呼吸感）。
    if (f.edgeFrac <= kAtmosphereEdgeMax) {
      return PanelDiagnosis(
        cls: PanelClass.atmosphere,
        clsConf: math.min(
            1.0, kAtmosphereEdgeMax / math.max(f.edgeFrac, 1e-6) * 0.5),
        features: f,
        strategy: PanelMotionStrategy(
            scale: kAtmosphereScale, tempo: kAtmosphereTempo),
      );
    }
    // 叙事/细节格：默认静止（模糊→静）。
    return PanelDiagnosis(
      cls: PanelClass.narrative,
      clsConf: 0.0,
      features: f,
      strategy: const PanelMotionStrategy(scale: 0.0),
    );
  }
}
