# comic-motion-backend

纯 Dart 实现的漫画图片动效引擎。对静态漫画图做**深度分层拆解**，合成鸿蒙阅读风格的 **2.5D 视差 + 呼吸感 + 氛围粒子** 动效，输出 GIF 动图与 PNG 帧序列。

- 纯 Dart，无原生依赖，UI-free，可嵌入任意 Dart / Flutter 工程
- 同参数输出字节级可复现（确定性随机种子 + configHash）
- 三种使用方式：CLI 单图 / 目录批处理 / HTTP API 服务
- 20 种可组合动效 + 25 个内置预设参数

## 环境要求

| 项 | 要求 |
|---|---|
| Dart SDK | ≥ 3.4.0 |
| 操作系统 | Windows / Linux / macOS（纯 Dart） |
| 网络 | 仅 `dart pub get` 时需要 |

## 快速开始

```bash
git clone https://github.com/nexhub-app/comic-motion-effects.git
cd comic-motion-effects
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

## CLI 用法

入口：`dart run bin/comic_motion.dart <命令> [参数]`

| 命令 | 说明 |
|---|---|
| `process --input <图片> [--out DIR]` | 处理单张图片 |
| `batch --input <目录> [--out DIR]` | 批量处理目录内全部 png/jpg/jpeg/webp，单张失败不中断 |
| `serve [--port N] [--data-dir DIR]` | 启动 HTTP API 服务（默认端口 8787） |
| `job <jobId\|all> [--data-dir DIR]` | 查询处理台账 |
| `--version` | 打印版本 |

通用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--fps` | 24 | 输出帧率 |
| `--duration` | 4.0 | 动效时长（秒） |
| `--layers` | 3 | 深度层数（2-4） |
| `--seed` | 20260914 | 确定性随机种子（同 seed + 同参数 ⇒ 同输出） |
| `--max-dimension` | 1600 | 工作分辨率上限（自动降采样） |
| `--format` | both | `gif` \| `frames` \| `both` |
| `--amplitude` | 0.012 | 视差幅度（占图宽比例） |
| `--direction` | 0 | 视差主方向（度，0=水平） |
| `--effects` | parallax,breathing,ambient | 动效组合，逗号分隔 |
| `--config` | — | 复用 `params.json` 或预设 JSON 回放参数 |
| `--dither` | 开 | GIF 色带抖动 |
| `--reduced-motion` | — | 减弱动态：输出单帧静态图 |

## 动效目录（20 种）

`--effects` 可任意组合，全部整循环无缝（首尾帧一致）：

| 类别 | 效果 |
|---|---|
| 核心三件套（默认开启） | `parallax` 2.5D 视差 · `breathing` 呼吸缩放 · `ambient` 氛围粒子上浮 |
| 天气氛围 | `rain` 雨丝 · `snow` 飘雪 · `fog` 雾气 · `sakura` 樱吹雪 · `embers` 火星 |
| 光影氛围 | `fireflies` 萤火 · `godRays` 丁达尔光束 · `starlight` 星光 · `lightning` 闪电 |
| 动势强调 | `speedLines` 速度线 · `impactFlash` 冲击闪光 · `slowPush` 缓慢推近 |
| 节奏与色调 | `heartbeat` 心跳脉冲 · `toneShift` 色调偏移 · `vignette` 暗角 |
| 点缀 | `lightSweep` 扫光 · `dust` 尘埃 |

示例：

```bash
dart run bin/comic_motion.dart process --input sample_images/07_night_city.png \
  --effects parallax,rain,lightning --fps 24 --duration 3.0
```

## 内置预设（presets/）

25 个现成参数组合，`--config` 直接使用：

```bash
# 雨夜城市
dart run bin/comic_motion.dart process -i sample_images/07_night_city.png \
  -c presets/rain_night_city.json

# 樱花人像
dart run bin/comic_motion.dart process -i sample_images/01_portrait.png \
  -c presets/sakura_portrait.json
```

预设覆盖：classic（经典三件套）、rain / snow / fog / embers / lightning / fireflies / godRays / starlight / heartbeat / impact / speedlines / slowpush / vignette / toneshift / dither 对比等单效果，以及 combo_campfire、combo_full_action、combo_rain_lanterns、combo_sakura_light、combo_storm_night 组合效果。

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

任务串行执行，状态机 `queued → running → succeeded | failed`；参数非法返回 `E_BAD_CONFIG` 等结构化错误码。

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

final result = MotionPipeline(EffectConfig(fps: 12)).processFile(input, outDir);
```

前端集成建议：`Process.run('dart', ['run', 'bin/comic_motion.dart', ...])` 或直接 HTTP 调用本服务。

## 实时翻页演示（realtime/）

纯静态单文件（零依赖）的 Canvas 2D 阅读翻页动效演示：仿真卷页、拖拽跟手、回弹过冲、三层光影、idle 呼吸微动。直接双击 `realtime/index.html` 或部署到任意静态服务器即可。

## 工程结构

```
lib/
  comic_motion.dart        # 对外导出（可独立引用的引擎包）
  src/
    image_model.dart       # RGBA 像素模型
    image_io.dart          # 解码/编码门面（image 包, 纯 Dart）
    depth_splitter.dart    # 深度估算 + 分层拆解（羽化边缘）
    motion_math.dart       # 动效数学（视差/呼吸/粒子轨迹）
    frame_compositor.dart  # 帧合成器
    gif_writer.dart        # GIF 编码
    effect_config.dart     # 参数体系（JSON 序列化 + configHash）
    json_compat.dart       # 兼容性 JSON 工具
    pipeline.dart          # 单图处理管线
    batch_runner.dart      # 批处理
    ledger.dart            # JSONL 台账
    api_service.dart       # shelf HTTP API
    cli.dart               # CLI 入口
bin/comic_motion.dart      # 可执行入口
presets/                   # 25 个内置预设参数
sample_images/             # 10 张占位样图
tool/                      # 样图生成 / 冒烟 / 性能基准 / GIF 校验等脚本
test/engine_test.dart      # 自动化测试（20 例，含 GIF 编码器回归）
realtime/index.html        # 实时翻页渲染演示（纯静态单文件）
```

## 错误处理

| 场景 | 表现 |
|---|---|
| 空文件 / 损坏图 / 非图片 | `ImageDecodeException`（含中文原因） |
| 超大图（>64MB 文件 或 >12000px） | `ImageTooLargeException` |
| 配置文件坏 JSON / 字段类型错 / 未知效果名 | `ConfigException` |

任务失败不崩溃、批处理不中断，全部记入台账。

## 性能参考

| 指标 | 实测 |
|---|---|
| 单张处理耗时 | 480p ≈ 1-2 s；1080p ≈ 10-14 s |
| 峰值内存 | ≈ 300-500 MB |
| 可复现性 | 同参数字节级一致（FNV-1a 比对验证） |

## 测试与基准

```bash
dart test                      # 20 例自动化测试
dart run tool/bench.dart       # 性能基准 + 复现性验证
dart run tool/gif_check.dart   # GIF 严格逐帧解码校验
```

## License

[Apache-2.0](LICENSE)
