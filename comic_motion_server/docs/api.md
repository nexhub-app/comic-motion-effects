# comic-motion-backend HTTP API 文档

版本 1.3.0 · 纯 Dart (shelf) 实现 · 全部接口返回 JSON（UTF-8）

## 启动

```bash
dart run bin/comic_motion.dart serve --port 8787 --data-dir DELIVERY/data
```

服务内 **最多 2 个任务并发**（`MotionApiService(concurrency: 2)` 的默认值），每个任务的帧渲染并行度按 `kDefaultParallel ~/ concurrency` 分摊，避免 worker isolate 数 = 并发数 × 8 把 CPU/内存打超。注意 `MotionApiService` 只经 `bin/comic_motion.dart serve` 暴露，`package:comic_motion/comic_motion.dart` 并未导出它——要内嵌服务请 `import 'package:comic_motion/src/api_service.dart';`（同为纯 Dart，但按内部路径引用，版本间不承诺签名稳定）。

健康检查：

```json
{"status":"ok","service":"comic-motion-backend","version":"1.3.0",
 "queueDepth":0,"active":0,"jobsTracked":0}
```

## 接口一览

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 存活性/版本/队列深度探针 |
| POST | `/api/v1/jobs` | 提交处理任务 |
| GET | `/api/v1/jobs/<id>` | 查询任务状态与结果（含 `createdAt`） |
| GET | `/api/v1/jobs` | 列出全部任务：`{"jobs":[{"jobId","status",("result"),("error")}]}`（列表项不含 `createdAt`） |
| GET | `/api/v1/ledger?jobId=&status=` | 台账查询 |
| GET | `/files/<相对输出路径>` | 下载产物（仅限输出目录内，`..` 拒绝） |

## POST /api/v1/jobs

请求体（JSON）。**字段名是 `config`，不是 `params`**——写错的字段会被静默忽略并落回默认配置：

```json
{
  "inputPath": "C:/abs/path/to/comic.png",
  "parallel": 8,
  "config": {
    "fps": 12,
    "durationSec": 3.0,
    "layerCount": 3,
    "seed": 20260914,
    "maxDimension": 640,
    "outputFormat": "gif",
    "effects": ["parallax", "breathing", "rain", "moodScript"],
    "parallax": { "amplitude": 0.012, "periodSec": 6.0, "directionDeg": 0 },
    "rain": { "count": 110, "angleDeg": 14, "opacity": 0.42 },
    "moodScript": { "mood": "tension", "cycles": 1, "strength": 1.0 },
    "quality": { "dither": true, "ditherMode": "sierra", "tier": "standard", "edgeStretchPx": 6 }
  }
}
```

- `inputPath` 绝对路径，与 `inputBase64` 二选一（后者落盘到 `<data-dir>/uploads/up_<ms>_<seq>.bin`）。
- `config` 全部可选，字段与 `params.json` / `presets/*.json` 同一套 schema（`EffectConfig.fromJson`）。
- `parallel`（可选，顶层）覆盖本任务的帧渲染并行度；缺省时按服务并发数分摊。`1` = 串行。
- 响应 `202`：

```json
{"jobId":"job-1789389000000-1","status":"queued"}
```

状态机：`queued → running → success | failed`（注意是 `success`，不是 `succeeded`）。

## GET /api/v1/jobs/<id>

```json
{
  "jobId": "job-1789389000000-1",
  "status": "success",
  "createdAt": "2026-09-19T04:10:02.113Z",
  "result": {
    "input": "C:/abs/path/to/comic.png",
    "gif": "DELIVERY/data\\outputs\\comic_732d213e\\anim.gif",
    "framesDir": "…\\frames",
    "width": 900, "height": 1300, "layerCount": 3, "frameCount": 36,
    "elapsedMs": 2248,
    "configHash": "732d213ea9da834f",
    "parallel": 8
  }
}
```

`result` 仅在有结果时出现，两个可选标记：

| 字段 | 出现条件 | 含义 |
|---|---|---|
| `parallel` | 总是 | 实际使用的 worker 数（不是请求值） |
| `parallelFallback: true` | 起 isolate 池失败时 | 已回落串行执行，输出字节与并行一致，只是慢 |
| `warnings: [...]` | 有配置回落时 | 目前只有 `moodScript` 未知 `mood` → `calm`；不影响出图，只提示配置没按字面生效 |

