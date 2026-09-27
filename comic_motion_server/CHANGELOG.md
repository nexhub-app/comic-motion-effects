# Changelog

## 1.3.0

- 自 `comic-motion-backend` 单包拆分而来：CLI（process/batch/job/serve）与 HTTP API、JSONL 台账查询全部迁入本包。
- 引擎渲染管线不在此包，依赖 `comic_motion ^1.3.0`（本仓库内通过 `pubspec_overrides.yaml` 指向 `../comic_motion`）。
- 新增 HTTP API 契约测试（health / 非法 JSON / 非法配置 / 缺输入 / 提交-轮询-成功全流程）。
