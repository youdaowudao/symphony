# 开源 Symphony 轮询、续跑与上下文传递机制

日期：`2026-05-22`
状态：`只读分析`

## 1. 本文边界

这份笔记只基于两类来源：

- 本地规格翻译：`/home/ss/workspace/规划/powersymphony/测试与合并重构讨论/SPEC_简体中文_utf8.md`
- GitHub 开源仓库：`openai/symphony`
  - 本次锚点：`main@2c1851830477434100fdb8980fcc1fce1a8af81d`
  - 提交时间：`2026-05-20`

这份笔记只记录当前已经有直接代码证据支撑的运行机制与业务路径判断，不引入任何本地旧仓库实现细节。

---

## 2. 先给总判断

当前开源 Symphony 的默认运行模型是：

`轮询 issue 快照 -> 判断是否 dispatch / 续跑 -> 启动或延续 coder session -> coder 在 session 内自行使用工具读更多上下文`

它当前不是：

`轮询评论增量 -> 把评论增量直接作为 orchestrator payload 推送给 coder`

### 2.1 这份文档现在是否可直接交接

可以。

这份文档现在已经包含：

- 已确认结论
- 关键实现分层
- 四类评论 / 反馈的读取责任与触发路径
- `Human Review` 与 `active_states` 的默认张力
- 空转问题当前最合理的根因方向
- 接手人下一步最小任务
- 不应再反复误判的点

因此，下一位接手人只需要从这份文档继续，不需要再向上一个人索要一大段额外提示词才能开工。

---

## 3. 编排器外层轮询到底在轮询什么

### 3.1 轮询频率

默认 `elixir/WORKFLOW.md` 中：

- `polling.interval_ms: 5000`

所以 orchestrator 默认每 `5s` 做一次 poll cycle。

### 3.2 轮询拉取的 tracker 数据

`elixir/lib/symphony_elixir/linear/client.ex` 当前 GraphQL 查询拉取的是：

- `id`
- `identifier`
- `title`
- `description`
- `priority`
- `state.name`
- `branchName`
- `url`
- `assignee.id`
- `labels.nodes.name`
- `inverseRelations`
- `createdAt`
- `updatedAt`

关键点：

- 当前查询里没有 `comments`
- 没有 comment threads
- 没有楼中楼
- 没有正文历史版本
- 没有评论增量字段

因此，当前 orchestrator 能直接感知的是“最新 issue 快照”，不是“评论流”。

---

## 4. 两层循环必须分开看

### 4.1 外层：orchestrator poll / reconcile / dispatch

`orchestrator.ex` 当前主循环会做这些事：

1. reconcile 正在 running 的 issue
2. reconcile blocked issues
3. 拉取 candidate issues
4. 按优先级与创建时间排序
5. 有空闲槽位就 dispatch

它的关注点是：

- issue 当前 state 是否仍 active
- issue 是否 terminal
- issue 是否 non-active
- 是否还有可用 agent slot
- 是否需要 retry / continuation

### 4.2 内层：单个 worker session 内的多 turn continuation

`agent_runner.ex` 当前模型不是“一次 worker 只跑一轮 turn”。

它会：

1. 启动一次 app-server session
2. 在同一个 session 内运行多轮 turn
3. 每轮 turn 正常结束后刷新 issue state
4. 如果 issue 仍处于 active state，并且还没达到 `max_turns`，就继续下一轮

默认 `elixir/WORKFLOW.md` 中：

- `agent.max_turns: 20`

所以默认一次 worker lifetime 内最多能跑 `20` 个 turn。

---

## 5. 传给 coder 的内容到底是什么

### 5.1 第 1 轮 turn：完整 prompt + issue 快照

第 1 轮 turn 会通过 `PromptBuilder.build_prompt/2` 渲染 `WORKFLOW.md` prompt。

模板输入只有两个核心变量：

- `attempt`
- `issue`

其中 `issue` 当前包含的可见字段，来自 `Linear.Issue` 结构体：

- `id`
- `identifier`
- `title`
- `description`
- `priority`
- `state`
- `branch_name`
- `url`
- `assignee_id`
- `blocked_by`
- `labels`
- `assigned_to_worker`
- `created_at`
- `updated_at`

然后 `codex/app_server.ex` 会把这整段 prompt 作为：

- `turn/start.params.input = [{type: "text", text: prompt}]`

送进 coder。

所以第 1 轮得到的是：

- 完整 workflow prompt
- 完整 issue 快照

但不是：

- 评论列表
- 评论增量
- 楼中楼增量

### 5.2 同一 session 的 continuation turn：不是重新发送整张 issue

