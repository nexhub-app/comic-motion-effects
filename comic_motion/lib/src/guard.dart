/// Optional concurrency guard for the render pipeline. Pure opt-in — the
/// library never enforces it on its own.
///
/// 为什么需要：单条管线峰值内存 300~600MB（见 README 性能基准），两个管线
/// 并发就是直接叠加，移动端会 OOM。嵌入方（尤其是移动端漫画阅读器）应
/// 保证「同一时刻只跑一个渲染任务」：串行排队而不是并发叠加。
///
/// 用法（与取消配合：取消抛出的 [MotionCancelledException] 也会正常走
/// finally 释放槽位）：
/// ```dart
/// await MotionPipelineGuard.run(() =>
///     MotionPipeline(config).processFile(input, outDir));
/// ```
library;

import 'dart:async';
import 'dart:collection';

/// Optional concurrency guard for the render pipeline. Pure opt-in — the
/// library never enforces it on its own.
///
/// 为什么需要：单条管线峰值内存 300~600MB（见 README 性能基准），两个管线
/// 并发就是直接叠加，移动端会 OOM。嵌入方（尤其是移动端漫画阅读器）应
/// 保证「同一时刻只跑一个渲染任务」：串行排队而不是并发叠加。
///
/// 用法（与取消配合：取消抛出的 [MotionCancelledException] 也会正常走
/// finally 释放槽位）：
/// ```dart
/// await MotionPipelineGuard.run(() =>
///     MotionPipeline(config).processFile(input, outDir));
/// ```

/// 静态信号量：`acquire()` 满员排队（FIFO），`release()` 放行队首。
/// 进程级共享（静态），跨所有 [MotionPipeline] 实例生效。
class MotionPipelineGuard {
  MotionPipelineGuard._();

  static int _maxConcurrent = 1;
  static int _active = 0;
  static final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  /// 配置最大并发数（默认 1）。移动端保持 1；桌面批处理可调大。
  static void configure({int maxConcurrent = 1}) {
    if (maxConcurrent < 1) {
      throw ArgumentError.value(maxConcurrent, 'maxConcurrent', 'must be >= 1');
    }
    _maxConcurrent = maxConcurrent;
  }

  static int get maxConcurrent => _maxConcurrent;

  /// 当前持有的槽位数。
  static int get activeCount => _active;

  /// 当前排队等待的任务数。
  static int get queueLength => _waiters.length;

  /// 取一个执行槽；满员时 FIFO 排队，直到有 [release]。
  static Future<void> acquire() {
    if (_active < _maxConcurrent) {
      _active++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  /// 释放执行槽并放行队首等待者。未持槽时调用抛 [StateError]（尽早暴露
  /// 配对错误）。
  static void release() {
    if (_active == 0) {
      throw StateError('MotionPipelineGuard.release() without acquire()');
    }
    _active--;
    while (_active < _maxConcurrent && _waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
      _active++;
    }
  }

  /// 便捷封装：acquire → 执行 body → release。body 抛任何异常（含取消/
  /// 超时）都会先释放再原样重抛。
  static Future<T> run<T>(Future<T> Function() body) async {
    await acquire();
    try {
      return await body();
    } finally {
      release();
    }
  }
}
