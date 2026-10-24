/// 主体分割与深度钳制（Phase D）：根除「人物骑跨深度带被切开」的割裂感。
///
/// 根因：[LayerSplitter] 按全图深度分位切层，人物（脸/皮肤深、头发衣服浅）
/// 的深度值天然横跨多个分位带 → 同一人物被切进不同层；层间相对位移下
/// 羽化带（几像素）遮不住错位 → 撕裂/重影；相邻层反相摆动进一步放大。
///
/// 修法：外部主体分割器（端侧小模型，见 comic_motion_depth_onnx 包的
/// OnnxSubjectSegmenter）给出主体掩码 → [clampSubjectDepth] 把每个主体
/// 连通域的深度统一为域内中位数 → 主体整体落入单一深度带，随所在层整体
/// 移动，人物不再被层边界切开。
///
/// 与 [PanelMotionJudge] 同级的运行期依赖：不进 EffectConfig、不参与
/// configHash；产物缓存以 [SubjectSegmenter.cacheTag] 后缀隔离（管线侧
/// `subjectDirTag`）。核心包只含抽象与纯函数，模型运行在嵌入方。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'apng_writer.dart' show PixelRect;
import 'depth_splitter.dart' show DepthMap;
import 'image_model.dart';

/// 分割概率阈值：概率图（双线性重采样到目标分辨率后）≥ 此值判主体。
/// 初始工程值 0.5（u2netp sigmoid 输出的自然中点）；最终值由 30 页参考
/// 样本的掩码质量分布勘察定稿（与 scene_motion 的定值纪律一致：只许分布
/// 定值，禁止逐页标注调参）。
const double kSubjectMaskThreshold = 0.5;

/// 最小主体连通域占格面积比：小于此值的碎域按噪声丢弃。
/// 初始工程值（防边角碎块把背景钳错）；分布勘察定稿。
const double kSubjectMinBlobFrac = 0.004;

/// 最小主体连通域绝对面积（目标分辨率像素）：相对下限的地板，小格上
/// minBlobFrac×面积可能过小。初始工程值；分布勘察定稿。
const int kSubjectMinBlobArea = 32;

/// 一个主体连通域（目标分辨率像素坐标）。
class SubjectBlob {
  const SubjectBlob({required this.rect, required this.area});

  /// 外接矩形（含右下边界）。
  final PixelRect rect;

  /// 像素数。
  final int area;
}

/// 主体掩码：阈值化 + 连通域分析后的二值主体域。
class SubjectMask {
  SubjectMask._(this.width, this.height, this._labels, this.blobs);

  final int width;
  final int height;

  /// 0 = 背景，1..blobs.length = 主体域编号（与 [blobs] 下标 +1 对应）。
  final Int32List _labels;

  /// 过滤碎域后的主体域（输入序）。
  final List<SubjectBlob> blobs;

  bool get hasSubjects => blobs.isNotEmpty;

  /// 全空掩码（无主体）：分割器失败降级与「通道关闭」的统一形态。
  factory SubjectMask.empty(int width, int height) => SubjectMask._(
      width, height, Int32List(width * height), const <SubjectBlob>[]);

  /// 主体像素占比（过滤后）。
  double get coverage => blobs.isEmpty
      ? 0.0
      : blobs.fold(0, (s, b) => s + b.area) / (width * height);

  /// 最大单域占比（特写判断特征，Phase E 消费）。
  double get maxBlobFrac =>
      blobs.isEmpty ? 0.0 : blobs.map((b) => b.area).reduce(math.max) / (width * height);

  /// (x, y) 处的主体域编号；越界按最近边界钳位（防御，正常调用不越界）。
  int labelAt(int x, int y) {
    final cx = x.clamp(0, width - 1), cy = y.clamp(0, height - 1);
    return _labels[cy * width + cx];
  }

