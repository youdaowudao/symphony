# PLAN: Codex 会话查看与运行状态展示 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Symphony 的运行状态展示收成一条清楚的实现路径：先锁共享状态合同，再调整主屏渲染，再用定向测试证明它仍然只是运行状态展示，不是完整 viewer。

**Architecture:** 终端 `StatusDashboard` 是这次的主展示面，LiveView 只负责把它挂到页面上。共享观测语义继续沿用 `Presenter` 和现有 snapshot，不去给 `Orchestrator` 增加事件历史缓冲；如果发现展示目标需要更多字段，先回到合同而不是硬塞到渲染里。

**Tech Stack:** Elixir、Phoenix LiveView、Phoenix JSON controller、ExUnit snapshot tests、仓库现有 `StatusDashboard` / `Presenter` / `Orchestrator`。

---

## 1. 计划边界

### 1.1 这次计划要做什么

- 对齐共享运行状态投影，让终端主屏和 API 看到一致的状态语义。
- 把主屏展示改成更适合判断“AI 还在不在跑”的样子，主展示面固定为 `StatusDashboard`，优先按事件/按行展示。
- 增加或调整定向测试，证明最近内容、状态语义、失败语义和回归边界都对。

### 1.2 这次计划明确不做什么

- 不重做完整 viewer。
- 不做终端镜像。
- 不把深历史、完整对话树、逐条 tool call 变成主屏职责。
- 不新增第三份正式 `verification` 文档；验证结论先写在 plan 和测试里。

### 1.3 允许修改的文件 / 目录

- `elixir/lib/symphony_elixir/status_dashboard.ex`
- `elixir/lib/symphony_elixir_web/presenter.ex`
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs`
- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- `elixir/test/symphony_elixir/extensions_test.exs`
- `elixir/test/fixtures/status_dashboard_snapshots/running_rows.snapshot.txt`
- `elixir/test/fixtures/status_dashboard_snapshots/running_rows.evidence.md`
- `docs/superpowers/specs/SPEC_2026-05-24-codex-runtime-status-display.md`
- `docs/superpowers/plans/PLAN_2026-05-24-codex-runtime-status-display.md`

### 1.4 明确禁止修改的文件 / 目录

- `docs/initiatives/global-planning/01_Codex会话查看与运行状态展示规划.md`
- `docs/initiatives/长期资产/codex会话查看功能研究/04_最终判定结论.md`
- `SPEC.md`
- `docs/governance/`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- 任何与完整 viewer、深历史浏览器或第三方工具对比分析无关的实现文件

### 1.5 如果越界怎么办

- 如果发现这次展示要新增一个完整 viewer 能力，必须立刻停下，回到 spec。
- 如果发现 API / dashboard / terminal 语义开始分叉，必须先回到共享投影合同，再继续。
- 如果定向测试证明现有数据契约装不下目标展示，必须先收边界，不允许默默扩范围。

## 2. 任务拆解

### Task 1: 锁定共享状态合同

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 写出最小共享合同调整**

```text
明确主屏、API 和 snapshot 需要共享的运行状态字段、最近事件字段和时间字段。
如果现有字段已足够，保持 `Orchestrator.snapshot/1` 只读，不引入新的历史缓冲或额外投影。
```

- [ ] **Step 2: 运行对应验证**

```bash
cd elixir
SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/extensions_test.exs
```

- [ ] **Step 3: 确认结果符合预期**

```text
确认 API / snapshot / presenter 使用同一套最新状态语义，且测试明确覆盖运行、停滞、等待、报错和结束语义。
```

### Task 2: 调整主屏展示为事件/按行视图

**Files:**
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Modify: `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- Modify: `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Create: `elixir/test/fixtures/status_dashboard_snapshots/running_rows.snapshot.txt`
- Create: `elixir/test/fixtures/status_dashboard_snapshots/running_rows.evidence.md`

- [ ] **Step 1: 写出最小展示改动**

```text
让终端主展示面更像事件/按行视图，而不是字符流式最后一句。
默认保留最近 2 到 3 行有效信息，并尽量带时间或等价时间提示。
```

- [ ] **Step 2: 运行对应验证**

```bash
cd elixir
SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/orchestrator_status_test.exs
```

- [ ] **Step 3: 确认结果符合预期**

```text
确认 snapshot 不再只表达最后一句摘要；确认宽度、状态行、最近内容控制和新 fixture 都仍然稳定。
```

### Task 3: 收口定向验证与边界回归

**Files:**
- Modify: `docs/superpowers/specs/SPEC_2026-05-24-codex-runtime-status-display.md`
- Modify: `docs/superpowers/plans/PLAN_2026-05-24-codex-runtime-status-display.md`
- Modify: `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Modify: `elixir/test/fixtures/status_dashboard_snapshots/running_rows.snapshot.txt`
- Modify: `elixir/test/fixtures/status_dashboard_snapshots/running_rows.evidence.md`

- [ ] **Step 1: 补齐能证明边界的定向测试**

```text
补上/调整能证明这些点的测试：最近内容保留、状态区分、未知/过期/不可用语义、深历史不进入主屏。
至少要有一个直接证明事件/按行展示的新 fixture 或断言。
```

- [ ] **Step 2: 运行最小验证集**

```bash
cd elixir
SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/status_dashboard_snapshot_test.exs test/symphony_elixir/extensions_test.exs
```

- [ ] **Step 3: 确认结果符合预期**

```text
确认新增测试只证明运行状态展示合同，没有把主屏推进成完整 viewer，也没有引入新的历史缓冲。
```

## 3. 实施顺序

1. 先对齐共享状态合同，确认 API、snapshot 和主屏不会各说各话。
2. 再改主屏展示，把运行状态从“最后一句”收窄成“事件/按行”。
3. 最后补齐定向测试和边界回归，确认深历史没有被偷偷拉回主屏。

## 4. 验证顺序

1. 先跑 `orchestrator_status_test.exs` 和 `extensions_test.exs`，锁住共享投影语义。
2. 再跑 `status_dashboard_snapshot_test.exs`，确认主屏快照与展示行为一致。
3. 如果任何一步暴露出范围扩张或语义分叉，先停，再回到 spec。

## 5. 停止条件

- 发现需要完整 viewer 才能满足需求时，停止。
- 发现主屏、API、snapshot 三层语义开始分叉时，停止。
- 发现计划里的验证无法证明“仍然只是运行状态展示”时，停止。
- 发现需要修改 `docs/initiatives/` 的长期结论才解释得通实现时，停止并回到 spec。

## 6. 复核清单

- [ ] 计划没有重复 SPEC 的需求正文
- [ ] 允许修改范围写清楚了
- [ ] 禁止修改范围写清楚了
- [ ] 如果越界，有明确停下和回退规则
- [ ] 任务足够小，不会把多个动作塞进同一步
- [ ] 验证顺序是具体可执行的，不是空话
