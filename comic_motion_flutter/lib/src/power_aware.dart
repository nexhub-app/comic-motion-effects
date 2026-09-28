/// 功耗感知策略（W4）：生命周期 / 视口 / App 策略三路信号聚合。
///
/// 三路信号：
/// - **生命周期**：`AppLifecycleState` 离开 `resumed`（paused/hidden/
///   inactive/detached）即抑制动效，回到 resumed 恢复——默认启用；
/// - **视口**：`pauseWhenNotVisible` 开启后，滚动冒泡通知触发视口自检
///   （RenderBox 全局矩形与窗口求交），滚出即静帧、滚回恢复——opt-in
///   （默认关，向后兼容；仅覆盖滚动可见性，静态遮挡不检测）；
/// - **App 策略钩子**：`enableMotion: bool Function()?`——决策权在 App
///   （如低电量返回 false），本包**不引 battery 依赖**。钩子在信号聚合
///   点惰性求值（低频），返回值变化需 App rebuild 触发重估。
///
/// 子类职责：实现 [onMotionSuppressed]（静帧：停泵帧/断传感器）与
/// [onMotionRestored]（恢复），`initState` 调 [motionPowerInit]、
/// `dispose` 调 [motionPowerDispose]，build 输出包 `NotificationListener`
/// 转发 [onMotionScrollNotification]（启用视口检测时）。
///
/// 红线：默认参数下（`pauseWhenNotVisible: false`、钩子 null）行为与
/// W4 之前逐 widget 等价——生命周期路径初始为 resumed，不触发抑制。
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

mixin MotionPowerAware<T extends StatefulWidget> on State<T>
    implements WidgetsBindingObserver {
  bool _lifecycleActive = true;
  bool _viewportVisible = true;
  bool _lastActive = true;

  /// App 传入的策略钩子；null = 恒允许。子类覆盖返回 widget 字段。
  bool Function()? get enableMotion => null;

  /// 视口外自动暂停开关。子类覆盖返回 widget 字段；默认 false。
  bool get pauseWhenNotVisible => false;

  /// 当前动效是否被允许（生命周期 + 视口 + 钩子三路聚合）。
  bool get motionActive {
    if (!_lifecycleActive || !_viewportVisible) return false;
    final hook = enableMotion;
    if (hook != null && !hook()) return false;
    return true;
  }

  /// 聚合结果 false → true 时回调：恢复动效。
  void onMotionRestored() {}

  /// 聚合结果 true → false 时回调：进入静帧（零持续开销：停泵帧循环 /
  /// 断传感器订阅）。
  void onMotionSuppressed() {}

  /// 挂生命周期 observer + 初始视口检查。子类 initState 调用。
  void motionPowerInit() {
    _lastActive = true;
    WidgetsBinding.instance.addObserver(this);
    if (pauseWhenNotVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) updateMotionVisibility(_computeViewportVisible());
      });
    }
  }

  /// 移除 observer。子类 dispose 调用。
  void motionPowerDispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  /// 滚动通知转发（子类 build 包 `NotificationListener<ScrollNotification>`
  /// 时调用）。返回值恒 false（不消费通知）。
  bool onMotionScrollNotification(ScrollNotification notification) {
    if (pauseWhenNotVisible) {
      // 惰性检查：滚动帧布局完成后做一次视口求交。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) updateMotionVisibility(_computeViewportVisible());
      });
    }
    return false;
  }

  /// 生命周期变化（WidgetsBindingObserver 桥接）。
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _setLifecycleActive(state == AppLifecycleState.resumed);
  }

  /// App 状态可能变化的重估入口（didUpdateWidget 中调用）：钩子引用/
  /// 返回值、playing 等变化后重算聚合并按需切换。
  void reassessMotion() {
    _notifyIfChanged();
  }

  /// 视口自检（仅 pauseWhenNotVisible 启用时有效）。
  void _checkViewport() {
    if (!mounted) return;
    _setViewportVisible(_computeViewportVisible());
  }

  bool _computeViewportVisible() {
    final ro = context.findRenderObject();
    // 无法判定（未布局/已脱离）时保守视为可见——避免误静帧。
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return true;
    final view = View.of(context);
    final dpr = view.devicePixelRatio;
    final screenRect = Offset.zero & view.physicalSize / dpr;
    final globalRect = ro.paintBounds.shift(ro.localToGlobal(Offset.zero));
    return globalRect.overlaps(screenRect);
  }

  void _setLifecycleActive(bool active) {
    if (_lifecycleActive == active) return;
    _lifecycleActive = active;
    _notifyIfChanged();
  }

  void _setViewportVisible(bool visible) {
    if (_viewportVisible == visible) return;
    _viewportVisible = visible;
    _notifyIfChanged();
  }

  void _notifyIfChanged() {
    final now = motionActive;
    if (now == _lastActive) return;
    _lastActive = now;
    if (now) {
      onMotionRestored();
    } else {
      onMotionSuppressed();
    }
  }
}