`agent_runner.ex` 中，第 2 轮及之后不会再次调用 `PromptBuilder.build_prompt(issue, opts)`。

它发送的是一段固定 continuation guidance，核心语义是：

- 上一轮正常完成
- issue 仍是 active
- 继续当前 workspace / workpad
- 不要从头重复

所以同一个 app-server session 内：

- 不会自动把最新 issue 正文重新整份塞进去
- 不会自动把评论重发
- 不会自动把评论增量发进去

---

## 6. 什么时候会重新把最新 issue 快照给 coder

只有“新 worker attempt”的首轮 turn，才会重新生成一份基于最新 issue 快照的完整 prompt。

新 worker attempt 的典型来源：

- 正常退出后 issue 仍 active，进入 continuation retry，再次 dispatch
- 异常退出后进入 retry queue，再次 dispatch
- orchestrator 重启后重新接管

也就是说：

- 同一 session 内 continuation：不重发完整 issue
- 新一次 dispatch 的首轮：会重新带上当时最新的 issue 快照

---

## 7. 为什么没有评论也可能继续烧很多 token

### 7.1 直接原因

当前开源仓库的继续条件主要是：

- issue 仍在 active state

而不是：

- 检测到新评论

### 7.2 运行后果

这会导致一种现象：

- 就算没有新评论
- 只要 issue 仍在 active state
- coder 也可能被继续唤起并继续 turn

### 7.3 token 为什么会看起来很大

当前实现里，Codex token 统计来自 app-server usage/rate-limit telemetry。

高 token 不等于 orchestrator 每轮都重新发了很多新内容。

更合理的解释是：

- 同一个 thread 保留了之前的上下文
- workspace、之前的对话、工具调用结果、工作记录都还在上下文链里
- continuation 虽然只新增一小段 guidance，但模型仍在已有 thread 上继续推理

所以：

- “持续烧 token” 和 “持续发送评论增量” 不是一回事

---

## 8. Human Review 的一个关键默认矛盾

`elixir/WORKFLOW.md` 的文字规则里写着：

- `Human Review -> wait and poll for decision/review updates`

但同一个文件 front matter 里的 `tracker.active_states` 默认只有：

- `Todo`
- `In Progress`
- `Merging`
- `Rework`

没有：

- `Human Review`

这意味着按当前默认配置：

- issue 进入 `Human Review` 后，不再属于 candidate active issues
- orchestrator 默认不会继续 dispatch 它

所以如果问题是：

`Human Review 期间，评论区出现 review 评论，默认实现会不会自动继续把评论喂给 coder？`

那基于当前代码，默认答案更接近：

- 不会靠 orchestrator 默认机制自动做到

这也是后续需要继续专项取证的矛盾点。

---

## 9. 四类评论 / 反馈的真实处理路径

这一节回答四件事：

- issue comment
- 楼中楼 / thread comment
- PR top-level comment
- PR inline review comment

并明确说明：

- 谁负责读
- 什么时候会读
- 靠什么状态重新触发
- 默认哪里有断点

### 9.1 总结先说

当前开源 Symphony 里，这四类信息的默认读取责任都不在 orchestrator。

默认责任划分更接近：

- orchestrator 负责调度、续跑、重派发
- agent 负责在 session 内自己去读 issue / PR / comment / review 上下文

所以它的真实业务模型更接近：

`状态驱动唤醒 + agent 自主拉取反馈`

而不是：

`编排器增量捕捉评论并主动转发`

### 9.2 issue comment

#### 谁负责读

默认由 agent 负责读，不是 orchestrator。

证据：

- orchestrator 的 Linear polling 查询不含 `comments`
- `linear` skill 提供 `linear_graphql`
- `WORKFLOW.md` 明确要求 agent 维护单一 `## Codex Workpad` comment，并在运行时查找、复用、更新它
- live e2e 里也直接要求 agent 用 `linear_graphql` 查询 `issue.comments`

#### 什么时候会读

按 workflow 设计，主要会在这些时机读：

- `Todo -> In Progress` 启动时，先找或创建 `## Codex Workpad`
- `In Progress` 持续工作时，反复读并更新 workpad
- `Rework` 时，重新读 full issue body 和 human comments

#### 靠什么状态重新触发

默认主要靠这些 active states：

- `Todo`
- `In Progress`
- `Rework`
- `Merging`

其中 issue comment 对重新唤起最相关的是：

- 人把 issue 重新切到 `Rework`
- 或 issue 仍在 active state，worker 继续续跑 / retry / re-dispatch

#### 默认断点

默认断点有两个：