  /// 概率图 → 掩码：双线性采样 [prob] 到 `width×height`，阈值化，4 邻接
  /// 连通域，碎域过滤 + 重编号（1..m 连续）。[prob] 与目标分辨率可不同
  /// （模型输出多为固定 320×320，目标是格/页工作分辨率）。纯函数。
  factory SubjectMask.fromProbability({
    required List<double> prob,
    required int probWidth,
    required int probHeight,
    required int width,
    required int height,
    double threshold = kSubjectMaskThreshold,
    double minBlobFrac = kSubjectMinBlobFrac,
    int minBlobArea = kSubjectMinBlobArea,
  }) {
    final n = width * height;
    final labels = Int32List(n);
    if (n == 0 ||
        probWidth <= 0 ||
        probHeight <= 0 ||
        prob.length < probWidth * probHeight) {
      return SubjectMask._(width, height, labels, const <SubjectBlob>[]);
    }

    // 双线性阈值化（像素中心约定，边界钳位；与 DepthMap.sampleBilinear
    // 同款几何，作用在标量概率场上）。
    final bin = Uint8List(n);
    final sx = probWidth / width, sy = probHeight / height;
    for (var y = 0; y < height; y++) {
      final fy = ((y + 0.5) * sy - 0.5).clamp(0.0, probHeight - 1.0);
      final y0 = fy.floor(), y1 = math.min(y0 + 1, probHeight - 1);
      final ty = fy - y0;
      for (var x = 0; x < width; x++) {
        final fx = ((x + 0.5) * sx - 0.5).clamp(0.0, probWidth - 1.0);
        final x0 = fx.floor(), x1 = math.min(x0 + 1, probWidth - 1);
        final tx = fx - x0;
        final p = (prob[y0 * probWidth + x0] * (1 - tx) +
                    prob[y0 * probWidth + x1] * tx) *
                (1 - ty) +
            (prob[y1 * probWidth + x0] * (1 - tx) +
                    prob[y1 * probWidth + x1] * tx) *
                ty;
        if (p >= threshold) bin[y * width + x] = 1;
      }
    }

    // 4 邻接连通域（栈式洪泛，与 scene_motion 文字斑点同款遍历）。
    final visited = Uint8List(n);
    final stack = <int>[];
    final rects = <PixelRect>[];
    final areas = <int>[];
    var next = 0;
    for (var i = 0; i < n; i++) {
      if (bin[i] == 0 || visited[i] != 0) continue;
      next++;
      var minX = width, minY = height, maxX = -1, maxY = -1;
      var area = 0;
      stack.add(i);
      visited[i] = 1;
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        labels[p] = next;
        area++;
        final px = p % width, py = p ~/ width;
        if (px < minX) minX = px;
        if (px > maxX) maxX = px;
        if (py < minY) minY = py;
        if (py > maxY) maxY = py;
        if (px > 0 && bin[p - 1] != 0 && visited[p - 1] == 0) {
          visited[p - 1] = 1;
          stack.add(p - 1);
        }
        if (px < width - 1 && bin[p + 1] != 0 && visited[p + 1] == 0) {
          visited[p + 1] = 1;
          stack.add(p + 1);
        }
        if (py > 0 && bin[p - width] != 0 && visited[p - width] == 0) {
          visited[p - width] = 1;
          stack.add(p - width);
        }
        if (py < height - 1 && bin[p + width] != 0 && visited[p + width] == 0) {
          visited[p + width] = 1;
          stack.add(p + width);
        }
      }
      rects.add(PixelRect(minX, minY, maxX - minX + 1, maxY - minY + 1));
      areas.add(area);
    }

    // 碎域过滤 + 重编号（保留域重编为 1..m，保证与 blobs 下标 +1 对应、
    // 钳制的桶下标连续）。
    final minArea = math.max(minBlobArea, (minBlobFrac * n).ceil());
    final keep = Uint8List(areas.length + 1);
    for (var b = 0; b < areas.length; b++) {
      if (areas[b] >= minArea) keep[b + 1] = 1;
    }
    final oldToNew = Int32List(areas.length + 1);
    final blobs = <SubjectBlob>[];
    for (var b = 1; b <= areas.length; b++) {
      if (keep[b] == 0) continue;
      oldToNew[b] = blobs.length + 1;
      blobs.add(SubjectBlob(rect: rects[b - 1], area: areas[b - 1]));
    }
    if (blobs.isEmpty) return SubjectMask._(width, height, Int32List(n), blobs);
    for (var i = 0; i < n; i++) {
      final l = labels[i];
      if (l > 0) labels[i] = oldToNew[l];
    }
    return SubjectMask._(width, height, labels, blobs);
  }
}

/// 主体分割接缝（运行期依赖，不进 EffectConfig、不参与 configHash）。
///
/// 契约：[segment] 必须是纯函数（同输入同输出）且**永不抛**——失败（模型
/// 缺失/形状不符等）返回空 [SubjectMask]（`hasSubjects == false`），管线
/// 回落到不钳制的既有行为，不中断渲染。深度估算器（[DepthEstimator]）
/// 允许抛是因为它是主通路；分割器是增强通路，降级优于失败。
abstract class SubjectSegmenter {
  const SubjectSegmenter();

