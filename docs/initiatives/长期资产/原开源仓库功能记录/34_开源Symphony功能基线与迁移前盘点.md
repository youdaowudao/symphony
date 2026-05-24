# 开源 Symphony 功能基线与迁移前盘点

日期：`2026-05-22`
状态：`只读分析`

## 1. 本文边界

这份文档只基于两类来源：

- 你给的本地规格文档：`/home/ss/workspace/规划/powersymphony/测试与合并重构讨论/SPEC_简体中文_utf8.md`
- GitHub 开源仓库：`openai/symphony`
  - 本次复核锚点：`main@2c1851830477434100fdb8980fcc1fce1a8af81d`
  - 该提交时间：`2026-05-20`

这份文档**不使用**任何本地旧仓库资料，也不把 PowerSymphony 现状反投到开源仓库上。

---

## 2. 先给总判断

`openai/symphony` 当前公开出来的，不只是“一份 SPEC + 一个 demo”。

更准确地说，它已经形成了五层可复用资产：

1. `规范层`
2. `参考实现层`
3. `repo-owned workflow 层`
4. `repo-owned skill 层`
5. `测试与 CI 层`

所以你后面要 fork 并继续做，不应该只盯着某几个 Elixir 模块看。

真正要继承的，是它当前已经成形的这些合同：

- Symphony 是什么，不是什么
- 一个 issue 如何被拉起、续跑、停止、回收
- `WORKFLOW.md` 到底承载哪些运行时配置和提示词规则
- agent session 与 workspace 的边界
- Linear 读取、归一化、阻塞判断、只读差分的合同
- 观测面最少要暴露什么
- 哪些能力已经有，哪些能力开源仓库明确还没有

---

## 3. 仓库资产分层

### 3.1 规范层

根目录 `SPEC.md` 定义的是语言无关的 Symphony 服务规范。

它覆盖：

- 问题定义
- goals / non-goals
- 系统组件
- 核心领域模型
- `WORKFLOW.md` 合同
- 配置解析与动态重载
- orchestration state machine
- polling / dispatch / retry / reconcile
- workspace 生命周期与安全边界
- Codex app-server 集成合同
- Linear 兼容的 tracker 合同
- prompt 构建合同
- logging / status / observability
- failure model / recovery
- security / operational safety
- reference algorithms
- test / validation matrix
- optional SSH worker extension

也就是说，开源仓库真正的“底座”首先是 `SPEC.md`，不是某个具体实现文件。

### 3.2 参考实现层

`elixir/` 目录提供当前官方参考实现。

它不是产品化控制面，但已经把以下东西跑通了：

- `WORKFLOW.md` 读取与热重载
- Linear 轮询
- per-issue workspace
- Codex app-server 会话
- continuation / retry / reconciliation
- terminal dashboard
- Phoenix LiveView dashboard
- JSON observability API
- 本地与 SSH worker 两种执行路径

### 3.3 repo-owned workflow 层

`elixir/WORKFLOW.md` 不是示例废稿，而是当前开源仓库把“运行规则”真正压进仓库的体现。

它不仅配置：

- tracker
- polling
- workspace root
- hooks
- agent concurrency / turns
- codex command / sandbox / approval

还把实际执行工作流写进 prompt：

- `Todo -> In Progress -> Human Review -> Merging -> Done`
- `Rework` 的重新开工语义
- 单 workpad comment 规则
- PR feedback sweep
- validation gate
- blocked-access escape hatch
- `land` skill 的使用方式

也就是说，开源仓库现有功能的一部分，实际上活在 `WORKFLOW.md` 里。

### 3.4 repo-owned skill 层

根目录 `.codex/skills/` 当前可见：

- `commit`
- `debug`
- `land`
- `linear`
- `pull`
- `push`

这说明它不是单纯“后端拉起 agent”，而是默认把 repo 内技能也视为运行时的一部分。

### 3.5 测试与 CI 层

开源仓库还带了明确的质量资产：

- `elixir/Makefile`
- `make all`
- `coverage`
- `dialyzer`
- `live_e2e`
- `.github/workflows/make-all.yml`
- `.github/workflows/pr-description-lint.yml`
- 多个 ExUnit 测试文件

这部分很重要，因为它决定了“当前哪些功能是被系统性验证过的”。

---

## 4. 开源仓库现有功能模块总表

下面这部分不是按你未来项目拆卡，而是按开源仓库当前真实已有功能来分模块。

### 4.1 服务定位与系统边界

开源仓库当前把 Symphony 定义为：

- 长期运行的自动化服务
- issue tracker reader
- scheduler / runner
- per-issue workspace orchestrator
- coding agent session host

