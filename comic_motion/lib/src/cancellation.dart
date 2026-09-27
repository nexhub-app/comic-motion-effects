/// Cooperative cancellation for the render pipeline.
///
/// 设计要点（轻量）：
/// - token 内部只有一个 bool；`cancel()` 与检查点同处调用方 isolate（主
///   isolate 单线程前提，无锁、无定时器）。跨 isolate 使用见
///   `pipeline.dart` 的后台入口：cancel() 经控制 SendPort 推送，后台
///   isolate 在自己的本地 token 上响应。
/// - 取消检查点全部位于主 isolate 侧的**帧调度层**（派发前 / 每帧回包 /
///   探针帧渲染前），不打断 worker isolate 内部的单帧渲染——帧是纯函数，
///   跑完自然丢弃。因此取消与超时的生效粒度都是「帧边界」。
/// - 超时不使用 Timer：deadline 在每个检查点直接比对，效果等价且无泄漏
///   风险（检查点之间最长间隔 = 一帧的渲染时长）。
library;

/// 轻量取消令牌：`cancel()` 幂等，`isCancelled` 由管线在帧调度检查点轮询。
class MotionCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  /// 触发取消。可从任意代码路径调用；已取消后重复调用无副作用。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final h = _hook;
    if (h != null) h();
  }

  /// 取消桥（仅供后台 isolate 包装层使用，见 background.dart）：注册后
  /// cancel() 首次触发时会回调一次，把取消转发到后台 isolate 的控制
  /// SendPort。普通嵌入方无需接触。
  void Function()? _hook;
  set cancelHook(void Function()? hook) => _hook = hook;
}

/// 取消或超时异常。code 为 `E_CANCELLED`（调用方取消）或 `E_TIMEOUT`
/// （超时走同一取消路径），与其余 `E_*` 错误码体系对齐。
class MotionCancelledException implements Exception {
  MotionCancelledException(this.message, {this.code = 'E_CANCELLED'});

  /// Human-readable English reason.
  final String message;

  /// Stable error code: `E_CANCELLED` or `E_TIMEOUT`.
  final String code;

  @override
  String toString() => 'MotionCancelledException [$code]: $message';
}
