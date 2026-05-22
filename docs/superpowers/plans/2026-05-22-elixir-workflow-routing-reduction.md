# `elixir/WORKFLOW.md` 路由收敛实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 收敛 `elixir/WORKFLOW.md` 的运行时入口，只保留对 `elixir/TESTING.md` 与 `elixir/CHANGE_FLOW.md` 的指引，并压缩重复展开的测试/变更顺序说明。

**Architecture:** 这次只改 `elixir/WORKFLOW.md`，不重写 `TESTING.md` 或 `CHANGE_FLOW.md`。保留流程骨架和状态机，只把重复说明改成短入口和最少运行时可见顺序要求，避免继续把测试制度和变更制度散写在 `WORKFLOW.md` 里。

**Tech Stack:** Markdown 文档编辑，仓库内定向复核。

---

### Task 1: 在前部说明区补入新的测试/变更入口

**Files:**
- Modify: `elixir/WORKFLOW.md:68-78`

- [ ] **Step 1: Insert the new front-matter-facing runtime guidance**

```md
- 测试与校验统一遵循 `elixir/TESTING.md`；先走最小可证明路径，只有命中当前 `Next Push Gate` 时才升级。
- 变更推进统一遵循 `elixir/CHANGE_FLOW.md`；代码变更的独立 `final zero-context reviewer`、PR create/update、GitHub 关键写操作和 `auto-merge first` 都按该文件执行。
- 任何 `push` / create PR / update PR / merge 前，先按 `elixir/CHANGE_FLOW.md` 判断当前阶段，再按 `elixir/TESTING.md` 执行对应 gate；不要自行把普通 `elixir/` 改动或 `app-touching` 默认升级为 `make all`、浏览器验证或其他高等级路径。
```

- [ ] **Step 2: Keep the rest of the opening section unchanged**

```md
## 前置条件：Linear MCP 或 `linear_graphql` tool 可用
```

### Task 2: 压缩 app-touching 的运行时验证提示

**Files:**
- Modify: `elixir/WORKFLOW.md:208-215`

- [ ] **Step 1: Replace the app-touching validation sentence with the shorter requirement**

```md
- 只有 ticket 明确要求 UI/runtime/browser 证据时才执行。
```

- [ ] **Step 2: Preserve the surrounding validation guidance**

```md
- 运行 scope 所需的 validation/tests。
- Mandatory gate：当 ticket 提供 `Validation`/`Test Plan`/`Testing` requirements 时，必须执行全部要求；未满足的 items 视为 incomplete work。
- 优先选择能直接证明被改 behavior 的 targeted proof。
```

### Task 3: 收短失败后回退顺序里对高等级验证的描述

**Files:**
- Modify: `elixir/WORKFLOW.md:216`

- [ ] **Step 1: Keep the push precondition sentence**

```md
每次尝试 `git push` 前，运行 scope 所需 validation 并确认通过；
```

- [ ] **Step 2: Replace the trailing retry clause with the new rollback rule**

```md
如果高等级验证失败后的修复引入新代码变化，先回到最小 proof / targeted tests 和当前 diff 所需 review，再回到更高等级 gate。
```

### Task 4: 收敛 create/update PR 后的 GitHub 写操作顺序

**Files:**
- Modify: `elixir/WORKFLOW.md:217-219`

- [ ] **Step 1: Remove the old sequence that separately mentions PR URL attachment, label, merge, and checks**

```md
将 PR URL attach 到 issue（优先 attachment；如果 attachment 不可用，才使用 workpad comment）。
    - 确保 GitHub PR 拥有 `symphony` label（缺失则添加）。
    9.  将 latest `origin/main` merge 到 branch，解决 conflicts，并重新运行 checks。
```

- [ ] **Step 2: Replace it with a single short runtime note**

```md
create/update PR 成功后，后续 GitHub 关键写操作按 `elixir/CHANGE_FLOW.md` 执行，并先尝试 auto-merge。
```

### Task 5: 压缩 Human Review 前的 poll/check/review 展开

**Files:**
- Modify: `elixir/WORKFLOW.md:226-233`

- [ ] **Step 1: Replace the long pre-Human Review checklist block**

```md
- 进入 `Human Review` 前，按 `elixir/CHANGE_FLOW.md` 完成当前阶段要求的 review 与验证，不在 `WORKFLOW.md` 里重复展开。
```

- [ ] **Step 2: Keep the final transition requirement intact**

```md
只有在此之后，才将 issue 移动到 `Human Review`。
```

### Task 6: Final self-check against the plan and the target file

**Files:**
- Review: `docs/superpowers/plans/2026-05-22-elixir-workflow-routing-reduction.md`
- Review: `elixir/WORKFLOW.md`

- [ ] **Step 1: Verify every planned edit maps to an actual line range in `elixir/WORKFLOW.md`**

```text
Task 1 -> opening instruction block
Task 2 -> app-touching validation line
Task 3 -> push retry clause
Task 4 -> PR follow-up sequence
Task 5 -> Human Review precheck block
Task 6 -> completion bar app-touching line
```

- [ ] **Step 2: Verify the plan does not re-add the full `TESTING.md` or `CHANGE_FLOW.md`制度正文**

```text
Only short entry points and the few runtime-visible ordering requirements remain in WORKFLOW.md.
```

- [ ] **Step 3: Verify the document still preserves the issue workflow skeleton**

```text
Status map, step routing, and rework/merge structure remain intact.
```