失败时 `status=failed`，`error` 是**字符串**（`"E_WORKER_CRASH: …"` 或异常文本），不是对象。

## 配置字段速查（v1.3）

| 字段 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `effects` | `EffectKind` 名数组（32 项） | `[parallax,breathing,ambient]` | 未列出的效果其参数段也不序列化 |
| `quality.tier` | `legacy`\|`standard`\|`rich` | `legacy` | `legacy` 逐字节复现 v1.2；`rich` 当前与 `standard` 等价 |
| `quality.dither` | bool | `false` | Floyd–Steinberg / Sierra 误差扩散抖动 |
| `quality.ditherMode` | `floyd`\|`sierra` | `floyd` | `sierra` 只在 standard+ 有意义 |
| `quality.edgeStretchPx` | 0-16 | `6` | 层边缘色外扩，消除视差露底双边（standard+） |
| `quality.mipLevels` | 1-2 | `2` | 预留字段，尚无消费方 |
| `moodScript.mood` | `tension`\|`calm`\|`eerie`\|`burst` | `tension` | 未知值回落 `calm` 并写 `warnings` |
| `moodScript.strength` | 0-1+ | `1.0` | `0` = 恒等因子，逐字节等价于不挂该效果 |
| `moodScript.cycles` | 正整数 | `1` | 每条循环重复的包络轮数（整数保证无缝） |
| `parallel`（顶层，非 config） | 正整数 | 按并发分摊 | 只影响耗时，不影响输出字节 |

## 错误码

HTTP 层错误响应格式：`{"error":"E_…","message":"…"}`（`error` 是字符串码）。

| HTTP | code | 场景 |
|---|---|---|
| 400 | `E_INVALID_JSON` | 请求体不是合法 JSON |
| 400 | `E_BAD_CONFIG` | `config` 字段类型或取值非法（`ConfigException`） |
| 400 | `E_BAD_INPUT` | `inputBase64` 不是合法 Base64 |
| 400 | `E_NO_INPUT` | 缺少 `inputPath`/`inputBase64`，或文件不存在 |
| 400 | `E_BAD_PATH` | `/files/` 路径含 `..` |
| 404 | `E_NO_JOB` | jobId 不存在 |
| 404 | （纯 404 文本） | `/files/` 目标不存在 |
| 500 | `E_INTERNAL` | 未预期异常 |

任务级失败（状态 `failed`，`error` 为字符串）：`ImageDecodeException`（空文件/损坏/非图片）、`ImageTooLargeException`（>64MB 或边长 >12000px）、`E_WORKER_CRASH`（帧 worker 抛异常或 isolate 意外退出）。任务失败不崩服务，队列继续。

## 调用示例（curl）

```bash
# 1. 健康检查
curl http://127.0.0.1:8787/health

# 2. 提交任务（注意 config 这个键名）
curl -X POST http://127.0.0.1:8787/api/v1/jobs \
  -H "Content-Type: application/json" \
  -d '{"inputPath":"C:/work/sample_images/01_portrait.png","config":{"fps":12,"effects":["parallax","breathing","focusLines"]}}'

# 3. 轮询直到 success/failed
curl http://127.0.0.1:8787/api/v1/jobs/job-1789389000000-1

# 4. 取回结果（路径来自 result.gif 的相对部分）
curl -o out.gif "http://127.0.0.1:8787/files/<jobdir>/anim.gif"
```

## 台账

每次任务（API / CLI `process` / `batch` 同源）追加一行 JSONL 到 `<data-dir>/ledger/ledger.jsonl`。字段：

```
jobId, ts, input, configHash, status, outputGif, frameDir, paramsFile,
width, height, layerCount, frameCount, elapsedMs, parallel,
parallelFallback?, warnings?, error?
```

`parallelFallback` 与 `warnings` 只在非空/为真时写入（v1.2 之前的行没有这些字段，读取时需容错）。查询：`GET /api/v1/ledger?status=failed&jobId=…` 或 CLI `dart run bin/comic_motion.dart job <id>|all`。
