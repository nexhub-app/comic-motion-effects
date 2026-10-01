/// Program-readable render parameter catalog (R5).
///
/// 供嵌入 App 动态生成设置面板：名称 / 类型 / 取值范围 / 默认值 / 语义全部
/// 程序可读，范围不必在 App 侧硬编码。本文件为纯 Dart（无 dart:io），序列
/// 化层可在任意平台使用。
///
/// 覆盖范围：CLI 通用参数表里的全部渲染参数（fps / duration / maxDimension /
/// layers / seed / quality / dither / format / amplitude / direction）+ 效果
/// 列表本身。`parallel` / `memoryBudgetMb` 属于执行期参数（在
/// [MotionPipeline] 上，不进 configHash），见 pipeline.dart 文档。
library;

import 'effect_config.dart';
import 'render/quality.dart';

/// 单个渲染参数的描述。
class ParamSpec {
  const ParamSpec({
    required this.name,
    required this.type,
    this.enumValues,
    this.min,
    this.max,
    required this.strictRange,
    required this.defaultValue,
    this.mapsTo,
    required this.description,
  });

  /// 参数名，与 [EffectConfig] 构造参数同名。
  final String name;

  /// `'int'` | `'double'` | `'bool'` | `'enum'` | `'effectList'`。
  final String type;

  /// type 为 `'enum'` 时的合法取值（名称形式）。
  final List<String>? enumValues;

  /// 建议取值下界（含）。
  final num? min;

  /// 建议取值上界（含）。
  final num? max;

  /// true = 越界在 [EffectConfig] 构造时 fail-fast 抛 [ConfigException]
  /// （code `E_BAD_CONFIG`）；false = 建议范围，越界由渲染通路按既有语义
  /// 静默 clamp（改值不抛错）。
  final bool strictRange;

  /// 默认值（枚举为枚举实例；effectList 为效果名字符串列表）。
  final Object? defaultValue;

  /// 顶层便捷参数映射到的既有嵌套字段（如 `quality.dither`）；本就直接
  /// 位于顶层的参数为 null。
  final String? mapsTo;

  final String description;
}

/// 渲染参数目录。顺序即建议的设置面板展示顺序。
const List<ParamSpec> kRenderParamSpecs = [
  ParamSpec(
    name: 'fps',
    type: 'int',
    min: 1,
    strictRange: true,
    defaultValue: 24,
    description: '动画帧率；总帧数 = (fps × durationSec).round()，钳制到 '
        '[2, maxFrames]',
  ),
  ParamSpec(
    name: 'durationSec',
    type: 'double',
    min: 0,
    strictRange: true,
    defaultValue: 4.0,
    description: '动画时长（秒），必须 > 0；GIF 单循环无缝',
  ),
  ParamSpec(
    name: 'maxDimension',
    type: 'int',
    min: 1,
    strictRange: true,
    defaultValue: 1600,
    description: '工作分辨率上限（最长边像素）；峰值内存随工作像素线性增长，'
        '移动端建议 ≤ 1280',
  ),
  ParamSpec(
    name: 'layerCount',
    type: 'int',
    min: 1,
    max: 8,
    strictRange: true,
    defaultValue: 3,
    description: '景深层层数；层数越多视差越细腻、内存与耗时越高',
  ),
  ParamSpec(
    name: 'maxFrames',
    type: 'int',
    min: 2,
    strictRange: true,
    defaultValue: 96,
    description: '总帧数硬上限（帧数钳制上界）',
  ),
  ParamSpec(
    name: 'seed',
    type: 'int',
    strictRange: false,
    defaultValue: 20260914,
    description: '确定性随机种子；同 seed + 同参数输出逐字节一致',
  ),
  ParamSpec(
    name: 'dither',
    type: 'bool',
    strictRange: false,
    defaultValue: false,
    mapsTo: 'quality.dither',
    description: 'GIF 256 色误差扩散抖动，显著减轻渐变色带；关闭回退最近色'
        '（v1.1 行为）',
  ),
  ParamSpec(
    name: 'qualityTier',
    type: 'enum',
    enumValues: ['legacy', 'standard', 'rich'],
    strictRange: false,
    defaultValue: RenderTier.legacy,
    mapsTo: 'quality.tier',
    description: '渲染档位：legacy 逐字节复现 v1.2（回滚载体）；standard '
        '抗锯齿 + 面积平均重采样；rich 目前与 standard 等价',
  ),
  ParamSpec(
    name: 'diffMode',
    type: 'enum',
    enumValues: ['none', 'rect'],
    strictRange: false,
    defaultValue: 'none',
    mapsTo: 'encoding.diffMode',
    description: 'GIF 帧间差分：none 每帧全画布编码（v1.3 行为）；rect '
        '相邻帧只编码变化矩形，移动端体积收益大（条漫画尤甚）',
  ),
  ParamSpec(
    name: 'outputFormat',
    type: 'enum',
    enumValues: ['gif', 'frames', 'both'],
    strictRange: true,
    defaultValue: OutputFormat.both,
    description: '产物形态：gif / PNG 帧序列 / 两者；内存模式不落帧序列',
  ),
  ParamSpec(
    name: 'amplitude',
    type: 'double',
    min: 0,
    max: 0.1,
    strictRange: false,
    defaultValue: 0.030,
    mapsTo: 'parallax.amplitude',
    description: '视差最大位移幅度（占图宽比例）；越界由渲染 clamp',
  ),
  ParamSpec(
    name: 'directionDeg',
    type: 'double',
    min: -360,
    max: 360,
    strictRange: false,
    defaultValue: 0.0,
    mapsTo: 'parallax.directionDeg',
    description: '视差主扫方向（度，屏幕坐标系顺时针）；越界由渲染 clamp',
  ),
  ParamSpec(
    name: 'effects',
    type: 'effectList',
    strictRange: false,
    defaultValue: ['parallax', 'breathing', 'ambient'],
    description: '启用的动效列表，取值为 EffectKind.values 的 name（32 种），'
        '可任意开闭组合；全空 = 静帧',
  ),
];

