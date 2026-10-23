import 'dart:typed_data';

import 'depth_splitter.dart';
import 'image_model.dart';

/// 区域一致深度包装：把任意 [DepthEstimator] 的平滑深度场量化为
/// 「同色连通区域一个值、墨线连通域一个值」，避免 3 层量化把平涂区与
/// 线稿切开（文字/气泡重影）。
///
/// 纯 Dart、零原生依赖：模型可以跑在嵌入方，本包装在引擎内做后处理。
/// 输出保持 inner 的数值尺度，不做归一化（区域均值是仿射不变的）。
///
/// 处理顺序：
/// 1. inner 深度双线性放大到图片分辨率；
/// 2. `colorBits` 量化颜色，8 邻域同色连通域取深度均值；
/// 3. 墨线（亮度 < [inkThreshold]）逐连通域取最近非墨像素的深度均值；
/// 4. [detailMinArea] > 0 时，小区域改取最近的「大区域」深度——大区域
///    包含大面积墨块（气泡/文本框）与其中的小字（浅色字、网点细节），
///    使字随所在色块运动，而不是自带一套深度或穿墙吸到页面背景。
class RegionCoherentDepthEstimator implements DepthEstimator {
  const RegionCoherentDepthEstimator({
    this.inner = const HeuristicDepthEstimator(),
    this.colorBits = 5,
    this.inkThreshold = 100,
    this.detailMinArea = 64,
  })  : assert(colorBits >= 1 && colorBits <= 8),
        assert(inkThreshold >= 0 && inkThreshold <= 255),
        assert(detailMinArea >= 0);

  final DepthEstimator inner;

  /// 每通道保留位数（5 ⇒ 32768 个颜色桶，够区分平涂色块又不会被压缩噪声拆碎）。
  final int colorBits;

  /// 墨线阈值：BT.601 亮度低于该值的像素先不参与区域统计，最后按连通域回填。
  final int inkThreshold;

  /// 面积小于该值（图片像素）的同色区域继承最近的大区域深度；0 = 关闭。
  final int detailMinArea;

  @override
  DepthMap estimate(RgbaImage img) {
    final w = img.width, h = img.height, n = w * h;

    final src = inner.estimate(img);
    final depth = Float64List(n);
    final sx = src.width / w, sy = src.height / h;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        depth[y * w + x] =
            src.sampleBilinear((x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5);
      }
    }

    final shift = 8 - colorBits;
    final packed = Int32List(n);
    final ink = Uint8List(n);
    var hasInk = false, hasFlat = false;
    for (var i = 0; i < n; i++) {
      final r = img.data[i * 4] >> shift;
      final g = img.data[i * 4 + 1] >> shift;
      final b = img.data[i * 4 + 2] >> shift;
      packed[i] = (r << (2 * colorBits)) | (g << colorBits) | b;
      if (img.luminance(i) < inkThreshold) {
        ink[i] = 1;
        hasInk = true;
      } else {
        hasFlat = true;
      }
    }
    if (!hasFlat) return _copy(src, w, h)..constantValued = true;

