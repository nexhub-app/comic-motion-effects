/// 动效画面判断（v1.9）：按画面内容裁决「这一格该不该动」。
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
/// 保守语义「模糊→动」：三条件 AND，任一不满足即满幅。外部 AI 逐格裁决
/// 走 `scene.json` 侧车（`scene_sidecar.dart`），命中格覆盖启发式。
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

/// 单格画面特征（工作分辨率口径；与校准探针逐行同源）。
class PanelMotionFeatures {
  const PanelMotionFeatures({
    required this.speckDensity,
    required this.whiteFrac,
    required this.dirCoherence,
    required this.edgeFrac,
  });

  /// 小暗连通域密度（斑点数/千像素）——文字笔画的结构代理。
  final double speckDensity;

  /// 近白（亮度 ≥245）像素占比——气泡白底可见性。
  final double whiteFrac;

  /// 强边缘方向直方图 top-bin 质量/强边缘总数——方向笔触族信号。
  final double dirCoherence;

  /// 强边缘像素占比（辅助观测，不参与判定）。
  final double edgeFrac;
}

int _lum(RgbaImage img, int o) =>
    (img.data[o] * 2 + img.data[o + 1] * 3 + img.data[o + 2]) ~/ 6;

/// 提取单格特征。输入为该格的子图（调用方裁剪）；纯函数，同输入同输出。
PanelMotionFeatures extractPanelMotionFeatures(RgbaImage panel) {
  final w = panel.width, h = panel.height;
  final n = w * h;
  var white = 0;
  final isDark = List<bool>.filled(n, false);
  for (var y = 0; y < h; y++) {
    var o = y * w * 4;
    for (var x = 0; x < w; x++, o += 4) {
      final l = _lum(panel, o);
      if (l >= 245) white++;
      if (l <= 96) isDark[y * w + x] = true;
    }
  }

  // Sobel 强边缘 + 12 bin 无方向直方图（0..π），跳过 1px 边框。
  const tau = 120;
  final hist = List<int>.filled(12, 0);
  var edgeCount = 0;
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
      }
    }
  }
  final topBin = hist.reduce(math.max);
  final dirCoh = edgeCount == 0 ? 0.0 : topBin / edgeCount;

  // 小暗连通域（4 邻接，面积 2..48 计数）：文字斑点。
  final visited = List<bool>.filled(n, false);
  final stack = <int>[];
  var specks = 0;
  for (var i = 0; i < n; i++) {
    if (!isDark[i] || visited[i]) continue;
    var area = 0;
    var overflow = false;
    stack.add(i);
    visited[i] = true;
    while (stack.isNotEmpty) {
      final p = stack.removeLast();
      area++;
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
    if (!overflow && area >= 2) specks++;
  }

  return PanelMotionFeatures(
    speckDensity: specks * 1000.0 / n,
    whiteFrac: white / n,
    dirCoherence: dirCoh,
    edgeFrac: edgeCount / n,
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
    final still = f.speckDensity >= kTextSpeckMin &&
        f.whiteFrac >= kTextWhiteMin &&
        f.dirCoherence <= kMaxDirCoh;
    return still ? 0.0 : 1.0;
  }

  /// 文字格三条件判定（Phase E 复用：策略判断器的静格档同规则）。
  static bool isTextStill(PanelMotionFeatures f) =>
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

/// 内置张力分档判断器（Phase E）。**用户裁决（2026-10-24）：默认静止，
/// 只有氛围与张力描绘才需要动态效果**——保守语义自 v1.9 的「模糊→动」
/// 翻转为「模糊→静」，细节密集的叙事格不再被视差切片。
/// 分档（阈值全部分布定值，禁止逐页标注调参）：
/// - 文字格 → scale 0（复用 v1.9 三条件）；
/// - 张力·动作格（方向笔触族）→ tempo 1.5；
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
        _strategyOf(
          _cropPanel(working, panels[i]),
          i < subjects.length ? subjects[i] : SubjectMask.empty(1, 1),
        ),
    ];
  }

  PanelMotionStrategy _strategyOf(RgbaImage panel, SubjectMask mask) {
    final f = extractPanelMotionFeatures(panel);
    if (HeuristicPanelMotionJudge.isTextStill(f)) {
      return const PanelMotionStrategy(scale: 0.0);
    }
    // 张力·动作：速度线/集中线族。
    if (f.dirCoherence >= kActionDirCohMin) {
      return PanelMotionStrategy(tempo: kActionTempo);
    }
    // 张力·特写：大特写本身是戏剧张力（主体领跑）。
    if (mask.hasSubjects && mask.maxBlobFrac >= kCloseupBlobMin) {
      return PanelMotionStrategy(
          tempo: kCloseupTempo, subjectBoost: kCloseupBoost);
    }
    // 氛围：近空/渐变大场面（呼吸感）。
    if (f.edgeFrac <= kAtmosphereEdgeMax) {
      return PanelMotionStrategy(
          scale: kAtmosphereScale, tempo: kAtmosphereTempo);
    }
    // 叙事/细节格：默认静止（模糊→静）。
    return const PanelMotionStrategy(scale: 0.0);
  }
}