/// 效果名字目录（= [EffectKind.values] 的名称），供面板生成多选控件。
List<String> get kEffectNames => EffectKind.values.map((e) => e.name).toList();

/// 单个效果的预览资产引用（第五轮 W2）。
///
/// 路径相对核心包仓库根（`comic_motion/`），指向 `doc/previews/<demo>/`
/// 下的「所见即所得」预览（首帧 PNG + 360p 低配短循环 GIF）。该目录由
/// `tool/generate_showcase.dart` 单一真相源生成并随仓库提交；本表为
/// **效果名 → 演示目录** 的交叉引用，App 面板据此自动配图。
class EffectPreviewRef {
  const EffectPreviewRef({
    required this.effect,
    required this.demoKey,
    required this.category,
  });

  /// 效果名（= [EffectKind] 的 name / [kEffectNames] 的元素）。
  final String effect;

  /// 演示目录名：`doc/previews/<demoKey>/{preview.png, preview.gif}`。
  final String demoKey;

  /// 面板分组（base/weather/light/manga/motion/color/atmosphere/mood/
  /// combo/quality/ambient）。
  final String category;

  /// 首帧 PNG 路径（仓库相对，`comic_motion/` 为根）。
  String get previewPng => 'doc/previews/$demoKey/preview.png';

  /// 低配短循环 GIF 路径（仓库相对）。
  String get previewGif => 'doc/previews/$demoKey/preview.gif';
}

/// 效果 → 预览资产交叉引用（顺序与面板展示建议一致）。
///
/// 说明：
/// - `dust` 是 legacy 别名（渲染走 ambient 粒子通路），与 `ambient` 共用
///   `dust_motes` 演示；
/// - `parallax` / `breathing` 是所有演示的底座，用 `classic_base`
///   （纯底座）作代表预览。
const List<EffectPreviewRef> kEffectPreviewRefs = [
  EffectPreviewRef(effect: 'parallax', demoKey: 'classic_base', category: 'base'),
  EffectPreviewRef(effect: 'breathing', demoKey: 'classic_base', category: 'base'),
  EffectPreviewRef(effect: 'ambient', demoKey: 'dust_motes', category: 'ambient'),
  EffectPreviewRef(effect: 'dust', demoKey: 'dust_motes', category: 'ambient'),
  EffectPreviewRef(effect: 'lightSweep', demoKey: 'light_sweep_hall', category: 'light'),
  EffectPreviewRef(effect: 'rain', demoKey: 'rain_night_city', category: 'weather'),
  EffectPreviewRef(effect: 'snow', demoKey: 'snow_landscape', category: 'weather'),
  EffectPreviewRef(effect: 'sakura', demoKey: 'sakura_portrait', category: 'weather'),
  EffectPreviewRef(effect: 'fireflies', demoKey: 'fireflies_forest', category: 'weather'),
  EffectPreviewRef(effect: 'godRays', demoKey: 'godrays_forest', category: 'light'),
  EffectPreviewRef(effect: 'speedLines', demoKey: 'speedlines_action', category: 'manga'),
  EffectPreviewRef(effect: 'impactFlash', demoKey: 'impact_duel', category: 'manga'),
  EffectPreviewRef(effect: 'heartbeat', demoKey: 'heartbeat_closeup', category: 'motion'),
  EffectPreviewRef(effect: 'fog', demoKey: 'fog_landscape', category: 'atmosphere'),
  EffectPreviewRef(effect: 'embers', demoKey: 'embers_night_city', category: 'atmosphere'),
  EffectPreviewRef(effect: 'lightning', demoKey: 'lightning_night_city', category: 'weather'),
  EffectPreviewRef(effect: 'toneShift', demoKey: 'toneshift_landscape', category: 'color'),
  EffectPreviewRef(effect: 'vignette', demoKey: 'vignette_closeup', category: 'color'),
  EffectPreviewRef(effect: 'starlight', demoKey: 'starlight_night_city', category: 'light'),
  EffectPreviewRef(effect: 'slowPush', demoKey: 'slowpush_portrait', category: 'motion'),
  EffectPreviewRef(effect: 'shimmer', demoKey: 'shimmer_landscape', category: 'light'),
  EffectPreviewRef(effect: 'focusLines', demoKey: 'focus_lines_action', category: 'manga'),
  EffectPreviewRef(effect: 'screenTone', demoKey: 'screen_tone_closeup', category: 'manga'),
  EffectPreviewRef(effect: 'mangaShake', demoKey: 'manga_shake_impact', category: 'manga'),
  EffectPreviewRef(effect: 'impactRings', demoKey: 'impact_burst', category: 'manga'),
  EffectPreviewRef(effect: 'brushStreak', demoKey: 'brush_streak_run', category: 'manga'),
  EffectPreviewRef(effect: 'flame', demoKey: 'flame_campfire', category: 'atmosphere'),
  EffectPreviewRef(effect: 'smoke', demoKey: 'smoke_indoor', category: 'atmosphere'),
  EffectPreviewRef(effect: 'bubbles', demoKey: 'bubbles_underwater', category: 'atmosphere'),
  EffectPreviewRef(effect: 'leaves', demoKey: 'leaves_autumn', category: 'weather'),
  EffectPreviewRef(effect: 'meteors', demoKey: 'meteors_night', category: 'weather'),
  EffectPreviewRef(effect: 'moodScript', demoKey: 'mood_tension_build', category: 'mood'),
];
