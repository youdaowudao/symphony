# Symphony V0.2 全自动流转长期 SPEC

日期：`2026-05-28`
状态：`规划草案，待文档复核`
定位：长期有效、可直接被后续 SPEC、实施计划和 review 引用的 V0.2 合同

## 1. 这份 SPEC 在解决什么

这份长期 SPEC 沉淀 V0.2 已经确认的全自动流转合同。它不是实施计划，不记录当前代码完成度，也不替代 `docs/superpowers/` 下后续具体实现主题的可验证 SPEC。

V0.2 的核心目标是：让每张 Linear issue 能在不新增“任务组”概念的前提下，按自身状态、前置 blocker、项目 review 模式、AI review、人类评论和 merge gate 正确流转到 `Done`。

这里的“正确流转”包含三层：

1. 不该执行的 issue 不被唤醒。
2. 该执行的 issue 能按角色唤醒 coder、reviewer 或 lander。
3. 任何自动放行都必须绑定同一个 PR head、checks 结果、AI Review Gate 和最新人类评论。

## 2. 适用范围

本 SPEC 约束 V0.2 之后长期保持的语义：

1. issue 状态到 agent 角色的路由。
2. 前置 blocker 解除条件。
3. 项目级 `review_mode`。
4. AI Review Gate。
5. Submission Refresh Gate。
6. Linear 人类评论优先级。
7. GitHub PR、checks 和 auto-merge 的边界。
8. review worktree 与 coder workspace 的隔离。
9. `Rework` 的收窄语义。
10. Todo Pool 与健康检查的长期边界。

本 SPEC 不承担下面职责：

- 不规定具体 Elixir 模块如何拆。
- 不规定最终 UI 样式。
- 不记录每个 implementation plan 的任务列表。
- 不把当前讨论过程原样复制成台账。
- 不宣称 V0.2 代码已经实现完成。

## 3. 总体非目标

V0.2 不做下面这些事：

- 不新增“同一组 issue”或“任务组”作为调度概念。
- 不让 Orchestrator 代替 agent 修改 Linear issue 状态。
- 不把 GitHub PR review 设为 V0.2 的 review 真相源。
- 不允许 checks fail 时自动 merge 或自动 `Done`。
- 不把 `Todo Pool` 变成调度器的数据源。
- 不在健康检查功能里做 UI 重启主进程。
- 不做完整多租户平台、持久化队列或跨 orchestrator 抢占。

## 4. Issue 生命周期合同

### 4.1 状态到角色必须明确

V0.2 的状态路由长期保持为：

| Linear 状态 | 允许唤醒的角色 | 语义 |
| --- | --- | --- |
| `Todo` | coder | 已排队，且无未完成前置 blocker 时可以开始 |
| `In Progress` | coder | 实现、AI 返修、checks 返修 |
| `AI Review` | reviewer | 自动审查固定 PR head |
| `Human Review` | 无自动 coder | 等待人类业务判断 |
| `Merging` | lander | 合并前最终检查并执行 merge / auto-merge |
| `Rework` | coder | 仅表示人类要求 full reset |
| `Done` | 无 | terminal，解除后续 blocker |

状态改变由对应 agent 通过工具完成。Orchestrator 只读取状态并决定是否唤醒对应角色。

### 4.2 前置 blocker 只由 `Done` 解除

V0.2 之后，前置 blocker 的解除条件固定为：

```text
blocker issue state == Done
```

不能复用通用 `terminal_states` 来判断依赖解除。`Closed`、`Cancelled`、`Canceled`、`Duplicate` 等状态可以是 tracker terminal，但不能自动表示“这个前置工作已经正确完成，可以放行后续 issue”。

如果 blocker 状态缺失、无法读取或不是 `Done`，对应 `Todo` issue 在依赖维度上不可执行。

## 5. 项目级 `review_mode` 合同

### 5.1 `review_mode` 是人类维护的项目级配置

V0.2 在项目登记源中新增 `review_mode`。它是人类维护的项目级字段，必须通过 ProjectContext 下发到运行时和展示层。

允许值：

| 值 | 含义 |
| --- | --- |
| `human_gated` | AI review 通过后进入 `Human Review`，由人类批准后再进入 `Merging` |
| `auto_merge` | AI review 和 checks 通过后可以进入 `Merging`，由 lander 执行自动合并路径 |

缺失、读取失败或暂时无法判断时，运行时有效模式回退为 `human_gated`，并记为健康 warning。明确非法值时，运行时仍按 `human_gated` 解释，但项目健康检查必须标记为 failed，阻断该项目的新派发，直到人类修正配置。

