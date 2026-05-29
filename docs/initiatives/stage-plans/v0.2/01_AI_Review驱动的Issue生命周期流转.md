# AI Review 驱动的 Issue 生命周期流转

日期：`2026-05-29`
状态：`主文档，已收口，待文档复核`
阶段：`V0.2`
讨论级别：`Level 3`

## 1. 这份文档在解决什么

V0.2 最核心的问题，是让每张 Linear issue 的生命周期可以被清楚、稳定、可自动化地执行。

目标不是定义“一组 issue”，也不是增加新的任务池。每张 issue 只根据自己的 Linear 状态、前置 blocker、项目配置和 review 结论进入下一步。前置 blocker 只看“这张 issue 前面被谁挡住”，不看它挡住了谁，也不看普通关联关系。

一句话定义：

> V0.2 主流程让单张 issue 能从 `Todo` 开始，在没有未完成前置 blocker 时被 coder 执行，经过 AI review、人类 gate 或全自动路径后，到达 `Done`；只有 `Done` 才解除后续 issue 的前置 blocker。

## 2. 现有的是什么

### 2.1 当前单卡状态流已经存在

当前 `elixir/WORKFLOW.md` 已经定义了单张 issue 的基本流转：

- `Todo`：已排队；active work 前由 coder 改到 `In Progress`。
- `In Progress`：coder 正在执行。
- `Human Review`：PR 已 attached 且 validated；等待人类 approval。
- `Rework`：reviewer 要求 changes；当前语义是 full reset。
- `Done`：terminal state，不需要继续操作。

当前 `SPEC.md` 也已经固定边界：Orchestrator 是 scheduler / runner / tracker reader，ticket writes 通常由 coding agent 通过工具完成，不由 Orchestrator 内置业务写入逻辑。

### 2.2 当前 Todo blocker 规则已经存在

当前 Orchestrator 已经有保护规则：

- `Todo` issue 如果存在未完成前置 blocker，不进入 dispatch。
- `Todo` issue 如果前置 blocker 全部完成，才继续进入容量、claimed、running、retry 和 worker 等后续检查。

V0.2 保留这条规则，但收紧“完成”的判断：前置 blocker 只有到 `Done` 才算解除。不能把 `Closed`、`Cancelled`、`Duplicate` 等通用 terminal states 当作依赖解除依据。

### 2.3 当前流程缺口在 review

当前人类 review 已经能表达“coder 下线、等待外部判断”，但 V0.2 要补的是 AI review agent 的闭环：

- AI reviewer 什么时候被唤醒。
- AI reviewer 看哪个代码版本。
- AI reviewer 是否能改代码。
- AI review 不通过时谁来修。
- PR checks 和 AI review 谁能放行。
- 人类参与模式与全自动模式如何不混乱。
- 人类评论如何覆盖 AI 判断。

## 3. 新增的是什么

### 3.1 新增 `AI Review` 状态

V0.2 新增一个独立 Linear 状态：

```text
AI Review
```

它不复用 `Human Review`。两者语义必须分开：

| 状态 | 谁处理 | 含义 |
| --- | --- | --- |
| `AI Review` | review agent | coder 已完成一个可审查版本，系统可以唤醒 AI reviewer |
| `Human Review` | 人类 | 自动流程停下，等待人类业务判断 |

`AI Review` 是机器 gate，不是人类 gate。`Human Review` 是人类 gate，不自动唤醒 coder 写代码。

### 3.2 状态到角色的路由表

V0.2 当前运行身份只区分两类：

- `In Progress` = coder mode
- `AI Review` = reviewer mode

它们的共同前提是：

- 同一张 issue
- 同一个 issue workspace
- 不同 state 下启动的新 run

返修或复审时，不恢复旧线程；每次重新唤醒都是新的 run / 新的 session。

| Linear 状态 | 允许唤醒的角色 / mode | 说明 |
| --- | --- | --- |
| `Todo` | coder | 仅当没有未完成前置 blocker 时允许调度 |
| `In Progress` | coder | 实现、修复 review finding、修复 checks、在 PR 创建后短时等待 checks |
| `AI Review` | reviewer | 审查完整 issue prompt，但以 issue body 为默认一级输入；review 通过后可直接完成最终 merge |
| `Human Review` | 无自动推进 | 等待人类评论或人类状态修改 |
| `Rework` | coder | 只用于人类要求完全重做 |
| `Done` | 无 | terminal，触发 workspace cleanup，并解除后续 blocker |