  /// [panel] 为该格（或整页）工作分辨率子图；返回同视野的主体掩码。
  SubjectMask segment(RgbaImage panel);

  /// 缓存隔离标签：标识「哪个模型哪个版本」，进入产物目录名（管线侧做
  /// 文件系统安全清洗后以 `_s_<tag>` 后缀拼接）。换了分割器（或其模型
  /// 版本）必须换标签，否则嵌入方「目录存在即跳过」的缓存会命中旧画面。
  String get cacheTag;
}

/// 把每个主体连通域的深度值统一为域内中位数（偶数个采样取下中位，最近
/// 秩口径），返回逐 blob 中位数表（与 [mask.blobs] 对齐；blob 在深度图上
/// 无采样 → 对位 null）。
///
/// **不再晋升 [DepthMap.constantValued]**（D5 修订）：整场恒值化会把背景
/// 带边界一并硬化（跳羽化 → 接缝感，目检反馈）。主体完整性改由
/// [LayerSplitter] 的主体带覆盖实现——split 接收掩码 + 本表，主体像素的
/// membership 直接覆盖为其 blob 中位数所在带，绕过软/硬隶属函数；分位
/// 阈值即使落在主体平台上也不再撕开主体。深度图内的中位数回写仍保留：
/// 分位阈值、MotionGate 深度跨度与 depthSpreadScale 继续按「主体一个值」
/// 的口径计算。
///
/// 深度图与掩码分辨率独立（估算器内部可降采样，如 ONNX 固定 320×320）：
/// 深度像素按最近邻映射到掩码坐标。纯函数：同输入同输出，原地修改
/// [depth]；掩码无主体（或主体域在深度图上无采样）时零修改、返回全 null。
List<double?> clampSubjectDepth(DepthMap depth, SubjectMask mask) {
  final medians = List<double?>.filled(mask.blobs.length, null);
  if (!mask.hasSubjects) return medians;
  final dw = depth.width, dh = depth.height;

  // 深度像素 → 掩码最近邻映射，按域分桶收值。
  final buckets = List.generate(mask.blobs.length + 1, (_) => <double>[]);
  final sx = mask.width / dw, sy = mask.height / dh;
  for (var y = 0; y < dh; y++) {
    final my = ((y + 0.5) * sy - 0.5).clamp(0.0, mask.height - 1.0).round();
    for (var x = 0; x < dw; x++) {
      final mx = ((x + 0.5) * sx - 0.5).clamp(0.0, mask.width - 1.0).round();
      final label = mask.labelAt(mx, my);
      if (label > 0) buckets[label].add(depth.data[y * dw + x]);
    }
  }

  // 域中位数（下中位）。
  for (var b = 1; b <= mask.blobs.length; b++) {
    final v = buckets[b];
    if (v.isEmpty) continue;
    v.sort();
    medians[b - 1] = v[(v.length - 1) ~/ 2];
  }

  // 回写（单次遍历）：blob 编号与 blobs 下标 +1 对齐。
  for (var y = 0; y < dh; y++) {
    final my = ((y + 0.5) * sy - 0.5).clamp(0.0, mask.height - 1.0).round();
    for (var x = 0; x < dw; x++) {
      final mx = ((x + 0.5) * sx - 0.5).clamp(0.0, mask.width - 1.0).round();
      final label = mask.labelAt(mx, my);
      if (label > 0) {
        final m = medians[label - 1];
        if (m != null) depth.data[y * dw + x] = m;
      }
    }
  }
  return medians;
}

