# Symphony V0.2 阶段规划入口

日期：`2026-05-28`
状态：`规划草案，待文档复核`
定位：面向 V0.2 后续 SPEC、实施计划、review 和任务拆分的阶段入口

## 1. 这份入口在解决什么

V0.2 的核心目标，是让 Symphony 从“可以调度单张 issue 的自动化运行器”推进到“能让 issue 按状态、前置 blocker、AI review、人类 gate 和 merge 规则顺畅流转”的全自动化基础阶段。

这里的“全自动化”不是让系统绕过人类，也不是把 Orchestrator 做成状态写入者。V0.2 仍然保持当前长期边界：

- Orchestrator 负责读取 tracker、判断是否可以唤醒对应 agent、维护运行态和观测态。
- Linear issue 状态变化由对应 agent 自己完成。
- Linear 是任务生命周期和 review 结论的主真相源。
- GitHub PR 只承载 diff、checks、分支和 merge 能力，不作为 V0.2 的 review 真相源。

## 2. 本阶段功能顺序

本阶段按“一条主流程 + 两项辅助能力”的顺序推进规划：

1. [01_AI_Review驱动的Issue生命周期流转.md](./01_AI_Review驱动的Issue生命周期流转.md)  
   V0.2 主线。定义每张 issue 从 `Todo` 到 `Done` 的完整流转、项目级 `review_mode`、checks 与 AI Review 的顺序、issue body / `Codex Workpad` / 评论区分工、reviewer 直接 merge 的收口动作，以及失败回退。
2. [02_Todo_Pool人工检查功能.md](./02_Todo_Pool人工检查功能.md)  
   辅助观测能力。只读展示各项目 `Todo` 卡片及其前置 blocker，不参与调度，不写 Linear，也不成为任何真相源。
3. [03_项目级健康检查与安全恢复.md](./03_项目级健康检查与安全恢复.md)  
   辅助保护能力。提供全局与项目级健康检查，失败时只影响对应范围，并给 UI / CLI / API 留出安全恢复入口，不改写主流程合同。

这三项里，`01` 是主流程合同，`02` 和 `03` 都必须服从 `01`，不能反过来改写 issue 生命周期、review 真相源或依赖解除条件。

## 3. 本阶段不做什么

V0.2 阶段规划明确不把下面内容放进主线：

- 不定义“同一组 issue”或新的任务组概念；顺序只由每张 issue 的前置 blocker 决定。
- 不让 `Todo Pool` 成为调度器的数据源。
- 不让 Orchestrator 代替 agent 修改 Linear issue 状态。
- 不把 GitHub PR review 设置为 review 真相源；V0.2 默认不依赖 GitHub required reviews。
- 不允许 checks 失败时进入自动 merge / `Done`。
- 不把 `Rework` 当成 AI review 的普通返修状态。
- 不在 V0.2 主线里做 UI 重启主进程。
- 不做完整多租户平台、持久化队列、跨 orchestrator 抢占或复杂公平调度。

## 4. 长期合同同步

V0.2 已经上升为长期合同的部分，统一写入：

- [../../SPEC/03_Symphony_V0.2全自动流转长期SPEC.md](../../SPEC/03_Symphony_V0.2全自动流转长期SPEC.md)

阶段路线和长期变化说明同步写入：

- [../../global-planning/03_Symphony_V0.2阶段变化与路线.md](../../global-planning/03_Symphony_V0.2阶段变化与路线.md)

## 5. 文档状态说明

本目录当前仍是规划阶段产物，不是实施计划。进入实现前，还需要把各功能拆到 `docs/superpowers/` 下的可验证 SPEC 和实施 PLAN，并按 `elixir/PLANNING_FLOW.md` 完成文档阶段 review。
