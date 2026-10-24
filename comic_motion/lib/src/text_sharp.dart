/// 文字保真（text sharp，v1.10）：检测工作分辨率底图上的文字笔画区域，
/// 输出**位打包**掩码（1 bit/像素，源栅格坐标）。
///
/// 动机：视差/呼吸每帧都把层做分数位移重采样（standard+ 档 Catmull-Rom），
/// 线稿尚可，但文字笔画是最高频内容——半像素插值就把笔画边缘糊成中间灰。
/// 修复 = 掩码命中的像素在层贴图时改走**整数取整采样**（nearest）：
/// 文字像素逐帧都是源字形的纯平移拷贝，不再产生任何插值中间值。
///
/// 检测规则（结构定值，非逐页调参；阈值与 scene_motion 的文字斑点特征
/// 同源）：
/// - 暗像素 = 亮度 ≤96（与 kTextSpeckMin 系列的暗笔判定同一阈值）；
/// - 4 邻接连通域，两类判「文字样」：
///   a) 小域：面积 ≤4096px²（字母/标点/网点/短笔画——误收无害：整数化
///      平移对任何小笔画的观感只会更锐，不会更差）；
///   b) 稀疏域：外接框边 ≤200px 且 填充率（面积/框面积）≤0.6（大号
///      拟声词/题字：笔画在框内稀疏分布；实心色块填充率 ≈1 被排除）；
/// - 命中像素外扩 2 轮 4 邻接膨胀（≈±2px，罩住笔画抗锯齿晕圈——晕圈若
///   仍走插值，会与整数化的笔画错开半像素）。
///
/// 纯函数、确定性；无文字时返回 null（通道零成本）。
library;

import 'dart:typed_data';

import 'image_model.dart';

/// 暗笔画亮度阈值（与 scene_motion 的文字斑点判定同源）。
const int kTextSharpDarkLum = 96;

/// 小连通域面积上限：≤ 此值直接判文字样（字母/网点/短笔画）。
const int kTextSharpSmallArea = 4096;

/// 稀疏域外接框边长上限与填充率上限（大号文字：框内稀疏、笔画细）。
const int kTextSharpBBoxMaxSide = 200;
const double kTextSharpMaxFill = 0.6;

/// 检测文字区域掩码。返回 `(w*h+7)/8` 字节的位打包表（行主序，第
/// `y*w+x` 像素 = 第 `p>>3` 字节的 `1<<(p&7)` 位）；无文字样像素时
/// 返回 null。
Uint8List? detectTextSnapMask(RgbaImage img) {
  final w = img.width, h = img.height, n = w * h;
  final data = img.data;
  final dark = Uint8List(n);
  for (var p = 0; p < n; p++) {
    final o = p * 4;
    // 与 scene_motion._lum 同一权重（ITU 系数的整数近似）。
    if ((data[o] * 2 + data[o + 1] * 3 + data[o + 2]) ~/ 6 <=
        kTextSharpDarkLum) {
      dark[p] = 1;
    }
  }

  // 4 邻接连通域：一次扫描 + 显式栈（免递归），逐域累计面积与外接框。
  final visited = Uint8List(n);
  final stack = Int32List(n);
  final accepted = Uint8List(n);
  var any = false;
  for (var seed = 0; seed < n; seed++) {
    if (dark[seed] == 0 || visited[seed] != 0) continue;
    var top = 0;
    stack[top++] = seed;
    visited[seed] = 1;
    var area = 0;
    var minX = w, maxX = 0, minY = h, maxY = 0;
    while (top > 0) {
      final p = stack[--top];
      area++;
      final px = p % w, py = p ~/ w;
      if (px < minX) minX = px;
      if (px > maxX) maxX = px;
      if (py < minY) minY = py;
      if (py > maxY) maxY = py;
      if (px > 0 && dark[p - 1] != 0 && visited[p - 1] == 0) {
        visited[p - 1] = 1;
        stack[top++] = p - 1;
      }
      if (px < w - 1 && dark[p + 1] != 0 && visited[p + 1] == 0) {
        visited[p + 1] = 1;
        stack[top++] = p + 1;
      }
      if (py > 0 && dark[p - w] != 0 && visited[p - w] == 0) {
        visited[p - w] = 1;
        stack[top++] = p - w;
      }
      if (py < h - 1 && dark[p + w] != 0 && visited[p + w] == 0) {
        visited[p + w] = 1;
        stack[top++] = p + w;
      }
    }
    final bw = maxX - minX + 1, bh = maxY - minY + 1;
    final small = area <= kTextSharpSmallArea;
    final sparse = bw <= kTextSharpBBoxMaxSide &&
        bh <= kTextSharpBBoxMaxSide &&
        area / (bw * bh) <= kTextSharpMaxFill;
    if (!small && !sparse) continue;
    any = true;
    // 域成员回填：判定依赖整域统计（面积/外接框），生长结束后才知道是否
    // 收录，从 seed 沿 dark∧visited 重新生长一遍（连通性即域边界——
    // 其他域虽已 visited 但不与本 seed 连通，生长不会跨界）。
    _floodMark(accepted, dark, visited, w, h, seed);
  }
  if (!any) return null;

  // 两轮 4 邻接膨胀（罩住笔画抗锯齿晕圈），再位打包。
  var grid = accepted;
  for (var pass = 0; pass < 2; pass++) {
    grid = _dilate4(grid, w, h);
  }
  final packed = Uint8List((n + 7) >> 3);
  for (var p = 0; p < n; p++) {
    if (grid[p] != 0) packed[p >> 3] |= 1 << (p & 7);
  }
  return packed;
}

/// 从 [seed] 沿「暗 ∧ 已访问 ∧ 未标」4 邻接生长，把域成员标进 [accepted]。
/// 显式栈避免深递归；栈弹出顺序不影响集合结果。
void _floodMark(
    Uint8List accepted, Uint8List dark, Uint8List visited, int w, int h, int seed) {
  final stack = <int>[seed];
  accepted[seed] = 1;
  while (stack.isNotEmpty) {
    final p = stack.removeLast();
    final px = p % w, py = p ~/ w;
    void tryPush(int q) {
      if (dark[q] != 0 && visited[q] != 0 && accepted[q] == 0) {
        accepted[q] = 1;
        stack.add(q);
      }
    }

    if (px > 0) tryPush(p - 1);
    if (px < w - 1) tryPush(p + 1);
    if (py > 0) tryPush(p - w);
    if (py < h - 1) tryPush(p + w);
  }
}

/// 4 邻接膨胀一轮（读旧写新，整轮同步）。
Uint8List _dilate4(Uint8List src, int w, int h) {
  final out = Uint8List.fromList(src);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      final p = row + x;
      if (src[p] != 0) continue;
      if ((x > 0 && src[p - 1] != 0) ||
          (x < w - 1 && src[p + 1] != 0) ||
          (y > 0 && src[p - w] != 0) ||
          (y < h - 1 && src[p + w] != 0)) {
        out[p] = 1;
      }
    }
  }
  return out;
}

/// 读位打包掩码的第 (x,y) 位（测试/探针用；渲染热路径在 resampler 内联）。
bool textMaskBit(Uint8List mask, int w, int h, int x, int y) {
  if (x < 0 || y < 0 || x >= w || y >= h) return false;
  final p = y * w + x;
  return (mask[p >> 3] & (1 << (p & 7))) != 0;
}
