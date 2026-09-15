import 'dart:math';

/// Deterministic PRNG so identical parameters always produce identical frames.
class DeterministicRandom {
  DeterministicRandom(int seed) : _state = seed & 0x7fffffff;

  int _state;

  /// 无参时返回原始随机整数（0..0x7fffffff）；带 [max] 时返回 0..max-1。
  int nextInt([int? max]) {
    // xorshift32
    var x = _state;
    x ^= x << 13;
    x &= 0x7fffffff;
    x ^= x >> 17;
    x ^= x << 5;
    x &= 0x7fffffff;
    _state = x;
    if (max == null || max <= 1) return x;
    return x % max;
  }

  double nextDouble() => nextInt() / 0x7fffffff;
}

/// A 2D affine-ish motion applied to a layer per frame.
class LayerTransform {
  LayerTransform({
    this.offsetX = 0,
    this.offsetY = 0,
    this.scale = 1.0,
    this.rotateDeg = 0.0,
  });

  final double offsetX;
  final double offsetY;
  final double scale;
  final double rotateDeg;
}

/// Wave / oscillation helpers shared by motion generators.
class MotionMath {
  static double wave(double t, {double periodSec = 3.0, double phase = 0.0}) {
    final w = 2 * pi * (t / periodSec) + phase;
    return sin(w);
  }
}
