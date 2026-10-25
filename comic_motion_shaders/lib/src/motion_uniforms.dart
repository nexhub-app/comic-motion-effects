/// Uniform 映射逻辑（W7 MVP）：把四件参数化变换效果的实时参数序列化为
/// uber-shader `assets/shaders/comic_motion.frag` 约定的 float 数组。
///
/// 布局即契约——`toFloats()` 的索引顺序与 shader 内 uniform 声明序一一对应
/// （见 `kIndex*` 常量与 README uniform 表），改动任一侧必须同步另一侧。
///
/// 所有数值在序列化时钳制进合法区间；空槽层深度补 0；层数上限 4
/// （超出截断）。本类为纯 Dart 逻辑，可脱离 Flutter 运行时单测。
///
/// 确定性说明：实时路径由 uniform（时钟/交互）驱动，无 seed 概念，
/// 核心包的逐字节复现契约不适用于本包。
library;

import 'dart:typed_data';

import 'package:comic_motion/comic_motion.dart'
    show CameraType, MotionProgram;

/// uber-shader 最多绑定的层纹理数（sampler uTex0..uTex3）。
const int kMaxLayers = 4;

/// `toFloats()` 输出的 float 个数（与 shader float uniform 数一致）。
/// M3 镜头主线化（`motion_redesign_plan_20261025.md` §7.1）：19 → 28
/// （camera 块 7 + focus 块 2，加性扩展在尾部——旧布局索引 0..18 不动）。
const int kFloatCount = 28;

/// 四效果的实时参数集（值域钳制在 [toFloats] 内完成）。
class MotionUniforms {
  const MotionUniforms({
    this.parallax = false,
    this.parallaxDx = 0,
    this.parallaxDy = 0,
    this.depth = const <double>[],
    this.breathing = false,
    this.zoom = 0.02,
    this.phase = 0,
    this.sweep = false,
    this.sweepPosition = 0,
    this.sweepWidth = 0.08,
    this.sweepIntensity = 0.35,
    this.vignette = false,
    this.vignetteStrength = 0.35,
    this.vignetteSoftness = 0.5,
    this.canvasWidth = 1,
    this.canvasHeight = 1,
    this.cameraOn = false,
    this.cameraDrift = false,
    this.cameraAnchorX = 0.5,
    this.cameraAnchorY = 0.42,
    this.cameraZoomSpan = 0.0,
    this.cameraDriftAmp = 0.0,
    this.cameraPhase = 0.0,
    this.focusOn = false,
    this.focusScaleMul = 1.0,
  });

  /// 分层视差（远→近深度因子见 [depth]）。
  final bool parallax;

  /// 最大 uv 偏移（画布宽/高的分数；shader 内按每层 [depth] 加权）。
  final double parallaxDx;
  final double parallaxDy;

  /// 每层深度因子 0..1（0 = 基准层不位移）。长度定长化为 4：
  /// 不足补 0，超出截断。
  final List<double> depth;

  /// 呼吸缩放。
  final bool breathing;

  /// 呼吸幅度（0.02 = ±2%）。
  final double zoom;

  /// 呼吸相位 0..1（宿主时钟驱动）。
  final double phase;

  /// 扫光。
  final bool sweep;

  /// 扫光中心（uv x；允许略越界 [-0.5, 1.5] 以便光带滑入/滑出）。
  final double sweepPosition;

  /// 扫光半带宽（uv x 分数）。
  final double sweepWidth;

  /// 扫光高亮强度 0..1。
  final double sweepIntensity;

  /// 暗角。
  final bool vignette;

  /// 暗角压暗强度 0..1。
  final double vignetteStrength;

  /// 暗角过渡柔度 0..1。
  final double vignetteSoftness;

  /// 画布像素尺寸（shader 内 uv 归一化基准；非正值按 1 处理）。
  final double canvasWidth;
  final double canvasHeight;

  /// 镜头块（M3 主线化，方案 §3/§7.1）：全画布一致仿射——区域统一按整页
  /// （格级裁剪由宿主按 layer clip 分块绘制时下沉为各自的 canvas 尺寸）。
  final bool cameraOn;

  /// false = pushIn（往返推镜，cos 载体），true = drift（横移，sin 载体）。
  final bool cameraDrift;

  /// 缩放/漂移焦点（uv 坐标）：action=灭点，closeup=主体质心。
  final double cameraAnchorX;
  final double cameraAnchorY;