UI 必须展示每个项目当前 `review_mode`、运行时有效模式和健康结果，并尽量展示来源版本或最后更新时间，方便解释 gate 失效原因。

### 5.2 `review_policy` 是项目级辅助配置

V0.2 还使用项目级 `review_policy` 来定义 review 闭环里的等待上限。它是项目级配置，必须能从 ProjectContext 读取出来，并在 UI 中展示是否使用默认值。

最少需要三项：

| 字段 | 含义 |
| --- | --- |
| `review_attempt_limit` | 单个 issue cycle 内允许的总 review 尝试上限 |
| `checks_pending_timeout_minutes` | `AI Review` 中等待 checks 变绿的最长时间 |
| `merge_pending_timeout_minutes` | `Merging` 中等待 merge confirmed 的最长时间 |

`review_attempt_limit`、`checks_pending_timeout_minutes` 和 `merge_pending_timeout_minutes` 都必须是正整数。仓库默认值分别是 `3`、`30`、`15` 分钟；ProjectContext loader 在字段缺失时注入这些默认值。`review_attempt_limit` 只控制单个 issue cycle 的总 `review_attempt` 上限，不按 `review_outcome_class` 计数；`repeat_count` 仅记录某个 `review_outcome_class` 连续出现了多少次，用于 UI、日志和人工排障，但不会单独决定状态迁移。

缺失时按仓库默认值处理；明确非法值时，项目健康检查标记 failed，阻断该项目新派发，直到人类修正配置。

### 5.3 `review_mode` 不能在 issue 启动时锁死

人类可以在 issue 开发过程中修改项目模式。V0.2 不允许 coder、reviewer 或 lander 使用 dispatch 时的旧 mode 作为最终放行依据。

长期规则：

- dispatch 可以携带当时观察到的 `review_mode`，但它只是观察值。
- 提交 / review / merge 路由必须重新读取当前 ProjectContext。
- AI Review Gate 中的 mode 只用于审计，不用于永久放行。
- `review_mode` 可以在 issue 到达提交 / 收口前持续变化；进入提交阶段后，coder、reviewer 和 lander 都要以最新 ProjectContext 为准。

## 6. Submission Refresh Gate

### 6.1 刷新门的目的

Submission Refresh Gate 是 coder 在提交 / 收口前必须执行的一次运行期事实刷新。它防止 coder 按旧项目模式、旧人类评论或旧 PR head 进入后续状态。

### 6.2 刷新门不读取哪些内容

V0.2 明确不要求 Submission Refresh Gate 重新读取：

- `WORKFLOW.md`
- `CHANGE_FLOW.md`
- `TESTING.md`

这些文件不是本阶段设计中的动态可变输入。它们仍是 agent 执行规则，但不属于每次提交前的刷新对象。

### 6.3 刷新门读取哪些内容

Submission Refresh Gate 必须刷新：

- 当前 ProjectContext 中的 `review_mode`。
- 当前 ProjectContext 中的 `review_policy`。
- Linear 上最新人类评论。
- 当前 PR 是否存在、PR number 是什么。
- 当前 branch / PR latest head SHA。
- 当前 checks 状态。
- 是否存在人类 hold、request small fix、request full rework、override AI findings 或 approve current head 等明确业务指令。

coder 在以下动作前必须执行刷新：

- push branch 前。
- create/update PR 前。
- 从 `In Progress` 改到 `AI Review` 前。

刷新结果必须写入 `## Codex Workpad`，用于 reviewer 和 lander 后续判断。

`review_mode`、人类评论和 PR head 只能作为提交前最新事实，不作为仓库规则文件的替代品。Submission Refresh Gate 只负责刷新事实，不负责重新解释 `WORKFLOW.md`、`CHANGE_FLOW.md` 或 `TESTING.md`。

## 7. AI Review Gate

### 7.1 Gate 必须绑定 head

AI Review Gate 是 Linear 中的结构化 review 记录。它必须绑定一个具体 PR head，不能只写“通过”。

最小字段：

| 字段 | 含义 |
| --- | --- |
| `project_key` | 项目身份 |
| `observed_review_mode` | reviewer 当时看到的项目模式 |
| `mode_source_fingerprint` | mode 来源版本或指纹 |
| `pr_number` | 被审 PR |
| `head_sha` | 被审 commit |
| `review_attempt` | 第几轮 review |
| `review_outcome_class` | `code_fix_needed`、`checks_pending`、`checks_failed`、`uncertain`、`human_hold`、`full_reset_requested` |
| `repeat_count` | 同类结果连续出现的次数 |
| `gate_revision` | gate 记录版本 |
| `review_result` | `pass`、`fail`、`uncertain` |
| `checks_status` | `pending`、`green`、`fail` |
| `latest_human_comment_timestamp_considered` | 已考虑到哪条人类评论 |
| `findings` | findings 或通过说明 |
| `commands/evidence` | 关键命令和证据 |
| `created_at` | gate 写入时间 |