Orchestrator 只根据最新 tracker 状态决定是否唤醒对应角色，不直接修改 Linear 状态。

当前最小实现要求还包括：

- `AI Review` 必须加入 `active_states`
- `WORKFLOW.md` 需要按 `issue.state` 在 prompt 顶部注入 reviewer 前缀
- 编排器在派发 `AI Review` run 时，必须复用该 issue 已存在的 `workspace_path`，不得为 reviewer 新建第二 workspace 或第二 worktree
- 本轮不引入第二套 `CODEX_HOME`、第二套 agent home，也不引入 reviewer 专属 payload

### 3.3 新增项目级 `review_mode`

V0.2 在项目登记源中新增 `review_mode`。它是人类维护的项目级字段，必须从 ProjectContext 下发到当前主线真正会用到它的流程阶段。

建议取值：

| 值 | 含义 |
| --- | --- |
| `human_gated` | AI review 通过后进入 `Human Review`，由人类决定是否批准当前 head |
| `auto` | 全自动路径。当前语义是 AI review 通过后由 reviewer 直接手动 merge 当前 PR；不是 GitHub auto-merge |

缺失、读取失败或暂时无法判断时，当前流程语义回退为 `human_gated`。

`review_mode` 不是 issue 启动时永久锁死的字段。只要 issue 还没进入提交 / 收口阶段，人类可以修改项目模式。真正决定提交路径时，至少 coder 与 reviewer 都必须重新读取当前 ProjectContext 中的最新 `review_mode`。

### 3.4 对 `WORKFLOW.md` 与 prompt 组装的最小回填要求

为了让当前主线真正可实现，`WORKFLOW.md` 至少要补下面两条：

1. 在 `tracker.active_states` 中加入 `AI Review`
2. 在 `issue.state == "AI Review"` 时注入 reviewer 前缀

两种状态的 prompt 语义应收成：

- `In Progress`
  - 沿用当前 coder prompt
  - 继续传完整 issue prompt
- `AI Review`
  - 传 reviewer 前缀 + 完整 issue prompt
  - reviewer 仍会看到完整正文，但会被明确提醒自己的身份、边界以及在 `auto` 路径下需要自己完成最终 merge

当前 reviewer 前缀至少要明确告诉 worker：

- 你当前处于 `AI Review`
- 你现在是 reviewer，不是 coder
- 默认以 issue body 为一级输入
- 重点查看 `Goal`、`Scope Snapshot`、`Review Summary`、`Validation`、`Acceptance Criteria`、`Blockers`
- 默认不要把评论区当主输入；只有正文不足或需要确认最新人类要求时才去读评论区
- 若读取评论区，只采信最新有效信息
- 如需追执行细节或验证轨迹，再进入 `## Codex Workpad`
- 不修改生产代码，不 commit，不 push
- 如果当前 `review_mode = auto` 且你判断可以通过，则在写完正文与评论区汇报后，直接手动 merge 当前 PR；如果 merge 失败则改到 `Human Review`

这一节在实现层面的含义要再说清楚：

- 当前不需要新增第二套 Codex command
- 当前不需要新增第二套 `CODEX_HOME`
- 当前不需要改单独的 `PromptBuilder` 字段输入协议
- 当前要改的是同一个 `WORKFLOW.md` 模板里的状态分支与 `active_states`

### 3.5 新增项目级 `review_policy`

V0.2 当前主线最少只依赖一个硬门禁字段：

| 字段 | 含义 |
| --- | --- |
| `review_attempt_limit` | 单个 issue cycle 内允许的 review / 返修往返上限 |

当前默认值是 `3`。若缺失或非法，当前稿只锁定流程语义上的保守解释，不额外展开项目健康检查或 dispatch 阻断机制。

`review_attempt_limit` 的解释按当前回填后的流程改写为：

