import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'depth_splitter.dart';
import 'effect_config.dart';
import 'frame_compositor.dart';
import 'gif_writer.dart';
import 'image_io.dart';
import 'image_model.dart';

/// 单帧 GIF 编码器的可发送描述（= [GifFrameEncoder] 的构造参数）。
/// 调色板必须由主 isolate 定板后下发：worker 共享同一份板，量化才是纯函数。
class GifEncoderSpec {
  GifEncoderSpec({
    required this.width,
    required this.height,
    required this.delayCs,
    required this.palette,
    required this.dither,
    required this.sierra,
    required this.useLut,
  });

  /// 从已定板的流式构建器导出（未定板时抛 [StateError]）。
  GifEncoderSpec.from(StreamingGifBuilder g)
      : width = g.width,
        height = g.height,
        delayCs = g.delayCs,
        palette = List<int>.from(g.palettePacked!),
        dither = g.dither,
        sierra = g.sierra,
        useLut = g.tier.atLeastStandard;

  final int width;
  final int height;
  final int delayCs;
  final List<int> palette;
  final bool dither;
  final bool sierra;
  final bool useLut;

  GifFrameEncoder build() => GifFrameEncoder(
        width: width,
        height: height,
        delayCs: delayCs,
        palette: palette,
        dither: dither,
        sierra: sierra,
        useLut: useLut,
      );
}

/// 一帧渲染任务所需的全部纯数据。跨 isolate 发送时每个 worker 各得一份拷贝
/// —— 这是并行度的内存成本，已计入 [ParallelFrameRunner.fitParallel] 预算。
class FrameJobSpec {
  FrameJobSpec({
    required this.width,
    required this.height,
    required this.config,
    required this.basePixels,
    required this.layerPixels,
    this.pngDir,
    this.gif,
  });

  factory FrameJobSpec.fromLayers({
    required RgbaImage base,
    required List<LayerImage> layers,
    required EffectConfig config,
    String? pngDir,
    GifEncoderSpec? gif,
  }) =>
      FrameJobSpec(
        width: base.width,
        height: base.height,
        config: config,
        basePixels: base.data,
        layerPixels: layers.map((l) => l.image.data).toList(),
        pngDir: pngDir,
        gif: gif,
      );

  final int width;
  final int height;
  final EffectConfig config;
  final Uint8List basePixels;
  final List<Uint8List> layerPixels;

  /// 非空则该帧的 PNG 由执行方就地写盘 —— 栅格不出 isolate，省一次大消息。
  final String? pngDir;
  final GifEncoderSpec? gif;

  /// 每个 worker 常驻的栅格字节数（底图 + 各层 + 在途帧 + 索引帧）。
  int get rasterBytesPerWorker => width * height * 4 * (layerPixels.length + 3);
}

/// 单帧产物：GIF 片段字节（不编 GIF 时为 null）。PNG 是就地副作用，不回流。
class FrameOutput {
  FrameOutput(this.index, this.gifBody, {this.from}) : error = null;
  FrameOutput.failed(this.index, this.error)
      : gifBody = null,
        from = null;

  final int index;
  final Uint8List? gifBody;
  final String? error;

  /// worker 用来把自己归还给空闲池；串行路径为 null。
  final SendPort? from;
}

/// 唯一的单帧「渲染 → PNG → 量化 → LZW」通路。
///
/// 串行与并行共用本类，所以「并行 == 串行」是构造出来的性质而非事后比对：
/// 给定同一份定板调色板，单帧编码不依赖任何跨帧状态（编码器缓存只做纯查表
/// 记忆，只影响速度）。
class FrameJob {
  FrameJob(this.compositor, {this.pngDir, this.encoder});

  factory FrameJob.fromSpec(FrameJobSpec s) => FrameJob(
        FrameCompositor.fromRasters(
          base: s.basePixels,
          layers: s.layerPixels,
          w: s.width,
          h: s.height,
          config: s.config,
        ),
        pngDir: s.pngDir,
        encoder: s.gif?.build(),
      );

  final FrameCompositor compositor;
  final String? pngDir;
  final GifFrameEncoder? encoder;

  FrameOutput run(int index, {SendPort? from}) {
    final frame = compositor.renderFrame(index / compositor.config.fps);
    final dir = pngDir;
    if (dir != null) ImageIO.writePngFrame(dir, index, frame);
    return FrameOutput(index, encoder?.encodeFrameBody(frame), from: from);
  }
}

/// worker 内异常或 isolate 意外退出：任务整体失败，错误码 `E_WORKER_CRASH`。
class EngineWorkerException implements Exception {
  EngineWorkerException(this.frameIndex, this.cause,
      {this.code = 'E_WORKER_CRASH'});

  /// Stable error code; always `E_WORKER_CRASH` today.
  final String code;

  /// null = isolate 级崩溃，无法归因到单帧。
  final int? frameIndex;

  /// Human-readable English reason (also recorded by the HTTP layer).
  final String cause;

  @override
  String toString() =>
      'EngineWorkerException [$code]: render worker failed for frame '
      '${frameIndex ?? '?'}: $cause';
}

class _BootMsg {
  _BootMsg(this.ack, this.out, this.spec);
  final SendPort ack;
  final SendPort out;
  final FrameJobSpec spec;
}

