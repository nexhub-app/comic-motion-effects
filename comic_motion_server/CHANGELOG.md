# Changelog

## Unreleased（1.3.1 候选）

- 适配核心包 1.3.1：`EffectConfig.fromFile` → `effectConfigFromFile`；`EngineWorkerException.code` 改为实例字段（HTTP 层 `E_WORKER_CRASH` 映射不变）。
- **产物目录命名纳入内容指纹**：核心包 T1 将产物目录改为 `<stem>_<contentHash8>_<configHash8>`（strip 片级同步）；本包无代码改动，任务台账经 `PipelineResult.toJson` 自动携带 `contentHash` 字段。旧格式缓存目录需部署侧自行清理。
- **GIF 帧间差分可用**：核心包 T5 新增 `encoding.diffMode: rect`（默认 `none`）；HTTP/CLI 配置原样透传核心包解析，`{"encoding":{"diffMode":"rect"}}` 即可为条漫类任务大幅缩小 GIF 体积（解码结果与 none 逐像素一致）。本包无代码改动。
- 新增 HTTP 契约测试：health、E_INVALID_JSON / E_BAD_CONFIG / E_NO_INPUT、提交-轮询-success 全流程（产物落盘 + 台账可查）。

## 1.3.0

- 自 `comic-motion-backend` 单包拆分而来：CLI（process/batch/job/serve）与 HTTP API、JSONL 台账查询全部迁入本包。
- 引擎渲染管线不在此包，依赖 `comic_motion ^1.3.0`（本仓库内通过 `pubspec_overrides.yaml` 指向 `../comic_motion`）。
- 新增 HTTP API 契约测试（health / 非法 JSON / 非法配置 / 缺输入 / 提交-轮询-成功全流程）。