- 每次 reviewer 基于新的 coder 提交结果重新做一轮审查，计为新的一次往返
- 第二次、第三次返修时，虽然是新的 run / 新的 session，但仍属于同一个 issue cycle
- 只要当前 cycle 的总往返次数达到 `review_attempt_limit`，issue 就必须转入 `Human Review`

旧草案中的下面两个字段，在当前主线中不再作为门禁使用：

- `checks_pending_timeout_minutes`
- `merge_pending_timeout_minutes`

原因不是它们永远无效，而是：

- 当前顺序已经改成“先 checks，再 AI Review”
- 当前主线不采用“长时间 merge watcher / merge timeout 观察器”这一套设计

因此本稿不再把这两个超时字段写成当前 V0.2 主线必须实现的合同。

### 3.6 Linear、GitHub 与三层载体分工

V0.2 采用：

> Linear 是主流程真相源；GitHub PR 只承载 diff、checks、分支和 merge 能力。

这意味着：

- `issue body` 是稳定主合同，也是新 run 的默认一级输入
- `## Codex Workpad` comment 是执行台账与过程证据区
- 普通评论区是每轮汇报与人类沟通区
- GitHub PR 不作为 AI review 结论的主承载
- V0.2 默认不依赖 GitHub required reviews
- PR body 写给人看，只写摘要、测试、风险和链接，不写给 reviewer 的 AI 指令

当前 `issue body` 的稳定结构按本轮结论采用：

- `Goal`
- `Scope Snapshot`
- `Execution Brief`
- `Validation`
- `Acceptance Criteria`
- `Review Summary`
- `Blockers`

这里的 `Scope Snapshot` 是大类，不和下面那些 scope 说明并列。像：

- 本卡负责
- 本卡明确不做
- 需要保持不变的旧行为
- 当前阶段边界

这类内容默认属于写卡人预先写好的任务传递信息，不是 coder 每轮都要主动重写的执行台账。除非人类明确修改范围，否则 coder / reviewer 只需要在自己负责的位置维护信息，不需要反复重写这些 scope 子项。

其中：

- `Review Summary` 放在 issue body，不放进 `Codex Workpad` 原始模板
- coder 与 reviewer 都必须维护 issue body
- 任何一轮结束前，都必须先更新 issue body，再按需要更新 `## Codex Workpad`，最后写一条短评论汇报

这里的维护顺序是当前主线的硬要求：

1. 先更新 issue body
2. 再按需要更新 `## Codex Workpad`
3. 最后写评论区汇报

`## Codex Workpad` 的“按需要更新”也要写清楚：

- 只要 `Plan` 发生变化，就更新 `## Codex Workpad`
- 只要新增了验证证据、执行轨迹、过程性说明，就更新 `## Codex Workpad`
- 如果只是稳定合同变化而没有新增过程细节，至少先改 issue body

`## Codex Workpad` 继续保留仓库原始职责：

- `Plan`
- `Acceptance Criteria`
- `Validation`
- `Notes`
- `Confusions`

它在当前仓库原始定义里，仍然是一条单一的 persistent comment。

但它不再是后续 worker 的默认一级自动输入。只有在需要追执行细节、验证轨迹或审计过程时，才去读取它。

普通评论区的规则定为：

- 每一轮都必须写汇报
- 默认短汇报
- 只有存在未解决问题、blocker 或需要人类特别关注时才写长
- 评论区不是机器真相源，也不是主流程继承区

如果 `issue body` 和 `## Codex Workpad` 对同名字段出现冲突：

- 以 `issue body` 为准
- worker 发现冲突后，必须先修正 `issue body`，再同步 `## Codex Workpad`

Linear 上的人类评论是最高业务评论。AI 如果认为人类评论和仓库规则冲突，可以说明冲突和风险，但业务判断必须以人类评论为最高守则。

在 `Human Review` 里，不会自动唤醒 coder / reviewer 去替人类写状态。离开 `Human Review` 的状态迁移由人类手动完成，允许的手动方向是：

- 批准当前 head -> 允许继续当前人工路径；是否继续推进由人类或后续 agent 明确执行
- 要求小修 -> `In Progress`
- 要求完全重做 -> `Rework`
- 暂停 -> 保持 `Human Review`

