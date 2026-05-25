# TASK: Codex 会话查看与运行状态展示任务拆解

## 任务边界

- 只处理这次 `docs/superpowers/specs/SPEC_2026-05-24-codex-runtime-status-display.md` 和 `docs/superpowers/plans/PLAN_2026-05-24-codex-runtime-status-display.md` 的收口记录。
- 这份 task 只做轻量标准化，不扩成第二套 plan。
- 本 task 不允许修改生产代码。

## 任务依赖

- 先以 `docs/initiatives/global-planning/01_Codex会话查看与运行状态展示规划.md` 和 `docs/initiatives/长期资产/codex会话查看功能研究/04_最终判定结论.md` 作为长期方向依据。
- 再以修改后的 `docs/superpowers/specs/SPEC_2026-05-24-codex-runtime-status-display.md` 作为需求合同。
- 再以修改后的 `docs/superpowers/plans/PLAN_2026-05-24-codex-runtime-status-display.md` 作为实施边界。

## 当前状态

- [x] spec 已收紧到 `StatusDashboard` 作为主展示面。
- [x] spec 已冻结 `recent_events` 只保留单个最新事件快照。
- [x] plan 已删除 `elixir/lib/symphony_elixir/orchestrator.ex` 的修改范围。
- [x] plan 已把任务拆成共享状态合同、主屏展示、边界回归三块。
- [x] task 记录已建立。

## 当前阻塞

- 无。

## 下一步

- 后续如果进入实现，就按修订后的 plan 执行。
- 如果实现过程中发现需要事件历史缓冲或完整 viewer，必须先回到 spec。
