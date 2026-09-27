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

### 平台支持矩阵

| 平台 | 状态 | 说明 |
|---|---|---|
| Android / iOS | ✅ 首要目标 | 纯 Dart + isolate，无原生插件、无 UI 依赖 |
| Windows / macOS / Linux 桌面 | ✅ | 与 CLI / 服务端同源 |
| Web | 🚫 本轮未支持 | `dart:io` / isolate 边界尚未收敛（路线图项） |

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

### 从源码跑通引擎（本仓库开发者）

```bash
git clone https://github.com/nexhub-app/comic-motion-effects.git
cd comic-motion-effects/comic_motion
dart pub get
dart run tool/generate_samples.dart     # 生成 10 张占位样图（sample_images/）
dart run tool/smoke_test.dart           # 单张图 → GIF + 帧序列（约 2-4 秒）
```

输出位于 `build/smoke/01_portrait_<hash8>/`：

```
anim.gif                    # 动图成品
frames/frame_0000.png ...   # 逐帧 PNG
params.json                 # 完整参数回放文件
```

## 渲染档位（quality）

| 档 | 内容 | 用途 |
|---|---|---|
| `legacy`（默认） | v1.2 的绘制与编码路径 | 与历史输出**逐字节一致**，回滚承诺的载体 |
| `standard` | 抗锯齿光栅原语、面积平均 / Catmull-Rom 重采样、screen 光照混合、深度平滑上采样 + 掩码羽化、层边缘外扩、GIF 量化 LUT（抖动核可选 sierra） | 日常出图 |
| `rich` | 与 `standard` 走同一套通路：预留的 `supersample` 与 `mipLevels` 目前无消费方（已知偏差） | 与 standard 对照用 |

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
docs/                      # 动效目录（API/部署文档在 comic_motion_server/docs）
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

## 测试与基准

```bash
dart test                      # 自动化测试
dart run tool/bench.dart       # 性能基准 + 复现性 + 并行度扫描（超红线 exit 3）
dart run tool/gif_check.dart   # GIF 严格逐帧解码校验
```

## 兼容与废弃（deprecation）流程

公共 API 的破坏性变更走 `@Deprecated` 周期：旧接口先标注废弃并附迁移说明，
保留至少一个次版本，下一个主版本再移除。结构化错误码（`E_*`）是稳定标识：
只增不改义。v1.3.0 早于本政策——当时未经周期直接 breaking 修改
`RgbaImage.data`，正是本政策要约束的反例。

## License

[Apache-2.0](LICENSE)
