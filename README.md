# comic-motion-backend

纯 Dart 实现的漫画图片动效引擎（后端）。对静态漫画图做**深度分层拆解**，合成鸿蒙阅读风格的 **2.5D 视差（parallax）+ 呼吸感（breathing）+ 氛围粒子（ambient）** 动效，输出 GIF 动图与 PNG 帧序列。

- 纯 Dart，无原生依赖，UI-free，可嵌入任意 Dart / Flutter 工程
- 同参数输出**字节级可复现**（确定性随机种子 + configHash）
- 三种使用方式：命令行（CLI）、批处理、HTTP API 服务
- 当前版本 **1.2.0**（`pubspec.yaml`）

## 环境要求

| 项 | 要求 |
|---|---|
| Dart SDK | ≥ 3.4.0（验证环境：3.13.0 Windows x64） |
| 操作系统 | Windows / Linux / macOS（纯 Dart，无原生依赖） |
| 内存 | ≥ 4 GB（默认参数下峰值约 300-500 MB） |
| 网络 | 仅 `dart pub get` 安装依赖时需要 |

## 快速开始

```bash
cd comic-motion-backend
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

## 三种使用方式

### 1. CLI 单图处理

```bash
dart run bin/comic_motion.dart process --input sample_images/01_portrait.png --out build/out
```

### 2. 批量处理

```bash
dart run bin/comic_motion.dart batch --input sample_images --out build/batch_out
```

自动处理目录内全部 png/jpg/jpeg/webp，单张失败不中断批次。

### 3. HTTP API 服务

```bash
dart run bin/comic_motion.dart serve --port 8787 --data-dir DELIVERY/data
curl http://127.0.0.1:8787/health
# → 200 {"status":"ok","version":"1.0.0",...}
```

接口一览（完整文档见 [docs/api.md](docs/api.md)）：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 存活性/版本探针 |
| POST | `/api/v1/jobs` | 提交处理任务 |
| GET | `/api/v1/jobs/<id>` | 查询任务状态与结果 |
| GET | `/api/v1/ledger?status=failed` | 台账查询 |
| GET | `/files/<jobdir>/anim.gif` | 下载 GIF |

### 4. 查询处理台账

```bash
dart run bin/comic_motion.dart job all          # 全部记录
dart run bin/comic_motion.dart job <jobId>      # 单条记录
```

每次任务（API / CLI / 批处理同源）追加一行 JSONL 到 `<data-dir>/ledger/ledger.jsonl`，人可读、可 grep。

## CLI 通用参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--fps` | 24 | 输出帧率 |
| `--duration` | 4.0 | 动效时长（秒） |
| `--layers` | 3 | 深度层数（2-4） |
| `--seed` | 20260914 | 确定性随机种子（同 seed + 同参数 ⇒ 同输出） |
| `--max-dimension` | 1600 | 工作分辨率上限（自动降采样） |
| `--format` | both | `gif` \| `frames` \| `both` |
| `--amplitude` | 0.012 | 视差幅度（占图宽比例） |
| `--direction` | 0 | 视差主方向（0=水平，90=垂直） |
| `--effects` | parallax,breathing,ambient | 动效组合，如 `--effects parallax,rain` |
| `--config` | — | 复用 `params.json` 回放参数 |
| `--reduced-motion` | — | 减弱动态：输出单帧静态图 |

## 动效目录

**默认三件套**：parallax（2.5D 视差）、breathing（呼吸缩放）、ambient（氛围粒子上浮）。
可单独叠加：lightSweep（扫光）、dust（尘埃）。

**v1.1 新增 8 动效**（详见 [docs/motion_catalog.md](docs/motion_catalog.md)）：

| 效果 | 类别 | 作用 |
|---|---|---|
| rain 雨丝 | 天气氛围 | 雨夜氛围 |
| snow 飘雪 | 天气氛围 | 冬日静谧 |
| sakura 樱吹雪 | 氛围·情绪 | 春日花瓣 |
| fireflies 萤火 | 氛围·光效 | 夜光明灭 |
| godRays 丁达尔光束 | 光影 | 引导视线 |
| speedLines 速度线 | 动势强调 | 战斗动势 |
| impactFlash 冲击闪光 | 动势·反馈 | 打击反馈 |
| heartbeat 心跳脉冲 | 节奏情绪 | 情绪节拍 |