它**不是**：

- rich web UI 产品
- multi-tenant control plane
- 通用 workflow engine
- 分布式 job scheduler
- 内建 ticket business logic 平台

这个边界非常关键。它解释了为什么仓库里“编排内核”比较完整，但“产品控制面”并没有一起做完。

### 4.2 `WORKFLOW.md` 合同与配置系统

这一节要分清两层：

- `[SPEC 规范层]`
- `[Elixir 参考实现层]`

这是当前开源仓库最核心的一块。

已有能力：

- 支持从显式 path 或默认 cwd 下的 `WORKFLOW.md` 读取配置
- 支持 YAML front matter + Markdown prompt body
- front matter 解析失败时给出 typed error
- prompt body 为空时可回退默认 prompt
- 配置有 typed schema，而不是随便读 map
- 支持 defaults
- 支持 `$VAR_NAME` 形式的环境变量间接引用
- 支持 `~` 和路径规范化
- 支持运行中动态重载
- 重载失败时保持 last known good config，不把服务打崩

`[SPEC 规范层]` 当前核心 front matter 区域包括：

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `codex`

`[Elixir 参考实现层]` 当前公开能直接确认的扩展区包括：

- `worker`
- `server`

这里要特别注意：

- 规范层把 front matter 设计成可扩展
- Elixir 参考实现已经真的开始往扩展方向走

这意味着你后面做 fork 时，最不该轻易打碎的就是这套配置合同。

### 4.3 Prompt 构建与严格模板渲染

已有能力：

- prompt 从 repo-owned `WORKFLOW.md` 取
- 使用 strict template 渲染
- 提供 `issue` 与 `attempt` 两个核心输入
- 未知变量和未知 filter 直接失败
- continuation turn 使用不同提示文本
- issue struct 会被转成适合模板渲染的 map

这块的重要性在于：

- Symphony 不是把 prompt 硬编码在服务里
- 它把“团队运行规则”当成仓库资产

### 4.4 Tracker 集成与 issue 归一化

规范层当前核心目标 tracker 是 `Linear`。

参考实现已有能力：

- 按 project slug + active states 拉 candidate issues
- 按 issue IDs 拉当前状态做 reconciliation
- 读取 terminal-state issues 做 cleanup
- issue payload 归一化成稳定模型
- labels 统一小写
- blockers 从 inverse relations 中提取
- branchName / url / priority / createdAt / updatedAt 归一化
- 支持 assignee 路由过滤

同时，参考实现还额外有一个 `memory` tracker adapter，用于：

- 测试
- 本地开发
- 非真实 Linear 环境下的模拟

这说明当前仓库虽然产品语义是 `Linear-first`，但代码边界已经留出了 adapter 层。

### 4.5 调度内核与 state machine

这一节也要分清两层：

- `[SPEC 规范层]` 内部编排状态
- `[Elixir 参考实现层]` 当前 runtime 视图

这是开源仓库第二块真正成型的能力。

已有能力：

- 固定 cadence 轮询
- bounded concurrency
- in-memory authoritative runtime state
- `claimed / running / retrying / completed` 等调度状态管理
- priority + 创建时间排序
- state-based concurrency override
- active / non-active / terminal 的不同处理
- continuation retry
- failure retry with exponential backoff
- backoff cap
- stalled run 检测与重启
- live runtime config refresh

`[SPEC 规范层]` 明写的编排状态主轴是：

- `Unclaimed`
- `Claimed`
- `Running`
- `RetryQueued`
- `Released`

`[Elixir 参考实现层]` 另外还有一个独立的 `blocked` 运行时视图，用来表示：

- Codex 请求 operator input
- Codex 请求 approval

需要特别点名的现有语义：

- 正常退出并不等于 issue 永久完成
- 正常退出后，如果 issue 仍在 active state，会进入 continuation 路径
- approval / input required 会进入 blocked map
- blocked map 是内存态，重启后不会持久恢复

这决定了 Symphony 当前已经不是“跑一轮 agent 就结束”的模型，而是一个带续跑语义的 orchestrator。

### 4.6 Reconciliation 与生命周期收口

已有能力：

- 定时刷新 running issues 状态
- 发现 issue 进入 terminal state 时，停止 session 并清理 workspace
- 发现 issue 变成非 active state 时，停止 session 但不一定清理 workspace
- startup 阶段会做 terminal workspace cleanup
- issue 不再可见时，也有对应释放逻辑

这块说明 Symphony 已经把“tracker 状态变化反压执行态”做进来了，不是单向触发器。

