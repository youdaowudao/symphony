# 测试噪音收口任务拆解

## 任务边界

- 只处理当前仓库已有的测试噪音问题。
- 只做测试制度提醒和测试辅助收口，不引入 Playwright。
- 代码改动前后都要走子代理复核。

## 任务依赖

- 先确认 `docs/superpowers/specs/2026-05-22-testing-direction-snapshot.md`。
- 再执行 `docs/superpowers/plans/2026-05-22-testing-noise-closeout.md`。
- 再做代码层调整和 targeted verification。

## 当前状态

- [x] 测试方向已确认
- [x] `docs/superpowers/specs/2026-05-22-testing-direction-snapshot.md` 已写入
- [x] `elixir/TESTING.md` 的主动收口提醒已补
- [x] 测试噪音收口的代码层清理已执行
- [x] targeted verification 已执行

## 当前阻塞

- 无。

## 完成情况

- `elixir/TESTING.md` 已补主动收口提醒。
- `elixir/test/support/test_support.exs` 已收口重复等待辅助。
- `elixir/test/symphony_elixir/core_test.exs` 与当前 `WORKFLOW.md` 对齐。
- 目标测试集已通过验证。