### 7.2 Gate 失效规则

长期保持的失效规则：

- `head_sha` 变化：旧 review 结果完全失效。
- `review_mode` 变化：旧代码审查证据可参考，但路由结论失效。
- 新增人类业务评论：旧 gate 不能直接放行，必须重新分类。
- checks 状态变化：必须重新确认同一个 `head_sha` 上的 review + checks。

### 7.3 AI reviewer 权限边界

AI reviewer 可以：

- 读代码和 diff。
- 在独立 review worktree 中运行验证。
- 读取 GitHub checks。
- 写 Linear `## AI Review Gate`。
- 按规则修改 Linear 状态。
- 只写本合同列出的状态迁移，不得任意编辑其它 Linear 字段。

AI reviewer 不可以：

- 修改生产代码。
- commit。
- push。
- 创建或更新 PR。
- 在 PR body 或 PR review 中写 review 结论。
- 把普通 fail 改成 `Rework`。

AI review 的 attempt 计数长期规则：

- `review_attempt` 记录在 Linear 的 `## AI Review Gate`，并可以在 `## Codex Workpad` 中镜像。
- 只有 reviewer 审过新的 `head_sha`，才算进入下一轮 attempt。
- 只是在同一个 `head_sha` 上重跑 checks、补证据或重新读取人类评论，不重新计数。
- `review_attempt` 的上限来自项目级 review policy；缺失时按仓库默认值处理，仍然缺失时必须 fail closed 到 `Human Review`。
- `Rework` 会开启新的 issue cycle，新 cycle 重新从 1 计数。
- `repeat_count` 仅记录同类结果连续发生的次数，便于 UI、日志和人工排障；它不是独立门禁，也不会单独触发状态迁移。

## 8. GitHub PR 与 checks 边界

### 8.1 GitHub 不是 review 真相源

V0.2 默认选择 Linear 作为唯一 review 真相源。GitHub PR 只承载：

- diff
- branch
- checks
- merge / auto-merge 能力

PR body 写给人看，只写摘要、测试、风险和链接。AI reviewer 的判断、证据和返修要求写在 Linear `## AI Review Gate`，不写成 PR review 主真相源。

### 8.2 PR 创建后不能立刻 auto-merge

无论项目是 `human_gated` 还是 `auto_merge`，coder create/update PR 后都不能立刻开启 auto-merge。

auto-merge 只允许在 `Merging` 阶段，由 lander 在确认下面条件后开启或执行：

- 当前 ProjectContext 仍为 `auto_merge`。
- PR latest head 等于 AI Review Gate 审查通过的 `head_sha`。
- checks green。
- 没有新的 Linear 人类 hold 或 request changes。
- 当前 ProjectContext 中的 `review_policy` 允许继续等待合并，不超过 `merge_pending_timeout_minutes`。

在任何一次写 Linear 状态、开启 auto-merge 或实际 merge 前，lander 都必须重新比较最新人类评论、当前 `review_mode`、PR latest head 和 AI Review Gate head、以及 checks 状态。只要其中任一项和上一次刷新不一致，就先停止推进，再按新的事实重新分类。

如果 auto-merge 已经被开启，但此时 `review_mode` 变成 `human_gated`、出现新的 human comment 或 checks 变成非 green，lander 必须先取消 / 关闭 auto-merge，再回 `Human Review`、`AI Review` 或 `In Progress`，不能继续沿用旧授权。

lander 在 `Merging` 中持续 watch `latest human comment` / `review_mode` / `head_sha` / `checks`。如果在 `merge_pending_timeout_minutes` 内仍未得到 merge confirmed，必须回 `Human Review` 由人类接手。

### 8.3 checks fail 不能自动合并

checks fail 时，系统不能自动 merge，不能自动 `Done`。

人类可以覆盖 AI reviewer 的业务判断，但 V0.2 默认不允许人类评论把 checks fail 直接转成自动合并。若人类明确要求冒险合并，应进入人工处理路径，不进入全自动路径。

## 9. Human Review 与 Rework 合同

### 9.1 Linear 人类评论是最高业务评论

Linear 上的人类评论优先于 AI Review Gate 的业务判断。AI 可以指出人类评论和仓库规则之间的冲突，但不能用自己的判断覆盖人类评论。

如果人类评论语义不明确，AI 不能猜成批准，应保持或进入 `Human Review` 并请求澄清。