`Done` 不是人类可直接写入的人工 override 状态；`Done` 只由实际 PR merged 事件触发。这样可以避免 blocker 被人类误放开。

机器硬约束不能被伪装绕过。PR 不存在、push 失败、权限不足、branch protection 拒绝、checks 未完成或 failed 等情况，不能因为一句人类评论就自动进入 `Done`。如果人类明确要求在 checks fail 时继续推进，V0.2 默认进入人工处理路径，不进入全自动 merge 路径。

## 4. 完整生命周期

### 4.1 `Todo` 到 `In Progress`

调度器每轮从 tracker 读取 active states。一个 `Todo` issue 只有满足下面条件时才可唤醒 coder：

1. 当前 state 是 active 且不是 terminal。
2. 没有 running / claimed / retry 冲突。
3. 全局、项目级、state 级、worker host 容量允许。
4. 没有未完成前置 blocker。

这里的“前置 blocker 完成”只认 `Done`。如果 blocker 是 `Closed`、`Cancelled`、`Duplicate` 或状态缺失，V0.2 不能把它当作明确可解除。

coder 被唤醒后，按 workflow 自己将 issue 改到 `In Progress`，然后开始工作。

### 4.2 `In Progress` 的实现、提交与 checks 等待

coder 在 issue workspace 中执行实现、验证、提交和 checks 等待。

进入提交 / 收口动作前，必须执行 `Submission Refresh Gate`。它不是重新读取仓库规则文件；`WORKFLOW.md`、`CHANGE_FLOW.md`、`TESTING.md` 在本阶段不作为动态可变输入。它只刷新运行期会变的事实：

- 当前 ProjectContext 中的 `review_mode`。
- 当前 ProjectContext 中的 `review_policy`。
- Linear 上最新人类评论。
- 当前 PR 是否存在、PR number 是什么。
- 当前 branch / PR latest head SHA。
- 当前 checks 状态。
- 是否存在人类 hold、request small fix、request full rework、override AI findings 或 approve current head 等明确业务指令。

coder 在下面动作前必须完成刷新：

- `push branch` 前。
- `create/update PR` 前。
- 从 `In Progress` 改到 `AI Review` 前。

进入 `AI Review` 之前，coder 的收口顺序改成：

1. 本地验证已按当前任务要求通过。
2. 工作区 clean。
3. 已提交 commit。
4. 已 push branch。
5. 已创建或更新 PR。
6. PR 建好后，coder 继续停留在同一个 `In Progress` run 内，按每 `1` 分钟一次的频率检查 required checks。
7. 如果 checks fail，则保持 `In Progress`，由当前 coder 继续修复、push、更新 PR，再继续等待。
8. 如果 checks green，则先维护 issue body，再按需要维护 `## Codex Workpad`，最后写一条短评论汇报。
9. 没有开启 GitHub auto-merge。
10. 完成上述动作后，coder 才将 issue 改到 `AI Review` 并退出。

因此，V0.2 当前主线不再采用“PR 建好后立刻进入 AI Review”的旧顺序，而是：

```text
push / create-update PR
-> checks green
-> AI Review
```

coder 把卡推进到 `AI Review` 前，issue body 至少必须补齐下面七项：

- `Goal`
- `Scope Snapshot`
- `Execution Brief`
- `Validation`
- `Acceptance Criteria`
- `Review Summary`
- `Blockers`

这里的意思不是 coder 要把 `Scope Snapshot` 内部子项全部重写一遍，而是：

- 这块任务传递信息必须在卡片成型时就存在
- reviewer 在审查时需要能看到它
- 只有当 `Scope Snapshot` 本身缺失或已经和当前卡的真实边界明显冲突时，才视为 handoff 不完整

`review_mode` 允许人类在提交 / 收口前随时修改。提交阶段从 `Submission Refresh Gate` 开始才要求 coder 读取当前有效模式；在此之前，项目模式仍可按人类决策改写。

### 4.3 `AI Review`

