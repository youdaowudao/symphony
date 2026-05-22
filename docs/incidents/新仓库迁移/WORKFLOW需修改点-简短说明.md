# `elixir/WORKFLOW.md` 修改交接板

目标：让真实 `projects/symphony/elixir/WORKFLOW.md` 接上新的测试与变更流程规则，避免运行时继续按旧路由执行。

## 需要做的事

### 1. 在 `WORKFLOW.md` 前部说明区插入下面这段

```md
- 测试与校验统一遵循 `elixir/TESTING.md`；先走最小可证明路径，只有命中当前 `Next Push Gate` 时才升级。
- 变更推进统一遵循 `elixir/CHANGE_FLOW.md`；代码变更的独立 `final zero-context reviewer`、PR create/update、GitHub 关键写操作和 `auto-merge first` 都按该文件执行。
- 任何 `push` / create PR / update PR / merge 前，先按 `elixir/CHANGE_FLOW.md` 判断当前阶段，再按 `elixir/TESTING.md` 执行对应 gate；不要自行把普通 `elixir/` 改动或 `app-touching` 默认升级为 `make all`、浏览器验证或其他高等级路径。
```

### 2. 把下面这些旧句子删掉或改短

#### A. `app-touching` 默认跑 `launch-app` / media 的句子

改成：

- 只有 ticket 明确要求 UI/runtime/browser 证据时才执行。

#### B. `失败就处理并重跑直到 green` 的句子

改成：

- 如果高等级验证失败后的修复引入新代码变化，先回到最小 proof / targeted tests 和当前 diff 所需 review，再回到更高等级 gate。

#### C. create/update PR 后直接 attach PR URL、加 label、poll checks 的旧顺序

改成：

- create/update PR 成功后，后续 GitHub 关键写操作按 `elixir/CHANGE_FLOW.md` 执行，并先尝试 auto-merge。

#### D. `Human Review` 前那一大段重复展开的 poll/check/review 描述

改成：

- 进入 `Human Review` 前，按 `elixir/CHANGE_FLOW.md` 完成当前阶段要求的 review 与验证，不在 `WORKFLOW.md` 里重复展开。

## 不要做的事

- 不要把 `TESTING.md` 和 `CHANGE_FLOW.md` 的完整制度重新抄回 `WORKFLOW.md`
- 不要在 `WORKFLOW.md` 里重新定义 full-gate 路由细节
- 不要把高风险升级流程、多角色链条、合同流程重新写回去

## 完成标准

完成后，`WORKFLOW.md` 只负责两件事：

1. 告诉运行时 agent 应该看 `elixir/TESTING.md` 和 `elixir/CHANGE_FLOW.md`
2. 把必须运行时可见的少数顺序要求写清楚