void _workerEntry(_BootMsg boot) {
  final control = ReceivePort();
  boot.ack.send(control.sendPort);
  final self = control.sendPort;
  // 惰性建作业：建作业失败也必须以「该帧失败」回给主 isolate，
  // 否则 isolate 会带着未处理的异常消失，主 isolate 永远等不到结果。
  FrameJob? job;
  control.listen((msg) {
    final index = msg as int;
    try {
      final j = job ??= FrameJob.fromSpec(boot.spec);
      boot.out.send(j.run(index, from: self));
    } catch (e) {
      boot.out.send(FrameOutput.failed(index, '$e'));
    }
  });
}

/// isolate 帧池：结果按帧序回灌，重排窗口有界（`worker 数 × 2`），
/// 因此内存是 O(窗口) 而不是 O(帧数)。
class ParallelFrameRunner {
  ParallelFrameRunner._(this._out, this._exits);

  /// 全部 worker 的栅格 + 在途帧总预算；超预算就降并行度，最终退到串行。
  static const int _budgetBytes = 700 << 20;
  static const Duration _bootTimeout = Duration(seconds: 10);

  final ReceivePort _out;
  final ReceivePort _exits;
  final List<Isolate> _isolates = [];
  final Queue<SendPort> _idle = Queue();
  final Map<int, Completer<FrameOutput>> _pending = {};
  bool _killed = false;
  bool _disposed = false;

  /// 实际起用的 worker 数（= 并行度）。
  int get workerCount => _isolates.length;

  /// 在途帧上限：worker 数的两倍，让快帧提前开工、慢帧不撑爆内存。
  int get _window => _isolates.length * 2;

  /// 依请求值、核数与内存预算决定实际并行度（<=1 表示走串行）。
  static int fitParallel(int requested, FrameJobSpec spec) {
    if (requested <= 1) return 1;
    final hardware = math.max(1, io.Platform.numberOfProcessors);
    var p = math.min(requested, hardware);
    final perWorker = spec.rasterBytesPerWorker;
    while (p > 1 && p * perWorker > _budgetBytes) {
      p--;
    }
    return p;
  }

  /// spawn 失败或并行度不足 2 → 返回 null，由调用方降级为串行（不算任务失败）。
  static Future<ParallelFrameRunner?> start(
      FrameJobSpec spec, int requested) async {
    final parallel = fitParallel(requested, spec);
    if (parallel < 2) return null;
    final out = ReceivePort();
    final exits = ReceivePort();
    final runner = ParallelFrameRunner._(out, exits);
    out.listen(runner._onResult);
    exits.listen(runner._onExit);
    try {
      for (var i = 0; i < parallel; i++) {
        final ack = ReceivePort();
        final iso = await Isolate.spawn(
          _workerEntry,
          _BootMsg(ack.sendPort, out.sendPort, spec),
          debugName: 'cm-frame-worker-$i',
        );
        // 必须先挂退出监听再等 ack：worker 若在握手之后、注册之前死掉，
        // 退出事件就没人接，主 isolate 会永远等那一帧的结果。
        iso.addOnExitListener(exits.sendPort, response: i);
        // 逐个握手：一次只有一份 spec 拷贝在途，避免并行 spawn 抬高瞬时峰值。
        final control = (await ack.first.timeout(_bootTimeout)) as SendPort;
        ack.close();
        runner._isolates.add(iso);
        runner._idle.add(control);
      }
    } catch (_) {
      await runner.dispose();
      return null;
    }
    return runner;
  }

  void _onResult(Object? msg) {
    if (msg is! FrameOutput) return;
    final from = msg.from;
    if (from != null) _idle.add(from);
    // 只回填不移除——条目由 run() 在取到值之后才摘除。
    final c = _pending[msg.index];
    if (c != null && !c.isCompleted) c.complete(msg);
  }

  void _onExit(Object? msg) {
    if (_disposed) return;
    _killed = true;
    // 用「带错误的值」而非 completeError 回填：在途帧可能有多个，未被 await
    // 的那个若以 error 结束会变成未捕获异步异常，直接打死主 isolate。
    final waiting = Map<int, Completer<FrameOutput>>.from(_pending);
    _pending.clear();
    waiting.forEach((i, c) {
      if (!c.isCompleted) {
        c.complete(FrameOutput.failed(i, 'worker #$msg 意外退出'));
      }
    });
  }

  /// 按 [indices] 顺序产出结果。[presolved] 是主 isolate 已编好的帧（调色板
  /// 探针帧）：参与按序输出但不占 worker，省掉一次重复渲染。
  Future<void> run(
    List<int> indices,
    Map<int, FrameOutput> presolved,
    void Function(int index, FrameOutput out) inOrder,
  ) async {
    var next = 0;
    for (var k = 0; k < indices.length; k++) {
      while (next < indices.length && next - k < _window) {
        final i = indices[next];
        if (presolved.containsKey(i)) {
          next++;
          continue;
        }
        if (_idle.isEmpty) break;
        next++;
        _pending[i] = Completer<FrameOutput>();
        _idle.removeFirst().send(i);
      }
      final index = indices[k];
      if (_killed) {
        throw EngineWorkerException(index, 'worker isolate exited unexpectedly');
      }
      final waiting = _pending[index];
      if (waiting == null && !presolved.containsKey(index)) {
        throw EngineWorkerException(index, 'frame aborted before dispatch');
      }
      // 先 await 后摘除：提前 remove 会让随后到达的结果找不到 Completer，死等。
      final out = waiting == null ? presolved[index]! : await waiting.future;
      _pending.remove(index);
      final err = out.error;
      if (err != null) throw EngineWorkerException(out.index, err);
      inOrder(index, out);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final iso in _isolates) {
      iso.kill(priority: Isolate.immediate);
    }
    _isolates.clear();
    _idle.clear();
    _pending.clear();
    _out.close();
    _exits.close();
  }
}