全部动效整循环无缝（t=0 与 t=时长 帧一致，有测试断言）。

## 输出命名规范

```
<输出目录>/<文件名>_<configHash前8位>/anim.gif
<输出目录>/<文件名>_<configHash前8位>/frames/frame_0000.png ...
<输出目录>/<文件名>_<configHash前8位>/params.json
```

输出目录按 configHash 命名，不同参数产物互不覆盖；`params.json` 可用 `--config` 直接复用。

## 性能与验收线

| 指标 | 验收线 | 实测 |
|---|---|---|
| 单张处理耗时 | ≤ 30 秒 | 480p ≈ 1-2 s；1080p ≈ 10-14 s |
| 峰值内存 | ≤ 2 GB | ≈ 300-500 MB |
| 可复现性 | 同参数字节级一致 | PASS（FNV-1a 比对） |
| 参数敏感性 | 改参数输出必变 | PASS |

## 工程结构

```
lib/
  comic_motion.dart        # 对外导出（可独立引用的引擎包）
  src/
    image_model.dart       # RGBA 像素模型
    image_io.dart          # 解码/编码门面（image 包, 纯 Dart）
    depth_splitter.dart    # 深度估算 + 分层拆解（羽化边缘）
    frame_compositor.dart  # 视差/呼吸/粒子/扫光 帧合成器
    effect_config.dart     # 参数体系（JSON 序列化 + configHash）
    pipeline.dart          # 单图处理管线
    batch_runner.dart      # 批处理（失败不中断）
    ledger.dart            # JSONL 台账
    api_service.dart       # shelf HTTP API
    cli.dart               # CLI 入口（args 解析）
bin/comic_motion.dart      # 可执行入口
tool/                      # 样图生成 / 冒烟测试 / 性能基准 / GIF 校验等脚本
test/engine_test.dart      # 自动化测试（20 例，含 GIF 编码器回归）
docs/                      # API 文档 / 部署手册 / 动效目录 / 交接文档
realtime/                  # 实时翻页渲染演示（纯静态单文件，双击 index.html 即可运行）
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

前端集成建议：`Process.run('dart', ['run', 'bin/comic_motion.dart', ...])`，或直接 HTTP 调用本服务。

## 错误处理

| 场景 | 表现 | 处理 |
|---|---|---|
| 空文件 / 损坏图 / 非图片 | `ImageDecodeException`（中文原因） | 记入台账 failed，批处理继续 |
| 超大图（>64MB 文件 或 >12000px） | `ImageTooLargeException` | 同上 |
| 配置文件坏 JSON / 字段类型错 | `ConfigException` | 修正参数后重试 |
| HTTP 400/404 | `E_INVALID_JSON` / `E_NO_INPUT` / `E_NO_JOB` / `E_BAD_PATH` / `E_BAD_CONFIG` | 见 docs/api.md |

任务失败不崩溃、批处理不中断，全部记入台账。

## 部署与回滚

以 git tag 为发布单元（v1.0.0 / v1.1.0 / v1.2.0），完整步骤见 [docs/deploy.md](docs/deploy.md)。要点：

- 回滚 = `git reset --hard <tag>` + `dart pub get` + 冒烟验证
- 台账 JSONL 追加型，跨版本兼容，回滚不销毁历史
- 输出按 hash 命名，新旧版本产物互不覆盖

## 相关文档

- [docs/api.md](docs/api.md) — HTTP API 完整文档（含错误码、curl 示例）
- [docs/deploy.md](docs/deploy.md) — 部署与回滚手册
- [docs/motion_catalog.md](docs/motion_catalog.md) — 动效目录与参数
- [docs/handoff.md](docs/handoff.md) — 项目交接文档
- [realtime/readme.md](realtime/readme.md) — 实时翻页渲染演示说明