### 4.7 Workspace 管理与安全边界

已有能力：

- 一个 issue 一个 deterministic workspace
- workspace 名基于 sanitized issue identifier
- 本地 workspace root containment 校验
- symlink escape 检查
- 路径 canonicalization
- 远程 worker 场景下的 workspace 创建与删除
- `after_create`
- `before_run`
- `after_run`
- `before_remove`
- hook timeout
- hook 失败分级处理

这块要强调：

- workspace 不是临时脚本副产物
- workspace lifecycle 是正式模块

### 4.8 Agent Runner 与 continuation 执行模型

已有能力：

- 为单个 issue 启动一次 worker attempt
- 选定本地或 SSH worker host
- 进入 workspace
- 运行 `before_run`
- 启动 Codex app-server session
- 启动多 turn continuation
- 每轮后刷新 issue state
- 达到 `max_turns` 时返回 orchestrator
- 结束后运行 `after_run`

重要含义：

- 当前仓库不是 long-lived online thread product
- 但已经具备“同一 worker lifetime 内多 turn continuation”能力

### 4.9 Codex app-server 协议集成

已有能力：

- 通过 `bash -lc <codex.command>` 启动 app-server
- 本地 stdio 模式
- SSH 远程 stdio 模式
- JSON-RPC 2.0 stream 处理
- `initialize`
- `thread/start`
- `turn/start`
- `turn/completed`
- `turn/failed`
- `turn/cancelled`
- usage 提取
- rate limit 提取
- thread / turn / session 元数据提取
- approval request 处理
- tool call 处理
- user input request 处理
- malformed / non-JSON stream 处理

这块是当前参考实现最“协议化”的部分之一，已经远超过一个简单 subprocess wrapper。

### 4.10 Dynamic Tool：`linear_graphql`

已有能力：

- 向 agent session 暴露 `linear_graphql`
- 支持 raw GraphQL query / mutation
- 支持 `variables`
- 使用 Symphony 当前配置的 Linear auth
- 返回结构化 success / failure payload
- GraphQL top-level `errors` 不会假装成功

这块很重要，因为它把“运行期只读/写 Linear 的原始接口”作为 agent side tool 暴露，而不是直接塞进 orchestrator 业务逻辑里。

### 4.11 Observability：terminal dashboard

已有能力：

- 终端状态面板
- running / retrying / blocked 分区
- token throughput
- rate limits
- runtime seconds
- next poll 状态
- dashboard URL 提示
- humanized Codex event summary

也就是说，仓库当前不是“只有日志”，而是已经有一个 operator-facing terminal status surface。

### 4.12 Observability：Web dashboard 与 JSON API

已有能力：

- Phoenix endpoint
- LiveView dashboard
- `/api/v1/state`
- `/api/v1/:issue_identifier`
- `/api/v1/refresh`
- API error envelope
- presenter 层把 orchestrator snapshot 投影成 UI / API payload

这里要看清楚它当前的定位：

- 有 dashboard
- 有 API
- 但 API 还是 snapshot 级，不是深度 trace browser

### 4.13 远程执行与 SSH worker 扩展

规范层已经有 optional SSH worker appendix。

参考实现也已经真的落了：

- `worker.ssh_hosts`
- `worker.max_concurrent_agents_per_host`
- SSH command runner
- SSH port transport
- remote workspace root
- remote worker host selection
- per-host capacity control

这意味着“远程 worker”不是纸面设想，而是当前参考实现已进入代码和 live e2e 范围。

### 4.14 仓库内置运行工作流

开源仓库现有 `elixir/WORKFLOW.md` 已经内置：

- issue 状态路由
- 单 workpad comment 规则
- checklist / acceptance / validation 模板
- PR feedback sweep
- Human Review 行为
- Merging 阶段走 `land` skill
- Rework 完整重开流

这部分属于“现有功能”，因为它真实决定了 Symphony 跑起来时 agent 被如何编排。

### 4.15 CLI 与运行入口

已有能力：

- `bin/symphony`
- 默认读取 `./WORKFLOW.md`
- 支持显式 workflow path
- 支持 `--logs-root`
- 支持 `--port`
- `[Elixir 参考实现层]` 启动前要求明确确认“without the usual guardrails”

这个 guardrail acknowledgement 是一个很值得注意的现有设计信号。

### 4.16 测试、验证与 CI

当前仓库已明确具备：

- `core_test`
- `workspace_and_config_test`
- `app_server_test`
- `dynamic_tool_test`
- `extensions_test`
- `orchestrator_status_test`
- `ssh_test`
- `status_dashboard_snapshot_test`
- `cli_test`
- `live_e2e_test`

