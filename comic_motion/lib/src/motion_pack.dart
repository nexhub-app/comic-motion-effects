/// MotionPack v1（重构方案 M2，`motion_redesign_plan_20261025.md` §2）——
/// 分析一次、产出 pack、处处同播。
///
/// pack 是**唯一中心产物**：分析层结论（格/特征/策略/诊断）+ 渲染原料
/// （层纹理/主体掩码/深度）+ 逐格运动程序（镜头/焦点）打包落盘，阅读器
/// 端与导出端消费同一份数据——分析质量与渲染形态解耦，跨端不一致
/// （调研 G1 缺陷）在 pack 环节消失。
///
/// 确定性契约：同输入 + 同模型 tier → 逐字节一致（无时间戳字段；PNG 为
/// 无时间戳确定编码；JSON 固定键序）。`packHash` = FNV-1a 64 over 文件
/// 清单（路径 + 内容字节，路径序），是 pack 的身份（目录命名
/// `<stem>_<packHash12>/`）；`pack.json` 自身不入清单（其内容含 packHash）。
///
/// 落盘结构：
/// ```
/// pack.json      kind=motion_pack, version=1, packHash, configHash, domain,
///                modelTier, sourceDigest（不含 createdAt——确定性红线）
/// depth.png      16bit 灰度，工作分辨率 1/2（未来 mesh/连续视差原料）
/// layers/        layer_NN.png（layer_export 格式扩展）+ index.json（含格 clip）
/// masks.png      8bit 主体标签图（0=背景；页级唯一 id，格序×域序）
/// panels.json    [{rect, cls, clsConf, features{...}, strategy{...}}]
/// program.json   {version, programs: [逐格 MotionProgram]}（§3 镜头程序）
/// parts/         part_NN.json（part_motion 侧车同 schema，部件目录化）
/// ```
///
/// 镜头消费（§7.2）：导出/预览路径经 [renderPackStill]（与渲染主干同源
/// 的合成 + `render/camera.dart` 镜头 pass）；GIF 主线冻结不接镜头。
/// t=0 静息帧逐字节 == 无镜头渲染（首帧对拍契约，测试锁定）。
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'apng_writer.dart' show PixelRect;
import 'depth_splitter.dart' show HeuristicDepthEstimator;
import 'image_io.dart';
import 'image_model.dart';
import 'motion_program.dart';
import 'part_motion.dart';
import 'pipeline.dart';
import 'scene_motion.dart';

/// pack 格式版本（加性演进纪律：只增字段不破契约）。
const int kMotionPackVersion = 1;

/// FNV-1a 64（与 `ImageIO.contentHash8` 同族，输出 16 hex）。
String _fnv1a64(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final b in bytes) {
    hash ^= b & 0xff;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  final sb = StringBuffer();
  for (var shift = 60; shift >= 0; shift -= 4) {
    sb.write(((hash >> shift) & 0xf).toRadixString(16));
  }
  return sb.toString();
}

/// 模型分级（M4）：pack 声明本次分析实际生效的模型档位——降级**可见**，
/// 不再 existsSync 静默吞。tier 语义见 `docs/model_distribution_v1.md`。
class ModelTierInfo {
  const ModelTierInfo(this.tier, this.components);

  final int tier;
  final List<String> components;

  String get label => switch (tier) {
        3 => 'semantic',
        2 => 'depth',
        1 => 'subject',
        _ => 'geometry',
      };

  Map<String, dynamic> toJson() =>
      {'tier': tier, 'label': label, 'components': components};
}

/// pack 生产结果。
class MotionPackResult {
  MotionPackResult({
    required this.packHash,
    required this.packJson,
    required this.width,
    required this.height,
    required this.panels,
    required this.programs,
    required this.files,
    this.dir = '',
  });

  /// pack 身份（FNV-1a 64 over 文件清单，16 hex；pack.json 自身除外）。
  final String packHash;

  /// pack.json 文本（含 packHash）。
  final String packJson;

  /// 工作分辨率。
  final int width;
  final int height;

  /// 逐格矩形（工作分辨率画布坐标）与程序（对齐）。
  final List<PixelRect> panels;
  final List<MotionProgram> programs;

  /// 文件清单（路径 → 字节；不含 pack.json）。磁盘模式下同时已落盘。
  final Map<String, List<int>> files;

  /// 落盘目录（内存模式为空串）。
  final String dir;

