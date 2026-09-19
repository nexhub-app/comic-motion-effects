# comic-motion-backend

纯 Dart 实现的漫画图片动效引擎。对静态漫画图做**深度分层拆解**，合成鸿蒙阅读风格的 **2.5D 视差 + 呼吸感 + 氛围粒子** 动效，输出 GIF 动图与 PNG 帧序列。

- 纯 Dart，无原生依赖，UI-free，可嵌入任意 Dart / Flutter 工程
- 同参数输出字节级可复现（确定性随机种子 + configHash）
- 三种使用方式：CLI 单图 / 目录批处理 / HTTP API 服务
- 32 种可组合动效 + 38 个内置预设参数
- 帧渲染多 isolate 并行：只影响耗时，不影响输出字节

## 环境要求

| 项 | 要求 |
|---|---|
| Dart SDK | ≥ 3.4.0 |
| 操作系统 | Windows / Linux / macOS（纯 Dart） |
| 网络 | 仅 `dart pub get` 时需要 |

## 快速开始

```bash
git clone https://github.com/nexhub-app/comic-motion-effects.git
cd comic-motion-effects/comic-motion-backend
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

## 交付物一览

| 路径 | 内容 |
|---|---|
| `DELIVERY/effect_showcase/效果图鉴.html` | 37 组动效演示（GIF + 首帧静态图），卡片正文带参数取值与所属分类 |
| `DELIVERY/effect_showcase/<key>/` | 每组演示的 `anim.gif` / `frame_0000.png` / `params.json`（完整回放参数；v1.3 新增 15 条的 configHash 另列在 `docs/motion_catalog_v13.md` §六） |
| `DELIVERY/交付报告.html` | v1.0.0 那一轮的交付报告（历史记录；v1.3 的变更看 `CHANGELOG.md`） |
| `docs/motion_catalog_v13.md` | 32 动效目录 + 质量项 + 实测性能 + 回滚口径 |
| `docs/api.md` | HTTP API 文档 |
| `docs/deploy.md` | 部署与回滚手册（配置开关式四级收回） |
| `presets/` | 38 份可直接 `-c` 的参数组合 |

上表里的 `docs/` 与 `DELIVERY/` 被 `.gitignore` 标为内部交付件，不进 git 仓库（`build/`、`data/ledger/` 同）；在 GitHub 上只有 `presets/` 与 `CHANGELOG.md` 可见。

## CLI 用法

入口：`dart run bin/comic_motion.dart <命令> [参数]`

| 命令 | 说明 |
|---|---|
| `process --input <图片> [--out DIR]` | 处理单张图片 |
| `batch --input <目录> [--out DIR]` | 批量处理目录内全部 png/jpg/jpeg/webp，单张失败不中断 |
| `serve [--port N] [--data-dir DIR]` | 启动 HTTP API 服务（默认端口 8787，监听 0.0.0.0） |
| `job <jobId\|all> [--data-dir DIR]` | 查询处理台账 |

通用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--fps` | 24 | 输出帧率 |
| `--duration` | 4.0 | 动效时长（秒） |
| `--layers` | 3 | 深度层数（惯例 2-4；不夹紧——分层阈值固定为远/中/近三段，`>3` 时多出的层复用 near 带掩码、只按各自视差倍率叠加） |
| `--seed` | 20260914 | 确定性随机种子（同 seed + 同参数 ⇒ 同输出） |
| `--max-dimension` | 1600 | 工作分辨率上限（自动降采样） |
| `--format` | both | `gif` \| `frames` \| `both` |
| `--amplitude` | 0.012 | 视差幅度（占图宽比例） |
| `--direction` | 0 | 视差主方向（度，0=水平） |
| `--effects` | parallax,breathing,ambient | 动效组合，逗号分隔 |
| `--config` | — | 复用 `params.json` 或预设 JSON 回放参数 |
| `--quality` | legacy | 渲染档 `legacy` \| `standard` \| `rich`（见下） |
| `--dither` / `--no-dither` | 关 | GIF 误差扩散抖动，减轻 256 色色带 |
| `--parallel` | auto | 帧渲染并行 isolate 数（`auto` = min(8, 核数)，`1` = 串行） |
| `--reduced-motion` | — | 减弱动态：输出单帧静态图 |