1. orchestrator 不直接读 comment 增量
2. 如果 issue 已经不在 active state，单靠新 comment 本身不会保证重新唤起

### 9.3 楼中楼 / thread comment

这里先区分两层：

- Linear issue comment thread / reply
- “工作流注释”里的 resolved / unresolved thread 语义

#### 谁负责读

从当前公开代码能直接确认的部分看：

- orchestrator 不读
- agent 可能读，但依赖它在 session 内通过 Linear/GitHub 工具自行查询

当前仓库没有公开出 orchestrator 级别的 thread delta 处理层。

#### 什么时候会读

当前 `WORKFLOW.md` 只明确写了：

- 搜索 `## Codex Workpad`
- 忽略 resolved comments
- 只复用 active/unresolved comment 作为 live workpad

这说明至少在 workpad comment 这个场景里，agent 要理解“resolved / unresolved”。

#### 靠什么状态重新触发

仍然不是靠“检测到楼中楼回复”直接触发。

更接近：

- issue 进入可运行状态后，agent 自己重新查询并判断

#### 默认断点

当前最大的断点是：

- 开源仓库没有给出 orchestrator 级 thread comment 捕捉 / 增量推送能力
- 是否读到楼中楼，取决于 agent session 内具体工具查询与 workflow 执行

### 9.4 PR top-level comment

#### 谁负责读

默认由 agent 负责读。

证据：

- `WORKFLOW.md` 的 `PR feedback sweep protocol` 明写：
  - `gh pr view --comments`
  - gather top-level PR comments

这说明读取责任被下沉到 workflow + agent，而不是 orchestrator。

#### 什么时候会读

默认主要在这些时机：

- `Todo` 且已经有 attached PR 时，启动即进入 feedback / rework loop
- moving to `Human Review` 前，必须完整做一次 `PR feedback sweep`
- `Human Review` / `Rework` 相关流程中，需要重新检查 review updates

#### 靠什么状态重新触发

更稳的主路径是：

- reviewer 给 PR feedback
- 人把 issue 切到 `Rework`
- orchestrator 因 `Rework` 属于 active state 而重新 dispatch
- agent 再自己读 PR comments

#### 默认断点

默认断点是：

- PR top-level comment 本身不是 orchestrator 唤醒 trigger
- 它依赖 agent 被重新跑起来后自己去 GitHub/Linear 读

### 9.5 PR inline review comment

#### 谁负责读

默认也由 agent 负责读。

证据：

- `WORKFLOW.md` 明写 `gh api repos/<owner>/<repo>/pulls/<pr>/comments`
- 这就是显式要求 agent 自己抓 inline review comments

#### 什么时候会读

和 top-level PR comments 一样，主要在：

- attached PR feedback sweep
- moving to `Human Review` 前的清扫
- `Rework` 返工流

#### 靠什么状态重新触发

默认仍主要靠：

- `Rework`
- 或 issue 仍在 active state 时的持续续跑 / 重派发

#### 默认断点

断点也一样：

- inline review comment 不是 orchestrator 原生增量输入
- 它必须在 agent 自己的 PR feedback sweep 中被读到

### 9.6 四类评论的统一判断

当前开源仓库的真实业务逻辑更像：

1. 人类反馈落在 issue / workpad / PR / review thread
2. 状态变化把 issue 带回可运行状态，或 issue 本身继续保持 active
3. orchestrator 重新唤起 agent
4. agent 在 session 内通过 `linear_graphql`、Linear MCP、GitHub CLI/API 自己拉取反馈

所以如果问题是：

`评论有没有用？`

答案是：

- 有用

如果问题是：

`评论是不是会被 orchestrator 精准捕捉后直接传进去？`

答案是：

- 当前默认实现不是这样

---

## 10. 运行中高 token 空转问题

这一条不应该被看成“正常现象”。

按当前开源 Symphony 的设计目标看：

- agent 应该推进工作
- 推不下去时，应该进入合适的人类接管或返工状态
- 不应仅仅因为 issue 还留在 active state，就机械地空转到 `20` 轮

所以“运行中空转、高 token 消耗”更应该被理解为：

- 一类 workflow / 状态流转设计缺陷
- 而不是系统本来就允许的健康行为

### 10.1 当前更接近的根因判断

基于现有代码与默认 workflow，当前更强的判断是：

- 问题主因不像是“没有改状态能力”
- 更像是“有改状态能力，但 workflow 只允许在过窄条件下停和转状态”

换句话说：

- `linear_graphql` 明明允许 agent 调 `issueUpdate`
- `linear` skill 也明确给了 state transition 的做法
- 但默认 `WORKFLOW.md` 又同时施加了很强的继续工作约束

