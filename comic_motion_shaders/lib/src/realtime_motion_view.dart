/// RealtimeMotionView（W7 MVP）：FragmentShader 实时渲染分层纹理动效。
///
/// 输入为核心包 W6 `exportLayers` 导出的 `ui.Image` 层列表（远→近序，
/// 可经 `decodeLayerTextures` 解码）+ 全部实时可变的效果参数。内部以
/// Ticker 驱动呼吸相位与扫光位置，每帧把 [MotionUniforms] 写入
/// uber-shader 并绑定 4 个 sampler（空槽用 1x1 透明纹理占位）。
///
/// 分工定位：shader = 实时无限精度（高配设备、大屏、交互跟手场景）；
/// 预渲染帧集（MotionGifView / ParallaxGyroView）= 低功耗（低端设备、
/// 列表流）。选择指引见 README。
///
/// 所有权约定：`layers` 由调用方持有并在不再使用时自行 `dispose()`，
/// 本视图不接管其生命周期。
///
/// 与预渲染路径不同，实时路径由 uniform（时钟/交互）驱动，无 seed 概念，
/// 核心包的逐字节复现契约不适用。
library;

import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'motion_uniforms.dart';

/// shader 资源在包内的 asset 路径。
const String kShaderAsset =
    'packages/comic_motion_shaders/shaders/comic_motion.frag';

/// FragmentShader 实时渲染的分层动效视图。
class RealtimeMotionView extends StatefulWidget {
  const RealtimeMotionView({
    super.key,
    required this.layers,
    this.parallaxShift = Offset.zero,
    this.breathing = true,
    this.zoom = 0.02,
    this.breathingPeriod = const Duration(seconds: 6),
    this.sweep = true,
    this.sweepPeriod = const Duration(seconds: 9),
    this.sweepWidth = 0.08,
    this.sweepIntensity = 0.35,
    this.vignette = false,
    this.vignetteStrength = 0.35,
    this.vignetteSoftness = 0.5,
    this.playing = true,
  })  : assert(layers.length >= 1),
        assert(layers.length <= kMaxLayers);

  /// 分层纹理（远→近序，第 0 层为基准层不位移；上限 [kMaxLayers]）。
  final List<ui.Image> layers;

  /// 视差最大偏移（uv 分数；触摸/陀螺仪等外部信号直接驱动此值）。
  final Offset parallaxShift;

  /// 呼吸缩放开关与幅度/周期。
  final bool breathing;
  final double zoom;
  final Duration breathingPeriod;

  /// 扫光开关与周期/带宽/强度。
  final bool sweep;
  final Duration sweepPeriod;
  final double sweepWidth;
  final double sweepIntensity;

  /// 暗角开关与强度/柔度（静态 uniform，无时钟）。
  final bool vignette;
  final double vignetteStrength;
  final double vignetteSoftness;

  /// false 时停住时钟（呼吸/扫光冻结在当前相位），视差仍实时生效。
  final bool playing;

  @override
  State<RealtimeMotionView> createState() => _RealtimeMotionViewState();
}

class _RealtimeMotionViewState extends State<RealtimeMotionView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  // 时钟 notifier：Ticker 每帧写入 elapsed，驱动 painter 重绘（避免 setState）。
  final ValueNotifier<Duration> _clock = ValueNotifier<Duration>(Duration.zero);
  ui.FragmentShader? _shader;
  ui.Image? _emptyImage;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((Duration elapsed) => _clock.value = elapsed);
    if (widget.playing) _ticker.start();
    _loadProgram();
  }

  Future<void> _loadProgram() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(kShaderAsset);
      final shader = program.fragmentShader();
      final empty = await _makeEmptyImage();
      if (!mounted) {
        empty.dispose();
        return;
      }
      setState(() {
        _shader = shader;
        _emptyImage = empty;
      });
    } catch (_) {
      // shader 资源缺失/运行时不支持时安全降级：build 保持空视图。
    }
  }

  static Future<ui.Image> _makeEmptyImage() async {
    // 1x1 透明占位纹理：空 sampler 槽绑定，采样不影响合成。
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      ui.Paint()..blendMode = ui.BlendMode.clear,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(1, 1);
    picture.dispose();
    return image;
  }

  @override
  void didUpdateWidget(covariant RealtimeMotionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing != oldWidget.playing) {
      if (widget.playing) {
        _ticker.start();
      } else {
        _ticker.stop();
      }
    }
    // 参数（含视差偏移）变化触发重绘：时钟冻结时 ValueNotifier 不会因
    // 相同值发通知，必须显式 setState 走 painter 重建路径。
    setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    _shader?.dispose();
    _emptyImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    final empty = _emptyImage;
    if (shader == null || empty == null) {
      return const SizedBox.shrink();
    }
    final first = widget.layers.first;
    return AspectRatio(
      aspectRatio: first.width / first.height,
      child: CustomPaint(
        painter: _MotionPainter(state: this, emptyImage: empty),
      ),
    );
  }
}

class _MotionPainter extends CustomPainter {
  _MotionPainter({required this.state, required this.emptyImage})
      : super(repaint: state._clock);

  final _RealtimeMotionViewState state;
  final ui.Image emptyImage;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    // paint 时读 state.widget 取最新参数（didUpdateWidget 后经 notifier
    // 触发的重绘也能拿到新值）。
    final w = state.widget;
    final elapsed = state._clock.value;
    final phaseT = w.breathingPeriod.inMicroseconds <= 0
        ? 0.0
        : (elapsed.inMicroseconds % w.breathingPeriod.inMicroseconds) /
            w.breathingPeriod.inMicroseconds;
    final sweepPos = sweepPositionFor(
      elapsed: elapsed,
      period: w.sweepPeriod,
      halfWidth: w.sweepWidth,
    );

    final uniforms = MotionUniforms(
      parallax: w.parallaxShift != Offset.zero,
      parallaxDx: w.parallaxShift.dx,
      parallaxDy: w.parallaxShift.dy,
      depth: MotionUniforms.depthFactors(w.layers.length),
      breathing: w.breathing,
      zoom: w.zoom,
      phase: phaseT,
      sweep: w.sweep,
      sweepPosition: sweepPos,
      sweepWidth: w.sweepWidth,
      sweepIntensity: w.sweepIntensity,
      vignette: w.vignette,
      vignetteStrength: w.vignetteStrength,
      vignetteSoftness: w.vignetteSoftness,
      canvasWidth: size.width,
      canvasHeight: size.height,
    );

    final shader = state._shader!;
    final floats = uniforms.toFloats();
    for (var i = 0; i < floats.length; i++) {
      shader.setFloat(i, floats[i]);
    }
    for (var i = 0; i < kMaxLayers; i++) {
      shader.setImageSampler(
          i, i < w.layers.length ? w.layers[i] : emptyImage);
    }
    canvas.drawRect(ui.Offset.zero & size, ui.Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _MotionPainter oldDelegate) => true;
}