  /// 推镜跨度 zoom1 − zoom0（zoom0 恒 1；shader 内 z = 1 + span·波）。
  final double cameraZoomSpan;

  /// 漂移幅度（uv 宽度分数，drift 模式）。
  final double cameraDriftAmp;

  /// 镜头相位 0..1（宿主按 [cameraPhaseFor] 整周期对齐；0 = 静息恒等）。
  final double cameraPhase;

  /// 焦点升档（G-3）：阅读器聚焦该格时动效本体变强（镜头跨度与视差
  /// 幅度 ×[focusScaleMul]；熄焦回落）。tempoMul 在宿主相位处生效
  /// （[cameraPhaseFor] 的 [tempoMul] 入参），不进 shader。
  final bool focusOn;
  final double focusScaleMul;

  // —— 布局契约：与 comic_motion.frag 的 uniform 声明序一致 ——
  static const int kIndexParallaxOn = 0;
  static const int kIndexParallaxX = 1;
  static const int kIndexParallaxY = 2;
  static const int kIndexDepth0 = 3;
  static const int kIndexDepth1 = 4;
  static const int kIndexDepth2 = 5;
  static const int kIndexDepth3 = 6;
  static const int kIndexBreathingOn = 7;
  static const int kIndexZoom = 8;
  static const int kIndexPhase = 9;
  static const int kIndexSweepOn = 10;
  static const int kIndexSweepPos = 11;
  static const int kIndexSweepWidth = 12;
  static const int kIndexSweepIntensity = 13;
  static const int kIndexVignetteOn = 14;
  static const int kIndexVignetteStrength = 15;
  static const int kIndexVignetteSoftness = 16;
  static const int kIndexSizeX = 17;
  static const int kIndexSizeY = 18;
  // M3 camera 块（19..25）
  static const int kIndexCameraOn = 19;
  static const int kIndexCameraMode = 20; // 0=pushIn 1=drift
  static const int kIndexCameraAnchorX = 21;
  static const int kIndexCameraAnchorY = 22;
  static const int kIndexCameraZoomSpan = 23;
  static const int kIndexCameraDriftAmp = 24;
  static const int kIndexCameraPhase = 25;
  // M3 focus 块（26..27）
  static const int kIndexFocusOn = 26;
  static const int kIndexFocusScaleMul = 27;

  /// 按层序生成深度因子：基准层（index 0）恒为 0（不位移），其余层在
  /// 0..1 间线性铺开（层数 n：depth[i] = i / (n - 1)）。单层返回全 0。
  static List<double> depthFactors(int layerCount) {
    if (layerCount <= 1) return const <double>[0, 0, 0, 0];
    final n = layerCount > kMaxLayers ? kMaxLayers : layerCount;
    return <double>[for (var i = 0; i < kMaxLayers; i++) i / (n - 1)];
  }

  /// 序列化为 shader uniform 数组（长度恒 [kFloatCount]）。
  Float32List toFloats() {
    final d = _fixedDepth();
    return Float32List.fromList(<double>[
      // 0 parallax
      parallax ? 1.0 : 0.0,
      parallaxDx.clamp(-1.0, 1.0).toDouble(),
      parallaxDy.clamp(-1.0, 1.0).toDouble(),
      // 3 depth0..3
      d[0], d[1], d[2], d[3],
      // 7 breathing
      breathing ? 1.0 : 0.0,
      zoom.clamp(0.0, 0.5).toDouble(),
      phase.clamp(0.0, 1.0).toDouble(),
      // 10 sweep
      sweep ? 1.0 : 0.0,
      sweepPosition.clamp(-0.5, 1.5).toDouble(),
      sweepWidth.clamp(1e-4, 0.5).toDouble(),
      sweepIntensity.clamp(0.0, 1.0).toDouble(),
      // 14 vignette
      vignette ? 1.0 : 0.0,
      vignetteStrength.clamp(0.0, 1.0).toDouble(),
      vignetteSoftness.clamp(0.0, 1.0).toDouble(),
      // 17 canvas size（非正按 1）
      canvasWidth > 0 ? canvasWidth : 1.0,
      canvasHeight > 0 ? canvasHeight : 1.0,
      // 19 camera（M3 主线化）
      cameraOn ? 1.0 : 0.0,
      cameraDrift ? 1.0 : 0.0,
      cameraAnchorX.clamp(0.0, 1.0).toDouble(),
      cameraAnchorY.clamp(0.0, 1.0).toDouble(),
      cameraZoomSpan.clamp(0.0, 0.5).toDouble(),
      cameraDriftAmp.clamp(0.0, 0.25).toDouble(),
      cameraPhase.clamp(0.0, 1.0).toDouble(),
      // 26 focus（G-3 焦点升档）
      focusOn ? 1.0 : 0.0,
      focusOn ? focusScaleMul.clamp(1.0, 4.0).toDouble() : 1.0,
    ]);
  }

