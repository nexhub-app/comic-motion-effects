/// 分层纹理集导出（W6）：把工作分辨率分层栅格导出为 PNG 纹理集 + 层元数据
/// JSON——同时服务 W7 shader 伴生包（GPU 实时化的纹理输入）与外部 ML 调试
/// （AI 深度注入后的分层目视校验）。
///
/// 与交互帧集 / 入场帧序列同构的产物契约：
/// - 落盘目录 `<stem>_<contentHash8>_<configHash8>_layers/`，
///   `layer_NN.png`（rank 序）+ `index.json`（`kind: layers`）；
/// - panelAware 开启时每层携带 `clip`（画布坐标格边界），索引一并记录——
///   shader 侧按 clip 限制绘制区域即可复现格边界裁剪。
///
/// 确定性：同输入同 config → 同产物（层序 = 格序 × 格内 rank 序，PNG 为
/// 无时间戳确定编码）。
library;

import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'apng_writer.dart' show PixelRect;
import 'image_io.dart';
import 'image_model.dart';
import 'pipeline.dart';

/// 单层导出产物。
class LayerRaster {
  const LayerRaster({required this.rank, required this.clip, required this.pngBytes});

  /// 格内深度 rank（0 = far …）。panelAware 关闭时即全局层序。
  final int rank;

  /// 画布坐标裁剪（panelAware 格边界）；null = 全画布。
  final PixelRect? clip;

  /// 该层 PNG 字节（与引擎 PNG 帧编码器同源，尺寸 = 工作分辨率）。
  final Uint8List pngBytes;
}

/// 分层纹理集导出结果。
class LayerExportResult {
  const LayerExportResult({
    required this.layers,
    required this.width,
    required this.height,
    required this.configHash,
    required this.contentHash,
    required this.indexJson,
    this.dir = '',
  });

  /// 按导出序（格序 × 格内 rank）排列的层。
  final List<LayerRaster> layers;

  /// 工作分辨率。
  final int width;
  final int height;

  final String configHash;
  final String contentHash;

  /// 索引 JSON（`kind: layers`；与落盘 index.json 同字节）。
  final String indexJson;

  /// 落盘目录（内存模式为空串）。
  final String dir;

  Map<String, dynamic> toJson() => {
        'layers': layers.length,
        'width': width,
        'height': height,
        'configHash': configHash,
        'contentHash': contentHash,
        if (dir.isNotEmpty) 'dir': dir,
      };
}

extension LayerExport on MotionPipeline {
  /// 内存入口：导出 [src] 降采样后的分层纹理集。
  LayerExportResult exportLayers(RgbaImage src) =>
      _runLayerExport(this, src, contentHash: '', inputStem: 'image', outputDir: null);

  /// 文件入口：落盘 `<outputDir>/<stem>_<contentHash8>_<configHash8>_layers/`
  /// （layer_NN.png + index.json），同时返回内存结果。
  Future<LayerExportResult> exportLayersFile(
      String inputPath, String outputDir) async {
    final bytes = ImageIO.readFileBytes(inputPath);
    final src = ImageIO.decode(bytes);
    final stem = io.File(inputPath).uri.pathSegments.last;
    final dot = stem.lastIndexOf('.');
    final baseName = dot > 0 ? stem.substring(0, dot) : stem;
    return _runLayerExport(
      this,
      src,
      contentHash: ImageIO.contentHash8(bytes),
      inputStem: baseName,
      outputDir: outputDir,
    );
  }
}

LayerExportResult _runLayerExport(
  MotionPipeline pipeline,
  RgbaImage src, {
  required String contentHash,
  required String inputStem,
  required String? outputDir,
}) {
  final cfg = pipeline.config;
  // 与渲染管线同一条降采样 + 深度 + 分层主干（含 panelAware 逐格路径与
  // 注入的 depthEstimator），保证导出层与管线内部分层完全一致。
  final (working, layers) = pipeline.downscaleAndSplitForExport(src);

  final rasters = <LayerRaster>[];
  for (final l in layers) {
    rasters.add(LayerRaster(
      rank: l.depthRank,
      clip: l.clip,
      // RGBA PNG：分层遮罩的 alpha（羽化/成员度）是 shader 混合的必要信息。
      pngBytes: Uint8List.fromList(ImageIO.encodePngFrameRgba(l.image)),
    ));
  }

  final configHash = cfg.configHash;
  // 确定性索引：固定键序，无时间戳字段。
  final index = <String, dynamic>{
    'kind': 'layers',
    'width': working.width,
    'height': working.height,
    'configHash': configHash,
    if (contentHash.isNotEmpty) 'contentHash': contentHash,
    'layerCount': cfg.layerCount,
    'panelAware': cfg.panelAware,
    'layers': [
      for (var i = 0; i < rasters.length; i++)
        <String, dynamic>{
          'file': 'layer_${i.toString().padLeft(2, '0')}.png',
          'rank': rasters[i].rank,
          if (rasters[i].clip != null)
            'clip': {
              'x': rasters[i].clip!.x,
              'y': rasters[i].clip!.y,
              'w': rasters[i].clip!.width,
              'h': rasters[i].clip!.height,
            },
        },
    ],
  };
  final indexJson = const JsonEncoder.withIndent('  ').convert(index);

  var dir = '';
  if (outputDir != null) {
    dir = '$outputDir/${inputStem}_${contentHash}_${configHash.substring(0, 8)}_layers';
    io.Directory(dir).createSync(recursive: true);
    for (var i = 0; i < rasters.length; i++) {
      io.File('$dir/layer_${i.toString().padLeft(2, '0')}.png')
          .writeAsBytesSync(rasters[i].pngBytes);
    }
    io.File('$dir/index.json').writeAsStringSync(indexJson);
  }

  return LayerExportResult(
    layers: rasters,
    width: working.width,
    height: working.height,
    configHash: configHash,
    contentHash: contentHash,
    indexJson: indexJson,
    dir: dir,
  );
}
