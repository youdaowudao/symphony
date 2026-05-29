# Symphony V0.2 阶段变化与路线

日期：`2026-05-28`
状态：`规划草案，待文档复核`

## 1. 这份规划在解决什么

这份规划说明 Symphony 从 V0.1 进入 V0.2 后，阶段重点发生了什么变化。

V0.1 的重点是多项目共享执行池：项目身份、workspace 隔离、project-aware runtime、最小多项目观测和 dispatch 前置合同。

V0.2 的重点转向 issue 生命周期自动流转：每张 issue 如何从 `Todo` 进入执行、如何经过 AI review、人类 gate 或全自动 merge，最后到达 `Done`，并只在 `Done` 后解除后续 blocker。

## 2. V0.2 总目标

V0.2 的总目标是：

> 让 Symphony 支持以 Linear issue 为主真相源的自动流转闭环，使 issue 能在前置 blocker、AI Review Gate、项目 review mode、checks、人类评论和 merge gate 的共同约束下稳定推进。

这里不引入“同一组 issue”概念。多个 issue 的顺序只由 Linear 前置 blocker 表达。

## 3. V0.2 阶段主线

V0.2 的主流程先行，辅助能力后补：

1. AI Review 驱动的 issue 生命周期流转  
   这是 V0.2 的核心。它新增 `AI Review`、项目级 `review_mode`、Submission Refresh Gate、AI Review Gate、review worktree 隔离和 merge 前最终刷新。

2. Todo Pool 人工检查功能  
   这是辅助观测能力。它把首页中的 `Todo Pool` 从占位变成真实只读检查区，用来查看各项目 `Todo` 卡片和前置 blocker。

3. 项目级健康检查与安全恢复  
   这是辅助保护能力。它让系统能区分全局失败和单项目失败，并允许人类触发重新检查、清除健康失败缓存或立即 poll。

## 4. 与 V0.1 的关系

V0.2 不回写篡改 V0.1 的完成定义。

V0.2 继续依赖 V0.1 的长期合同：

- Project Registry 是项目静态真相源。
- ProjectContext 是运行期项目身份来源。
- workspace 归属和 cleanup 必须 fail closed。
- project-aware runtime state 和项目级并发门禁必须保留。
- UI / Presenter 只能消费上游 contract，不自造第二真相源。

V0.2 在这些基础上新增：

- `review_mode` 作为项目级配置。
- `AI Review` 作为新的机器审查状态。
- `Done` 作为唯一依赖解除状态。
- Linear `## AI Review Gate` 作为 AI review 真相记录。
- review worktree 作为独立审查执行目录。

## 5. 阶段非目标

V0.2 不承诺完成：

- 完整多租户平台。
- per-project workflow。
- 持久化任务队列。
- 多 orchestrator 抢占。
- GitHub required reviews 作为主 review gate。
- PR 评论作为 review 真相源。
- UI 重启主进程。
- 复杂公平调度或 token 成本调度器。

这些可以作为未来主题，但不能塞回 V0.2 主线。

## 6. 后续实施入口

V0.2 当前阶段文档入口：

- [../stage-plans/v0.2/README.md](../stage-plans/v0.2/README.md)

长期合同入口：

- [../SPEC/03_Symphony_V0.2全自动流转长期SPEC.md](../SPEC/03_Symphony_V0.2全自动流转长期SPEC.md)

进入实现前，每个功能仍需要拆成 `docs/superpowers/` 下的可验证 SPEC 和实施 PLAN，并完成 `elixir/PLANNING_FLOW.md` 要求的文档复核。