reviewer 被 `AI Review` 唤醒后，拿到的是完整 issue prompt 与当前 issue workspace。当前主线不再把 reviewer 建模成第二 workspace / 第二 worktree / 第二并行线程，而是沿用同一张卡、同一 workspace、不同 state 下的新 run。

这里的前提是：coder 在把状态推进到 `AI Review` 前，必须已经完成 commit / push / PR update，并保证当前 workspace clean。reviewer 复用的就是这份已收口、已清理的同一 workspace，而不是另一份独立副本。

这也意味着编排器在 `AI Review` dispatch 时，不能重新分配新的 review 工作区；它必须把 reviewer run 绑定到这张 issue 当前已经存在的 workspace 上继续执行。

reviewer 必须通读完整 issue prompt，但默认以 issue body 为一级输入，重点查看：

- `Goal`
- `Scope Snapshot`
- `Review Summary`
- `Validation`
- `Acceptance Criteria`
- `Blockers`

评论区默认不是 reviewer 的主输入。只有当：

- issue body 仍不足以支撑判断
- 或 reviewer 需要确认最新人类要求

时，reviewer 才去读取评论区。若读取评论区，只采信最新有效信息，不得把旧评论、已过时评论、或已被最新 issue body 覆盖的信息混入当前结论。

`## Codex Workpad` 也不是 reviewer 的默认一级输入。只有需要追执行细节、验证轨迹或过程证据时，才去读它。

reviewer 权限边界：

- 可以读代码、读 diff、运行验证、读取 checks。
- 可以按规则修改 Linear 状态。
- 禁止修改生产代码。
- 禁止 commit、push、创建 PR、修改 PR body。
- 只有当 `review_mode = auto` 且当前 review 结论为通过时，才允许在完成正文与评论区更新后直接手动 merge；除此之外不执行 merge。

reviewer 结束自己这一轮前，必须：

1. 先更新 issue body，尤其是 `Review Summary`、`Blockers` 与其他已失效或已变化的区块
2. 如需补充过程细节，再更新 `## Codex Workpad`
3. 最后写一条给人类看的评论区汇报

评论区汇报规则固定为：

- 每轮必写
- 默认短汇报
- 只有存在未解决问题、blocker 或需要人类特别关注时才写长

`Review Summary` 在这里承担的职责是：

- reviewer 写入本轮 review 结论
- 列出需要返修的问题
- 在通过时说明当前为何可放行

已失效的旧结论不应原样堆积，而应被新的有效状态覆盖。这样第二次、第三次返修时，新拉起的 coder 可以直接从最新 `Review Summary` 接棒。

AI review 结果：

- `fail`：改回 `In Progress`。
- `uncertain`：改到 `Human Review`。
- `pass`：
  - 当前 `review_mode = human_gated`：改到 `Human Review`。
  - 当前 `review_mode = auto`：先更新 issue body、`## Codex Workpad` 与评论区汇报，然后由 reviewer 直接手动 merge 当前 PR；merge 失败则改到 `Human Review`。

当前顺序下，checks 已经在 `AI Review` 之前完成，所以本节不再保留 `pass + checks pending` 这类在 review 内等待 checks 的旧分支。

如果 reviewer 发现 issue body 最少必备七项缺失到无法判断，也应直接视为 handoff 不完整，改回 `In Progress`，而不是在 `AI Review` 内兜底等待。

### 4.4 AI review 失败后的 `In Progress`

AI review 不通过时，issue 回到 `In Progress`。

此时不进入 `Rework`。coder 会以新的 run / 新的 session 被重新唤醒，但继续使用同一个 issue workspace、branch 和 PR。

新的 coder run 会再次拿到完整 issue prompt，但主接棒位置应是 issue body 里的最新 `Review Summary`。coder 返修完成后，必须把 `Review Summary` 改写成“当前哪些 finding 已解决、哪些仍未解决、下一步应该进入什么状态”的最新状态，不能把过时 review 结论原样留在那里误导下一轮。

为避免无限循环，V0.2 当前主线只要求控制总往返次数，不再要求一套额外的 `AI Review Gate` 字段表。

当前要求是：