  Map<String, dynamic> toJson() => {
        'packHash': packHash,
        'width': width,
        'height': height,
        'panelCount': panels.length,
        'dir': dir,
        'files': files.keys.toList(),
      };
}

/// pack 导出（`MotionPipeline` 扩展）。
extension MotionPackExport on MotionPipeline {
  /// 内存入口：分析 [src] 并组装 pack（不落盘）。
  MotionPackResult exportMotionPack(RgbaImage src, {String domain = 'generic'}) =>
      _buildPack(this, src,
          domain: domain, inputStem: 'image', sourceDigest: '', outputDir: null);

  /// 文件入口：落盘 `<outputDir>/<stem>_<packHash12>/` 并返回内存结果。
  MotionPackResult exportMotionPackFile(
      String inputPath, String outputDir,
      {String domain = 'generic'}) {
    final bytes = ImageIO.readFileBytes(inputPath);
    final src = ImageIO.decode(bytes);
    final stem = io.File(inputPath).uri.pathSegments.last;
    final dot = stem.lastIndexOf('.');
    final baseName = dot > 0 ? stem.substring(0, dot) : stem;
    return _buildPack(this, src,
        domain: domain,
        inputStem: baseName,
        sourceDigest: ImageIO.contentHash8(bytes),
        outputDir: outputDir);
  }
}

/// 逐格程序构建（pack 组装与 `MotionPipeline.renderPackStillFrame` 共用）：
/// 类别/锚点/特征来自诊断，layers 值取**已裁决**策略（scene 侧车优先级
/// 与渲染一致）。
MotionProgram buildPackProgramForPanel(
    PackAnalysis analysis, MotionProgramTable table, int i) {
  final d = analysis.diagnoses[i];
  final base = table.build(
      d: d,
      panel: analysis.panels[i],
      mask: i < analysis.subjects.length ? analysis.subjects[i] : null);
  final st = i < analysis.strategies.length
      ? analysis.strategies[i]
      : PanelMotionStrategy.neutral;
  return MotionProgram(
    camera: base.camera,
    scale: st.scale,
    tempo: st.tempo,
    subjectBoost: st.subjectBoost,
    effects: base.effects,
    focus: base.focus,
  );
}

/// 全页程序表（序与 panels 对齐）。
List<MotionProgram> buildPackPrograms(PackAnalysis analysis) {
  const table = MotionProgramTable();
  return [
    for (var i = 0; i < analysis.panels.length; i++)
      buildPackProgramForPanel(analysis, table, i),
  ];
}