/// 底图主体带补绘（D6，消双边缘）：把主体剪影边界向内 [bandPx] 深的条带
/// 用「从剪影外侧逐轮传播进来的背景色」替换，返回**新** [RgbaImage]（不
/// 改输入；无主体或 bandPx≤0 时原样返回调用方传入的实例引用之外的新副本
/// 亦不必要——直接返回 [base] 本体）。
///
/// 为什么修底图：主体层被覆盖为单一 membership 带后，其它带在主体处是
/// 透明洞——主体层位移时让出的条带露出的是**未位移的底图原图**（主体
/// 原位的幽灵像 = 目检报告的双边缘；standard 档 snapWave 有直流偏置，
/// 该露出连 t=0 静息帧也存在）。补绘后露出的条带显示延续的背景。
///
/// 算法：逐轮同步 BFS（与 LayerSplitter._stretchEdges 同款整轮推进
/// 语义，与扫描顺序无关）——第 r 轮把「距剪影边界 r」的未填充像素填成
/// 4 邻接中上一轮已就绪像素的颜色；恰好 [bandPx] 轮后，深度超过 bandPx
/// 的剪影内部保持原像素。确定性：邻居取色按左、上、右、下固定次序取
/// 第一个就绪者。[masks[i]] 与 [rects[i]] 对应（rect = 掩码在画布上的
/// 原点矩形；掩码分辨率可与 rect 不同，最近邻映射）。
RgbaImage inpaintSubjectBands(
    RgbaImage base, List<SubjectMask> masks, List<PixelRect> rects, int bandPx) {
  if (bandPx <= 0 || masks.isEmpty) return base;
  final w = base.width, h = base.height;

  // 画布坐标 label 栅格（0 = 非主体）。
  final labels = Int32List(w * h);
  var any = false;
  for (var m = 0; m < masks.length && m < rects.length; m++) {
    final mask = masks[m], rect = rects[m];
    if (!mask.hasSubjects) continue;
    for (var y = 0; y < rect.height && rect.y + y < h; y++) {
      final my = ((y + 0.5) * mask.height / rect.height - 0.5)
          .clamp(0.0, mask.height - 1.0)
          .round();
      for (var x = 0; x < rect.width && rect.x + x < w; x++) {
        final mx = ((x + 0.5) * mask.width / rect.width - 0.5)
            .clamp(0.0, mask.width - 1.0)
            .round();
        final label = mask.labelAt(mx, my);
        if (label > 0) {
          labels[(rect.y + y) * w + rect.x + x] = label;
          any = true;
        }
      }
    }
  }
  if (!any) return base;

  final out = RgbaImage(width: w, height: h);
  out.data.setAll(0, base.data);
  // state：0 = 剪影内未填充；1 = 可作取色源（剪影外，或此前轮次已填充）；
  // 2 = 本轮刚填充（同轮不可作源，保证 BFS 分层与扫描顺序无关）。
  final state = Uint8List(w * h);
  var frontier = <int>[];
  for (var i = 0; i < w * h; i++) {
    if (labels[i] == 0) {
      state[i] = 1;
    } else {
      final x = i % w, y = i ~/ w;
      final outside = (x > 0 && labels[i - 1] == 0) ||
          (x < w - 1 && labels[i + 1] == 0) ||
          (y > 0 && labels[i - w] == 0) ||
          (y < h - 1 && labels[i + w] == 0);
      if (outside) frontier.add(i);
    }
  }
  for (var round = 0; round < bandPx && frontier.isNotEmpty; round++) {
    final next = <int>[];
    for (final p in frontier) {
      final x = p % w, y = p ~/ w;
      int? src;
      // 固定次序取第一个上一轮就绪的邻居（确定性）。
      if (x > 0 && state[p - 1] == 1) {
        src = p - 1;
      } else if (y > 0 && state[p - w] == 1) {
        src = p - w;
      } else if (x < w - 1 && state[p + 1] == 1) {
        src = p + 1;
      } else if (y < h - 1 && state[p + w] == 1) {
        src = p + w;
      }
      if (src == null) {
        next.add(p); // 留待后续轮次
        continue;
      }
      final o = p * 4, so = src * 4;
      out.data[o] = out.data[so];
      out.data[o + 1] = out.data[so + 1];
      out.data[o + 2] = out.data[so + 2];
      out.data[o + 3] = out.data[so + 3];
      state[p] = 2;
      // 剪影内的未填充邻居进入下一轮。
      if (x > 0 && labels[p - 1] != 0 && state[p - 1] == 0) next.add(p - 1);
      if (y > 0 && labels[p - w] != 0 && state[p - w] == 0) next.add(p - w);
      if (x < w - 1 && labels[p + 1] != 0 && state[p + 1] == 0) next.add(p + 1);
      if (y < h - 1 && labels[p + w] != 0 && state[p + w] == 0) next.add(p + w);
    }
    // 本轮填充晋升为可取色源；去重（同一像素可能被多个邻居加入）。
    for (var i = 0; i < w * h; i++) {
      if (state[i] == 2) state[i] = 1;
    }
    frontier = next.toSet().toList();
  }
  return out;
}
