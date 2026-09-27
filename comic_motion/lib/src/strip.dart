/// 条漫（webtoon）strip 模式（R6）。
///
/// 为什么需要：条漫长图（宽 800 × 高 10000+）直接渲染会被 maxDimension 降
/// 采样毁掉细节，且超边长上限直接抛 `E_TOO_LARGE`；parallax 类效果跨分格
/// 错位。strip 模式把长图按视口比例切成独立片，每片走标准管线独立渲染——
/// 每片自配 configHash、独立 params.json，天然可缓存去重。
///
/// 重叠语义（裁剪式）：相邻两片的重叠像素**同时包含在两片的裁剪窗内**，
/// 片间不做任何混合——每片输出只依赖自己的输入，逐字节确定性成立。阅读器
/// 按片序播放时重叠区自然衔接。
library;

import 'dart:io' as io;
import 'dart:math' as math;

import 'effect_config.dart';
import 'image_io.dart';
import 'image_model.dart';
import 'pipeline.dart';

/// 叠加类安全效果集：逐像素/局部效果，切片间无耦合，跨片独立渲染安全。
/// 白名单外的效果（parallax / breathing / slowPush / mangaShake 等）允许
/// 使用，但 [processStrip] 会在 `warnings` 里提示跨分格错位风险（实验性）。
const Set<EffectKind> kStripSafeEffects = {
  EffectKind.rain,
  EffectKind.snow,
  EffectKind.fog,
  EffectKind.sakura,
  EffectKind.embers,
  EffectKind.fireflies,
  EffectKind.godRays,
  EffectKind.starlight,
  EffectKind.lightning,
  EffectKind.shimmer,
  EffectKind.lightSweep,
  EffectKind.dust,
  EffectKind.bubbles,
  EffectKind.leaves,
  EffectKind.meteors,
  EffectKind.flame,
  EffectKind.smoke,
  EffectKind.vignette,
  EffectKind.toneShift,
};

/// 单个切片的裁剪窗（行区间，左闭右开）。
class StripSlice {
  const StripSlice({
    required this.index,
    required this.yStart,
    required this.yEnd,
  });

  /// 片序号（从 0 起，用于输出命名 `slice000`）。
  final int index;

  /// 源图内起始行（含）。
  final int yStart;

  /// 源图内结束行（不含）。
  final int yEnd;

  int get height => yEnd - yStart;
}

/// 长图切片器：按视口比例（默认 9:16）定片高，片间可选重叠 N px（默认 0，
/// 裁剪语义不做混合）。尾片过短（不足整片 1/3）时并入前一片，避免出现
/// 几像素高的废片。
class StripSplitter {
  const StripSplitter({
    this.viewportWidth = 9,
    this.viewportHeight = 16,
    this.overlapPx = 0,
  });

  /// 视口宽（比例分子）。片高 = round(源宽 × viewportHeight / viewportWidth)。
  final int viewportWidth;

  /// 视口高（比例分母）。
  final int viewportHeight;

  /// 片间重叠像素（>=0）。第 i 片（i>0）起点向前回看 overlapPx 行——相邻
  /// 两片的共享区域恰好 = overlapPx 行（裁剪语义，不做混合）。
  final int overlapPx;

  /// 纯几何规划（不触像素），可单测。
  List<StripSlice> plan(int srcWidth, int srcHeight) {
    if (srcWidth < 1 || srcHeight < 1) {
      throw ArgumentError('source must be at least 1x1, got '
          '${srcWidth}x$srcHeight');
    }
    if (viewportWidth < 1 || viewportHeight < 1) {
      throw ArgumentError('viewport ratio must be >= 1');
    }
    if (overlapPx < 0) {
      throw ArgumentError.value(overlapPx, 'overlapPx', 'must be >= 0');
    }
    final fullSlice =
        math.max(1, (srcWidth * viewportHeight / viewportWidth).round());

    final slices = <StripSlice>[];
    var y = 0;
    var index = 0;
    while (y < srcHeight) {
      var end = math.min(srcHeight, y + fullSlice);
      final remainder = srcHeight - end;
      if (remainder > 0 && remainder < fullSlice / 3) {
        end = srcHeight; // 尾片并入：避免几像素高的废片
      }
      slices.add(StripSlice(index: index++, yStart: y, yEnd: end));
      y = end;
    }

    if (overlapPx > 0) {
      // 只向前回看：第 i 片（i>0）起点前移 overlapPx。相邻两片的共享区域
      // 恰好 = overlapPx 行，尾片 yEnd 不后扩（天然到 srcHeight）。
      for (var i = 1; i < slices.length; i++) {
        final s = slices[i];
        slices[i] = StripSlice(
          index: s.index,
          yStart: math.max(0, s.yStart - overlapPx),
          yEnd: s.yEnd,
        );
      }
    }
    return slices;
  }