  List<double> _fixedDepth() {
    final out = List<double>.filled(kMaxLayers, 0.0);
    for (var i = 0; i < kMaxLayers && i < depth.length; i++) {
      out[i] = depth[i].clamp(0.0, 1.0).toDouble();
    }
    return out;
  }
}

/// 扫光位置的时钟映射：中心从 -halfWidth 滑到 1+halfWidth，
/// 光带完整穿场后循环（宿主 Ticker elapsed → uniform uSweepPos）。
double sweepPositionFor({
  required Duration elapsed,
  required Duration period,
  required double halfWidth,
}) {
  final t = period.inMicroseconds <= 0
      ? 0.0
      : (elapsed.inMicroseconds % period.inMicroseconds) /
          period.inMicroseconds;
  final half = halfWidth.clamp(1e-4, 0.5).toDouble();
  return -half + t * (1.0 + 2 * half);
}

/// 镜头相位（M3）：整周期对齐（`MotionMath.cycleCount` 同款口径）——
/// `t = durationSec` 时相位精确回到 0（无缝契约延续到镜头维度）；
/// [tempoMul] 为焦点升档的节奏乘数（G-3：>1 加快，整数周期口径不破）。
double cameraPhaseFor({
  required double tSec,
  required double durationSec,
  required double periodSec,
  double tempoMul = 1.0,
}) {
  if (durationSec <= 0 || periodSec <= 0) return 0.0;
  final raw = durationSec / periodSec;
  final n = raw.round();
  final cycles = (n < 1 ? 1 : n) * (tempoMul <= 0 ? 1.0 : tempoMul);
  final u = tSec * cycles / durationSec;
  return u - u.floorToDouble();
}

/// pack 程序（core `MotionProgram`）→ camera/focus uniform 块（M3 主线
/// 接线：`program.json` 与 shader 消费同一份数据）。camera.type == none
/// 返回 cameraOn=false（uniform 恒等，既有渲染路径零变化）；[tSec] 为
/// 页内时刻，[durationSec] 为配置时长，[focused] 为阅读器聚焦态（G-3
/// 焦点升档取程序内的 focus 乘数）。
MotionUniforms withPackProgram(
  MotionUniforms base,
  MotionProgram program, {
  required double tSec,
  required double durationSec,
  bool focused = false,
}) {
  final cam = program.camera;
  final focus = focused && cam.type != CameraType.none ? program.focus : null;
  return MotionUniforms(
    parallax: base.parallax,
    parallaxDx: base.parallaxDx,
    parallaxDy: base.parallaxDy,
    depth: base.depth,
    breathing: base.breathing,
    zoom: base.zoom,
    phase: base.phase,
    sweep: base.sweep,
    sweepPosition: base.sweepPosition,
    sweepWidth: base.sweepWidth,
    sweepIntensity: base.sweepIntensity,
    vignette: base.vignette,
    vignetteStrength: base.vignetteStrength,
    vignetteSoftness: base.vignetteSoftness,
    canvasWidth: base.canvasWidth,
    canvasHeight: base.canvasHeight,
    cameraOn: cam.type != CameraType.none,
    cameraDrift: cam.type == CameraType.drift,
    cameraAnchorX: cam.anchorX,
    cameraAnchorY: cam.anchorY,
    cameraZoomSpan:
        cam.type == CameraType.pushIn ? (cam.zoom1 - cam.zoom0) : 0.0,
    cameraDriftAmp: cam.type == CameraType.drift ? cam.driftAmp : 0.0,
    cameraPhase: cam.type == CameraType.none
        ? 0.0
        : cameraPhaseFor(
            tSec: tSec,
            durationSec: durationSec,
            periodSec: cam.periodSec,
            tempoMul: focus?.tempoMul ?? 1.0,
          ),
    focusOn: focus != null,
    focusScaleMul: focus?.scaleMul ?? 1.0,
  );
}