MotionPackResult _buildPack(
    MotionPipeline pipeline, RgbaImage src,
    {required String domain,
    required String inputStem,
    required String sourceDigest,
    required String? outputDir}) {
  final analysis = pipeline.analyzeForPack(src);
  final programs = buildPackPrograms(analysis);
  final working = analysis.working;
  final cfg = pipeline.config;

  final files = <String, List<int>>{};

  // ---- layers/（layer_export 格式扩展：layer_NN.png + index.json）----
  for (var i = 0; i < analysis.layers.length; i++) {
    final l = analysis.layers[i];
    files['layers/layer_${i.toString().padLeft(2, '0')}.png'] =
        Uint8List.fromList(ImageIO.encodePngFrameRgba(l.image));
  }
  files['layers/index.json'] = utf8.encode(const JsonEncoder.withIndent('  ')
      .convert(<String, dynamic>{
    'kind': 'layers',
    'width': working.width,
    'height': working.height,
    'configHash': cfg.configHash,
    'layerCount': cfg.layerCount,
    'panelAware': cfg.panelAware,
    'layers': [
      for (var i = 0; i < analysis.layers.length; i++)
        <String, dynamic>{
          'file': 'layer_${i.toString().padLeft(2, '0')}.png',
          'rank': analysis.layers[i].depthRank,
          if (analysis.layers[i].clip != null)
            'clip': {
              'x': analysis.layers[i].clip!.x,
              'y': analysis.layers[i].clip!.y,
              'w': analysis.layers[i].clip!.width,
              'h': analysis.layers[i].clip!.height,
            },
        },
    ],
  }));

  // ---- depth.png（16bit 灰度，工作分辨率 1/2）----
  files['depth.png'] = _encodeDepth16(analysis);

  // ---- masks.png（8bit 标签图，页级唯一 id）----
  files['masks.png'] = _encodeMasks8(analysis);

  // ---- panels.json / program.json ----
  files['panels.json'] = utf8.encode(const JsonEncoder.withIndent('  ')
      .convert(<String, dynamic>{
    'version': kMotionPackVersion,
    'panels': [
      for (var i = 0; i < analysis.panels.length; i++)
        _panelJson(analysis, i),
    ],
  }));
  files['program.json'] = utf8.encode(const JsonEncoder.withIndent('  ')
      .convert(<String, dynamic>{
    'kind': 'motion_program',
    'version': kMotionPackVersion,
    'programs': [for (final p in programs) p.toJson()],
  }));

  // ---- parts/（部件目录化；part_motion 侧车同 schema）----
  final parts = pipeline.effectiveParts;
  for (var i = 0; i < parts.length; i++) {
    files['parts/part_${i.toString().padLeft(2, '0')}.json'] =
        utf8.encode(const JsonEncoder.withIndent('  ')
            .convert(_partJson(parts[i])));
  }

  // ---- packHash（清单序 = 路径字典序）----
  final paths = files.keys.toList()..sort();
  final hash = _fnv1a64([
    for (final p in paths) ...[
      ...utf8.encode(p),
      0x00,
      ..._u64be(files[p]!.length),
      ...files[p]!,
    ],
  ]);
  final packHash = hash;

  final tier = _modelTier(pipeline);
  final pack = <String, dynamic>{
    'kind': 'motion_pack',
    'version': kMotionPackVersion,
    'packHash': packHash,
    'configHash': cfg.configHash,
    if (sourceDigest.isNotEmpty) 'sourceDigest': sourceDigest,
    'domain': domain,
    'modelTier': tier.toJson(),
    'width': working.width,
    'height': working.height,
    'panelCount': analysis.panels.length,
    'files': [
      for (final p in paths) {'path': p, 'bytes': files[p]!.length},
    ],
  };
  final packJson = const JsonEncoder.withIndent('  ').convert(pack);
  final packJsonBytes = utf8.encode(packJson);

  var dir = '';
  if (outputDir != null) {
    dir = '$outputDir/${inputStem}_${packHash.substring(0, 12)}';
    io.Directory(dir).createSync(recursive: true);
    for (final p in paths) {
      io.File('$dir/$p')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(files[p]!);
    }
    io.File('$dir/pack.json').writeAsBytesSync(packJsonBytes);
  }

  return MotionPackResult(
    packHash: packHash,
    packJson: packJson,
    width: working.width,
    height: working.height,
    panels: analysis.panels,
    programs: programs,
    files: files,
    dir: dir,
  );
}

Map<String, dynamic> _panelJson(PackAnalysis analysis, int i) {
  final d = analysis.diagnoses[i];
  final st = i < analysis.strategies.length
      ? analysis.strategies[i]
      : PanelMotionStrategy.neutral;
  final f = d.features;
  final rect = analysis.panels[i];
  return {
    'rect': {'x': rect.x, 'y': rect.y, 'w': rect.width, 'h': rect.height},
    'cls': d.cls.name,
    'clsConf': double.parse(d.clsConf.toStringAsFixed(4)),
    'features': {
      'speckDensity': double.parse(f.speckDensity.toStringAsFixed(4)),
      'whiteFrac': double.parse(f.whiteFrac.toStringAsFixed(4)),
      'dirCoherence': double.parse(f.dirCoherence.toStringAsFixed(4)),
      'edgeFrac': double.parse(f.edgeFrac.toStringAsFixed(4)),
      'dotPeriodicity': double.parse(f.dotPeriodicity.toStringAsFixed(4)),
      'speckUniformity': double.parse(f.speckUniformity.toStringAsFixed(4)),
      'convergenceCoh': double.parse(f.convergenceCoh.toStringAsFixed(4)),
      'vpX': double.parse(f.vpX.toStringAsFixed(4)),
      'vpY': double.parse(f.vpY.toStringAsFixed(4)),
    },
    'strategy': {
      'scale': st.scale,
      'tempo': st.tempo,
      'subjectBoost': st.subjectBoost,
    },
  };
}

Map<String, dynamic> _partJson(PartMotion p) => {
      'kind': p.kind.name,
      'polygon': [
        for (final pt in p.polygon) [pt.x, pt.y],
      ],
      'anchor': {'x': p.anchorX, 'y': p.anchorY, if (p.joint.isNotEmpty)
          'joint': p.joint},
      if (p.inpaintPath != null) 'inpaint': p.inpaintPath,
    };