- issue body 中必须能看出当前是第几轮 review / 第几轮返修
- 每次 reviewer 完成一轮审查并打回 `In Progress`，总往返次数加一
- 只要往返次数达到 `review_attempt_limit`，就必须进入 `Human Review`

### 4.5 `Human Review`

`Human Review` 只表示自动流程停下，等待人类业务判断。进入这个状态后，不会自动唤醒 coder / reviewer 去替人类推进状态；系统只保留 issue body、`## Codex Workpad`、最新评论、checks 和 PR 信息供人类查看。

进入原因必须记录，例如：

- `human_gated_pass`：项目是人类参与模式，AI review 已通过。
- `ai_uncertain`：AI reviewer 不确定。
- `attempt_limit_exceeded`：自动返修次数超限。
- `human_hold`：人类评论要求暂停。
- `override_needed`：人类评论与当前流程结论存在冲突，需要人工裁决。

人类评论的推荐语义：

| 人类意图 | 推荐状态 |
| --- | --- |
| 批准当前 head | 保持或进入 `Human Review`，由人类明确允许继续；不要求新增单独 merge 状态 |
| 要求小修 | 人类手动写入 `In Progress` |
| 要求完全重做 | 人类手动写入 `Rework` |
| 暂停 | 保持 `Human Review` |
| 覆盖 AI finding | 由 agent 说明风险后按人类评论继续，但仍不能绕过机器硬约束 |

如果人类评论语义不明确，AI 不能猜成批准，应保持或进入 `Human Review` 并请求澄清。

如果人类明确批准当前 head，这个批准只绑定当时的 PR latest head。一旦 PR latest head 变化，旧批准自动失效，必须重新确认。

### 4.6 `Rework`

`Rework` 保留，但语义收窄为：

> 人类明确要求完全重做。

AI reviewer 不能把 issue 改到 `Rework`。普通 AI review fail 或 checks fail 都回 `In Progress`。只有人类在 `Human Review` 里明确要求完全重做时，才手动把 issue 改到 `Rework`。

进入 `Rework` 时，当前稿只锁定它的语义边界：

- 这是人类明确要求的 full reset
- 它不是普通 review fail 的出口
- 具体执行动作仍可沿用现有 workflow 思路，但本轮不把“关闭旧 PR / 新建 fresh branch / 重建 workpad”等细节写成已经重新拍板的当前合同

这样 `Rework` 不会闲置：它只服务人类明确要求“不是小修，而是整轮重来”的情况。

### 4.7 全自动路径下的直接 merge

当前主线不再保留单独的 `Merging` 状态。

它的定义现在收成一句话：

> 当 `review_mode = auto` 且 reviewer 判断当前 PR 可以通过时，由 reviewer 在完成正文与评论区更新后直接手动 merge 当前 PR；成功则依赖 `On PR merge -> Done` 收口，失败则改到 `Human Review`。

这一条的含义是：

- 不新增第三种长期角色
- 不新增 merge 专属 prompt
- 不要求给 merge 单独传正文或评论
- 不要求 reviewer 在 merge 前再做一轮完整 checks 判断
- 只要当前流程能进入 `auto` 路径，就把 merge 动作视为 reviewer 放行后的最后一步

reviewer 在 `auto` 路径里只做下面几步：

1. 完成 review 结论
2. 先更新 issue body，尤其是 `Review Summary` 与 `Blockers`
3. 如有需要，再更新 `## Codex Workpad`
4. 写一条给人类看的评论区汇报
5. 直接手动 merge 当前 PR

如果 merge 失败：

- 改到 `Human Review`
- 由人类决定是重新回 `In Progress`、继续处理，还是手动接管

Linear 自动化在这里固定为：

- `On PR ready for merge -> No action`
- `On PR merge -> Done`

所以当前主线里，所谓 `auto` 只表示“AI review 通过后由 reviewer 直接手动 merge”，不表示使用 GitHub 的 auto-merge 功能。

### 4.8 `Done`

`Done` 是唯一解除前置 blocker 的状态。

进入 `Done` 的条件：

- PR 已实际 merged
- merge 不是停留在“已批准”或“ready for merge”阶段，而是 GitHub / Linear 已确认 merge 事实
- 当前完成分支策略仍按“合入主完成分支才算 Done”解释；如果未来引入 `develop`、`staging` 或临时集成分支，需要改成 branch-specific completion policy

