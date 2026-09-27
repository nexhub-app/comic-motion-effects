# comic_motion_server

[comic_motion](../comic_motion) 漫画动效引擎的 CLI 与 HTTP API 服务层：单图处理、目录批处理、JSONL 处理台账、异步任务 REST 服务。

引擎本体（`package:comic_motion`）不依赖本包——只想嵌引擎渲染管线的 App / 库请直接依赖引擎包；本包面向自托管服务与批量出图场景。

## 安装

```yaml
dependencies:
  comic_motion_server:
    git:
      url: https://github.com/nexhub-app/comic-motion-effects.git
      path: comic_motion_server
```

本仓库内开发时，`pubspec_overrides.yaml` 已把 `comic_motion` 指向 `../comic_motion`（该文件只在以本包为根解析时生效，不影响下游消费者）。

> 注意：`comic_motion` 尚未发布到 pub.dev 之前，本包保持 `publish_to: none`；发布后可改为 hosted 依赖并解除限制。

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
| `--quality` | legacy | 渲染档 `legacy` \| `standard` \| `rich`（定义见引擎 README） |
| `--dither` / `--no-dither` | 关 | GIF 误差扩散抖动，减轻 256 色色带 |
| `--parallel` | auto | 帧渲染并行 isolate 数（`auto` = min(8, 核数)，`1` = 串行） |
| `--reduced-motion` | — | 减弱动态：输出单帧静态图 |

`--config` 会整体替换参数来源（此时 `--fps/--duration/--amplitude` 等不再叠加），但 `--effects`、`--quality`、`--dither`、`--reduced-motion` 仍可覆盖同名项。

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

请求体的参数键名是 **`config`**（不是 `params`；写错的键会被静默忽略并落回默认配置）。顶层还可给 `parallel`。任务队列并发 2，每个任务内部再按 `parallel` 开帧并行 worker；状态机 `queued → running → success | failed`。参数非法返回 `E_BAD_CONFIG` 等结构化错误码，worker 中途崩溃返回 `E_WORKER_CRASH`。详见 [docs/api.md](docs/api.md) 与 [docs/deploy.md](docs/deploy.md)。

## 处理台账

每次任务（API / CLI / 批处理同源）追加一行 JSONL 到 `<data-dir>/ledger/ledger.jsonl`，人可读、可 grep。查询：

```bash
dart run bin/comic_motion.dart job all
```

## License

[Apache-2.0](LICENSE)
