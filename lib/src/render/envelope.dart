/// v1.3 情绪编排：一条整循环包络曲线，按归一化时间 `u` 输出 5 个调制量。
///
/// `moodScript` 不画任何东西——它只按情绪重排已有动效的**振幅**。三个约束
/// 决定了这里的写法：
/// 1. 曲线必须是 `u` 的整周期函数（首尾关键点取值相同），否则无缝契约破裂；
/// 2. 只做乘性/加性调制，不引入新周期（H8：各效果自身周期不变）；
/// 3. 未启用时因子必须精确等于 1.0 / 0.0，乘加之后浮点结果一位都不变，
///    legacy 回滚链才谈得上逐字节一致。
class EnvelopeFactors {
  const EnvelopeFactors({
    this.motion = 1.0,
    this.particles = 1.0,
    this.exposure = 1.0,
    this.warmth = 0.0,
    this.vignette = 0.0,
  });

  /// 乘性因子（恒正）：视差与呼吸振幅、粒子浓度、加法光效强度。
  final double motion;
  final double particles;
  final double exposure;

  /// 加性增量：`toneShift` 的暖偏移量、暗角强度的额外系数（可为负）。
  final double warmth;
  final double vignette;

  /// 恒等因子：未启用 `moodScript` 时全链路使用它。
  static const EnvelopeFactors identity = EnvelopeFactors();

  @override
  String toString() => 'EnvelopeFactors(motion: ${motion.toStringAsFixed(3)}, '
      'particles: ${particles.toStringAsFixed(3)}, '
      'exposure: ${exposure.toStringAsFixed(3)}, '
      'warmth: ${warmth.toStringAsFixed(3)}, '
      'vignette: ${vignette.toStringAsFixed(3)})';
}

/// 关键点：`u` 处的五个因子取值。相邻点之间用 smoothstep 插值 → 一阶导连续，
/// 振幅变化不会有「突然卡一下」的折角。
class _Key {
  const _Key(this.u, this.motion, this.particles, this.exposure, this.warmth,
      this.vignette);

  final double u;
  final double motion;
  final double particles;
  final double exposure;
  final double warmth;
  final double vignette;
}

/// `tension` 低平蓄力 → 慢升 → 0.35 处尖峰 → 骤回落（大招起手）。
const List<_Key> _tension = [
  _Key(0.00, 0.60, 0.70, 0.90, 0.00, 0.10),
  _Key(0.30, 1.35, 1.10, 1.05, 0.04, 0.00),
  _Key(0.35, 1.60, 1.40, 1.35, 0.10, -0.15),
  _Key(0.42, 0.70, 0.85, 0.95, 0.02, 0.05),
  _Key(1.00, 0.60, 0.70, 0.90, 0.00, 0.10),
];

/// `calm` 0.97~1.04 的极缓波，四段错相让画面像「在呼吸」而不是在摆。
const List<_Key> _calm = [
  _Key(0.00, 0.98, 0.98, 1.00, 0.00, 0.00),
  _Key(0.25, 1.02, 1.03, 1.02, 0.02, -0.02),
  _Key(0.50, 0.97, 0.98, 0.99, 0.00, 0.02),
  _Key(0.75, 1.04, 1.02, 1.01, -0.01, -0.02),
  _Key(1.00, 0.98, 0.98, 1.00, 0.00, 0.00),
];

/// `burst` 0.15 处爆发 → 快速衰减 → 0.70 处一次余波 → 收尾回到 1.0。
const List<_Key> _burst = [
  _Key(0.00, 1.00, 1.00, 1.00, 0.00, 0.00),
  _Key(0.15, 1.80, 1.55, 1.45, 0.12, -0.18),
  _Key(0.30, 1.25, 1.20, 1.15, 0.05, -0.06),
  _Key(0.45, 1.05, 1.10, 1.05, 0.02, 0.00),
  _Key(0.70, 1.10, 1.05, 1.06, 0.03, -0.03),
  _Key(1.00, 1.00, 1.00, 1.00, 0.00, 0.00),
];

/// `eerie` 每 1/4 循环一次轻微下沉 + 暗角收拢（悬疑、恐怖）。
final List<_Key> _eerie = [
  for (var i = 0; i < 4; i++) ...[
    _Key(i * 0.25, 1.00, 1.00, 1.00, -0.02, 0.00),
    _Key(i * 0.25 + 0.125, 0.88, 0.92, 0.94, -0.04, 0.12),
  ],
  const _Key(1.00, 1.00, 1.00, 1.00, -0.02, 0.00),
];

/// 支持的 mood 表（迭代顺序即文档/CLI 展示顺序）。
final Map<String, List<_Key>> _moods = {
  'tension': _tension,
  'calm': _calm,
  'eerie': _eerie,
  'burst': _burst,
};

/// 一个 mood 的包络曲线。
class MotionEnvelope {
  /// [mood] 未知时回落 `calm` 并置 [usedFallback]（不影响其余动效）。
  /// [strength] 是与恒等因子的混合比：0 → 完全恒等，1 → 完整曲线。
  /// [cycles] 每条循环重复的包络轮数，整数才能保持无缝。
  MotionEnvelope.of(String mood, {double strength = 1.0, int cycles = 1})
      : moodUsed = _resolve(mood),
        usedFallback = !_moods.containsKey(mood.trim().toLowerCase()),
        strength = strength.clamp(0.0, 1.0),
        cycles = cycles.clamp(1, 4),
        _keys = _moods[_resolve(mood)]!;

  /// 实际生效的 mood（未知值已回落 `calm`）。
  final String moodUsed;

  /// true = 请求的 mood 不在支持表内，已回落 `calm`。
  final bool usedFallback;

  /// 实际生效的强度与周期（均已夹到定义域）。
  final double strength;
  final int cycles;

  final List<_Key> _keys;

  /// 支持的 mood 名。
  static List<String> get knownMoods => _moods.keys.toList();

  static String _resolve(String mood) {
    final m = mood.trim().toLowerCase();
    return _moods.containsKey(m) ? m : 'calm';
  }

  /// `u∈[0,1]`。`strength=0` 退化为恒等；否则所有乘性因子都在 `(0,3)` 内。
  EnvelopeFactors at(double u) {
    if (strength == 0.0) return EnvelopeFactors.identity;
    var f = (u * cycles) % 1.0;
    if (f < 0) f += 1.0;
    final keys = _keys;
    var i = 0;
    while (i < keys.length - 2 && f >= keys[i + 1].u) {
      i++;
    }
    final a = keys[i], b = keys[i + 1];
    final span = b.u - a.u;
    final t = span <= 0 ? 0.0 : _smooth((f - a.u) / span);
    double mix(double x, double y) => x + (y - x) * t;
    // 乘性项按 strength 向 1.0 收，加性项按 strength 缩放（0 即恒等）。
    double mul(double v) => 1.0 + (v - 1.0) * strength;
    double add(double v) => v * strength;
    return EnvelopeFactors(
      motion: mul(mix(a.motion, b.motion)),
      particles: mul(mix(a.particles, b.particles)),
      exposure: mul(mix(a.exposure, b.exposure)),
      warmth: add(mix(a.warmth, b.warmth)),
      vignette: add(mix(a.vignette, b.vignette)),
    );
  }

  /// smoothstep：两端导数为 0，接缝处看不出斜率突变。
  static double _smooth(double t) {
    final x = t.clamp(0.0, 1.0);
    return x * x * (3 - 2 * x);
  }
}