CI / 质量任务包括：

- `make all`
- `fmt-check`
- `lint`
- `coverage`
- `dialyzer`
- `pr_body.check`
- `specs.check`

而且 `mix.exs` 已把 coverage threshold 设成 `100`，但它同时对一批模块做了 coverage ignore。

更准确地说，这说明当前仓库已经形成了明确质量门槛，但不能简单理解成“全仓库所有模块都要求字面 100% 覆盖”。

### 4.17 仓库治理与运维资产

这部分不是 orchestration 主链，但对 fork 迁移很重要。

当前公开仓库里还能直接确认这些资产：

- `elixir/AGENTS.md`
  - 写清了实现与 `SPEC.md` 的关系
  - 强调 workspace safety
  - 规定 `make all` 为主质量门
  - 规定 `mix specs.check`
  - 规定 PR body 格式检查
- `elixir/docs/logging.md`
  - 补 logging 约束
- `elixir/docs/token_accounting.md`
  - 补 token 统计口径
- `path_safety.ex`
  - 专门负责路径 canonicalization 与安全边界
- `log_file.ex`
  - 专门负责 rotating disk log handler
- `specs_check.ex`
  - 专门负责 public function `@spec` 门禁

这些资产说明当前开源仓库并不是“只有功能模块”，还已经形成一套工程约束与运行约束。

### 4.18 按模块的迁移建议速览

这张表只回答一件事：

- fork 时，这块该怎么看、该怎么继承

| 模块 | 当前开源仓库已有内容 | 迁移建议 |
| --- | --- | --- |
| 服务边界 | scheduler / runner / tracker reader，而不是产品控制面 | 原样保留为底层定位，不要一上来改成“大而全平台” |
| `WORKFLOW.md` 合同 | 配置、prompt、状态流转、workpad、PR feedback、merge 流 | 视为一等合同，优先继承，不要先打散到代码里 |
| 配置系统 | typed schema、defaults、`$VAR`、路径处理、动态重载 | 直接继承设计，后续扩展字段也沿这条路走 |
| prompt 构建 | strict template、`issue`/`attempt`、continuation prompt | 保留 strict 模式，避免 fork 后退回宽松拼字符串 |
| tracker adapter | Linear 主实现 + memory adapter + assignee routing | 先保持 `Linear-first`，未来多 tracker 也沿 adapter 扩，不要侵入 orchestrator |
| 调度内核 | poll / claim / run / retry / blocked / reconcile | 这是最该保的主链，不建议先重写 |
| 生命周期收口 | terminal cleanup、non-active stop、startup cleanup | 直接继承语义，否则后面很容易出现脏 run / 脏 workspace |
| workspace 管理 | per-issue workspace、hooks、安全校验、本地/远程两套路径 | 必须保留为独立层，不要把 workspace 逻辑散回 runner |
| agent runner | 单 issue attempt、多 turn continuation、issue refresh | 继续把它当 worker kernel，而不是在线产品线程模型 |
| Codex app-server 集成 | JSON-RPC、approval/tool/user input/usage/rate-limit 处理 | 先继承协议边界，后面再加更强编排，不要重造 transport |
| dynamic tool | `linear_graphql` | 后续若加更多工具，也建议走同类 client-side tool 边界 |
| terminal / web observability | terminal dashboard、LiveView dashboard、JSON API | 先把它当最小可用观测面，再往深度 trace UI 扩 |
| SSH worker | ssh host pool、per-host cap、远程 workspace | 如果要扩多机执行，沿现有 worker 抽象继续做 |
| repo-owned skills | `commit/pull/push/linear/land/debug` | fork 后不要只迁代码，技能体系也要一起审视 |
| 测试与 CI | `make all`、coverage、dialyzer、live e2e、PR description lint | 把它当迁移门禁，不要 fork 之后先降级质量线 |

---

## 5. 当前开源仓库明确还没有什么

这部分也要看清，不然 fork 后很容易误判“它其实已经快做完了”。

### 5.1 仓库明确非目标

规范层直接写了非目标：

- rich web UI
- multi-tenant control plane
- 通用工作流引擎
- 分布式调度器
- 把 ticket business logic 内建进 orchestrator

### 5.2 规范层写成 RECOMMENDED / TODO，但当前未形成核心现成能力

包括：

- 持久化 retry queue 和 session metadata
- 把 observability 设置系统化配置化
- first-class tracker write APIs 进入 orchestrator
- Linear 之外的正式 tracker adapter

### 5.3 当前 Web / API 还不是深度运行浏览器

当前已有的是：

