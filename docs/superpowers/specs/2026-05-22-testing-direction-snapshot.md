# 测试方向与收口快照

> **For agentic workers:** 这里记录当前仓库测试方向的稳定结论；后续任何代码修改前，先按这里的约束重新检查。

**Goal:** 固定当前仓库的测试方向，保留已确认的规则，避免把旧仓库测试资产和不适配的验证方式带进来。

**Architecture:** 以 `elixir/TESTING.md` 作为测试制度主入口，`docs/superpowers/` 只存稳定快照和后续执行入口。当前只确认三件事：测试噪音要收口、coverage 门槛要改成 `99`、真实浏览器层单独放并固定用 `Playwright`。代码修改前必须先做子代理复核。

**Tech Stack:** Markdown 文档、Elixir ExUnit、Playwright、仓库内测试约定。

---

## 目标 / 需求快照

这次要解决的是：

- 把当前测试方向固定下来，后面的人不用回看一长串迁移讨论。
- 明确哪些规则已经定了，哪些只是待检查，不再混写。
- 给后续代码收口留一个稳定入口。

成功标准：

- `elixir/TESTING.md` 继续作为测试制度主入口。
- 所有测试命令仍然显式带 `SYMPHONY_TEST_MAX_CASES`。
- 测试噪音收口到公共 helper，不再把 `timeout` / `polling` 等等待逻辑散写在测试正文里。
- `elixir/mix.exs` 的 coverage 门槛使用 `99`。
- 真实浏览器层单独存在，固定选 `Playwright`，`MCP 浏览器` 只做辅助。

明确不做：

- 不迁移旧仓库测试资产。
- 不把旧仓库的 fake-heavy 测试风格带回主路径。
- 不把真实浏览器混进真实业务闭环层。

固定约束：

- 任何代码修改前，先走子代理二次审核。
- 当前工作区已有其他未相关改动，不要顺手触碰。

## 已确认

- `elixir/TESTING.md` 已经写明 `SYMPHONY_TEST_MAX_CASES`、`polling`、`assert_eventually` 和 `timeout` 收口要求。
- `elixir/mix.exs` 的 coverage threshold 已经改成 `99`。
- 真实浏览器层的选型已经固定为 `Playwright`。

## 已检查但还没收干净

当前仓库里仍能看到零散等待和轮询写法，例如：

- `elixir/test/symphony_elixir/core_test.exs`
- `elixir/test/symphony_elixir/extensions_test.exs`
- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- `elixir/test/symphony_elixir/ssh_test.exs`
- `elixir/test/symphony_elixir/live_e2e_test.exs`

这说明“测试噪音收口”目前还不是完全收干净的状态，只是规则和部分入口已经定下来了。

## 后续执行入口

后面如果要继续做代码层收口，顺序固定为：

1. 先确认哪些等待逻辑应当保留，哪些应当改成公共 helper。
2. 再做最小代码修改。
3. 修改前后都要做子代理二次审核。
4. 最后再做 targeted verification。
