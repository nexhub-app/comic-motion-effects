# comic_motion

[![CI](https://github.com/nexhub-app/comic-motion-effects/actions/workflows/ci.yml/badge.svg)](https://github.com/nexhub-app/comic-motion-effects/actions/workflows/ci.yml)

纯 Dart 实现的漫画图片动效引擎。对静态漫画图做**深度分层拆解**，合成鸿蒙阅读风格的 **2.5D 视差 + 呼吸感 + 氛围粒子** 动效，输出 GIF 动图与 PNG 帧序列。

- 纯 Dart，无原生依赖，UI-free，可嵌入任意 Dart / Flutter 工程；运行时只依赖 `image` 一个包
- 同参数输出字节级可复现（确定性随机种子 + configHash）
- 32 种可组合动效 + 38 个内置预设参数
- 帧渲染多 isolate 并行：只影响耗时，不影响输出字节

CLI（单图 / 批处理）与 HTTP API 服务在姊妹包 **[comic_motion_server](../comic_motion_server)**，二者与本包解耦：只想嵌引擎的 App 不会引入任何 HTTP 服务栈。

## 环境要求

| 项 | 要求 |
|---|---|
| Dart SDK | ≥ 3.4.0 |
| 操作系统 | Windows / Linux / macOS（纯 Dart） |
| 网络 | 仅 `dart pub get` 时需要 |

## 作为库嵌入 Flutter 工程

### 引入方式

pub.dev（推荐）：

```yaml
dependencies:
  comic_motion: ^1.3.0
```

git 直连：

```yaml
dependencies:
  comic_motion:
    git:
      url: https://github.com/nexhub-app/comic-motion-effects.git
      path: comic_motion
```

```dart
import 'package:comic_motion/comic_motion.dart';

final result = await MotionPipeline(EffectConfig(fps: 12), parallel: 4)
    .processFile(input, outDir);
```

`processFile` 是异步的（并行度 >1 时跨 isolate），必须 `await`。管线构造参数 `parallel` 为执行期参数，不进入 `EffectConfig`，因此不影响 configHash 与输出字节。

### ⚠️ 线程模型：不要在 UI isolate 上渲染

`processFile` / `processBytes` 虽是 `async`，但**解码 → 降采样 → 深度估算 → 分层 → 调色板探针**各段同步跑在调用方 isolate 上（只有后续帧渲染派发 worker 池）。在 UI isolate 直接调用会卡住 UI 数百毫秒到秒级。两种解法：

1. **用后台入口（推荐）**——整条管线（含解码）在后台 isolate 执行，进度与取消自动桥接回调用方：

   ```dart
   final token = MotionCancelToken();
   final result = await processFileInBackground(
     inputPath, outDir,
     config: EffectConfig(fps: 12, durationSec: 2.5, maxDimension: 800),
     parallel: 4,
     memoryBudgetMb: 256,
     cancelToken: token,
     onProgress: (done, total) => debugPrint('$done/$total'),
     timeout: const Duration(seconds: 30),
   );
   // 用户中途翻页离开：
   token.cancel(); // 在下一帧边界停止派发，抛 E_CANCELLED
   ```

   `processBytesInBackground({required Uint8List input, ...})` 是它的内存孪生：bytes 进 bytes 出，无临时文件；返回的 GIF 字节与落盘产物逐字节一致。

2. **自行包装**：`Isolate.run(() => MotionPipeline(cfg).processFile(in, out))`——适合即发即忘的调用，但进度与取消无法跨过这层 isolate 边界。

取消/超时语义（同步与后台入口一致）：检查点全部位于帧调度层（派发前 / 每帧回包 / 探针渲染前）——worker 内部进行中的单帧渲染不会被强行打断（帧是纯函数，结果自然丢弃），粒度为一个帧边界。取消的运行默认删除本次写出的半成品（`keepPartial: true` 保留）并抛 `MotionCancelledException`：调用方取消 code 为 `E_CANCELLED`，超过 `timeout` deadline 走同一路径、code 为 `E_TIMEOUT`（deadline 在相同检查点比对）。进度计数含探针帧，取消/超时后不再回调。

### 并发：移动端同一时刻只跑一个渲染任务

单条管线峰值内存 300~600MB（见性能基准）。两条管线并发就是直接叠加，移动端会 OOM。移动端 App 应保证**同一时刻只跑一个渲染任务**——排队而不是叠着跑。可选用 `MotionPipelineGuard`（进程级信号量，纯 opt-in，库本身不做任何强制）：

```dart
await MotionPipelineGuard.run(() =>
    MotionPipeline(config).processFile(input, outDir)); // 忙时自动排队
```

body 抛任何异常（包括取消的 `MotionCancelledException`）都会先释放槽位再重抛。桌面批处理可显式调大 `maxConcurrent`。

### 一站式渲染参数与效果选择

CLI 能调的全部渲染参数都是 [EffectConfig] 构造的一等参数——不必再理解嵌套对象：

```dart
final config = EffectConfig(
  fps: 12, durationSec: 2.5, maxDimension: 800,   // 时长 / 分辨率
  layerCount: 3, seed: 42, outputFormat: OutputFormat.gif,
  dither: true, qualityTier: RenderTier.standard, // → quality.dither / quality.tier
  amplitude: 0.02, directionDeg: 45,              // → parallax.amplitude / directionDeg
  effects: [EffectKind.rain],
).withoutEffect(EffectKind.fog).withEffect(EffectKind.snow); // 不可变链式
```

- 便捷参数（`dither` / `qualityTier` / `amplitude` / `directionDeg`）为可空命名参数，非空时映射到既有嵌套字段——与显式构造嵌套对象**序列化与 configHash 逐字节一致**（等价性矩阵有测试）；默认值路径的指纹完全不变。
- 效果选择（`withEffect` / `withoutEffect` / `withEffects` / `clearEffects`）一律返回**新实例**，原 config 绝不修改；全关 = 静帧。
- 参数目录（供 App 自动生成设置面板）：`kRenderParamSpecs`（名称 / 类型 / min / max / 默认值 / 语义，并标注哪些范围是 fail-fast）与 `kEffectNames`——App 侧范围不硬编码。
- 持久化推荐：直接存 `config.toJsonString()`，用 `EffectConfig.fromJson` 读回即恢复——hash 往返一致，可直接当缓存键。

### 条漫 strip 模式

条漫长图（如 800 × 10000+）直接渲染会被 `maxDimension` 降采样毁掉细节、超出边长上限直接被拒，且 parallax 类效果跨分格错位。`processStrip` 按视口比例（默认 9:16，可选重叠）切片，每片走标准管线独立渲染：

```dart
final strip = await processStrip(
  inputPath, outDir,
  config: EffectConfig(
      fps: 12, durationSec: 2, maxDimension: 800,
      effects: [EffectKind.rain, EffectKind.vignette]),
  viewportWidth: 9, viewportHeight: 16,
  overlapPx: 0, // 裁剪语义：相邻片共享恰好 N 行，不做混合
);
for (final s in strip.slices) {
  print(s.slice.yStart);      // 源图行窗口
  print(s.result.outputGif);  // `<stem>_slice<NNN>_<contentHash8>_<configHash8>/anim.gif`
}
```

- 每片独立目录 `<stem>_slice<NNN>_<contentHash8>_<configHash8>`，独立 configHash + 片级内容指纹 + params.json——确定性复现，天然可缓存去重。
- `kStripSafeEffects` 是跨片安全的叠加类效果集；白名单外效果（parallax/breathing/slowPush/mangaShake 等）允许使用，但会在 `strip.warnings` 提示实验性（每片独立做深度估算，跨片可能错位）。
- 整话像素总量上限（默认 40M 像素）在切片前的解码阶段强制执行；超限抛 `E_TOO_LARGE` 并提示使用 strip 模式。超大单话可显式调大 `maxPixels`——每片工作栅格始终很小，不受整话高度影响。

### 平台支持矩阵

| 平台 | 状态 | 说明 |
|---|---|---|
| Android / iOS | ✅ 首要目标 | 纯 Dart + isolate，无原生插件、无 UI 依赖 |
| Windows / macOS / Linux 桌面 | ✅ | 与 CLI / 服务端同源 |
| Web | 🚫 不支持 | 核心模块（`image_io` / `pipeline` / `worker_pool`）依赖 `dart:io`，且 `Isolate.spawn` 在 Flutter Web 不可用；远期若移植需换 web 解码 API 与 web worker——仅为方向，不做实现承诺 |

### 产物命名与内容指纹

产物目录按 `<stem>_<contentHash8>_<configHash8>` 命名（strip 模式为
`<stem>_slice<NNN>_<contentHash8>_<configHash8>`）。两个 hash 是正交的两个维度：

- `configHash8` —— 参数指纹字符串的前 8 位。同配置必同值；FNV-1a 结果最高
  位置位时该段带前导 `-`（configHash 是有符号整数的十六进制串，稳定且
  按字面携带）。
- `contentHash8` —— **输入字节** FNV-1a 64 指纹的前 8 位（`processImage`
  无原始文件字节，取传入栅格 RGBA 字节计算，同样确定）。内容指纹不进
  `EffectConfig` 序列化，也不参与 configHash。

内容指纹解决的是：同名文件被重新下载 / 覆盖后，产物落**新目录**——嵌入方
「目录存在 → 跳过渲染」的缓存逻辑不会再命中旧画面。注意这是对命名契约的
**BREAKING 变更**（1.3.1 之前为 `<stem>_<configHash8>`）：旧产物目录不被
新布局识别，需 App 侧自行清理（对缓存根目录做一次性删除是安全的——里面
只会有引擎产物）。

### 缓存管理

上面的命名契约是库自己定义的——清理工具也由库提供（`MotionCacheManager`，
`cache_manager.dart`）：

```dart
final cache = MotionCacheManager(cacheRootDir);

for (final e in cache.listEntries()) {
  print('${e.stem} slice=${e.sliceIndex} ${e.byteSize}B ${e.modifiedAt}');
}
print(cache.totalSize());

// LRU 淘汰：先删 30 天前的旧条目，再在 200 条 / 512MB 预算内从旧到新淘汰。
// 三个条件可任意组合。
final report = cache.purgeLRU(
    olderThan: const Duration(days: 30),
    maxEntries: 200,
    maxBytes: 512 << 20);
print(report); // 清理明细（条目 + 释放字节）

cache.purgePrefix('chapter_0042'); // 清某一话：含全部片级条目
cache.purgeAll();
```

`purge*` 只删除**完整匹配库命名契约**的目录；无法识别的文件与目录（App
自己的东西）一律跳过、绝不触碰。条漫画一话可产出几十个片级 GIF——长期
运行的 App 请按周期做 `purgeLRU`。

### 静帧与首帧封面

App 常常在动画加载完成前（或干脆代替动画）需要一张封面帧。两种方式，成本都只是一帧：

```dart
final config = EffectConfig(fps: 12, durationSec: 2.5, maxDimension: 800);

// 1) 独立静帧：单次渲染 t 时刻（默认 0），PNG bytes 出。
//    完全跳过 GIF 编码与调色板探针。
final png = await MotionPipeline(config, cancelToken: token, timeout: limit)
    .renderStillFrame(input: bytes);            // bytes 进
final png2 = await MotionPipeline(config).renderStillFrameFile(path); // 路径进
// 全量渲染的第 i 帧对应 t = i / fps；t = 0 即首帧。

// 2) 搭全量渲染的车：免费附带首帧——它本来就是管线要渲的调色板探针帧。
final result = await MotionPipeline(config)
    .processFile(input, outDir, includeFirstFrame: true);
final cover = result.firstFramePng;             // 未请求时为 null
```

`renderStillFrame` 与全量渲染共享解码 → 降采样 → 分层主干，t=0 静帧与 GIF
首帧是同一渲染帧（GIF 里的副本经调色板量化）。受 `cancelToken` / `timeout`
管控（入口与渲染前各检查一次）；`parallel` / `memoryBudgetMb` 与静帧无关
（无 worker 池）。`includeFirstFrame` 在 `processFile` / `processBytes` /
`processImage` 与后台入口均可用；返回字节与落盘的
`frames/frame_0000.png` 完全一致。

### 帧流回调（渐进预览）

`MotionPipeline.onFrame` 在管线运行中把每一帧以 PNG 字节交付出来——可做
渐进预览、缩略图条，或把帧流送去别处，不必等 GIF：

```dart
final result = await MotionPipeline(config, parallel: 2, onFrame: (index, png) {
  // 按帧号有序，一帧恰好一次（含探针帧）；
  // PNG 字节与落盘 frames/frame_NNNN.png 同源同字节
  previewWidget.update(index, png);
}).processFile(input, outDir);
```

回调执行位置：**在执行管线的 isolate 上**——同步入口即在调用方 isolate
（回包点是同步执行段，回调里做重活会直接拖慢渲染）；后台便捷入口
（`processFileInBackground` / `processBytesInBackground`）经 `SendPort`
桥接，用户回调执行在调用方 isolate（与 `onProgress` 一致）。仅设置
`onFrame` 时才会逐帧编码并回传 PNG（不设置零额外成本）。回调与
`onProgress` 并存；取消 / 超时后不再回调（与其他检查点同一语义）。

### GIF 帧间差分（opt-in，移动端体积）

默认 `encoding.diffMode: none` 每帧全画布 LZW 编码，属于逐字节复现契约的
一部分。条漫画一话可达数百 MB 是移动端存储 / 流量的最大痛点，因此
`diffMode: rect` 把每帧重编码为「相对前一帧的变化矩形」——首帧仍全画布，
帧声明 do-not-dispose 供标准解码器跨帧合成，完全静止的节拍以 1×1 占位帧
保住时序。差分在量化后调色板索引层面进行；dither / sierra 的误差扩散逐帧
独立，确定性保持：

```dart
final config = EffectConfig(
  fps: 12, durationSec: 2, maxDimension: 800,
  effects: [EffectKind.rain, EffectKind.vignette],
  encoding: EncodingParams(diffMode: 'rect'),
);
```

strip 模式每片都走标准管线，片内帧差分自动受益。条漫画类内容 GIF 体积
大致可缩到原来的 1/2～1/5（请以自己的素材实测）；解码结果与 `none`
逐像素一致——有测试用规范合成器锁定。

### 移动端推荐参数

| 参数 | 推荐 | 原因 |
|---|---|---|
| `maxDimension` | ≤ 1280 | 峰值内存与工作分辨率像素总量线性相关 |
| `fps` / `durationSec` | 12 / 2-3 秒 | 帧数 = fps × duration，直接决定编码耗时与内存驻留 |
| `parallel` | 2-4 | 每个 worker 持一整套层栅格副本，内存随并行线性涨 |
| `memoryBudgetMb` | 按设备档位（如 256 / 512） | 超预算自动降并行、再降工作分辨率，降级写入 `warnings` |

### 内存预算 API

```dart
final result = await MotionPipeline(
  EffectConfig(fps: 12, durationSec: 2.5, maxDimension: 1280),
  parallel: 4,
  memoryBudgetMb: 256, // 执行期参数：不进 EffectConfig、不影响 configHash
).processFile(input, outDir);
for (final w in result.warnings) {
  debugPrint(w); // 预算触发的降级（降并行 / 降工作分辨率）都记在这里
}
```

预算模型是保守启发式（按实际像素 × 层数 + 安全系数估算）：宁可提前降级也不 OOM。工作分辨率被预算收缩时产物像素随之改变——与无预算运行不逐字节一致，但同预算 + 同输入仍确定性复现；`memoryBudgetMb` 不传时路径零改动，legacy 档逐字节契约不受影响。

### GIF 播放消费指引（Flutter）

引擎保持 UI-free：只交付 GIF 文件 / 字节，怎么*播放*由 App 决定。本节是给嵌入方的实践参考，不是 API，也不给库引入任何 UI 依赖。

**播放组件选型**（三者最终都走同一个 `dart:ui` 解码器——按控制能力选，不是按画质选）：

| 选项 | 擅长 | 注意 |
|---|---|---|
| 内建 `Image`（`Image.file` / `Image.memory` / `Image.network`） | 零额外依赖；动态 GIF 开箱即播、自动循环 | 无播放控制——不能暂停 / 恢复 / 跳帧；「暂停」= 把组件换成静帧 |
| `extended_image`（第三方） | `GifImage` 支持 `autoPlay`、暂停 / 恢复、逐帧控制 | 多一个依赖；底层同一个解码器，解码内存不变 |
| `dart:ui` 的 `instantiateImageCodec`（自管） | 帧时序与缓存完全可控 | 解码循环、帧缓存、dispose 生命周期都要自己管 |

**解码内存。** 播放中的 GIF 保有存活解码器与至少一帧解码后的 RGBA 位图（`宽 × 高 × 4` 字节）；同屏多个播放中的 GIF 按个数线性叠加。杠杆按收益排序：

- 渲染端就省：`frameCount = fps × durationSec` 与 `maxDimension` 决定产物大小——480p/12fps/2s 的 GIF 无论显示还是存储都比 1280p/24fps/4s 便宜得多。
- 按显示尺寸解码：传 `cacheWidth` / `cacheHeight`，400px 卡片里的 GIF 按 400px 解码，不按原始尺寸。
- 控制同屏播放个数（1–3）：逐帧解码是周期性 CPU 消耗，移动端折算成电量与发热。

**列表页（信息流 / 章节网格）。** 引擎的 GIF 整循环无缝（首帧 == 尾帧），天然适合拿一帧当封面：

- 用 `outputFormat: OutputFormat.both` 渲染，取 `result.frameDir/frame_0000.png` 作封面 / 占位，在加载完成前（或代替播放）展示；内存模式（`processBytes`）没有帧 PNG——要么客户端解 GIF 首帧，要么封面场景走落盘模式。
- 转场落地前对首屏 GIF 用 `precacheImage` 预热；保持列表虚拟化让离屏项释放解码器，或在滚出视口时把播放中的 GIF 换回封面帧（`extended_image` 可以直接暂停）。
- 尊重系统「减弱动态」（Flutter 侧 `MediaQuery.disableAnimations`）：展示封面帧；渲染端对应的 `reducedMotion` 选项可产出单帧产物。

### 从源码跑通引擎（本仓库开发者）

```bash
git clone https://github.com/nexhub-app/comic-motion-effects.git
cd comic-motion-effects/comic_motion
dart pub get
dart run tool/generate_samples.dart     # 生成 10 张占位样图（sample_images/）
dart run tool/smoke_test.dart           # 单张图 → GIF + 帧序列（约 2-4 秒）
```

输出位于 `build/smoke/01_portrait_<contentHash8>_<configHash8>/`：

```
anim.gif                    # 动图成品
frames/frame_0000.png ...   # 逐帧 PNG
params.json                 # 完整参数回放文件
```

## 输入格式矩阵

解码委托给纯 Dart 的 `image` 包（行为由测试钉住：下方 Animated WebP 契约有专门的测试用例，依赖升级导致行为漂移时会在 CI 首先暴露）：

| 格式 | 状态 | 行为 |
|---|---|---|
| JPEG | ✅ 支持 | 基础解码通路 |
| PNG | ✅ 支持 | 基础解码通路 |
| WebP（静态，VP8 有损） | ✅ 支持 | 完整解码通路 |
| WebP（静态，VP8L 无损） | ✅ 支持 | 完整解码通路 |
| WebP（扩展头 VP8X） | ✅ 支持 | 画布尺寸感知 |
| **WebP（动态）** | ⚠️ **仅取首帧** | 解码成功；引擎以第 0 帧渲染，其余动画帧丢弃（`image` 4.10.1 实测——动画本身不会被播放） |
| **GIF（含动态）** | ⚠️ **仅取首帧** | 同样解码成功（`image` 包自带 GIF 解码器）；引擎以解码出的首帧渲染，动画帧丢弃 |
| AVIF / HEIF | 🚫 不支持 | 以 `E_DECODE_CORRUPT` 拒绝；请先转码为 PNG / JPEG / WebP |

损坏 / 伪装文件的错误路径：

| 输入 | 错误码 |
|---|---|
| 0 字节文件 / 空 bytes | `E_DECODE_EMPTY` |
| 文件不存在（路径输入） | `E_DECODE_NOT_FOUND` |
| 伪装成图片的文本文件 | `E_DECODE_CORRUPT` |
| 码流损坏或截断 | `E_DECODE_CORRUPT` |
| 头部声明尺寸超像素预算 | `E_TOO_LARGE`（在分配栅格**之前**拒绝——像素炸弹不产生分配） |
| 条漫形态的超限拒绝（高 > 2 × 宽） | `E_TOO_LARGE` + 消息提示改用 strip 模式（`processStrip`） |

## 渲染档位（quality）

| 档 | 内容 | 用途 |
|---|---|---|
| `legacy`（默认） | v1.2 的绘制与编码路径 | 与历史输出**逐字节一致**，回滚承诺的载体 |
| `standard` | 抗锯齿光栅原语、面积平均 / Catmull-Rom 重采样、screen 光照混合、深度平滑上采样 + 掩码羽化、层边缘外扩、GIF 量化 LUT（抖动核可选 sierra） | 日常出图 |
| `rich` | **当前与 `standard` 渲染结果逐字节一致**——预留的 `supersample` / `mipLevels` 尚无消费方（已知偏差） | 已废弃：请用 `standard`；JSON 的 `"tier": "rich"` 仍按本档解析（废弃 ≠ 移除） |

档位只改像素路径，不改动效列表；`legacy` 档与 `presets/classic.json` 是两个独立维度的收回开关。`sierra` 抖动核需要 `dither: true` + `quality.ditherMode: "sierra"` + 非 legacy 档三者同时成立。

## 复现承诺与边界

同 seed + 同参数输出**逐字节一致**；`legacy` 档与 v1.2 输出逐字节一致（回滚承诺）。该承诺有明确边界：

- **依赖版本**：GIF/PNG 编码由 `image` 包承担，字节级复现以 `pubspec.lock` 锁定的 `image` 版本区间为准。下游 `pub upgrade` 若跨入不同编码器实现（调色板/压缩参数变化），输出字节可能改变——对复现敏感的应用请把 `pubspec.lock` 一并纳入版本管理。
- **configHash 版本化**：configHash 是参数指纹（当前 v1 算法），与 `version` 字段一同写入 `params.json`。未来若 hash 算法或字段序列化变更，将带版本前缀迁移——读取旧 `version` 的回放文件按旧算法口径处理，不静默失效。
- **执行期参数不在承诺内**：`parallel`、`memoryBudgetMb` 不进 configHash、不影响像素决策（`parallel`），但 `memoryBudgetMb` 收缩工作分辨率时会改变输出像素（见「内存预算 API」）——此时「同参数」以实际生效的工作分辨率为准。

## 动效目录（32 种）

`EffectConfig.effects` 可任意组合，全部整循环无缝（首尾帧一致）：

| 类别 | 效果 |
|---|---|
| 核心三件套（默认开启） | `parallax` 2.5D 视差 · `breathing` 呼吸缩放 · `ambient` 氛围粒子上浮 |
| 天气氛围 | `rain` 雨丝 · `snow` 飘雪 · `fog` 雾气 · `sakura` 樱吹雪 · `embers` 火星 |
| 光影氛围 | `fireflies` 萤火 · `godRays` 丁达尔光束 · `starlight` 星光 · `lightning` 闪电 · `shimmer` 波光 |
| 动势强调 | `speedLines` 速度线 · `impactFlash` 冲击闪光 · `slowPush` 缓慢推近 |
| 节奏与色调 | `heartbeat` 心跳脉冲 · `toneShift` 色调偏移 · `vignette` 暗角 |
| 点缀 | `lightSweep` 扫光 · `dust` 尘埃 |
| 漫画动势语言（v1.3） | `focusLines` 集中线 · `screenTone` 网点 · `mangaShake` 画面震颤 · `impactRings` 冲击环 · `brushStreak` 笔触飞白 |
| 自然氛围扩充（v1.3） | `flame` 火焰 · `smoke` 烟雾 · `bubbles` 气泡 · `leaves` 落叶 · `meteors` 流星 |
| 节奏与情绪编排（v1.3） | `moodScript` 情绪包络（不画东西，只按 `tension`/`calm`/`burst`/`eerie` 重排已有动效的振幅） |

## 内置预设（presets/）

38 个现成参数组合（`EffectConfig.fromJson` 直接加载；CLI 场景可 `--config` 使用）：

| 分组 | 份数 | 说明 |
|---|---|---|
| `classic` | 1 | 三件套 + legacy 档 + 无抖动，逐字节复现 v1.2 |
| v1.1/v1.2 单效果（legacy 档） | 16 | rain / snow / fog / embers / lightning / fireflies / godRays / starlight / shimmer / heartbeat / impact_duel / sakura / speedlines / slowpush / vignette / toneshift |
| dither 对比 | 1 | `dither_compare_forest`（唯一 `dither: true` 档） |
| v1.2 组合（legacy 档） | 5 | combo_campfire / full_action / rain_lanterns / sakura_light / storm_night |
| v1.3 单效果（standard 档） | 10 | focus_lines / screen_tone / manga_shake / impact_burst（冲击环+闪光）/ brush_streak / flame / smoke / bubbles / leaves / meteors |
| v1.3 情绪包络 | 2 | `mood_tension_build`、`mood_burst_impact` |
| v1.3 组合（standard 档） | 3 | combo_manga_impact / night_battle / peaceful_evening |

这 37 份演示预设与图鉴演示一一对应，由 `tool/generate_showcase.dart` 单源生成（改预设请改生成器，否则会被下次生成覆盖）。

## 工程结构

```
lib/
  comic_motion.dart        # 对外导出（可独立引用的引擎包）
  src/
    version.dart           # 单一版本真相源（与 pubspec.yaml 同步）
    image_model.dart       # RGBA 像素模型（flat Uint8List，零拷贝）
    image_io.dart          # 解码/编码门面（image 包, 纯 Dart）
    depth_splitter.dart    # 深度估算 + 分层拆解（羽化边缘）
    motion_math.dart       # 动效数学（视差/呼吸/粒子轨迹）
    frame_compositor.dart  # 帧合成器
    gif_writer.dart        # GIF 编码（量化 LUT + 误差扩散抖动）
    effect_config.dart     # 参数体系（JSON 序列化 + configHash）
    json_compat.dart       # 兼容性 JSON 工具
    pipeline.dart          # 单图处理管线
    worker_pool.dart       # 并行帧渲染 isolate 池
    background.dart        # 后台 isolate 入口（进度/取消桥接）
    cancellation.dart      # MotionCancelToken + MotionCancelledException
    guard.dart             # 可选并发信号量（MotionPipelineGuard）
    param_catalog.dart      # 程序可读的渲染参数目录
    strip.dart             # 条漫 strip 模式（切片 + processStrip）
    batch_runner.dart      # 批处理
    ledger.dart            # JSONL 台账
    render/
      quality.dart         # RenderTier 档位定义
      raster.dart          # 抗锯齿光栅原语（覆盖度采样）
      resampler.dart       # 面积平均 + 可分离 Catmull-Rom
      envelope.dart        # moodScript 情绪包络曲线
    effects/
      comic_pass.dart      # 漫画动势类效果的绘制通路
      particle_raster_pass.dart  # 粒子类效果的统一光栅通路
presets/                   # 38 个内置预设参数
sample_images/             # 10 张占位样图
tool/                      # 样图生成 / 冒烟 / 图鉴生成 / 性能基准 / GIF 校验等脚本
test/engine_test.dart      # 引擎与配置测试
test/render_test.dart      # 渲染与效果测试
doc/                       # 动效目录（API/部署文档在 comic_motion_server/docs）
```

## 错误处理

| 场景 | 表现 |
|---|---|
| 空文件 / 损坏图 / 非图片 | `ImageDecodeException`（含中文原因） |
| 超大图（>64MB 文件 或 >12000px 边长 或 >40M 像素总量） | `ImageTooLargeException`（像素预算可在解码入口按设备能力配置） |
| 配置文件坏 JSON / 字段类型错 / 未知效果名 | `ConfigException` |
| 并行 worker 启动失败 | 自动降级串行，结果里 `parallelFallback: true` |
| 并行 worker 渲染中途崩溃 | `EngineWorkerException`（不静默降级，任务判失败；HTTP 层映射为 `E_WORKER_CRASH`） |
| `moodScript` 给了未知 `mood` | 落回 `calm`，并在 `warnings` / 台账里记一条 |

任务失败不崩溃、批处理不中断，全部记入台账。

## 性能参考

以下为 `tool/bench.dart` 在 1080p 样图上的实测（`build/bench/bench_report.json`，parallel=8）：

| 场景 | 效果数 | 档位 | 耗时 | 峰值内存 | 红线 |
|---|---|---|---|---|---|
| 480p / 12fps / 2s（草稿） | 3 | legacy | 233 ms | 377 MB | ≤450 ms ✅ |
| 1080p / 24fps / 4s（典型） | 3 | legacy | 2.25 s | 534 MB | ≤5 s ✅ |
| 1600 / 24fps / 4s（预览上限） | 3 | legacy | 3.49 s | 607 MB | ≤7 s ✅ |
| 1080p 标准档 | 3 | standard | 4.26 s | 607 MB | — |
| 1080p 全效果（最坏情况） | 32 | standard | 5.20 s | 628 MB | ≤9 s ✅ |

并行度扫描（standard 档 1080p 96 帧三件套）：`1 → 16.67 s`、`2 → 9.45 s`、`4 → 6.08 s`、`8 → 4.77 s`，四次 GIF **字节一致**，`parallel=1` 峰值 628 MB（红线 780 MB）。可复现性：同参数 SHA256/FNV-1a 逐字节一致；legacy 档与 v1.2 输出逐字节一致（`presets/classic.json` 演练通过）。

### 移动端真机参考区间（粗略）

上表桌面数据**不适用于手机**（大核更少、热节流、内存行为不同）。下表为粗略经验区间——由桌面 bench 折算移动端并行度与热假设得出，**尚未经真机实测校准**，只作数量级参考；实际设备请用 `estimateCost(...)` 与 `warnings` 降级提示判断：

| 场景 | 配置 | 典型耗时 | 指引 |
|---|---|---|---|
| 草稿（信息流预览） | 480p、12fps、2s、核心三件套、parallel 2 | ~0.5–1.5 s | 骁龙/天玑中端档 |
| 典型 | 1080p、24fps、4s、核心三件套、parallel 2–4 | ~4–10 s | 按需渲染，翻页时不要跑 |
| 低端机 | 720p、12fps、2s、核心三件套、parallel 1–2 | ~1–3 s | `maxDimension` ≤ 720，务必传 `memoryBudgetMb` |

手机端经验法则：`parallel` ≤ 4（每个 worker 持一份完整层栅格副本）；始终传 `memoryBudgetMb` 并把 `warnings` 呈现给用户；滚动预览用草稿配置、典型配置按需渲染；同一时刻只跑一个渲染任务（见并发章节）。

## 测试与基准

```bash
dart test                      # 自动化测试
dart run tool/bench.dart       # 性能基准 + 复现性 + 并行度扫描（超红线 exit 3）
dart run tool/gif_check.dart   # GIF 严格逐帧解码校验
```

## 生态

单向依赖：核心包保持纯 Dart，对伴生包一无所知。

| 包 | 职责 |
|---|---|
| **comic_motion**（本包） | 纯 Dart 渲染引擎——深度分层、动效、编码 |
| [comic_motion_server](../comic_motion_server) | CLI（单图/批量）+ HTTP API 服务 |
| [comic_motion_flutter](../comic_motion_flutter) | Flutter widgets：`MotionGifView`（占位 crossfade、播放控制、入场帧）、`ParallaxGyroView`（陀螺仪/触摸/注入流视差），以及资产/磁盘帧集加载工具 |

## 兼容与废弃（deprecation）流程

公共 API 的破坏性变更走 `@Deprecated` 周期：旧接口先标注废弃并附迁移说明，
保留至少一个次版本，下一个主版本再移除。结构化错误码（`E_*`）是稳定标识：
只增不改义。v1.3.0 早于本政策——当时未经周期直接 breaking 修改
`RgbaImage.data`，正是本政策要约束的反例。

## License

[Apache-2.0](LICENSE)