- dashboard
- snapshot API
- per-issue detail API

当前还没有在开源仓库里形成完整公开能力的是：

- run timeline browser
- raw event browser
- prompt / shell / linear trace 深挖 API
- 多项目总览控制面

---

## 6. 从开源仓库现状出发，对你 fork 后方向的建议

这一段只给方向，不把它写成新仓库设计定稿。

### 6.1 多项目方向

建议：

- 把当前开源 Symphony 看成“单项目 worker kernel”
- 不要先把它误当成“已经内建多项目 control plane”

原因：

- 当前 CLI 是单 workflow path
- 当前 `WorkflowStore` / `Config` / `Orchestrator` / dashboard 都是单实例语义
- 规范层也明确把 multi-tenant control plane 排除在核心目标外

因此更稳的方向是：

- 先保护单项目 worker kernel 的合同
- 再在其上包多项目控制层

这里是我的判断，但它是基于开源仓库当前结构做出的**推断**，不是仓库自己明写的路线图。

### 6.2 独立 UI 方向

建议：

- 把当前 `/api/v1/state` 与 per-issue detail payload 当成第一层稳定观测合同
- 真正要做独立 UI 时，再补 run 级 timeline / event / raw data API

原因：

- 当前开源仓库已经有 snapshot/presenter/dashboard 这一层
- 但还没有深层 trace browser

所以你后面扩 UI，应该是“在现有观测合同上向深处扩”，而不是把现有 snapshot 层一把推翻。

### 6.3 更多编排能力方向

如果你后面要强化编排，我建议优先看这些开源仓库当前最自然的延伸点：

- blocked / retry / session metadata 持久化
- richer operator intervention model
- first-class tracker write boundary
- run-level trace / timeline API
- more formal adapter boundary beyond Linear
- stronger multi-host scheduling policy

原因很简单：

- 这些都贴着当前仓库已经成形的内核走
- 扩起来阻力最小
- 也最不容易把现有合同打散

### 6.4 迁移时最不能丢的四类资产

我建议你后面 fork 开发时，最先锁死这四类“不得随便漂移”的合同：

1. `WORKFLOW.md` 合同
2. issue normalized model
3. orchestrator state machine
4. workspace / app-server / observability 边界

如果这四类合同没锁住，后面多项目、UI、深编排都会越做越飘。

---

## 7. 迁移前检查清单

如果你要拿这份开源仓库做 fork 起点，我建议先逐条确认：

- 你继承的是不是 `SPEC + reference implementation + WORKFLOW + skills + tests` 五层，而不是只拷代码
- 你有没有把“单项目 worker kernel”和“未来多项目控制面”分开
- 你有没有把“当前 snapshot 观测面”和“未来深度 UI”分开
- 你有没有把“仓库明确非目标”当作未来扩展点，而不是误判成现成功能
- 你有没有先冻结基础合同，再开始做延伸设计

---

## 8. 最终结论

`openai/symphony` 当前公开仓库，已经足够作为一个很强的 fork 起点。

它已经真正拥有的，不只是“能轮询 Linear 拉起 Codex”这么简单，而是：

- 一整套语言无关规范
- 一条可运行的单项目 orchestration 主链
- 一套 repo-owned workflow 合同
- 一套 repo-owned agent skill 协同方式
- 一套相对完整的观测、测试和 CI 资产

但同时，它当前还**不是**：

- 现成多项目产品
- 现成深度 UI 产品
- 现成全功能 control plane

所以你后面的正确姿势，不是重做它已经做对的内核，也不是误以为它已经帮你做完了多项目和产品面。

更稳的做法是：

- 先把这份开源仓库的现有合同吃透
- 在这个基线上决定哪些要保留、哪些要加壳、哪些要扩展

---

## 9. 证据入口

本次盘点重点读取：

- 本地规格翻译：
  - `/home/ss/workspace/规划/powersymphony/测试与合并重构讨论/SPEC_简体中文_utf8.md`

- 开源仓库根：
  - `https://github.com/openai/symphony`
  - `https://github.com/openai/symphony/blob/2c1851830477434100fdb8980fcc1fce1a8af81d/README.md`
  - `https://github.com/openai/symphony/blob/2c1851830477434100fdb8980fcc1fce1a8af81d/SPEC.md`

- 参考实现关键路径：
  - `elixir/README.md`
  - `elixir/WORKFLOW.md`
  - `elixir/lib/symphony_elixir/`
  - `elixir/lib/symphony_elixir_web/`
  - `elixir/test/symphony_elixir/`
  - `.codex/skills/`
  - `.github/workflows/`
