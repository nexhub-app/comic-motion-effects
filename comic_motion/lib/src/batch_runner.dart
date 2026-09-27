import 'dart:io';

import 'effect_config.dart';
import 'image_model.dart';
import 'ledger.dart';
import 'pipeline.dart';
import 'worker_pool.dart';

/// One batch item outcome.
class BatchItemResult {
  BatchItemResult({
    required this.input,
    required this.jobId,
    required this.ok,
    this.gifPath,
    this.frameDir,
    this.elapsedMs,
    this.error,
  });

  final String input;
  final String jobId;
  final bool ok;
  final String? gifPath;
  final String? frameDir;
  final int? elapsedMs;
  final String? error;

  Map<String, dynamic> toJson() => {
        'input': input,
        'jobId': jobId,
        'ok': ok,
        if (gifPath != null) 'gif': gifPath,
        if (frameDir != null) 'frames': frameDir,
        if (elapsedMs != null) 'elapsedMs': elapsedMs,
        if (error != null) 'error': error,
      };
}

/// Batch runner: process every image in a folder with one config.
/// A failing item never aborts the batch; its reason is recorded.
class BatchRunner {
  BatchRunner(this.ledger);

  final Ledger ledger;

  static const supportedExts = ['.png', '.jpg', '.jpeg', '.webp'];

  List<String> listImages(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) {
      throw ConfigException('Input directory does not exist: $dir',
          code: 'E_NO_INPUT');
    }
    return d
        .listSync()
        .whereType<File>()
        .where((f) => supportedExts
            .contains(f.path.substring(f.path.lastIndexOf('.')).toLowerCase()))
        .map((f) => f.path)
        .toList()
      ..sort();
  }

  /// 批量处理一个目录：单文件失败不中断整批，原因记进台账。
  ///
  /// [parallel] 覆盖单文件并行度（null = 用 [kDefaultParallel]，1 = 串行）。
  Future<List<BatchItemResult>> runFolder({
    required String inputDir,
    required String outputDir,
    required EffectConfig config,
    String? jobIdPrefix,
    int? parallel,
  }) {
    // 目录校验留在同步段：v1.2 的调用方直接 catch ConfigException。
    final files = listImages(inputDir);
    return _runAll(files,
        outputDir: outputDir,
        config: config,
        prefix: jobIdPrefix ?? 'batch',
        parallel: parallel);
  }

  Future<List<BatchItemResult>> _runAll(
    List<String> files, {
    required String outputDir,
    required EffectConfig config,
    required String prefix,
    int? parallel,
  }) async {
    final results = <BatchItemResult>[];
    for (final f in files) {
      final jobId = '$prefix-${DateTime.now().millisecondsSinceEpoch}-'
          '${results.length + 1}';
      try {
        final r = await MotionPipeline(config, parallel: parallel)
            .processFile(f, outputDir);
        ledger.appendJob(
          jobId: jobId,
          input: f,
          configHash: config.configHash,
          status: 'success',
          outputGif: r.outputGif,
          frameDir: r.frameDir,
          paramsFile: r.paramsFile,
          width: r.width,
          height: r.height,
          layerCount: r.layerCount,
          frameCount: r.frameCount,
          elapsedMs: r.elapsedMs,
          parallel: r.parallel,
          parallelFallback: r.parallelFallback ? true : null,
          warnings: r.warnings,
        );
        results.add(BatchItemResult(
          input: f,
          jobId: jobId,
          ok: true,
          gifPath: r.outputGif,
          frameDir: r.frameDir,
          elapsedMs: r.elapsedMs,
        ));
      } on ImageDecodeException catch (e) {
        results.add(_fail(f, jobId, config, e.toString(), outputDir));
      } on ImageTooLargeException catch (e) {
        results.add(_fail(f, jobId, config, e.toString(), outputDir));
      } on EngineWorkerException catch (e) {
        results.add(_fail(
            f, jobId, config, '${e.code}: $e', outputDir));
      } on FileSystemException catch (e) {
        results.add(_fail(f, jobId, config, 'File I/O failed: ${e.message}', outputDir));
      } catch (e) {
        results.add(_fail(f, jobId, config, 'Unexpected error: $e', outputDir));
      }
    }
    return results;
  }

  BatchItemResult _fail(String f, String jobId, EffectConfig config,
      String error, String outputDir) {
    ledger.appendJob(
      jobId: jobId,
      input: f,
      configHash: config.configHash,
      status: 'failed',
      error: error,
    );
    return BatchItemResult(input: f, jobId: jobId, ok: false, error: error);
  }
}