这会把 agent 压进一个危险夹缝：

1. issue 仍是 active state
2. prompt 要求不要在 issue active 时轻易结束 turn
3. prompt 又要求只有满足严格 completion bar 才能转去 `Human Review`
4. 如果 agent 实际上已经做不下去，但又不符合“true blocker”的定义
5. 那它就既不该继续有效推进，也不被鼓励尽快转状态

这种夹缝正是最容易产生空转的地方。

### 10.2 已确认的能力面：不是不能改状态

当前开源仓库里，agent 并不是没有状态写入能力。

已有能力：

- `linear_graphql` 支持 raw GraphQL query / mutation
- `.codex/skills/linear/SKILL.md` 直接给出 `issueUpdate`
- `commentCreate`
- `commentUpdate`
- `attachmentLinkGitHubPR`

所以“做不下去却无法改状态”的问题，至少不能先归因成：

- orchestrator 或 app-server 根本不给改状态入口

更准确的说法是：

- 能力入口是有的
- 但默认 workflow 没把“做不下去时该如何尽快退出 active loop”设计得足够好

### 10.3 已确认的规则压力：为什么容易被困在 active loop

默认 `WORKFLOW.md` 同时给了这些压力：

- `Only stop early for a true blocker`
- `Do not end the turn while the issue remains in an active state unless you are blocked`
- `Operate autonomously end-to-end`
- `Do not move to Human Review unless the completion bar is satisfied`

这几条叠在一起，会形成一个很强的行为偏置：

- 不许轻易停
- 不许轻易转状态
- 不符合严格 blocker 定义也不该上交给人
- 但只要 issue 还在 active state，下一轮又会继续跑

如果 agent 实际处境是：

- 没有新反馈
- 没有更多有效动作
- 也达不到“完成”
- 但又不属于“权限/密钥/认证缺失”那种标准 blocker

它就很容易被困在：

- 既不能合理收口
- 又不能顺利升级状态
- 只能继续尝试的循环里

### 10.4 已确认的调度放大器：为什么它会被放大成高 token

如果 issue 仍在 active state：

- 同一 worker session 内可以连续跑到 `agent.max_turns = 20`
- worker 正常退出后，只要 issue 仍 active，还会被 orchestrator 走 continuation retry 再次派发

因此一旦 workflow 没能及时把 issue 带出 active loop，即使“外部看起来没有新事情”：

- agent 仍可能继续被要求工作
- token 仍可能持续增长

这说明高 token 空转更像是：

- workflow 状态流转设计问题
- 被 orchestrator 的 active-state continuation 机制放大

### 10.5 当前最可疑的具体失配点

当前最需要重点盯的几个方向是：

1. `active state` 过宽
   - issue 长时间停留在 `In Progress` / `Rework`
   - orchestrator 就持续认为它仍值得继续跑

2. continuation 条件过粗
   - 当前继续条件更接近“issue 还 active”
   - 而不是“存在新的外部变化或剩余可执行任务”

3. thread 上下文累积
   - continuation turn 虽然只新增少量 guidance
   - 但 Codex thread 会持续带历史上下文，导致 token 消耗看起来很高

4. 缺少“非 blocker 但也无法继续推进”的显式中间状态
   - 当前 workflow 的 blocker 定义过窄
   - 很容易遗漏“已无有效动作，但也不算权限阻塞”的情况

5. 缺少“空转判停”语义
   - 当前实现对“没有新反馈、没有新计划、没有新代码动作”的空转识别不够强

### 10.6 建议列为后续重点观察 / 改进项

建议后续单独追踪这些问题：

- 为什么某些 issue 在运行中没有有效新增工作，却仍连续消耗大 token
- continuation 是否应增加更严格的“无增量变化则停机”判断
- 是否需要把“评论 / 正文 / PR feedback 是否发生变化”变成更正式的继续条件
- 是否需要把“唤起 agent”和“把新增变化上下文传进去”拆成两层正式机制
- 是否需要新增一个比 `true blocker` 更宽、但又不直接等于“已完成”的收口状态
- 是否需要允许 agent 在“已无有效动作”时更早转入 `Human Review` / `Rework` / 其他中间状态，而不是被 completion bar 卡死

---

## 11. 当前已经能下的最短结论

当前开源 Symphony 的已证实行为是：

