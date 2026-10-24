/// §6.2 张力波形：`snapWave` —— 非对称、无缝、无直流（DC-free）的缓动波。
///
/// 纯函数、独立数学模块：Task 3.4 接线之前不被任何渲染器调用，因此本文件
/// 不改变任何现有渲染输出。定义只含 2π 的**整数次谐波**（1、2、3 次，
/// N=3，spec §6.2/H5 系数），故对 u 自动满足：
/// 1. period-1：`f(0)==f(1)`，无缝契约天然成立；
/// 2. C-连续：整数谐波的三角和是 C∞（远超无缝要求的 C¹）；
/// 3. DC-free：一个周期上积分为 0，叠加后不产生均值漂移。
/// 形状：快上升 → 过冲 → 慢回缓，峰值比纯正弦更尖锐。
library;

import 'dart:math' as math;

/// raw 谐波和的最大绝对值，实测恰在 u=3/4 处取得
/// `|−1 − 0.42 + 0.18| = 1.24`（正峰 ≈0.8932830，u≈0.0909/0.4091），
/// 因此 |snapWave| 的峰值精确归一到 1.0。const——不做逐调用寻峰。
const double _peak = 1.24;

/// §6.2 张力缓动波形。`u ∈ [0,1)`；任意实数先折回 [0,1)。
double snapWave(double u) {
  final t = (u % 1.0 + 1.0) % 1.0;
  final w = 2 * math.pi * t;
  final raw = math.sin(w) +
      0.42 * math.sin(2 * w + math.pi / 2) +
      0.18 * math.sin(3 * w);
  return raw / _peak;
}

/// snapWave 在 u=0（与 u=0.5，rank·π 视差相位的两个静息点）的直流值
/// 0.42 / 1.24 —— v1.9 及之前 t=0 帧因此带 ~34% 幅度的分数位移（首帧/
/// 静息帧整页被重采样，文字发虚的直接根源之一）。
const double kSnapWaveRestOffset = 0.42 / _peak;

/// 静息归零的张力波形（文字保真 v1.10）：`restSnapWave(u, uRest)` 在
/// `u == uRest` 处精确为 0，其余形状与 [snapWave] 同族。
///
/// 每条通道（每层的横/竖视差）以自己的 t=0 相位 [uRest] 为静息点：位移
/// `d(t) = (snapWave(u(t)) − snapWave(uRest)) / (1 + |snapWave(uRest)|)`。
/// - t=0 ⇒ u=uRest ⇒ 位移精确 0（首帧/静息帧 = 原画，逐字节不再重采样）；
/// - 无缝：一个动效周期内 u 推进整数圈 ⇒ u(dur)=u(0)=uRest，端点相等；
/// - 峰值归一：除以 `1 + |snapWave(uRest)|`（最坏 uRest=直流点时 1.339），
///   通道峰值仍 ≤1，amplitude 参数语义（峰值像素幅度）保持；
/// - 纯函数、无状态，确定性不受影响。
///
/// uRest 恒取各通道 t=0 的相位（视差 rank·π/相位跟随偏移/节奏周期都只
/// 平移 u），因此每条通道独立归零，混合层栈在 t=0 整体归位。
double restSnapWave(double u, double uRest) {
  final base = snapWave(uRest);
  return (snapWave(u) - base) / (1.0 + base.abs());
}
