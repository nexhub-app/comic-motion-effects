/// Background-isolate entry points for the pipeline (R3).
///
/// 为什么需要：[MotionPipeline.processFile] / [processBytes] 虽为 async，但
/// 解码、降采样、深度估算、分层与调色板探针同步跑在调用方 isolate（仅后续
/// 帧渲染派发 worker 池）。UI isolate 直接调用会卡帧数百毫秒到秒级。
///
/// 传递语义（Isolate.spawn + 控制通道，非 Isolate.run——run 无法向后台发
/// 消息）：
/// - `config` / `parallel` / `memoryBudgetMb` / `timeout`：纯数据，随启动
///   消息一次性下发（深拷贝语义）。
/// - progress：后台 isolate 的 onProgress 经 SendPort 回传主 isolate，主侧
///   回调在事件循环中异步触发（不阻塞渲染）。
/// - cancel：[MotionCancelToken.cancelHook] 桥把 cancel() 即时转发到后台
///   isolate 的控制 ReceivePort → 后台本地 token.cancel() → 管线在下一次
///   帧调度检查点响应。后台无轮询定时器；「检查频率」= 管线检查点粒度
///   （派发前 / 每帧回包 / 探针前），即取消延迟 ≤ 一帧渲染时长 + 消息
///   传递延迟。
/// - 异常：后台 catch-all 后把异常对象（本引擎的异常只含可发送字段）发回
///   主 isolate 原样重抛，`E_*` 错误码与类型不丢。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'cancellation.dart';
import 'effect_config.dart';
import 'pipeline.dart';

/// 后台 isolate 版 [MotionPipeline.processFile]。参数语义与同步版一致，
/// 全部为执行期参数（不参与 configHash）。
///
/// [config] 缺省为 `EffectConfig()`（与 CLI 默认一致）。
Future<PipelineResult> processFileInBackground(
  String inputPath,
  String outputDir, {
  EffectConfig? config,
  int? parallel,
  int? memoryBudgetMb,
  MotionCancelToken? cancelToken,
  void Function(int framesDone, int framesTotal)? onProgress,
  Duration? timeout,
  bool keepPartial = false,
  bool includeFirstFrame = false,
}) async {
  final r = await _runInBackground(
    boot: _BackgroundBoot(
      fileMode: true,
      inputPath: inputPath,
      outputDir: outputDir,
      config: config ?? EffectConfig(),
      parallel: parallel,
      memoryBudgetMb: memoryBudgetMb,
      timeout: timeout,
      keepPartial: keepPartial,
      includeFirstFrame: includeFirstFrame,
    ),
    cancelToken: cancelToken,
    forwardProgress: onProgress,
  );
  return r as PipelineResult;
}

/// 后台 isolate 版 [MotionPipeline.processBytes]：bytes 进、bytes 出，
/// 整条管线（含解码与分层）不占用调用方 isolate。
Future<MemoryPipelineResult> processBytesInBackground({
  required Uint8List input,
  EffectConfig? config,
  int? parallel,
  int? memoryBudgetMb,
  MotionCancelToken? cancelToken,
  void Function(int framesDone, int framesTotal)? onProgress,
  Duration? timeout,
  bool keepPartial = false,
  bool includeFirstFrame = false,
}) async {
  final r = await _runInBackground(
    boot: _BackgroundBoot(
      fileMode: false,
      inputBytes: input,
      config: config ?? EffectConfig(),
      parallel: parallel,
      memoryBudgetMb: memoryBudgetMb,
      timeout: timeout,
      keepPartial: keepPartial,
      includeFirstFrame: includeFirstFrame,
    ),
    cancelToken: cancelToken,
    forwardProgress: onProgress,
  );
  return r as MemoryPipelineResult;
}

/// 启动消息（一次性下发，深拷贝）。
class _BackgroundBoot {
  _BackgroundBoot({
    required this.fileMode,
    required this.config,
    this.inputPath,
    this.outputDir,
    this.inputBytes,
    this.parallel,
    this.memoryBudgetMb,
    this.timeout,
    this.keepPartial = false,
    this.includeFirstFrame = false,
  });

  late final SendPort ack;
  late final SendPort result;
  late final SendPort progress;

  final bool fileMode;
  final String? inputPath;
  final String? outputDir;
  final Uint8List? inputBytes;
  final EffectConfig config;
  final int? parallel;
  final int? memoryBudgetMb;
  final Duration? timeout;
  final bool keepPartial;
  final bool includeFirstFrame;
}