1. orchestrator 轮询的是 issue 快照，不是评论流
2. 首轮 turn 会把完整 issue 快照送进 coder
3. 同一 session 内 continuation 不会重新发送整张 issue
4. 没有评论时依然可能继续烧 token，因为续跑条件是“issue 仍 active”
5. 四类评论 / 反馈默认都依赖 agent 自己通过 Linear/GitHub 工具读取
6. 默认配置下 `Human Review` 不在 active_states，和“继续等 review 更新”的文字规则之间存在实现层张力
7. “运行中空转导致高 token 消耗”应列为后续重点观察 / 改进项

---

## 12. 交接给下一位时，最该先记住的点

这一节不是补新结论，而是防止接手人一上来又走偏。

### 12.1 不要再误判成“在线 agent 持续挂着等评论推送”

当前开源 Symphony 更接近：

- active state 内持续运行 / 续跑
- 非 active 或人类接管阶段则 agent 不默认在线
- 之后靠状态重新回到 active，再重新唤起

而不是：

- 像在线客服线程一样持续在线等待评论推送

### 12.2 不要再误判成“评论没用”

评论有用。

但当前实现里，评论的作用更接近：

- 被重新唤起后的 agent 自己去读

而不是：

- orchestrator 把评论增量精准推送给 agent

### 12.3 不要再误判成“做不下去是因为没有改状态能力”

当前公开实现里：

- `linear_graphql` 能做 mutation
- `linear` skill 也给了 `issueUpdate`

所以问题更接近：

- workflow 规则把“何时允许退出 active loop”定义得过窄

### 12.4 不要把默认 `WORKFLOW.md` 的文字规则和实际 active state 配置混成一层

必须一直分层看：

- prompt / workflow 文字里怎么说
- front matter 的 `active_states` 实际怎么配
- orchestrator 真正按什么字段调度

很多矛盾都来自这三层没有分开。

---

## 13. 给下一位接手人的最小任务说明

如果下一位要继续分析，不需要重做全盘盘点。

最小起步任务应该是：

1. 先接受这份文档里的已确认结论为当前基线
2. 不再回头争论“评论到底有没有用”这种已经收口的问题
3. 只沿着后续真正未解的问题继续

当前还值得继续做的方向，按优先级建议是：

### 13.1 方向 A：空转与状态流转缺陷

目标：

- 找出哪些 workflow 规则组合会把 agent 卡在 active loop 内

重点看：

- `WORKFLOW.md`
- `agent_runner.ex`
- `orchestrator.ex`
- `app_server_test.exs`

### 13.2 方向 B：评论 / review 变化是否应变成正式继续条件

目标：

- 判断未来 fork 后，是否要把“有无新反馈”从 agent 自主读取，升级成 orchestrator 可见条件

重点看：

- 当前 Linear polling 查询缺哪些字段
- 哪些 GitHub / Linear 反馈目前完全依赖 agent 自己扫
- 哪些变化值得做成 delta transport

### 13.3 方向 C：`Human Review` 与 `active_states` 的默认矛盾

目标：

- 判断默认 workflow 是否语义不闭合

重点看：

- `Human Review` 为什么写成“wait and poll”
- 但默认又不在 `active_states`
- 这到底是刻意设计，还是参考实现尚未补齐

---

## 14. 给下一位接手人的禁止事项

为了避免重新污染判断，下一位接手人不应该做这些事：

1. 不要引入任何本地旧仓库实现来解释开源 Symphony
2. 不要把 README 宣传描述直接当成实现细节
3. 不要把 “agent 能通过工具读评论” 混同于 “orchestrator 会推评论增量”
4. 不要把 “有状态写入能力” 混同于 “workflow 已经把退出条件设计好”
5. 不要先急着提改法，再回头补机制分析

---

## 15. 给下一位接手人的最短启动口径

如果必须给下一位一句最短启动说明，可以直接用下面这段：

`请只基于这份文档列出的 GitHub 开源仓库证据继续分析，不要引入任何本地旧仓库信息。当前已经确认：orchestrator 轮询的是 issue 快照，不是评论流；评论与 PR review 默认由 agent 自己通过 Linear/GitHub 工具读取；Human Review 与 active_states 之间存在默认张力；空转不是正常行为，更像 workflow 状态流转设计缺陷。请在这个基线上继续，不要重新推翻已确认结论。`

如果不需要复制提示词，直接把这份文档交过去也够用。

---

## 16. 证据入口

- `SPEC.md`
- `README.md`
- `elixir/README.md`
- `elixir/WORKFLOW.md`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/linear/client.ex`
- `elixir/lib/symphony_elixir/linear/issue.ex`
- `elixir/lib/symphony_elixir/prompt_builder.ex`
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- `.codex/skills/linear/SKILL.md`
- `elixir/test/symphony_elixir/live_e2e_test.exs`
- `elixir/lib/symphony_elixir/codex/app_server.ex`
