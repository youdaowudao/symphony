# 测试噪音收口实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把当前仓库的测试噪音收口成明确规则，并把明显的零散等待/轮询整理到更合适的公共辅助层。

**Architecture:** 先补一条更直白的测试政策提醒，再做最小范围的测试噪音清理。只处理当前仓库里已经存在、且能直接降低噪音的等待逻辑；不引入浏览器层，不改测试方向，不重新讨论 Playwright。

**Tech Stack:** Markdown 文档、Elixir ExUnit、仓库现有测试辅助函数。

---

### Task 1: 把“主动收尾噪音”的要求写进测试制度

**Files:**
- Modify: `elixir/TESTING.md`

- [x] **Step 1: Add one explicit reminder about test-noise closeout**

```md
- 每次新增或修改测试时，先主动收口噪音：优先复用公共 helper；等待、轮询和 cleanup 不要散写在单个测试正文里。
```

- [x] **Step 2: Keep the existing `SYMPHONY_TEST_MAX_CASES` / polling / timeout rules intact**

```md
- 本地 ExUnit 并发必须始终显式限制。所有测试命令都必须带 `SYMPHONY_TEST_MAX_CASES`。
- 优先用 polling 或 `assert_eventually`。
- timeout 统一收进公共 helper，不要把毫秒常量散写在测试正文。
```

### Task 2: 收口当前仓库里最明显的测试噪音点

**Files:**
- Modify: `elixir/test/support/test_support.exs`
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Modify: `elixir/test/symphony_elixir/ssh_test.exs`
- Modify: `elixir/test/symphony_elixir/live_e2e_test.exs`

- [x] **Step 1: Identify which repeated waits can move into shared helper code**

```text
Candidates: repeated polling, repeated assert_eventually-like loops, repeated cleanup/wait scaffolding.
Do not move one-off timing assertions that encode real behavior.
```

- [x] **Step 2: Extract only the repeated noise into helper code**

```text
Prefer the existing test support module first.
If a helper is shared by multiple test files, centralize it once instead of cloning local loops.
```

- [x] **Step 3: Keep semantic timing assertions local when they describe the behavior under test**

```text
If a sleep or timeout is the behavior being asserted, leave it local and document why it is intentional.
```

### Task 3: Run targeted verification for touched files

**Files:**
- Review: `elixir/TESTING.md`
- Review: touched test files from Task 2

- [x] **Step 1: Run the narrowest targeted test set that covers the edited files**

```bash
cd elixir
SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/ssh_test.exs
```

- [x] **Step 2: Re-run any file-specific test that changes helper behavior**

```bash
cd elixir
SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/live_e2e_test.exs
```

- [x] **Step 3: Confirm the final diff no longer leaves obvious noise untouched in the edited scope**

```text
Check the modified test files for leftover ad-hoc wait scaffolding and confirm the shared helper covers the repeated cases.
```