/// 后台 isolate 入口：本地 token 承接控制通道的取消命令，progress 回传，
/// 渲染完成后把结果（或异常对象）发回主 isolate。
Future<void> _backgroundEntry(_BackgroundBoot boot) async {
  final control = ReceivePort();
  boot.ack.send(control.sendPort);
  final localToken = MotionCancelToken();
  control.listen((_) => localToken.cancel());
  final pipeline = MotionPipeline(
    boot.config,
    parallel: boot.parallel,
    memoryBudgetMb: boot.memoryBudgetMb,
    cancelToken: localToken,
    timeout: boot.timeout,
    keepPartial: boot.keepPartial,
    onProgress: (done, total) => boot.progress.send(<int>[done, total]),
  );
  try {
    final result = boot.fileMode
        ? await pipeline.processFile(boot.inputPath!, boot.outputDir!,
            includeFirstFrame: boot.includeFirstFrame)
        : await pipeline.processBytes(
            input: boot.inputBytes!, includeFirstFrame: boot.includeFirstFrame);
    boot.result.send(result);
  } catch (e, st) {
    try {
      boot.result.send(_RemoteError(e, '$e', '$st'));
    } catch (_) {
      // 异常对象不可跨 isolate 发送（引擎异常不会走到这里）：退化为纯文本。
      boot.result.send(_RemoteError(null, '$e', '$st'));
    }
  }
  control.close();
}

/// 跨 isolate 的错误信封。[error] 为可发送的原始异常对象（主侧原样重抛）；
/// 不可发送时为 null，主侧退化为 [StateError]（文案在 [errorText]）。
class _RemoteError {
  _RemoteError(this.error, this.errorText, this.stackTraceText);

  final Object? error;
  final String errorText;
  final String stackTraceText;
}

Future<Object> _runInBackground({
  required _BackgroundBoot boot,
  MotionCancelToken? cancelToken,
  void Function(int framesDone, int framesTotal)? forwardProgress,
}) async {
  final resultPort = ReceivePort();
  final progressPort = ReceivePort();
  final ack = ReceivePort();
  final exitPort = ReceivePort();
  Isolate? isolate;
  var bridgeAlive = false;
  final result = Completer<Object>();

  resultPort.listen((msg) {
    if (result.isCompleted) return;
    if (msg is _RemoteError) {
      final err = msg.error;
      if (err is Exception) {
        result.completeError(err, StackTrace.fromString(msg.stackTraceText));
      } else if (err is Error) {
        result.completeError(err, StackTrace.fromString(msg.stackTraceText));
      } else {
        result.completeError(
            StateError('background pipeline failed: ${msg.errorText}'));
      }
    } else {
      result.complete(msg as Object);
    }
  });
  progressPort.listen((msg) {
    if (forwardProgress != null && msg is List && msg.length == 2) {
      forwardProgress(msg[0] as int, msg[1] as int);
    }
  });
  exitPort.listen((_) {
    if (!result.isCompleted) {
      result.completeError(StateError('background isolate exited unexpectedly'));
    }
  });

  try {
    boot.ack = ack.sendPort;
    boot.result = resultPort.sendPort;
    boot.progress = progressPort.sendPort;
    isolate = await Isolate.spawn(_backgroundEntry, boot,
        debugName: 'cm-background-pipeline');
    isolate.addOnExitListener(exitPort.sendPort);
    // 握手拿控制端口；期间后台若已退出/已给出错误，直接走那条路。
    final controlSend = await Future.any<Object>([
      ack.first.then((m) => m as Object),
      result.future.then(
          (_) => throw StateError('background finished before handshake')),
    ]).timeout(const Duration(seconds: 30)) as SendPort;
    ack.close();

    if (cancelToken != null) {
      bridgeAlive = true;
      cancelToken.cancelHook = () {
        if (bridgeAlive) controlSend.send(null);
      };
      // 启动前就已取消的令牌：补发一次（幂等）。
      if (cancelToken.isCancelled) controlSend.send(null);
    }
    return await result.future;
  } finally {
    bridgeAlive = false;
    cancelToken?.cancelHook = null;
    ack.close();
    resultPort.close();
    progressPort.close();
    exitPort.close();
    isolate?.kill(priority: Isolate.immediate);
  }
}