/// 深度 16bit PNG：半工作分辨率。多格页按格归属采样（格间白缝置 0=最远）。
Uint8List _encodeDepth16(PackAnalysis analysis) {
  final working = analysis.working;
  final dw = (working.width / 2).round().clamp(1, working.width);
  final dh = (working.height / 2).round().clamp(1, working.height);
  final pixels = Uint16List(dw * dh);
  for (var y = 0; y < dh; y++) {
    for (var x = 0; x < dw; x++) {
      final fx = x * 2, fy = y * 2; // 全分辨率对应像素
      final v = _depthAt(analysis, fx, fy);
      pixels[y * dw + x] = (v * 65535.0).round().clamp(0, 65535);
    }
  }
  final image = img.Image.fromBytes(
    width: dw,
    height: dh,
    bytes: pixels.buffer,
    format: img.Format.uint16,
    numChannels: 1,
  );
  return Uint8List.fromList(img.encodePng(image));
}

double _depthAt(PackAnalysis analysis, int fx, int fy) {
  for (var i = 0; i < analysis.panels.length && i < analysis.depths.length;
      i++) {
    final r = analysis.panels[i];
    if (fx < r.x || fy < r.y || fx >= r.x + r.width || fy >= r.y + r.height) {
      continue;
    }
    final dm = analysis.depths[i];
    final u = (fx - r.x + 0.5) * dm.width / r.width - 0.5;
    final v = (fy - r.y + 0.5) * dm.height / r.height - 0.5;
    return dm.sampleBilinear(u, v);
  }
  return 0.0; // 格间白缝：最远。
}

/// 主体标签 8bit PNG（R 通道 = 标签）：0=背景，1..n 页级唯一（格序×域序）。
Uint8List _encodeMasks8(PackAnalysis analysis) {
  final working = analysis.working;
  final labels = Uint8List(working.pixelCount);
  var next = 0;
  for (var i = 0;
      i < analysis.panels.length && i < analysis.subjects.length;
      i++) {
    final mask = analysis.subjects[i];
    final r = analysis.panels[i];
    for (var by = 0; by < mask.height; by++) {
      for (var bx = 0; bx < mask.width; bx++) {
        final label = mask.labelAt(bx, by);
        if (label == 0) continue;
        final fx = r.x + (bx * r.width / mask.width).floor().clamp(0, r.width - 1);
        final fy = r.y + (by * r.height / mask.height).floor().clamp(0, r.height - 1);
        final canvasIdx = fy * working.width + fx;
        if (labels[canvasIdx] == 0) {
          final id = next + label;
          labels[canvasIdx] = id > 255 ? 255 : id;
        }
      }
    }
    next += mask.blobs.length;
  }
  final image = img.Image.fromBytes(
    width: working.width,
    height: working.height,
    bytes: labels.buffer,
    format: img.Format.uint8,
    numChannels: 1,
  );
  return Uint8List.fromList(img.encodePng(image));
}

List<int> _u64be(int v) => [
      (v >> 56) & 0xff,
      (v >> 48) & 0xff,
      (v >> 40) & 0xff,
      (v >> 32) & 0xff,
      (v >> 24) & 0xff,
      (v >> 16) & 0xff,
      (v >> 8) & 0xff,
      v & 0xff,
    ];

/// 模型分级判定（M4）：按本次注入的估算器推导生效 tier——**显式**记录，
/// 不做运行时静默降级。组件列表进 pack.json（可审计）。
ModelTierInfo _modelTier(MotionPipeline pipeline) {
  final components = <String>[];
  var tier = 0;
  if (pipeline.effectiveSubjectSegmenter != null) {
    tier = 1;
    components.add('subject_segmenter:${pipeline.effectiveSubjectSegmenter!.cacheTag}');
  }
  final depth = pipeline.effectiveDepthEstimator;
  if (depth is! HeuristicDepthEstimator) {
    tier = 2;
    components.add('depth:${depth.runtimeType}');
  }
  if (pipeline.effectivePanelStrategyJudge is ClassifierPanelStrategyJudge) {
    tier = 3;
    components.add('panel_classifier');
  }
  return ModelTierInfo(tier, components);
}