人类明确批准当前 head 时，这个批准只绑定当时的 `head_sha`。一旦 PR latest head 变化，旧批准自动失效，必须重新确认。

### 9.2 `Human Review` 必须记录进入原因

进入 `Human Review` 时，应记录原因：

- `human_gated_pass`
- `ai_uncertain`
- `attempt_limit_exceeded`
- `human_hold`
- `override_needed`
- `timeout_exceeded`

不同原因影响后续路由。人类 hold 或 override 不能被后续 mode 变化自动绕过。

### 9.3 `Rework` 只表示人类要求 full reset

V0.2 收窄 `Rework` 语义：

- AI review fail 回 `In Progress`。
- checks fail 回 `In Progress`。
- 人类要求小修回 `In Progress`。
- 只有人类明确要求完全重做时进入 `Rework`。

`Rework` 进入后按 full reset 处理：关闭旧 PR、archive 旧 workpad、fresh branch、fresh workpad、重新 planning / implementation / validation。
`Rework` 只在 human 明确要求 full reset 时使用；AI reviewer 不能把普通 fail 直接改成 `Rework`。只有人类在 `Human Review` 里手动改到 `Rework`，该状态才生效。

## 10. Review Worktree 合同

AI review 必须使用独立 review worktree，不复用 coder issue workspace。

推荐路径：

```text
<workspace.root>/.reviews/<project_key>/<issue_id>/<pr_number>/<head_sha>/<attempt_id>
```

长期保持的规则：

- review worktree detached checkout 到 `head_sha`。
- review worktree 有 owner / lock / manifest。
- reviewer 不使用 coder workspace 的 git index。
- reviewer 结束后默认删除 review worktree。
- 需要保留证据时，必须在 Linear gate 中记录路径和保留原因。
- issue 到 `Done` 后，清理该 issue 的残留 review worktrees。
- reviewer 写 Linear 状态时只能使用本合同列出的状态迁移，不得任意编辑其它 Linear 字段。
- `Human Review` 的状态迁移由人类手动触发；reviewer / lander 只负责解释当前 head、checks 和评论，不自动替人类推进 `Done`。

## 11. Todo Pool 长期边界

Todo Pool 是首页人工检查区，只读展示各项目 `Todo` 卡片及其前置 blocker。

长期保持的规则：

- `Todo Pool` 不触发 dispatch。
- `Todo Pool` 不修改 Linear。
- `Todo Pool` 不成为调度器数据源。
- 展示只使用前置 blocker，不混入普通关联关系。
- 未知 blocker 状态不能显示成可执行。
- 单项目读取失败只影响该项目展示。
- runtime `blocked` 与 Todo 前置 blocker 不能混用。

## 12. 健康检查长期边界

健康检查是只读诊断和运行期派发保护。

长期保持的规则：

- 全局健康失败阻断全池新派发。
- 项目级健康失败只阻断对应项目新派发。
- 健康检查不写回 `project_registry.yaml`。
- 健康检查不自动改 `enabled`、`review_mode` 或 Linear issue 状态。
- 恢复动作只重新检查、清除健康失败缓存或请求立即 poll。
- UI 重启主进程不属于 V0.2 健康检查主线。

健康检查结果是 runtime state，不是 canonical registry。缺失 `review_mode` 时默认按 `human_gated` 运行并记 warning；明确非法 `review_mode` 时，项目级健康检查标记 failed，阻断该项目新派发，直到人类修正配置。
`review_policy` 也属于项目级健康输入；缺失时可用默认值，明确非法时标记 failed，阻断该项目新派发。

## 13. 长期质量门禁

后续凡是实现 V0.2 全自动流转能力，至少要继续复核：

1. 状态角色门禁：coder / reviewer / human / lander 路由不混用。
2. blocker 门禁：只有 `Done` 解除前置 blocker。
3. mode 门禁：`review_mode` 来自 ProjectContext，且提交 / review / merge 前刷新当前值。
4. Linear 真相源门禁：AI review 结论和人类评论以 Linear 为准，PR 不成为第二 review 真相源。
5. head-bound gate 门禁：AI Review Gate 绑定 PR latest head，head 变化后旧 gate 失效。
6. checks 门禁：checks fail 不自动 merge，不自动 `Done`。
7. auto-merge 门禁：PR create/update 后不自动开启 auto-merge；只有 `Merging` 阶段 lander 可按 mode 开启。
8. Rework 门禁：`Rework` 只由人类 full reset 决策触发。
9. review worktree 门禁：review 不污染 coder workspace，cleanup 生命周期独立。
10. UI 门禁：项目 review mode、Todo Pool、健康状态的展示只消费上游合同，不自造第二真相源。