`--config` 会整体替换参数来源（此时 `--fps/--duration/--amplitude` 等不再叠加），但 `--effects`、`--quality`、`--dither`、`--reduced-motion` 仍可覆盖同名项。

### 渲染档位（--quality）

| 档 | 内容 | 用途 |
|---|---|---|
| `legacy`（默认） | v1.2 的绘制与编码路径 | 与历史输出**逐字节一致**，回滚承诺的载体 |
| `standard` | 抗锯齿光栅原语、面积平均 / Catmull-Rom 重采样、screen 光照混合、深度平滑上采样 + 掩码羽化、层边缘外扩、GIF 量化 LUT（抖动核可选 sierra） | 日常出图 |
| `rich` | 与 `standard` 走同一套通路：预留的 `supersample` 与 `mipLevels` 目前无消费方（已知偏差） | 与 standard 对照用 |

档位只改像素路径，不改动效列表；`--quality legacy` 与 `presets/classic.json` 是两个独立维度的收回开关。`sierra` 抖动核需要 `dither: true` + `quality.ditherMode: "sierra"` + 非 legacy 档三者同时成立。

## 动效目录（32 种）

`--effects` 可任意组合，全部整循环无缝（首尾帧一致）：

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

示例：

```bash
dart run bin/comic_motion.dart process --input sample_images/07_night_city.png \
  --effects parallax,rain,lightning --fps 24 --duration 3.0

# v1.3：集中线 + 速度线 + tension 情绪包络，走 standard 质量档、4 并行
dart run bin/comic_motion.dart process -i sample_images/02_action.png \
  -c presets/mood_tension_build.json --quality standard --parallel 4
```

## 内置预设（presets/）

38 个现成参数组合，`--config` 直接使用：

```bash
# 雨夜城市
dart run bin/comic_motion.dart process -i sample_images/07_night_city.png \
  -c presets/rain_night_city.json

# 樱花人像
dart run bin/comic_motion.dart process -i sample_images/01_portrait.png \
  -c presets/sakura_portrait.json
```

38 份 = `classic`（回滚基线）+ 37 组图鉴演示各一份。按档位分：

| 分组 | 份数 | 说明 |
|---|---|---|
| `classic` | 1 | 三件套 + legacy 档 + 无抖动，逐字节复现 v1.2 |
| v1.1/v1.2 单效果（legacy 档） | 16 | rain / snow / fog / embers / lightning / fireflies / godRays / starlight / shimmer / heartbeat / impact_duel / sakura / speedlines / slowpush / vignette / toneshift |
| dither 对比 | 1 | `dither_compare_forest`（唯一 `dither: true` 档） |
| v1.2 组合（legacy 档） | 5 | combo_campfire / full_action / rain_lanterns / sakura_light / storm_night |
| v1.3 单效果（standard 档） | 10 | focus_lines / screen_tone / manga_shake / impact_burst（冲击环+闪光）/ brush_streak / flame / smoke / bubbles / leaves / meteors |
| v1.3 情绪包络 | 2 | `mood_tension_build`、`mood_burst_impact` |
| v1.3 组合（standard 档） | 3 | combo_manga_impact / night_battle / peaceful_evening |

这 37 份演示预设与 `DELIVERY/effect_showcase` 一一对应，由 `tool/generate_showcase.dart` 单源生成（改预设请改生成器，否则会被下次生成覆盖）。

## HTTP API

```bash
dart run bin/comic_motion.dart serve --port 8787 --data-dir data
```

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 健康检查 |
| POST | `/api/v1/jobs` | 提交任务（`inputPath` 绝对路径或 `inputBase64`；`config` 可选） |
| GET | `/api/v1/jobs/<id>` | 轮询任务状态与结果 |
| GET | `/api/v1/ledger?status=failed` | 台账查询 |
| GET | `/files/<jobdir>/anim.gif` | 下载产物（仅限输出目录内） |