    // 同色 8 邻域连通域（每像素只查左/左上/上/右上四个已访问邻居）。
    final parent = Int32List(n);
    final size = Int32List(n);
    for (var i = 0; i < n; i++) {
      if (ink[i] == 0) {
        parent[i] = i;
        size[i] = 1;
      } else {
        parent[i] = -1;
      }
    }
    void join(int a, int b) {
      if (ink[b] != 0 || packed[b] != packed[a]) return;
      var ra = _find(parent, a), rb = _find(parent, b);
      if (ra == rb) return;
      if (size[ra] < size[rb]) {
        final t = ra;
        ra = rb;
        rb = t;
      }
      parent[rb] = ra;
      size[ra] += size[rb];
    }

    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        final i = row + x;
        if (ink[i] != 0) continue;
        if (x > 0) join(i, i - 1);
        if (y > 0) {
          join(i, i - w);
          if (x > 0) join(i, i - w - 1);
          if (x + 1 < w) join(i, i - w + 1);
        }
      }
    }

    // 区域均值；compSum 原地变成均值表（仅根下标有效）。
    final compArea = Int32List(n);
    final compSum = Float64List(n);
    for (var i = 0; i < n; i++) {
      if (ink[i] != 0) continue;
      final r = _find(parent, i);
      parent[i] = r;
      compArea[r]++;
      compSum[r] += depth[i];
    }
    for (var r = 0; r < n; r++) {
      if (compArea[r] > 0) compSum[r] /= compArea[r];
    }

    final out = Float64List.fromList(depth);
    for (var i = 0; i < n; i++) {
      if (ink[i] == 0) out[i] = compSum[parent[i]];
    }

    final snapSeeds = detailMinArea > 0 ? Uint8List(n) : null;

    if (hasInk) {
      final seeds = Uint8List(n);
      for (var i = 0; i < n; i++) {
        if (ink[i] == 0) seeds[i] = 1;
      }
      final owner = _nearestSeeds(seeds, w, h);
      final visited = Uint8List(n);
      final queue = Int32List(n);
      for (var start = 0; start < n; start++) {
        if (ink[start] == 0 || visited[start] != 0) continue;
        var head = 0, tail = 0;
        queue[tail++] = start;
        visited[start] = 1;
        var sum = 0.0;
        while (head < tail) {
          final p = queue[head++];
          final o = owner[p];
          sum += o >= 0 ? compSum[parent[o]] : depth[p];
          final x = p % w;
          for (var dy = -1; dy <= 1; dy++) {
            final ny = p ~/ w + dy;
            if (ny < 0 || ny >= h) continue;
            for (var dx = -1; dx <= 1; dx++) {
              if (dx == 0 && dy == 0) continue;
              final nx = x + dx;
              if (nx < 0 || nx >= w) continue;
              final q = ny * w + nx;
              if (ink[q] != 0 && visited[q] == 0) {
                visited[q] = 1;
                queue[tail++] = q;
              }
            }
          }
        }
        final mean = sum / tail;
        for (var k = 0; k < tail; k++) {
          out[queue[k]] = mean;
        }
        // 大块墨（气泡/文本框内部）也是小字的吸附种子。
        if (snapSeeds != null && tail >= detailMinArea) {
          for (var k = 0; k < tail; k++) {
            snapSeeds[queue[k]] = 1;
          }
        }
        // 遍历末段 `start` 已扫描过的像素不会重复入队（visited 封锁）。
      }
    }

    if (snapSeeds != null) {
      for (var i = 0; i < n; i++) {
        if (ink[i] == 0 && compArea[parent[i]] >= detailMinArea) snapSeeds[i] = 1;
      }
      final owner = _nearestSeeds(snapSeeds, w, h);
      final smallSum = Float64List(n);
      final smallCount = Int32List(n);
      for (var i = 0; i < n; i++) {
        if (ink[i] != 0) continue;
        final r = parent[i];
        if (compArea[r] >= detailMinArea) continue;
        final o = owner[i];
        if (o < 0) continue;
        smallSum[r] += out[o];
        smallCount[r]++;
      }
      for (var i = 0; i < n; i++) {
        if (ink[i] != 0) continue;
        final r = parent[i];
        if (compArea[r] >= detailMinArea || smallCount[r] == 0) continue;
        out[i] = smallSum[r] / smallCount[r];
      }
    }

    return _fromValues(out, w, h)..constantValued = true;
  }

  /// 多源 BFS：每个像素记录最近种子像素下标（-1 = 无种子）。
  static Int32List _nearestSeeds(Uint8List seeds, int w, int h) {
    final n = w * h;
    final owner = Int32List(n)..fillRange(0, n, -1);
    final queue = Int32List(n);
    var head = 0, tail = 0;
    for (var i = 0; i < n; i++) {
      if (seeds[i] != 0) {
        owner[i] = i;
        queue[tail++] = i;
      }
    }
    while (head < tail) {
      final p = queue[head++];
      final o = owner[p];
      final x = p % w;
      if (x > 0 && owner[p - 1] < 0) {
        owner[p - 1] = o;
        queue[tail++] = p - 1;
      }
      if (x + 1 < w && owner[p + 1] < 0) {
        owner[p + 1] = o;
        queue[tail++] = p + 1;
      }
      if (p >= w && owner[p - w] < 0) {
        owner[p - w] = o;
        queue[tail++] = p - w;
      }
      if (p + w < n && owner[p + w] < 0) {
        owner[p + w] = o;
        queue[tail++] = p + w;
      }
    }
    return owner;
  }

  static int _find(Int32List parent, int i) {
    var root = i;
    while (parent[root] != root) {
      root = parent[root];
    }
    while (parent[i] != root) {
      final next = parent[i];
      parent[i] = root;
      i = next;
    }
    return root;
  }

  static DepthMap _fromValues(Float64List values, int w, int h) {
    final dm = DepthMap(w, h);
    dm.data.setAll(0, values);
    return dm;
  }

  static DepthMap _copy(DepthMap src, int w, int h) {
    final dm = DepthMap(w, h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        dm.data[y * w + x] =
            src.sampleBilinear((x + 0.5) * src.width / w - 0.5,
                (y + 0.5) * src.height / h - 0.5);
      }
    }
    return dm;
  }
}