  /// 按计划裁出各片（行拷贝，无外部依赖）。
  List<RgbaImage> split(RgbaImage src) => plan(src.width, src.height)
      .map((s) => _cropRows(src, s.yStart, s.yEnd))
      .toList();

  static RgbaImage _cropRows(RgbaImage src, int yStart, int yEnd) {
    final h = yEnd - yStart;
    final out = RgbaImage(width: src.width, height: h);
    final rowBytes = src.width * 4;
    out.data.setRange(0, h * rowBytes, src.data, yStart * rowBytes);
    return out;
  }
}

/// [processStrip] 的单片产物。
class StripSliceResult {
  StripSliceResult({required this.slice, required this.result});

  /// 裁剪窗（含重叠后的实际渲染区间）。
  final StripSlice slice;

  /// 该片的标准管线结果（outputGif / frameDir / paramsFile / configHash…）。
  final PipelineResult result;
}

/// [processStrip] 的汇总结果。
class StripProcessResult {
  StripProcessResult({
    required this.slices,
    required this.warnings,
    required this.width,
    required this.height,
    required this.elapsedMs,
  });

  /// 按片序排列；`slices[i].result.configHash` 独立成立。
  final List<StripSliceResult> slices;

  /// strip 层告警（如白名单外效果的实验性提示）；片级告警在各
  /// [PipelineResult.warnings] 里。
  final List<String> warnings;

  /// 源图尺寸。
  final int width;
  final int height;
  final int elapsedMs;

  /// 各片 GIF 路径（片序）。
  List<String> get gifPaths =>
      slices.map((s) => s.result.outputGif).where((p) => p.isNotEmpty).toList();
}

/// 条漫 strip 模式入口：长图 → 视口比例切片 → 每片走标准管线独立渲染。
///
/// 输出命名：`<stem>_slice<NNN>_<contentHash8>_<configHash8>/anim.gif`——每片
/// 独立目录、独立 configHash 与片级 contentHash（片栅格 RGBA 字节指纹），
/// 同配置同输入逐字节可复现，源图重下载/覆盖后片目录随之改变，天然防串缓存。
///
/// 像素总量上限（第一轮 maxPixels）在切片前由解码强制执行：整话超限抛
/// `ImageTooLargeException`（code `E_TOO_LARGE`）。注意 strip 模式仍需把
/// 整图解码驻留后切片；超大单话可显式调大 [maxPixels]（每片的工作栅格
/// 依旧很小，渲染内存不受整话尺寸影响）。
///
/// [config] 缺省 `EffectConfig()`。[viewportWidth]/[viewportHeight] 为视口
/// 比例（默认 9:16），[overlapPx] 为片间重叠（默认 0，裁剪语义）。
Future<StripProcessResult> processStrip(
  String inputPath,
  String outputDir, {
  EffectConfig? config,
  int? parallel,
  int? memoryBudgetMb,
  int viewportWidth = 9,
  int viewportHeight = 16,
  int overlapPx = 0,
  int? maxPixels,
}) async {
  final sw = Stopwatch()..start();
  final cfg = config ?? EffectConfig();
  final src = ImageIO.decodeFile(inputPath,
      maxPixels: maxPixels ?? ImageIO.defaultMaxPixels);

  final warnings = <String>[];
  final unsafe = cfg.effects
      .where((e) => !kStripSafeEffects.contains(e))
      .toList(growable: false);
  if (unsafe.isNotEmpty) {
    warnings.add(
        'experimental: effects [${unsafe.map((e) => e.name).join(", ")}] are '
        'not in the strip-safe set; parallax-like motion may misalign at '
        'slice boundaries (each slice estimates depth independently)');
  }

  final splitter = StripSplitter(
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
    overlapPx: overlapPx,
  );
  final plan = splitter.plan(src.width, src.height);

  final stem = io.File(inputPath).uri.pathSegments.last;
  final dot = stem.lastIndexOf('.');
  final base = dot > 0 ? stem.substring(0, dot) : stem;

  final pipeline =
      MotionPipeline(cfg, parallel: parallel, memoryBudgetMb: memoryBudgetMb);
  final sliceResults = <StripSliceResult>[];
  for (final slice in plan) {
    final crop = StripSplitter._cropRows(src, slice.yStart, slice.yEnd);
    final result = await pipeline.processImage(
      crop,
      outputDir,
      baseName: '${base}_slice${slice.index.toString().padLeft(3, '0')}',
      inputLabel: '$inputPath#slice${slice.index}',
    );
    sliceResults.add(StripSliceResult(slice: slice, result: result));
  }

  sw.stop();
  return StripProcessResult(
    slices: sliceResults,
    warnings: warnings,
    width: src.width,
    height: src.height,
    elapsedMs: sw.elapsedMilliseconds,
  );
}