提交示例：

```bash
curl -X POST http://127.0.0.1:8787/api/v1/jobs \
  -H "Content-Type: application/json" \
  -d '{"inputPath":"C:/work/sample_images/01_portrait.png","config":{"fps":12}}'
```

请求体的参数键名是 **`config`**（不是 `params`；写错的键会被静默忽略并落回默认配置）。顶层还可给 `parallel`。任务队列并发 2，每个任务内部再按 `parallel` 开帧并行 worker；状态机 `queued → running → success | failed`。参数非法返回 `E_BAD_CONFIG` 等结构化错误码，worker 中途崩溃返回 `E_WORKER_CRASH`。详见 `docs/api.md`。

## 处理台账

每次任务（API / CLI / 批处理同源）追加一行 JSONL 到 `<data-dir>/ledger/ledger.jsonl`，人可读、可 grep。查询：

```bash
dart run bin/comic_motion.dart job all
```

## 作为库嵌入 Flutter 工程

```yaml
dependencies:
  comic_motion:
    path: ../comic-motion-backend
```

```dart
import 'package:comic_motion/comic_motion.dart';

final result = await MotionPipeline(EffectConfig(fps: 12), parallel: 4)
    .processFile(input, outDir);
```

`processFile` 是异步的（并行度 >1 时跨 isolate），必须 `await`。管线构造参数 `parallel` 为执行期参数，不进入 `EffectConfig`，因此不影响 configHash 与输出字节。

前端集成建议：`Process.run('dart', ['run', 'bin/comic_motion.dart', ...])` 或直接 HTTP 调用本服务。

## 实时翻页演示（realtime/）

纯静态单文件（零依赖）的 Canvas 2D 阅读翻页动效演示：仿真卷页、拖拽跟手、回弹过冲、三层光影、idle 呼吸微动。直接双击 `realtime/index.html` 或部署到任意静态服务器即可。

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
    batch_runner.dart      # 批处理
    ledger.dart            # JSONL 台账
    api_service.dart       # shelf HTTP API
    cli.dart               # CLI 入口
    render/
      quality.dart         # RenderTier 档位定义
      raster.dart          # 抗锯齿光栅原语（覆盖度采样）
      resampler.dart       # 面积平均 + 可分离 Catmull-Rom
      envelope.dart        # moodScript 情绪包络曲线
    effects/
      comic_pass.dart      # 漫画动势类效果的绘制通路
      particle_raster_pass.dart  # 粒子类效果的统一光栅通路
bin/comic_motion.dart      # 可执行入口
presets/                   # 38 个内置预设参数
sample_images/             # 10 张占位样图
tool/                      # 样图生成 / 冒烟 / 图鉴生成 / 性能基准 / GIF 校验等脚本
test/engine_test.dart      # 引擎与配置测试（107 例）
test/render_test.dart      # 渲染与效果测试（17 例）
docs/                      # 动效目录 / HTTP API 文档 / 部署与回滚手册
DELIVERY/effect_showcase/  # 37 组演示动图 + 图鉴页
realtime/index.html        # 实时翻页渲染演示（纯静态单文件）
```

## 错误处理

| 场景 | 表现 |
|---|---|
| 空文件 / 损坏图 / 非图片 | `ImageDecodeException`（含中文原因） |
| 超大图（>64MB 文件 或 >12000px） | `ImageTooLargeException` |
| 配置文件坏 JSON / 字段类型错 / 未知效果名 | `ConfigException` |
| 并行 worker 启动失败 | 自动降级串行，结果里 `parallelFallback: true` |
| 并行 worker 渲染中途崩溃 | `E_WORKER_CRASH`（不静默降级，任务判失败） |
| `moodScript` 给了未知 `mood` | 落回 `calm`，并在 `warnings` / stderr / 台账里记一条 |

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
dart test                      # 124 例自动化测试
dart run tool/bench.dart       # 性能基准 + 复现性 + 并行度扫描（超红线 exit 3）
dart run tool/gif_check.dart   # GIF 严格逐帧解码校验
```

## License

[Apache-2.0](LICENSE)