进入 `Done` 后，terminal cleanup 删除 coder issue workspace。

## 5. 风险是什么

### 5.1 PR 创建后立刻尝试 merge 会绕过 AI Review

当前仓库旧流程里有“PR create/update 后第一优先级尝试 auto-merge”的规则。V0.2 当前主线必须修正这条规则，否则 checks green 后可能直接合并，绕过 AI Review。

结论：当前主线的顺序必须固定为：

```text
create / update PR
-> checks green
-> AI Review
-> Human Review / reviewer direct merge
-> PR merged
-> Done
```

### 5.2 `review_mode` 不能在 dispatch 时锁死

人类可能在 coder 工作期间切换项目模式。如果 coder 或 reviewer 使用旧模式，会把 `human_gated` 错推进自动路径，或把 `auto` 错停在人类 gate。

结论：提交 / review / merge 的路由必须读取当前 ProjectContext；旧 gate 里的 mode 只作为观察值。

### 5.3 issue body、workpad 和评论区职责混淆会让后续 run 误判

如果把稳定合同、执行台账和人类汇报混在一个地方，第二次、第三次返修时，新 run 会拿到互相冲突的信息，导致 coder 或 reviewer 被过时内容误导。

结论：

- issue body 只放稳定主合同与最新交接信息
- `## Codex Workpad` 只做执行台账与过程证据
- 普通评论区只做每轮汇报和人类沟通
- 同名字段冲突时以 issue body 为准

### 5.4 评论区不能被当成机器真相源

如果把评论区当成默认主输入，reviewer 在第二次、第三次 review 时就必须反复扫全量评论，既耗 token，也容易把旧评论和最新结论混在一起。

结论：评论区只在需要确认最新人类要求、或正文确实不足时才读取；默认主输入仍是 issue body。

### 5.5 `Rework` 不能被 AI reviewer 滥用

如果 AI reviewer 普通 fail 就改 `Rework`，会导致所有小修都走 full reset，浪费 token、分支和 review 成本。

结论：AI reviewer 只能 fail 回 `In Progress`；只有人类明确要求完全重做时才进入 `Rework`。

### 5.6 单独的 merge 状态会把当前主线复杂化

如果继续保留单独的 merge 状态，当前系统就需要额外定义：

- 谁来吃这一步的 prompt
- 这一步是否进入 `active_states`
- 这一步拿什么输入
- 为什么不直接由 reviewer 在通过后点击 merge

结论：

- 当前主线不保留单独的 merge 状态
- `auto` 路径下由 reviewer 直接手动 merge
- merge 成功后依靠 `On PR merge -> Done` 自动收口

## 6. 成功标准

V0.2 主流程后续进入实现前，至少要能用文档和测试证明：

1. 状态到角色的路由清楚，当前只明确 coder / reviewer 两种 prompt 身份。
2. `AI Review` 已进入 `active_states`。
3. `WORKFLOW.md` 能按 `issue.state` 注入 reviewer 前缀。
4. checks 明确发生在 `AI Review` 之前；PR 建好后由 coder 在同一 run 内短时等待 checks。
5. `human_gated` 和 `auto` 的状态出口差异可验证，其中 `auto` 不等于 GitHub auto-merge。
6. issue body、`## Codex Workpad` 和普通评论区的职责分工清楚，且同名字段冲突时以 issue body 为准。
7. `Review Summary` 已正式成为 issue body 的稳定区块，并承担 reviewer 结论与 coder 返修交接。
8. AI review fail / checks fail 回 `In Progress`，不进入 `Rework`。
9. `Rework` 只表示人类要求 full reset。
10. `auto` 路径下由 reviewer 在 review 通过后直接手动 merge；merge 失败转 `Human Review`。
11. `On PR ready for merge -> No action`，`On PR merge -> Done`，且 `Done` 才解除 blocker。
12. 本稿不再把 reviewer 独立 worktree、复杂 merge watcher、评论区自动注入 prompt 等未来方案误写成当前已具备能力。
