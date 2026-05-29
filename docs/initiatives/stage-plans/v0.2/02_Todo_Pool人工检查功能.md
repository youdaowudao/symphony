# Todo Pool 人工检查功能

日期：`2026-05-28`
状态：`规划草案，待文档复核`
阶段：`V0.2`

## 1. 这份文档在解决什么

本功能在首页保留 `Todo Pool` 人工检查区。人类点击 `手动检查` 后，系统按已登记项目读取 Linear 中当前 `Todo` 卡片，并展示每张卡片的前置 blocker。

一句话定义：

> `Todo Pool` 是首页上的只读人工检查区，用来查看各项目当前处于 `Todo` 的卡片，以及这些卡片是否被前置 blocker 挡住。

这里的 `Todo Pool` 不是新的调度数据源，不是持久队列，也不是 Linear 的新状态。

## 2. 现有的是什么

### 2.1 `Todo` 是 Linear 状态

当前 `elixir/WORKFLOW.md` 已经把 `Todo` 放在 `tracker.active_states` 中。`Todo` 的语义是“已排队”。当 agent 真正开始处理时，agent 按 workflow 自己把卡片从 `Todo` 移到 `In Progress`。

这说明：

- `Todo` 不是 Symphony 新造的状态。
- `Todo` 本来就属于调度器可见范围。
- Linear 状态变更属于 agent 工作流，不属于 `Todo Pool` UI。

### 2.2 当前前端已有 `Todo Pool` 占位

当前 `DashboardLive` 已经有 `Todo Pool` 面板、`手动检查` 按钮和项目卡片区域，但仍是占位能力：

- 点击 `手动检查` 只更新本地页面状态。
- 页面会展开项目摘要。
- 当前不会触发真实 Linear 查询。
- 当前项目卡片显示的是占位数量和占位详情。

V0.2 不是从零做一个新页面，而是在现有首页壳子上把 `Todo Pool` 从占位变成真实人工检查功能。

### 2.3 当前后端已经能读取前置 blocker

当前 Linear 查询已经读取 issue 的 `inverseRelations`，并只把 `type == "blocks"` 的关系归一化为 `blocked_by`。

当前调度器也已经有保护规则：

- 如果一张 `Todo` 卡片的 `blocked_by` 里存在未完成 blocker，不唤起 coder。
- 如果没有未完成 blocker，继续进入容量、claimed、running、retry、worker 等后续检查。

这条规则看的是“这张卡片前面被谁挡住”，不是“这张卡片挡住了谁”，也不是普通关联关系。

## 3. 新增的是什么

### 3.1 点击 `手动检查` 后做什么

点击 `手动检查` 后，系统执行一次只读后台检查：

1. 读取当前已登记并启用的项目。
2. 对每个项目读取 Linear 中当前处于 `Todo` 的卡片。
3. 对每张 `Todo` 卡片读取它的前置 blocker。
4. 把检查结果返回给首页展示。

这里的检查是一次用户触发的读取动作，不等于调度器 poll，不等于手动启动 coder，也不修改 Linear。

### 3.2 页面需要展示什么

首页至少要让人看懂：

- 每个项目现在有多少张 `Todo` 卡片。
- 每张 `Todo` 卡片是谁，包括 issue identifier、标题和项目名。
- 这张卡片是否有未完成前置 blocker。
- 如果有 blocker，blocker 是谁、当前是什么状态。
- 如果没有未完成 blocker，显示它在 blocker 维度上“可以进入调度候选”，但这不等于一定会被立即唤起。
- 如果某个项目读取失败，显示该项目检查失败，而不是误显示为没有 Todo。

这里的“可以进入调度候选”只表示没有未完成前置 blocker。它不承诺马上被调度器唤起，因为真正 dispatch 还要看容量、running、claimed、retry、worker、Codex rate limit、项目健康状态和当前角色路由。

这里再次明确：前置 blocker 只在 blocker issue 到 `Done` 后解除，不能把 `Closed`、`Cancelled`、`Duplicate` 等通用 terminal state 当成解除依据。

### 3.3 展示数据边界

`Todo Pool` 不能复用 runtime `blocked`。

当前系统里的 `blocked` 是运行时 blocked，例如 Codex 等待输入、等待批准或运行失败后被放到 blocked 区。它不是 Linear `Todo` 卡片的前置 blocker 列表。

建议展示数据最小包含：

| 字段 | 含义 |
| --- | --- |
| `checked_at` | 本次人工检查完成时间 |
| `projects[]` | 每个已登记项目的检查结果 |
| `project_key` | 项目身份，只能来自项目登记表 |
| `project_display_name` | 项目展示名，拿不到时回退 `project_key` |
| `todo_count` | 该项目当前 Todo 卡片数量 |
| `ready_count` | 没有未完成前置 blocker 的 Todo 数量 |
| `blocked_count` | 有未完成前置 blocker 的 Todo 数量 |
| `unknown_count` | blocker 信息不足、无法判断的 Todo 数量 |
| `issues[]` | Todo 卡片列表 |
| `issue_id` | Linear issue 机器 ID |
| `issue_identifier` | 人类可读编号 |
| `title` | 卡片标题 |
| `blockers[]` | 前置 blocker 列表 |
| `status` | `ready`、`blocked_by_dependency` 或 `unknown` |
| `project_error` | 单项目读取失败原因 |

字段名进入正式实现 SPEC 前还可以调整，但语义不能变成调度真相源。

## 4. 风险是什么

### 4.1 把 `Todo Pool` 误做成调度器

如果实现时让调度器只从 `Todo Pool` 的结果里取任务，会出问题。Linear 状态、blocker 关系和项目模式可能被人手动修改。调度器必须在自己的 poll / dispatch 流程中读取当时最新的 tracker 状态，并在 dispatch 前重新确认。

结论：`Todo Pool` 只给人看，不能成为调度器唯一依据。

### 4.2 把 `Todo Pool` 误做成状态修改入口

`Todo` 到 `In Progress` 的状态推进由 agent 按 workflow 自己做。`Todo Pool` 点击检查不能直接把卡片改成 `In Progress`，也不能让 Orchestrator 替 agent 做状态流转。

结论：`Todo Pool` 只读 Linear，不写 Linear。

### 4.3 把前置 blocker 和其他关系混在一起

本功能只关心“这张卡片前面被谁挡住”。它不关心这张卡片挡住了谁，也不关心 `related` 等普通关系。

结论：展示和判断必须只使用前置 blocker 关系；普通关联不能显示成阻塞。

### 4.4 把未知 blocker 状态显示成可执行

如果 blocker 信息不完整，例如 blocker state 缺失或无法读取，页面不能轻率显示“可执行”。

结论：证据不足时显示 `unknown` 或需人工确认，不能显示成明确可执行。

### 4.5 把单项目失败扩大成全局失败

如果某个项目 Linear 查询失败，其他项目的检查结果仍然应该展示。

结论：单项目检查失败只影响该项目的 `Todo Pool` 展示，不影响其他项目展示，也不影响调度器。

## 5. 成功标准

进入实现前，正式 SPEC 至少要能证明：

1. `手动检查` 是只读动作，不触发 dispatch，不修改 Linear。
2. 检查范围是已登记并启用的项目。
3. 检查对象是每个项目中当前处于 `Todo` 的卡片。
4. 判断重点是每张 `Todo` 前面有没有未完成 blocker。
5. 展示能看出“谁被谁挡住、blocker 当前是什么状态”。
6. 未知 blocker 不被显示为可执行。
7. 单项目失败不影响其他项目展示。
8. `Todo Pool` 与 runtime `blocked` 不混用。
