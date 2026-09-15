import 'dart:io' as io;

import 'effect_config.dart';
import 'frame_compositor.dart';
import 'gif_writer.dart';
import 'depth_splitter.dart';
import 'image_io.dart';
import 'image_model.dart';

/// Result of one processing job.
class PipelineResult {
  PipelineResult({
    required this.inputPath,
    required this.outputGif,
    required this.frameDir,
    required this.paramsFile,
    required this.width,
    required this.height,
    required this.layerCount,
    required this.frameCount,
    required this.elapsedMs,
    required this.peakRssMb,
    required this.configJson,
    required this.configHash,
  });

  final String inputPath;
  final String outputGif; // '' when frames-only
  final String frameDir; // '' when gif-only
  final String paramsFile; // 参数回放文件（params.json）
  final int width;
  final int height;
  final int layerCount;
  final int frameCount;
  final int elapsedMs;
  final double peakRssMb;
  final String configJson;
  final String configHash;

  Map<String, dynamic> toJson() => {
        'input': inputPath,
        'outputGif': outputGif,
        'frameDir': frameDir,
        'paramsFile': paramsFile,
        'width': width,
        'height': height,
        'layerCount': layerCount,
        'frameCount': frameCount,
        'elapsedMs': elapsedMs,
        'peakRssMb': double.parse(peakRssMb.toStringAsFixed(1)),
        'configHash': configHash,
      };
}

/// One-shot processing pipeline: decode -> depth -> layers -> frames -> encode.
class MotionPipeline {
  MotionPipeline(this.config);

  final EffectConfig config;

  /// Process one image file into [outputDir] with uniform naming:
  /// `<input-stem>_<configHash>/anim.gif` and `frames/frame_NNNN.png`.
  PipelineResult processFile(String inputPath, String outputDir) {
    final sw = Stopwatch()..start();
    final src = ImageIO.decodeFile(inputPath);

    // Working resolution guard: downscale very large inputs for speed.
    final working = _downscaleTo(src, config.maxDimension);

    // Depth + layers.
    final depth = DepthEstimator(workScale: 0.5).estimate(working);
    final splitter = LayerSplitter(layerCount: config.layerCount);
    final layers = splitter.split(working, depth);

    // Frames: stream-render -> quantize -> LZW -> discard (O(one frame) RAM).
    final compositor = FrameCompositor(layers, working, config);

    // Uniform output naming.
    final stem = io.File(inputPath).uri.pathSegments.last;
    final dot = stem.lastIndexOf('.');
    final baseName = dot > 0 ? stem.substring(0, dot) : stem;
    final jobDir =
        '$outputDir\\${baseName}_${config.configHash.substring(0, 8)}';
    io.Directory(jobDir).createSync(recursive: true);

    var gifPath = '';
    var frameDir = '';
    final wantGif = config.outputFormat == OutputFormat.gif ||
        config.outputFormat == OutputFormat.both;
    final wantFrames = config.outputFormat == OutputFormat.frames ||
        config.outputFormat == OutputFormat.both;
    if (wantFrames) {
      frameDir = '$jobDir\\frames';
      io.Directory(frameDir).createSync(recursive: true);
    }
    final gif = wantGif
        ? StreamingGifBuilder(working.width, working.height,
            fps: config.fps, dither: config.quality.dither)
        : null;

    final n = config.frameCount;
    for (var i = 0; i < n; i++) {
      final frame = compositor.renderFrame(i / config.fps);
      if (wantFrames) {
        io.File('$frameDir\\frame_${i.toString().padLeft(4, '0')}.png')
            .writeAsBytesSync(ImageIO.encodePngFrame(frame));
      }
      gif?.addFrame(frame);
    }
    if (gif != null) {
      gifPath = '$jobDir\\anim.gif';
      io.File(gifPath).writeAsBytesSync(gif.finish());
    }

    // Persist the exact params next to outputs (reproducibility contract).
    final paramsFile = '$jobDir\\params.json';
    io.File(paramsFile).writeAsStringSync(config.toJsonString());

    sw.stop();
    return PipelineResult(
      inputPath: inputPath,
      outputGif: gifPath,
      frameDir: frameDir,
      paramsFile: paramsFile,
      width: src.width,
      height: src.height,
      layerCount: layers.length,
      frameCount: n,
      elapsedMs: sw.elapsedMilliseconds,
      peakRssMb: _currentRssMb(),
      configJson: config.toJsonString(),
      configHash: config.configHash,
    );
  }

  RgbaImage _downscaleTo(RgbaImage src, int maxDim) {
    final maxSide = src.width > src.height ? src.width : src.height;
    if (maxSide <= maxDim) return src;
    final ratio = maxDim / maxSide;
    final nw = (src.width * ratio).round().clamp(1, maxDim);
    final nh = (src.height * ratio).round().clamp(1, maxDim);
    final out = RgbaImage(width: nw, height: nh);
    final sx = src.width / nw, sy = src.height / nh;
    final tmp = List<int>.filled(4, 0);
    for (var y = 0; y < nh; y++) {
      for (var x = 0; x < nw; x++) {
        src.sampleBilinear((x + 0.5) * sx - 0.5, (y + 0.5) * sy - 0.5, tmp);
        out.setPixel(x, y, tmp[0], tmp[1], tmp[2], tmp[3]);
      }
    }
    return out;
  }

  static double _currentRssMb() {
    // dart:io ProcessInfo works across desktop platforms.
    try {
      return io.ProcessInfo.maxRss / (1024 * 1024);
    } catch (_) {
      return -1; // unsupported platform marker
    }
  }
}
