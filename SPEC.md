# Symphony 服务规范

状态：Draft v1（language-agnostic）

目的：定义一个用于编排 coding agents 以完成项目工作的服务。

## 规范性语言

本文档中的关键词 `MUST`、`MUST NOT`、`REQUIRED`、`SHOULD`、`SHOULD NOT`、`RECOMMENDED`、`MAY` 和
`OPTIONAL` 应按照 RFC 2119 中的描述解释。

`Implementation-defined` 表示该行为属于实现契约的一部分，但本规范不规定一个通用策略。实现方 MUST 文档化所选择的行为。

## 1. 问题陈述

Symphony 是一个长期运行的自动化服务：它持续从 issue tracker（本规范版本中为 Linear）读取工作，为每个 issue 创建隔离的 workspace，并在该 workspace 内为该 issue 运行一个 coding agent session。

该服务解决四个操作层问题：

- 它把 issue 执行从手动脚本转成可重复的 daemon workflow。
- 它在 per-issue workspace 中隔离 agent 执行，使 agent commands 只在 per-issue workspace directories 内运行。
- 它把 workflow policy 保留在 repo 内（`WORKFLOW.md`），使团队可以将 agent prompt 和 runtime settings 与代码一起版本化。
- 它提供足够的 observability，用于运维和调试多个并发 agent runs。

实现方应明确文档化其 trust and safety posture。本规范不要求单一的 approval、sandbox 或 operator-confirmation policy；有些实现面向采用 high-trust configuration 的 trusted environments，另一些实现则需要更严格的 approvals 或 sandboxing。

重要边界：

- Symphony 是 scheduler/runner 和 tracker reader。
- Ticket writes（state transitions、comments、PR links）通常由 coding agent 使用 workflow/runtime environment 中可用的工具执行。
- 成功的 run 可以结束在 workflow-defined handoff state（例如 `Human Review`），不一定必须是 `Done`。

## 2. Goals and Non-Goals

### 2.1 Goals

- 按固定节奏轮询 issue tracker，并以有界并发 dispatch work。
- 为 dispatch、retries 和 reconciliation 维护单一权威 orchestrator state。
- 创建确定性的 per-issue workspaces，并跨 runs 保留它们。
- 当 issue state changes 使 active runs 不再符合条件时，停止这些 active runs。
- 使用 exponential backoff 从 transient failures 中恢复。
- 从 repository-owned `WORKFLOW.md` contract 加载 runtime behavior。
- 暴露 operator-visible observability（至少 structured logs）。
- 支持由 tracker/filesystem 驱动的 restart recovery，而不要求 persistent database；精确的 in-memory scheduler state 不会被恢复。

### 2.2 Non-Goals

- Rich web UI 或 multi-tenant control plane。
- 规定具体的 dashboard 或 terminal UI implementation。
- General-purpose workflow engine 或 distributed job scheduler。
- 内置关于如何编辑 tickets、PRs 或 comments 的 business logic。（该逻辑存在于 workflow prompt 和 agent tooling 中。）
- 强制要求超出 coding agent 和 host OS 所提供能力之外的 strong sandbox controls。
- 为所有实现强制规定单一默认 approval、sandbox 或 operator-confirmation posture。

## 3. System Overview

### 3.1 Main Components

1. `Workflow Loader`
   - 读取 `WORKFLOW.md`。
   - 解析 YAML front matter 和 prompt body。
   - 返回 `{config, prompt_template}`。

2. `Config Layer`
   - 暴露 workflow config values 的 typed getters。
   - 应用 defaults 和 environment variable indirection。
   - 执行 orchestrator 在 dispatch 前使用的 validation。

3. `Issue Tracker Client`
   - 获取 active states 中的 candidate issues。
   - 获取特定 issue IDs 的 current states（reconciliation）。
   - 在 startup cleanup 期间获取 terminal-state issues。
   - 将 tracker payloads 规范化为稳定的 issue model。

4. `Orchestrator`
   - 拥有 poll tick。
   - 拥有 in-memory runtime state。
   - 决定哪些 issues 要 dispatch、retry、stop 或 release。
   - 跟踪 session metrics 和 retry queue state。

5. `Workspace Manager`
   - 将 issue identifiers 映射到 workspace paths。
   - 确保 per-issue workspace directories 存在。
   - 运行 workspace lifecycle hooks。
   - 清理 terminal issues 的 workspaces。

6. `Agent Runner`
   - 创建 workspace。
   - 从 issue + workflow template 构建 prompt。
   - 启动 coding agent app-server client。
   - 将 agent updates 流式传回 orchestrator。

7. `Status Surface` (OPTIONAL)
   - 展示人类可读的 runtime status（例如 terminal output、dashboard 或其他 operator-facing view）。

8. `Logging`
   - 将 structured runtime logs 发送到一个或多个已配置 sinks。

### 3.2 Abstraction Levels

在保持以下层次时，Symphony 最容易移植：

1. `Policy Layer` (repo-defined)
   - `WORKFLOW.md` prompt body。
   - 团队特定的 ticket handling、validation 和 handoff 规则。

2. `Configuration Layer` (typed getters)
   - 将 front matter 解析为 typed runtime settings。
   - 处理 defaults、environment tokens 和 path normalization。

3. `Coordination Layer` (orchestrator)
   - Polling loop、issue eligibility、concurrency、retries、reconciliation。

4. `Execution Layer` (workspace + agent subprocess)
   - Filesystem lifecycle、workspace preparation、coding-agent protocol。

5. `Integration Layer` (Linear adapter)
   - API calls 和 tracker data normalization。

6. `Observability Layer` (logs + OPTIONAL status surface)
   - 让 operator 能看到 orchestrator 和 agent behavior。

### 3.3 External Dependencies

- Issue tracker API（本规范版本中 `tracker.kind: linear` 使用 Linear）。
- 用于 workspaces 和 logs 的 local filesystem。
- OPTIONAL workspace population tooling（例如 Git CLI，如有使用）。
- 支持目标 Codex app-server mode 的 coding-agent executable。
- issue tracker 和 coding agent 的 host environment authentication。

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

用于 orchestration、prompt rendering 和 observability output 的 normalized issue record。

Fields：

- `id` (string)
  - 稳定的 tracker-internal ID。
- `identifier` (string)
  - 人类可读的 ticket key（示例：`ABC-123`）。
- `title` (string)
- `description` (string or null)
- `priority` (integer or null)
  - 在 dispatch sorting 中，数字越小 priority 越高。
- `state` (string)
  - 当前 tracker state name。
- `branch_name` (string or null)
  - 若可用，为 tracker-provided branch metadata。
- `url` (string or null)
- `labels` (list of strings)
  - 规范化为 lowercase。
- `blocked_by` (list of blocker refs)
  - 每个 blocker ref 包含：
    - `id` (string or null)
    - `identifier` (string or null)
    - `state` (string or null)
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

#### 4.1.2 Workflow Definition

解析后的 `WORKFLOW.md` payload：

- `config` (map)
  - YAML front matter root object。
- `prompt_template` (string)
  - front matter 之后的 Markdown body，已 trim。

#### 4.1.3 Service Config (Typed View)

从 `WorkflowDefinition.config` 加上 environment resolution 派生出的 typed runtime values。

Examples：

- poll interval
- workspace root
- active and terminal issue states
- concurrency limits
- coding-agent executable/args/timeouts
- workspace hooks

#### 4.1.4 Workspace

分配给一个 issue identifier 的 filesystem workspace。

Fields（logical）：

- `path` (absolute workspace path)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean, used to gate `after_create` hook)

#### 4.1.5 Run Attempt

一个 issue 的一次 execution attempt。

Fields（logical）：

- `issue_id`
- `issue_identifier`
- `attempt` (integer or null, `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (OPTIONAL)

#### 4.1.6 Live Session (Agent Session Metadata)

coding-agent subprocess 运行期间被跟踪的状态。

Fields：

- `session_id` (string, `<thread_id>-<turn_id>`)
- `thread_id` (string)
- `turn_id` (string)
- `codex_app_server_pid` (string or null)
- `last_codex_event` (string/enum or null)
- `last_codex_timestamp` (timestamp or null)
- `last_codex_message` (summarized payload)
- `codex_input_tokens` (integer)
- `codex_output_tokens` (integer)
- `codex_total_tokens` (integer)
- `last_reported_input_tokens` (integer)
- `last_reported_output_tokens` (integer)
- `last_reported_total_tokens` (integer)
- `turn_count` (integer)
  - 当前 worker lifetime 内已启动的 coding-agent turns 数量。

#### 4.1.7 Retry Entry

某个 issue 的 scheduled retry state。

Fields：

- `issue_id`
- `identifier`（尽力提供的 human ID，用于 status surfaces/logs）
- `attempt` (integer, 1-based for retry queue)
- `due_at_ms` (monotonic clock timestamp)
- `timer_handle` (runtime-specific timer reference)
- `error` (string or null)

#### 4.1.8 Orchestrator Runtime State

由 orchestrator 拥有的单一权威 in-memory state。

Fields：

- `poll_interval_ms`（当前 effective poll interval）
- `max_concurrent_agents`（当前 effective global concurrency limit）
- `running` (map `issue_id -> running entry`)
- `claimed`（reserved/running/retrying 的 issue IDs 集合）
- `retry_attempts` (map `issue_id -> RetryEntry`)
- `completed`（issue IDs 集合；仅用于 bookkeeping，不用于 dispatch gating）
- `codex_totals`（aggregate tokens + runtime seconds）
- `codex_rate_limits`（agent events 中最新的 rate-limit snapshot）

### 4.2 Stable Identifiers and Normalization Rules

- `Issue ID`
  - 用于 tracker lookups 和 internal map keys。
- `Issue Identifier`
  - 用于 human-readable logs 和 workspace naming。
- `Workspace Key`
  - 通过将 `issue.identifier` 中不属于 `[A-Za-z0-9._-]` 的字符替换为 `_` 派生。
  - 将 sanitized value 用作 workspace directory name。
- `Normalized Issue State`
  - 对 states 做 `lowercase` 后再比较。
- `Session ID`
  - 由 coding-agent `thread_id` 和 `turn_id` 组合为 `<thread_id>-<turn_id>`。

## 5. Workflow Specification (Repository Contract)

### 5.1 File Discovery and Path Resolution

Workflow file path 优先级：

1. 显式 application/runtime setting（由 CLI startup path 设置）。
2. 默认：当前 process working directory 中的 `WORKFLOW.md`。

Loader behavior：

- 如果文件不可读，返回 `missing_workflow_file` error。
- workflow file 预期由 repository 拥有并纳入 version control。

### 5.2 File Format

`WORKFLOW.md` 是一个带 OPTIONAL YAML front matter 的 Markdown 文件。

Design note：

- `WORKFLOW.md` SHOULD 足够自包含，以便描述并运行不同 workflows（prompt、runtime settings、hooks、tracker selection/config），而无需 out-of-band service-specific configuration。

Parsing rules：

- 如果文件以 `---` 开头，将直到下一个 `---` 的行解析为 YAML front matter。
- 剩余行成为 prompt body。
- 如果不存在 front matter，将整个文件视为 prompt body，并使用空 config map。
- YAML front matter MUST decode to a map/object；非 map YAML 是错误。
- Prompt body 在使用前会被 trim。

Returned workflow object：

- `config`: front matter root object（不嵌套在 `config` key 下）。
- `prompt_template`: 已 trim 的 Markdown body。

### 5.3 Front Matter Schema

Top-level keys：

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `codex`

Unknown keys SHOULD 为 forward compatibility 而被忽略。

Note：

- workflow front matter 是可扩展的。Extensions MAY 定义额外 top-level keys，而无需改变上述 core schema。
- Extensions SHOULD 文档化其 field schema、defaults、validation rules，以及 changes 是动态生效还是需要 restart。

#### 5.3.1 `tracker` (object)

Fields：

- `kind` (string)
  - REQUIRED for dispatch。
  - 当前支持的值：`linear`
- `endpoint` (string)
  - `tracker.kind == "linear"` 时的默认值：`https://api.linear.app/graphql`
- `api_key` (string)
  - MAY 是 literal token 或 `$VAR_NAME`。
  - `tracker.kind == "linear"` 的 canonical environment variable：`LINEAR_API_KEY`。
  - 如果 `$VAR_NAME` resolve 为 empty string，则将该 key 视为 missing。
- `project_slug` (string)
  - 当 `tracker.kind == "linear"` 时，dispatch REQUIRED。
- `active_states` (list of strings)
  - Default: `Todo`, `In Progress`
- `terminal_states` (list of strings)
  - Default: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`

#### 5.3.2 `polling` (object)

Fields：

- `interval_ms` (integer)
  - Default: `30000`
  - Changes SHOULD 在 runtime 重新应用，并且无需 restart 即可影响未来 tick scheduling。

#### 5.3.3 `workspace` (object)

Fields：

- `root` (path string or `$VAR`)
  - Default: `<system-temp>/symphony_workspaces`
  - `~` 会被展开。
  - Relative paths 相对于包含 `WORKFLOW.md` 的目录解析。
  - Effective workspace root 在使用前会 normalized to an absolute path。

#### 5.3.4 `hooks` (object)

Fields：

- `after_create` (multiline shell script string, OPTIONAL)
  - 仅在 workspace directory 被新创建时运行。
  - Failure 会中止 workspace creation。
- `before_run` (multiline shell script string, OPTIONAL)
  - 在 workspace preparation 之后、启动 coding agent 之前，于每次 agent attempt 前运行。
  - Failure 会中止当前 attempt。
- `after_run` (multiline shell script string, OPTIONAL)
  - 在每次 agent attempt 之后运行（success、failure、timeout 或 cancellation），前提是 workspace 已存在。
  - Failure 会被 logged 但 ignored。
- `before_remove` (multiline shell script string, OPTIONAL)
  - 如果 directory 存在，在 workspace deletion 前运行。
  - Failure 会被 logged 但 ignored；cleanup 仍会继续。
- `timeout_ms` (integer, OPTIONAL)
  - Default: `60000`
  - 适用于所有 workspace hooks。
  - Invalid values 会导致 configuration validation 失败。
  - Changes SHOULD 在 runtime 重新应用于未来 hook executions。

#### 5.3.5 `agent` (object)

Fields：

- `max_concurrent_agents` (integer)
  - Default: `10`
  - Changes SHOULD 在 runtime 重新应用，并影响后续 dispatch decisions。
- `max_turns` (positive integer)
  - Default: `20`
  - 限制一个 worker session 内 coding-agent turns 的数量。
  - Invalid values 会导致 configuration validation 失败。
- `max_retry_backoff_ms` (integer)
  - Default: `300000` (5 minutes)
  - Changes SHOULD 在 runtime 重新应用，并影响未来 retry scheduling。
- `max_concurrent_agents_by_state` (map `state_name -> positive integer`)
  - Default: empty map。
  - State keys 会 normalized（`lowercase`）后用于 lookup。
  - Invalid entries（non-positive 或 non-numeric）会被忽略。

#### 5.3.6 `codex` (object)

Fields：

对于 Codex-owned config values，例如 `approval_policy`、`thread_sandbox` 和 `turn_sandbox_policy`，其 supported values 由目标 Codex app-server version 定义。Implementors SHOULD 将它们视作 pass-through Codex config values，而不是依赖本 spec 中 hand-maintained enum。要检查已安装 Codex schema，运行 `codex app-server generate-json-schema --out <dir>`，并检查 `v2/ThreadStartParams.json` 和 `v2/TurnStartParams.json` 引用的相关 definitions。如果实现希望进行更严格的 startup checks，Implementations MAY 在本地 validate 这些 fields。

- `command` (string shell command)
  - Default: `codex app-server`
  - runtime 在 workspace directory 中通过 `bash -lc` 启动此 command。
  - 被启动的 process MUST 通过 stdio 使用兼容的 app-server protocol。
- `approval_policy` (Codex `AskForApproval` value)
  - Default: implementation-defined。
- `thread_sandbox` (Codex `SandboxMode` value)
  - Default: implementation-defined。
- `turn_sandbox_policy` (Codex `SandboxPolicy` value)
  - Default: implementation-defined。
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour)
- `read_timeout_ms` (integer)
  - Default: `5000`
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes)
  - 如果 `<= 0`，stall detection 被禁用。

### 5.4 Prompt Template Contract

`WORKFLOW.md` 的 Markdown body 是 per-issue prompt template。

Rendering requirements：

- 使用严格的 template engine（Liquid-compatible semantics 足够）。
- Unknown variables MUST 使 rendering 失败。
- Unknown filters MUST 使 rendering 失败。

Template input variables：

- `issue` (object)
  - 包含所有 normalized issue fields，包括 labels 和 blockers。
- `attempt` (integer or null)
  - first attempt 时为 `null`/absent。
  - retry 或 continuation run 时为 integer。

Fallback prompt behavior：

- 如果 workflow prompt body 为空，runtime MAY 使用一个最小 default prompt（`You are working on an issue from Linear.`）。
- Workflow file read/parse failures 是 configuration/validation errors，SHOULD NOT 静默 fallback 到某个 prompt。

### 5.5 Workflow Validation and Error Surface

Error classes：

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error`（during prompt rendering）
- `template_render_error`（unknown variable/filter, invalid interpolation）

Dispatch gating behavior：

- Workflow file read/YAML errors 会阻塞 new dispatches，直到修复。
- Template errors 只会使受影响的 run attempt 失败。

## 6. Configuration Specification

### 6.1 Configuration Resolution Pipeline

Configuration 按以下顺序解析：

1. 选择 workflow file path（显式 runtime setting，否则 cwd default）。
2. 将 YAML front matter 解析为 raw config map。
3. 对缺失的 OPTIONAL fields 应用 built-in defaults。
4. 只对明确包含 `$VAR_NAME` 的 config values 解析 `$VAR_NAME` indirection。
5. Coerce 并 validate typed values。

Environment variables 不会全局覆盖 YAML values。只有当 config value 明确引用它们时才使用。

Value coercion semantics：

- Path/command fields 支持：
  - `~` home expansion
  - env-backed path values 的 `$VAR` expansion
  - 仅对 intended to be local filesystem paths 的值应用 expansion；不要重写 URIs 或任意 shell command strings。
- Relative `workspace.root` values 相对于所选 `WORKFLOW.md` 所在目录解析。

### 6.2 Dynamic Reload Semantics

Dynamic reload 是 REQUIRED：

- 软件 MUST 检测 `WORKFLOW.md` changes。
- 发生 change 时，软件 MUST 重新读取并重新应用 workflow config 和 prompt template，无需 restart。
- 软件 MUST 尝试根据新 config 调整 live behavior（例如 polling cadence、concurrency limits、active/terminal states、codex settings、workspace paths/hooks，以及 future runs 的 prompt content）。
- Reloaded config 适用于 future dispatch、retry scheduling、reconciliation decisions、hook execution 和 agent launches。
- 当 config changes 时，Implementations 不 REQUIRED 自动 restart in-flight agent sessions。
- 管理自身 listeners/resources 的 extensions（例如 HTTP server port change）MAY require restart，除非实现明确支持 live rebind。
- Implementations SHOULD 在 runtime operations 中也防御性地 re-validate/reload（例如 before dispatch），以防 filesystem watch events 被漏掉。
- Invalid reloads MUST NOT crash service；应继续使用 last known good effective configuration 运行，并发出 operator-visible error。

### 6.3 Dispatch Preflight Validation

该 validation 是 scheduler preflight run，在尝试 dispatch new work 前执行。它校验 poll 和 launch workers 所需的 workflow/config，而不是对所有可能 workflow behavior 做完整 audit。

Startup validation：

- 在启动 scheduling loop 前 validate configuration。
- 如果 startup validation 失败，fail startup 并发出 operator-visible error。

Per-tick dispatch validation：

- 每个 dispatch cycle 前重新 validate。
- 如果 validation 失败，则跳过该 tick 的 dispatch，保持 reconciliation active，并发出 operator-visible error。

Validation checks：

- Workflow file 可以被加载和解析。
- `tracker.kind` 存在且受支持。
- `$` resolution 后 `tracker.api_key` 存在。
- 当所选 tracker kind REQUIRED 时，`tracker.project_slug` 存在。
- `codex.command` 存在且 non-empty。

### 6.4 Core Config Fields Summary (Cheat Sheet)

本节有意冗余，方便 coding agent 快速实现 config layer。Extension fields 在定义这些字段的 extension section 中记录。除非实现了该 extension，否则 core conformance 不要求识别或 validate extension fields。

- `tracker.kind`: string, REQUIRED, currently `linear`
- `tracker.endpoint`: string, default `https://api.linear.app/graphql` when `tracker.kind=linear`
- `tracker.api_key`: string or `$VAR`, canonical env `LINEAR_API_KEY` when `tracker.kind=linear`
- `tracker.project_slug`: string, REQUIRED when `tracker.kind=linear`
- `tracker.active_states`: list of strings, default `["Todo", "In Progress"]`
- `tracker.terminal_states`: list of strings, default `["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]`
- `polling.interval_ms`: integer, default `30000`
- `workspace.root`: path resolved to absolute, default `<system-temp>/symphony_workspaces`
- `hooks.after_create`: shell script or null
- `hooks.before_run`: shell script or null
- `hooks.after_run`: shell script or null
- `hooks.before_remove`: shell script or null
- `hooks.timeout_ms`: integer, default `60000`
- `agent.max_concurrent_agents`: integer, default `10`
- `agent.max_turns`: integer, default `20`
- `agent.max_retry_backoff_ms`: integer, default `300000` (5m)
- `agent.max_concurrent_agents_by_state`: map of positive integers, default `{}`
- `codex.command`: shell command string, default `codex app-server`
- `codex.approval_policy`: Codex `AskForApproval` value, default implementation-defined
- `codex.thread_sandbox`: Codex `SandboxMode` value, default implementation-defined
- `codex.turn_sandbox_policy`: Codex `SandboxPolicy` value, default implementation-defined
- `codex.turn_timeout_ms`: integer, default `3600000`
- `codex.read_timeout_ms`: integer, default `5000`
- `codex.stall_timeout_ms`: integer, default `300000`

## 7. Orchestration State Machine

orchestrator 是唯一会 mutate scheduling state 的组件。所有 worker outcomes 都会报告回它，并被转换为显式 state transitions。

### 7.1 Issue Orchestration States

这不同于 tracker states（`Todo`、`In Progress` 等）。这是服务内部的 claim state。

1. `Unclaimed`
   - Issue 未运行，也没有 scheduled retry。

2. `Claimed`
   - Orchestrator 已保留该 issue，以防 duplicate dispatch。
   - 实际上，claimed issues 要么是 `Running`，要么是 `RetryQueued`。

3. `Running`
   - Worker task 存在，并且 issue 在 `running` map 中被跟踪。

4. `RetryQueued`
   - Worker 未运行，但 `retry_attempts` 中存在 retry timer。

5. `Released`
   - 因为 issue 是 terminal、non-active、missing，或 retry path 完成但未重新 dispatch，claim 被移除。

重要细节：

- worker 成功退出并不意味着 issue 永远完成。
- worker MAY 在退出前连续执行多个 back-to-back coding-agent turns。
- 每次 normal turn completion 后，worker 会重新检查 tracker issue state。
- 如果 issue 仍处于 active state，worker SHOULD 在同一个 live coding-agent thread、同一个 workspace 中启动另一个 turn，最多到 `agent.max_turns`。
- 第一个 turn SHOULD 使用完整渲染后的 task prompt。
- Continuation turns SHOULD 只向既有 thread 发送 continuation guidance，而不是重新发送已经存在于 thread history 中的 original task prompt。
- 一旦 worker 正常退出，orchestrator 仍会调度一个短 continuation retry（约 1 秒），用于重新检查 issue 是否仍 active 且是否需要另一个 worker session。

### 7.2 Run Attempt Lifecycle

一个 run attempt 会经历以下 phases：

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

区分不同 terminal reasons 很重要，因为 retry logic 和 logs 会不同。

### 7.3 Transition Triggers

- `Poll Tick`
  - Reconcile active runs。
  - Validate config。
  - Fetch candidate issues。
  - Dispatch 直到 slots 耗尽。

- `Worker Exit (normal)`
  - 移除 running entry。
  - 更新 aggregate runtime totals。
  - 在 worker 耗尽或完成其 in-process turn loop 后，schedule continuation retry（attempt `1`）。

- `Worker Exit (abnormal)`
  - 移除 running entry。
  - 更新 aggregate runtime totals。
  - Schedule exponential-backoff retry。

- `Codex Update Event`
  - 更新 live session fields、token counters 和 rate limits。

- `Retry Timer Fired`
  - 重新获取 active candidates 并尝试 re-dispatch；如果不再 eligible，则 release claim。

- `Reconciliation State Refresh`
  - 停止 issue states 为 terminal 或不再 active 的 runs。

- `Stall Timeout`
  - Kill worker 并 schedule retry。

### 7.4 Idempotency and Recovery Rules

- orchestrator 通过单一 authority 串行化 state mutations，以避免 duplicate dispatch。
- 启动任何 worker 前，`claimed` 和 `running` checks 是 REQUIRED。
- Reconciliation 在每个 tick 的 dispatch 之前运行。
- Restart recovery 由 tracker 和 filesystem 驱动（没有 durable orchestrator DB）。
- Startup terminal cleanup 会移除已经处于 terminal states 的 issues 对应的 stale workspaces。

## 8. Polling, Scheduling, and Reconciliation

### 8.1 Poll Loop

启动时，服务 validate config，执行 startup cleanup，schedule an immediate tick，然后每隔 `polling.interval_ms` 重复。

当 workflow config changes 被重新应用时，effective poll interval SHOULD 更新。

Tick sequence：

1. Reconcile running issues。
2. 运行 dispatch preflight validation。
3. 使用 active states 从 tracker 获取 candidate issues。
4. 按 dispatch priority 对 issues 排序。
5. 在 slots 仍有剩余时 dispatch eligible issues。
6. 将 state changes 通知 observability/status consumers。

如果 per-tick validation 失败，该 tick 会跳过 dispatch，但 reconciliation 仍会先发生。

### 8.2 Candidate Selection Rules

只有当以下全部为 true 时，一个 issue 才是 dispatch-eligible：

- 它有 `id`、`identifier`、`title` 和 `state`。
- 它的 state 位于 `active_states` 且不在 `terminal_states`。
- 它尚未在 `running` 中。
- 它尚未在 `claimed` 中。
- Global concurrency slots 可用。
- Per-state concurrency slots 可用。
- `Todo` state 的 blocker rule 通过：
  - 如果 issue state 是 `Todo`，当任意 blocker 是 non-terminal 时不要 dispatch。

Sorting order（stable intent）：

1. `priority` ascending（优先 1..4；null/unknown 排在最后）
2. `created_at` oldest first
3. `identifier` lexicographic tie-breaker

### 8.3 Concurrency Control

Global limit：

- `available_slots = max(max_concurrent_agents - running_count, 0)`

Per-state limit：

- 如果存在 `max_concurrent_agents_by_state[state]`（state key 已 normalized），使用它
- 否则 fallback 到 global limit

runtime 会按 `running` map 中当前跟踪的 state 统计 issues。

### 8.4 Retry and Backoff

Retry entry creation：

- 取消同一个 issue 的任何 existing retry timer。
- 存储 `attempt`、`identifier`、`error`、`due_at_ms` 和新的 timer handle。

Backoff formula：

- clean worker exit 之后的 normal continuation retries 使用短 fixed delay：`1000` ms。
- Failure-driven retries 使用 `delay = min(10000 * 2^(attempt - 1), agent.max_retry_backoff_ms)`。
- 幂次由 configured max retry backoff 封顶（默认 `300000` / 5m）。

Retry handling behavior：

1. Fetch active candidate issues（不是所有 issues）。
2. 通过 `issue_id` 找到特定 issue。
3. 如果未找到，release claim。
4. 如果找到且仍 candidate-eligible：
   - 如果 slots 可用，则 dispatch。
   - 否则以 `no available orchestrator slots` error requeue。
5. 如果找到但不再 active，release claim。

Note：

- Terminal-state workspace cleanup 由 startup cleanup 和 active-run reconciliation 处理（包括当前 running issues 的 terminal transitions）。
- Retry handling 主要作用于 active candidates；当 issue 不存在时 release claims，而不是自身执行 terminal cleanup。

### 8.5 Active Run Reconciliation

Reconciliation 每个 tick 运行，包含两部分。

Part A: Stall detection

- 对每个 running issue，计算自以下时间以来的 `elapsed_ms`：
  - 如果已经看到任何 event，则使用 `last_codex_timestamp`，否则
  - 使用 `started_at`
- 如果 `elapsed_ms > codex.stall_timeout_ms`，terminate worker 并 queue a retry。
- 如果 `stall_timeout_ms <= 0`，完全跳过 stall detection。

Part B: Tracker state refresh

- 获取所有 running issue IDs 的 current issue states。
- 对每个 running issue：
  - 如果 tracker state 是 terminal：terminate worker 并 clean workspace。
  - 如果 tracker state 仍 active：更新 in-memory issue snapshot。
  - 如果 tracker state 既不是 active 也不是 terminal：terminate worker，但不 cleanup workspace。
- 如果 state refresh 失败，保持 workers running，并在下一个 tick 再试。

### 8.6 Startup Terminal Workspace Cleanup

当服务启动时：

1. 查询 tracker 中处于 terminal states 的 issues。
2. 对每个返回的 issue identifier，移除对应 workspace directory。
3. 如果 terminal-issues fetch 失败，log warning 并继续 startup。

这会防止 restarts 后 stale terminal workspaces 累积。

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

Workspace root：

- `workspace.root`（normalized absolute path）

Per-issue workspace path：

- `<workspace.root>/<sanitized_issue_identifier>`

Workspace persistence：

- Workspaces 会为同一个 issue 跨 runs 复用。
- Successful runs 不会 auto-delete workspaces。

### 9.2 Workspace Creation and Reuse

Input: `issue.identifier`

Algorithm summary：

1. 将 identifier sanitize 为 `workspace_key`。
2. 在 workspace root 下计算 workspace path。
3. 确保 workspace path 作为 directory 存在。
4. 仅当 directory 在本次调用期间被创建时标记 `created_now=true`；否则 `created_now=false`。
5. 如果 `created_now=true`，且已配置，则运行 `after_create` hook。

Notes：

- 本节不假定任何具体 repository/VCS workflow。
- 超出 directory creation 的 workspace preparation（例如 dependency bootstrap、checkout/sync、code generation）是 implementation-defined，通常通过 hooks 处理。

### 9.3 OPTIONAL Workspace Population (Implementation-Defined)

本 spec 不要求任何内置 VCS 或 repository bootstrap behavior。

Implementations MAY 使用 implementation-defined logic 和/或 hooks（例如 `after_create` 和/或 `before_run`）populate 或 synchronize workspace。

Failure handling：

- Workspace population/synchronization failures 会为当前 attempt 返回 error。
- 如果 failure 发生在创建全新 workspace 时，Implementations MAY 移除部分 prepared directory。
- Reused workspaces SHOULD NOT 在 population failure 时 destructive reset，除非该 policy 被明确选择并文档化。

### 9.4 Workspace Hooks

Supported hooks：

- `hooks.after_create`
- `hooks.before_run`
- `hooks.after_run`
- `hooks.before_remove`

Execution contract：

- 在适合 host OS 的 local shell context 中执行，workspace directory 作为 `cwd`。
- 在 POSIX systems 上，`sh -lc <script>`（或更严格的等价形式，如 `bash -lc <script>`）是 conforming default。
- Hook timeout 使用 `hooks.timeout_ms`；默认：`60000 ms`。
- Log hook start、failures 和 timeouts。

Failure semantics：

- `after_create` failure 或 timeout 对 workspace creation 是 fatal。
- `before_run` failure 或 timeout 对 current run attempt 是 fatal。
- `after_run` failure 或 timeout 会被 logged and ignored。
- `before_remove` failure 或 timeout 会被 logged and ignored。

### 9.5 Safety Invariants

这是最重要的 portability constraint。

Invariant 1: 只在 per-issue workspace path 中运行 coding agent。

- 启动 coding-agent subprocess 前，validate：
  - `cwd == workspace_path`

Invariant 2: Workspace path MUST 留在 workspace root 内。

- 将两个 paths 都 normalize to absolute。
- 要求 `workspace_path` 以 `workspace_root` 作为 prefix directory。
- 拒绝 workspace root 外部的任何 path。

Invariant 3: Workspace key 已 sanitized。

- Workspace directory names 中只允许 `[A-Za-z0-9._-]`。
- 将所有其他字符替换为 `_`。

## 10. Agent Runner Protocol (Coding Agent Integration)

本节定义 Symphony 在集成 Codex app-server 时的 language-neutral responsibilities。目标 Codex version 的 Codex app-server protocol 是 protocol schemas、message payloads、transport framing 和 method names 的 source of truth。

Protocol source of truth：

- Implementations MUST 发送对目标 Codex app-server version 有效的 messages。
- Implementations MUST 查阅目标 Codex app-server documentation 或 generated schema，而不是把本 specification 当成 protocol schema。
- 如果本 specification 看起来与目标 Codex app-server protocol 冲突，则 Codex protocol 控制 protocol shape 和 transport behavior。
- 本节中的 Symphony-specific requirements 仍然控制 orchestration behavior、workspace selection、prompt construction、continuation handling 和 observability extraction。

### 10.1 Launch Contract

Subprocess launch parameters：

- Command: `codex.command`
- Invocation: `bash -lc <codex.command>`
- Working directory: workspace path
- Transport/framing: 目标 Codex app-server version 要求的 protocol transport

Notes：

- 默认 command 是 `codex app-server`。
- Approval policy、sandbox policy、cwd、prompt input 以及 OPTIONAL tool declarations 使用目标 Codex app-server version 支持的 fields 提供。

RECOMMENDED additional process settings：

- Max line size: 10 MB（用于 safe buffering）

### 10.2 Session Startup Responsibilities

Reference: https://developers.openai.com/codex/app-server/

Startup MUST 遵循目标 Codex app-server contract。Symphony 还要求 client：

- 在 per-issue workspace 中启动 app-server subprocess。
- 使用目标 Codex app-server protocol 初始化 app-server session。
- 按照目标 protocol 创建或恢复 coding-agent thread。
- 在目标 protocol 接受 cwd 的位置，将 absolute per-issue workspace path 作为 thread/turn working directory 提供。
- 使用渲染后的 issue prompt 启动第一个 turn。
- 后续 in-worker continuation turns 在同一个 live thread 上使用 continuation guidance，而不是重新发送 original issue prompt。
- 使用目标 protocol 支持的 fields 提供该实现文档化的 approval 和 sandbox policy。
- 当目标 protocol 支持 turn 或 session titles 时，包含 issue-identifying metadata，例如 `<issue.identifier>: <issue.title>`。
- 使用目标 protocol 宣告已实现的 client-side tools。

Session identifiers：

- 从目标 Codex app-server protocol 返回的 thread identity 中提取 `thread_id`。
- 从每个 turn identity 中提取 `turn_id`。
- Emit `session_id = "<thread_id>-<turn_id>"`
- 在一个 worker run 内的所有 continuation turns 复用相同 `thread_id`。

### 10.3 Streaming Turn Processing

client 会按照目标 Codex app-server protocol 处理 app-server updates，直到 active turn 终止。

Completion conditions：

- Targeted-protocol turn completion signal -> success
- Targeted-protocol turn failure signal -> failure
- Targeted-protocol turn cancellation signal -> failure
- turn timeout (`turn_timeout_ms`) -> failure
- subprocess exit -> failure

Continuation processing：

- 如果 worker 在 successful turn 后决定继续，SHOULD 使用目标 protocol 在同一个 live thread 上启动另一个 turn。
- app-server subprocess SHOULD 在这些 continuation turns 之间保持 alive，并且只在 worker run 结束时停止。

Transport handling requirements：

- 遵循目标 Codex app-server version 的 transport 和 framing rules。
- 对于 stdio-based transports，除非目标 protocol 另有规定，否则 protocol stream handling 应与 diagnostic stderr handling 分离。

### 10.4 Emitted Runtime Events (Upstream to Orchestrator)

app-server client 会向 orchestrator callback 发出 structured events。每个 event SHOULD 包含：

- `event` (enum/string)
- `timestamp` (UTC timestamp)
- `codex_app_server_pid`（如可用）
- OPTIONAL `usage` map（token counts）
- 需要的 payload fields

Important emitted events 包括，例如：

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `turn_input_required`
- `approval_auto_approved`
- `unsupported_tool_call`
- `notification`
- `other_message`
- `malformed`

### 10.5 Approval, Tool Calls, and User Input Policy

Approval、sandbox 和 user-input behavior 是 implementation-defined。

Policy requirements：

- 每个 implementation MUST 文档化其选择的 approval、sandbox 和 operator-confirmation posture。
- Approval requests 和 user-input-required events MUST NOT 让 run 无限期 stalled。Implementation MAY 满足它们、向 operator 暴露它们、auto-resolve 它们，或按照其文档化 policy 使 run fail。

Example high-trust behavior：

- Auto-approve session 的 command execution approvals。
- Auto-approve session 的 file-change approvals。
- 将 user-input-required turns 视为 hard failure。

Unsupported dynamic tool calls：

- 明确实现并由 runtime advertised 的 supported dynamic tool calls SHOULD 根据其 extension contract 处理。
- 如果 agent 请求的 dynamic tool call 不受支持，使用目标 protocol 返回 tool failure response 并继续 session。
- 这可以防止 session 卡在 unsupported tool execution paths 上。

Optional client-side tool extension：

- Implementation MAY 向 app-server session 暴露有限的 client-side tools。
- 当前 standardized optional tool：`linear_graphql`。
- 如果实现该 tool，supported tools SHOULD 在 startup 期间使用目标 Codex app-server version 支持的 protocol mechanism advertised to the app-server session。
- Unsupported tool names SHOULD 仍然使用目标 protocol 返回 failure result 并继续 session。

`linear_graphql` extension contract：

- Purpose：使用 Symphony 为当前 session 配置的 tracker auth，对 Linear 执行 raw GraphQL query 或 mutation。
- Availability：仅当 `tracker.kind == "linear"` 且配置了有效 Linear auth 时有意义。
- Preferred input shape：

  ```json
  {
    "query": "single GraphQL query or mutation document",
    "variables": {
      "optional": "graphql variables object"
    }
  }
  ```

- `query` MUST 是 non-empty string。
- `query` MUST 正好包含一个 GraphQL operation。
- `variables` 是 OPTIONAL；若存在，MUST 是 JSON object。
- Implementations MAY 额外接受 raw GraphQL query string 作为 shorthand input。
- 每次 tool call 执行一个 GraphQL operation。
- 如果提供的 document 包含多个 operations，将该 tool call 作为 invalid input 拒绝。
- `operationName` selection 有意不在此 extension 范围内。
- 复用 active Symphony workflow/runtime config 中配置的 Linear endpoint 和 auth；不要要求 coding agent 从 disk 读取 raw tokens。
- Tool result semantics：
  - transport success + no top-level GraphQL `errors` -> `success=true`
  - 存在 top-level GraphQL `errors` -> `success=false`，但保留 GraphQL response body 供 debugging
  - invalid input、missing auth 或 transport failure -> `success=false` 并带 error payload
- 将 GraphQL response 或 error payload 作为 structured tool output 返回，以便 model 在 session 中检查。

User-input-required policy：

- Implementations MUST 文档化如何处理 targeted-protocol user-input-required signals。
- Run MUST NOT 无限期等待 user input 而 stall。
- Conforming implementation MAY 使 run fail、向 operator 暴露 request、通过 approved operator channel 满足 request，或根据其文档化 policy auto-resolve。
- 上面的 example high-trust behavior 会立即使 user-input-required turns fail。

### 10.6 Timeouts and Error Mapping

Timeouts：

- `codex.read_timeout_ms`: startup 和 sync requests 期间的 request/response timeout
- `codex.turn_timeout_ms`: total turn stream timeout
- `codex.stall_timeout_ms`: orchestrator 基于 event inactivity 强制执行

Error mapping（RECOMMENDED normalized categories）：

- `codex_not_found`
- `invalid_workspace_cwd`
- `response_timeout`
- `turn_timeout`
- `port_exit`
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`

### 10.7 Agent Runner Contract

`Agent Runner` 封装 workspace + prompt + app-server client。

Behavior：

1. 为 issue 创建/复用 workspace。
2. 从 workflow template 构建 prompt。
3. 启动 app-server session。
4. 将 app-server events 转发给 orchestrator。
5. 出现任何 error 时，使 worker attempt fail（orchestrator 会 retry）。

Note：

- Workspaces 在 successful runs 后会被有意保留。

## 11. Issue Tracker Integration Contract (Linear-Compatible)

### 11.1 REQUIRED Operations

Implementation MUST 支持以下 tracker adapter operations：

1. `fetch_candidate_issues()`
   - 返回 configured project 中 configured active states 的 issues。

2. `fetch_issues_by_states(state_names)`
   - 用于 startup terminal cleanup。

3. `fetch_issue_states_by_ids(issue_ids)`
   - 用于 active-run reconciliation。

### 11.2 Query Semantics (Linear)

当 `tracker.kind == "linear"` 时的 Linear-specific requirements：

- `tracker.kind == "linear"`
- GraphQL endpoint（default `https://api.linear.app/graphql`）
- Auth token 通过 `Authorization` header 发送
- `tracker.project_slug` 映射到 Linear project `slugId`
- Candidate issue query 使用 `project: { slugId: { eq: $projectSlug } }` filter project
- Issue-state refresh query 使用 GraphQL issue IDs，variable type 为 `[ID!]`
- Candidate issues 的 pagination REQUIRED
- Page size default: `50`
- Network timeout: `30000 ms`

Important：

- Linear GraphQL schema details 可能 drift。保持 query construction 隔离，并测试本规范 REQUIRED 的 exact query fields/types。

Non-Linear implementation MAY 改变 transport details，但 normalized outputs MUST 匹配 Section 4 中的 domain model。

### 11.3 Normalization Rules

Candidate issue normalization SHOULD 产生 Section 4.1.1 中列出的 fields。

Additional normalization details：

- `labels` -> lowercase strings
- `blocked_by` -> 从 relation type 为 `blocks` 的 inverse relations 派生
- `priority` -> 仅 integer（non-integers 变为 null）
- `created_at` 和 `updated_at` -> 解析 ISO-8601 timestamps

### 11.4 Error Handling Contract

RECOMMENDED error categories：

- `unsupported_tracker_kind`
- `missing_tracker_api_key`
- `missing_tracker_project_slug`
- `linear_api_request`（transport failures）
- `linear_api_status`（non-200 HTTP）
- `linear_graphql_errors`
- `linear_unknown_payload`
- `linear_missing_end_cursor`（pagination integrity error）

Orchestrator behavior on tracker errors：

- Candidate fetch failure：log 并跳过该 tick 的 dispatch。
- Running-state refresh failure：log 并保持 active workers running。
- Startup terminal cleanup failure：log warning 并继续 startup。

### 11.5 Tracker Writes (Important Boundary)

Symphony 不要求在 orchestrator 中提供 first-class tracker write APIs。

- Ticket mutations（state transitions、comments、PR metadata）通常由 coding agent 使用 workflow prompt 中定义的 tools 处理。
- 该服务仍然是 scheduler/runner 和 tracker reader。
- Workflow-specific success 通常意味着“到达下一个 handoff state”（例如 `Human Review`），而不是 tracker terminal state `Done`。
- 如果实现了 `linear_graphql` client-side tool extension，它仍然属于 agent toolchain 的一部分，而不是 orchestrator business logic。

## 12. Prompt Construction and Context Assembly

### 12.1 Inputs

Prompt rendering 的 inputs：

- `workflow.prompt_template`
- normalized `issue` object
- OPTIONAL `attempt` integer（retry/continuation metadata）

### 12.2 Rendering Rules

- 使用 strict variable checking 进行 render。
- 使用 strict filter checking 进行 render。
- 为 template compatibility，将 issue object keys 转换为 strings。
- 保留 nested arrays/maps（labels、blockers），使 templates 可以 iterate。

### 12.3 Retry/Continuation Semantics

`attempt` SHOULD 传给 template，因为 workflow prompt 可以为以下情况提供不同 instructions：

- first run（`attempt` null 或 absent）
- successful prior session 之后的 continuation run
- error/timeout/stall 之后的 retry

### 12.4 Failure Semantics

如果 prompt rendering 失败：

- 立即使 run attempt fail。
- 让 orchestrator 像处理任何其他 worker failure 一样处理它，并决定 retry behavior。

## 13. Logging, Status, and Observability

### 13.1 Logging Conventions

Issue-related logs 的 REQUIRED context fields：

- `issue_id`
- `issue_identifier`

Coding-agent session lifecycle logs 的 REQUIRED context：

- `session_id`

Message formatting requirements：

- 使用稳定的 `key=value` phrasing。
- 包含 action outcome（`completed`、`failed`、`retrying` 等）。
- 如有 failure reason，包含 concise failure reason。
- 除非必要，避免记录 large raw payloads。

### 13.2 Logging Outputs and Sinks

本 spec 不规定 logs 写到哪里（stderr、file、remote sink 等）。

Requirements：

- Operators MUST 能够在不附加 debugger 的情况下看到 startup/validation/dispatch failures。
- Implementations MAY 写入一个或多个 sinks。
- 如果 configured log sink 失败，service SHOULD 在可能时继续运行，并通过任何剩余 sink 发出 operator-visible warning。

### 13.3 Runtime Snapshot / Monitoring Interface (OPTIONAL but RECOMMENDED)

如果 implementation 暴露同步 runtime snapshot（用于 dashboards 或 monitoring），它 SHOULD 返回：

- `running`（running session rows 列表）
- 每个 running row SHOULD 包含 `turn_count`
- `retrying`（retry queue rows 列表）
- `codex_totals`
  - `input_tokens`
  - `output_tokens`
  - `total_tokens`
  - `seconds_running`（snapshot time 的 aggregate runtime seconds，包括 active sessions）
- `rate_limits`（如可用，为最新 coding-agent rate limit payload）

RECOMMENDED snapshot error modes：

- `timeout`
- `unavailable`

### 13.4 OPTIONAL Human-Readable Status Surface

Human-readable status surface（terminal output、dashboard 等）是 OPTIONAL 且 implementation-defined。

如果存在，它 SHOULD 只从 orchestrator state/metrics 获取数据，并且 MUST NOT 成为 correctness 的 REQUIRED 条件。

### 13.5 Session Metrics and Token Accounting

Token accounting rules：

- Agent events 可以以多种 payload shapes 包含 token counts。
- 可用时，优先使用 absolute thread totals，例如：
  - `thread/tokenUsage/updated` payloads
  - token-count wrapper events 中的 `total_token_usage`
- 对 dashboard/API totals，忽略 delta-style payloads，例如 `last_token_usage`。
- 从 selected payload 的常见 field names 中宽松提取 input/output/total token counts。
- 对 absolute totals，跟踪相对于 last reported totals 的 deltas，避免 double-counting。
- 不要将 generic `usage` maps 视为 cumulative totals，除非该 event type 定义其如此。
- 在 orchestrator state 中累积 aggregate totals。

Runtime accounting：

- Runtime SHOULD 在 snapshot/render time 以 live aggregate 报告。
- Implementations MAY 为已结束 sessions 维护 cumulative counter，并在生成 snapshot/status view 时加入由 `running` entries（例如 `started_at`）推导的 active-session elapsed time。
- 当 session 结束（normal exit 或 cancellation/termination）时，将 run duration seconds 加到 cumulative ended-session runtime。
- Runtime totals 不 REQUIRED 通过 continuous background ticking 更新。

Rate-limit tracking：

- 跟踪任意 agent update 中看到的最新 rate-limit payload。
- rate-limit data 的任何 human-readable presentation 都是 implementation-defined。

### 13.6 Humanized Agent Event Summaries (OPTIONAL)

Raw agent protocol events 的 humanized summaries 是 OPTIONAL。

如果实现：

- 将其视为 observability-only output。
- 不要让 orchestrator logic 依赖 humanized strings。

### 13.7 OPTIONAL HTTP Server Extension

本节定义一个用于 observability 和 operational control 的 OPTIONAL HTTP interface。

如果实现：

- HTTP server 是 extension，conformance 不 REQUIRED。
- Implementation MAY 为 dashboard 提供 server-rendered HTML 或 client-side application。
- Dashboard/API MUST 仅作为 observability/control surfaces，且 MUST NOT 成为 orchestrator correctness 的 REQUIRED 条件。

Extension config：

- `server.port` (integer, OPTIONAL)
  - 启用 HTTP server extension。
  - `0` 为 local development 和 tests 请求 ephemeral port。
  - CLI `--port` 在两者同时存在时覆盖 `server.port`。

Enablement (extension)：

- 当提供 CLI `--port` argument 时启动 HTTP server。
- 当 `server.port` 出现在 `WORKFLOW.md` front matter 中时启动 HTTP server。
- `server` top-level key 由该 extension 拥有。
- Positive `server.port` values 绑定该 port。
- Implementations SHOULD 默认绑定 loopback（`127.0.0.1` 或 host equivalent），除非显式配置其他行为。
- HTTP listener settings（例如 `server.port`）的 changes 不需要 hot-rebind；restart-required behavior 是 conformant。

#### 13.7.1 Human-Readable Dashboard (`/`)

- 在 `/` host 一个 human-readable dashboard。
- 返回的 document SHOULD 描绘系统当前 state（例如 active sessions、retry delays、token consumption、runtime totals、recent events，以及 health/error indicators）。
- 这可以由实现决定是 server-generated HTML，还是 consuming 下方 JSON API 的 client-side app。

#### 13.7.2 JSON REST API (`/api/v1/*`)

在 `/api/v1/*` 下提供 JSON REST API，用于 current runtime state 和 operational debugging。

Minimum endpoints：

- `GET /api/v1/state`
  - 返回当前 system state 的 summary view（running sessions、retry queue/delays、aggregate token/runtime totals、latest rate limits，以及任何额外 tracked summary fields）。
  - Suggested response shape：

    ```json
    {
      "generated_at": "2026-02-24T20:15:30Z",
      "counts": {
        "running": 2,
        "retrying": 1
      },
      "running": [
        {
          "issue_id": "abc123",
          "issue_identifier": "MT-649",
          "state": "In Progress",
          "session_id": "thread-1-turn-1",
          "turn_count": 7,
          "last_event": "turn_completed",
          "last_message": "",
          "started_at": "2026-02-24T20:10:12Z",
          "last_event_at": "2026-02-24T20:14:59Z",
          "tokens": {
            "input_tokens": 1200,
            "output_tokens": 800,
            "total_tokens": 2000
          }
        }
      ],
      "retrying": [
        {
          "issue_id": "def456",
          "issue_identifier": "MT-650",
          "attempt": 3,
          "due_at": "2026-02-24T20:16:00Z",
          "error": "no available orchestrator slots"
        }
      ],
      "codex_totals": {
        "input_tokens": 5000,
        "output_tokens": 2400,
        "total_tokens": 7400,
        "seconds_running": 1834.2
      },
      "rate_limits": null
    }
    ```

- `GET /api/v1/<issue_identifier>`
  - 返回 identified issue 的 issue-specific runtime/debug details，包括 implementation 跟踪的任何有助于 debugging 的信息。
  - Suggested response shape：

    ```json
    {
      "issue_identifier": "MT-649",
      "issue_id": "abc123",
      "status": "running",
      "workspace": {
        "path": "/tmp/symphony_workspaces/MT-649"
      },
      "attempts": {
        "restart_count": 1,
        "current_retry_attempt": 2
      },
      "running": {
        "session_id": "thread-1-turn-1",
        "turn_count": 7,
        "state": "In Progress",
        "started_at": "2026-02-24T20:10:12Z",
        "last_event": "notification",
        "last_message": "Working on tests",
        "last_event_at": "2026-02-24T20:14:59Z",
        "tokens": {
          "input_tokens": 1200,
          "output_tokens": 800,
          "total_tokens": 2000
        }
      },
      "retry": null,
      "logs": {
        "codex_session_logs": [
          {
            "label": "latest",
            "path": "/var/log/symphony/codex/MT-649/latest.log",
            "url": null
          }
        ]
      },
      "recent_events": [
        {
          "at": "2026-02-24T20:14:59Z",
          "event": "notification",
          "message": "Working on tests"
        }
      ],
      "last_error": null,
      "tracked": {}
    }
    ```

  - 如果 issue 对 current in-memory state 来说 unknown，返回 `404` 和 error response（例如 `{"error":{"code":"issue_not_found","message":"..."}}`）。

- `POST /api/v1/refresh`
  - Queues 一个 immediate tracker poll + reconciliation cycle（best-effort trigger；implementations MAY 合并重复 requests）。
  - Suggested request body：empty body 或 `{}`。
  - Suggested response（`202 Accepted`）shape：

    ```json
    {
      "queued": true,
      "coalesced": false,
      "requested_at": "2026-02-24T20:15:30Z",
      "operations": ["poll", "reconcile"]
    }
    ```

API design notes：

- 上述 JSON shapes 是 interoperability 和 debugging ergonomics 的 RECOMMENDED baseline。
- Implementations MAY 添加 fields，但 SHOULD 避免破坏一个 version 内的 existing fields。
- 除 `/refresh` 这类 operational triggers 外，endpoints SHOULD 是 read-only。
- Defined routes 上的 unsupported methods SHOULD 返回 `405 Method Not Allowed`。
- API errors SHOULD 使用 JSON envelope，例如 `{"error":{"code":"...","message":"..."}}`。
- 如果 dashboard 是 client-side app，它 SHOULD consume 此 API，而不是复制 state logic。

## 14. Failure Model and Recovery Strategy

### 14.1 Failure Classes

1. `Workflow/Config Failures`
   - Missing `WORKFLOW.md`
   - Invalid YAML front matter
   - Unsupported tracker kind 或 missing tracker credentials/project slug
   - Missing coding-agent executable

2. `Workspace Failures`
   - Workspace directory creation failure
   - Workspace population/synchronization failure（implementation-defined；可能来自 hooks）
   - Invalid workspace path configuration
   - Hook timeout/failure

3. `Agent Session Failures`
   - Startup handshake failure
   - Turn failed/cancelled
   - Turn timeout
   - User input requested，并按 implementation 文档化 policy 作为 failure 处理
   - Subprocess exit
   - Stalled session（无 activity）

4. `Tracker Failures`
   - API transport errors
   - Non-200 status
   - GraphQL errors
   - malformed payloads

5. `Observability Failures`
   - Snapshot timeout
   - Dashboard render errors
   - Log sink configuration failure

### 14.2 Recovery Behavior

- Dispatch validation failures：
  - 跳过 new dispatches。
  - 保持 service alive。
  - 在可能时继续 reconciliation。

- Worker failures：
  - 转换为 exponential backoff retries。

- Tracker candidate-fetch failures：
  - 跳过本 tick。
  - 下一个 tick 再试。

- Reconciliation state-refresh failures：
  - 保持 current workers。
  - 下一个 tick 再试。

- Dashboard/log failures：
  - 不要 crash orchestrator。

### 14.3 Partial State Recovery (Restart)

当前设计有意将 scheduler state 保持在 in-memory。
Restart recovery 意味着 service 可以通过 polling tracker state 和复用 preserved workspaces 恢复有用运行。它不意味着 retry timers、running sessions 或 live worker state 可以在 process restart 后存活。

After restart：

- 不从先前 process memory 恢复 retry timers。
- 不假定 running sessions 可恢复。
- Service 通过以下方式恢复：
  - startup terminal workspace cleanup
  - fresh polling of active issues
  - re-dispatching eligible work

### 14.4 Operator Intervention Points

Operators 可以通过以下方式控制 behavior：

- 编辑 `WORKFLOW.md`（prompt 和大多数 runtime settings）。
- `WORKFLOW.md` changes 会按 Section 6.2 自动检测并重新应用，无需 restart。
- 在 tracker 中改变 issue states：
  - terminal state -> reconciled 时 running session 会停止并清理 workspace
  - non-active state -> running session 会停止但不 cleanup
- 为 process recovery 或 deployment restart service（不是应用 workflow config changes 的正常路径）。

## 15. Security and Operational Safety

### 15.1 Trust Boundary Assumption

每个 implementation 定义自己的 trust boundary。

Operational safety requirements：

- Implementations SHOULD 明确说明其目标是 trusted environments、more restrictive environments，或两者兼顾。
- Implementations SHOULD 明确说明它们是否依赖 auto-approved actions、operator approvals、stricter sandboxing，或这些 controls 的组合。
- Workspace isolation 和 path validation 是重要的 baseline controls，但不能替代 implementation 选择的 approval 和 sandbox policy。

### 15.2 Filesystem Safety Requirements

Mandatory：

- Workspace path MUST remain under configured workspace root。
- Coding-agent cwd MUST 是当前 run 的 per-issue workspace path。
- Workspace directory names MUST 使用 sanitized identifiers。

RECOMMENDED additional hardening for ports：

- 在 dedicated OS user 下运行。
- 限制 workspace root permissions。
- 如可能，将 workspace root 挂载到 dedicated volume。

### 15.3 Secret Handling

- 支持 workflow config 中的 `$VAR` indirection。
- 不要 log API tokens 或 secret env values。
- Validate secrets 是否存在，但不要打印它们。

### 15.4 Hook Script Safety

Workspace hooks 是来自 `WORKFLOW.md` 的 arbitrary shell scripts。

Implications：

- Hooks 是 fully trusted configuration。
- Hooks 在 workspace directory 内运行。
- Hook output SHOULD 在 logs 中截断。
- Hook timeouts 是 REQUIRED，以避免 hanging orchestrator。

### 15.5 Harness Hardening Guidance

让 Codex agents 针对 repositories、issue trackers 以及其他可能包含 sensitive data 或 externally-controlled content 的 inputs 运行可能有危险。宽松的 deployment 可能导致 data leaks、destructive mutations，或当 agent 被诱导执行 harmful commands 或使用 overly-powerful integrations 时导致 full machine compromise。

Implementations SHOULD 明确评估自身 risk profile，并在适当位置 harden execution harness。本 specification 有意不强制单一 hardening posture，但 implementations SHOULD NOT 仅因为 tracker data、repository contents、prompt inputs 或 tool arguments 来自普通 workflow 内部，就假定它们完全可信。

Possible hardening measures include：

- 收紧本 specification 其他位置描述的 Codex approval 和 sandbox settings，而不是使用 maximally permissive configuration 运行。
- 添加外部 isolation layers，例如 OS/container/VM sandboxing、network restrictions，或超出 built-in Codex policy controls 的 separate credentials。
- 过滤哪些 Linear issues、projects、teams、labels 或其他 tracker sources 符合 dispatch 条件，使 untrusted 或 out-of-scope tasks 不会自动到达 agent。
- 缩窄 `linear_graphql` tool，使其只能 read 或 mutate intended project scope 内的数据，而不是暴露 general workspace-wide tracker access。
- 将 agent 可用的 client-side tools、credentials、filesystem paths 和 network destinations 缩减到 workflow 所需的最小集合。

正确 controls 取决于 deployment，但 implementations SHOULD 清楚文档化它们，并将 harness hardening 视为 core safety model 的一部分，而不是 optional afterthought。

## 16. Reference Algorithms (Language-Agnostic)

### 16.1 Service Startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  start_workflow_watch(on_change=reload_and_reapply_workflow)

  state = {
    poll_interval_ms: get_config_poll_interval_ms(),
    max_concurrent_agents: get_config_max_concurrent_agents(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    completed: set(),
    codex_totals: {input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    codex_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)

  event_loop(state)
```

### 16.2 Poll-and-Dispatch Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  issues = tracker.fetch_candidate_issues()
  if issues failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  for issue in sort_for_dispatch(issues):
    if no_available_slots(state):
      break

    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

### 16.3 Reconcile Active Runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    log_debug("keep workers running")
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if issue.state in active_states:
      state.running[issue.id].issue = issue
    else:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=false)

  return state
```

### 16.4 Dispatch One Issue

```text
function dispatch_issue(issue, state, attempt):
  worker = spawn_worker(
    fn -> run_agent_attempt(issue, attempt, parent_orchestrator_pid) end
  )

  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })

  state.running[issue.id] = {
    worker_handle,
    monitor_handle,
    identifier: issue.identifier,
    issue,
    session_id: null,
    codex_app_server_pid: null,
    last_codex_message: null,
    last_codex_event: null,
    last_codex_timestamp: null,
    codex_input_tokens: 0,
    codex_output_tokens: 0,
    codex_total_tokens: 0,
    last_reported_input_tokens: 0,
    last_reported_output_tokens: 0,
    last_reported_total_tokens: 0,
    retry_attempt: normalize_attempt(attempt),
    started_at: now_utc()
  }

  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker Attempt (Workspace + Prompt + Agent)

```text
function run_agent_attempt(issue, attempt, orchestrator_channel):
  workspace = workspace_manager.create_for_issue(issue.identifier)
  if workspace failed:
    fail_worker("workspace error")

  if run_hook("before_run", workspace.path) failed:
    fail_worker("before_run hook error")

  session = app_server.start_session(workspace=workspace.path)
  if session failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent session startup error")

  max_turns = config.agent.max_turns
  turn_number = 1

  while true:
    prompt = build_turn_prompt(workflow_template, issue, attempt, turn_number, max_turns)
    if prompt failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("prompt error")

    turn_result = app_server.run_turn(
      session=session,
      prompt=prompt,
      issue=issue,
      on_message=(msg) -> send(orchestrator_channel, {codex_update, issue.id, msg})
    )

    if turn_result failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("agent turn error")

    refreshed_issue = tracker.fetch_issue_states_by_ids([issue.id])
    if refreshed_issue failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("issue state refresh error")

    issue = refreshed_issue[0] or issue

    if issue.state is not active:
      break

    if turn_number >= max_turns:
      break

    turn_number = turn_number + 1

  app_server.stop_session(session)
  run_hook_best_effort("after_run", workspace.path)

  exit_normal()
```

### 16.6 Worker Exit and Retry Handling

```text
on_worker_exit(issue_id, reason, state):
  running_entry = state.running.remove(issue_id)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal:
    state.completed.add(issue_id)  # bookkeeping only
    state = schedule_retry(state, issue_id, 1, {
      identifier: running_entry.identifier,
      delay_type: continuation
    })
  else:
    state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
      identifier: running_entry.identifier,
      error: format("worker exited: %reason")
    })

  notify_observers()
  return state
```

```text
on_retry_timer(issue_id, state):
  retry_entry = state.retry_attempts.pop(issue_id)
  if missing:
    return state

  candidates = tracker.fetch_candidate_issues()
  if fetch failed:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: retry_entry.identifier,
      error: "retry poll failed"
    })

  issue = find_by_id(candidates, issue_id)
  if issue is null:
    state.claimed.remove(issue_id)
    return state

  if available_slots(state) == 0:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: issue.identifier,
      error: "no available orchestrator slots"
    })

  return dispatch_issue(issue, state, attempt=retry_entry.attempt)
```

## 17. Test and Validation Matrix

Conforming implementation SHOULD 包含覆盖本 specification 中定义 behaviors 的 tests。

Validation profiles：

- `Core Conformance`: 所有 conforming implementations REQUIRED 的 deterministic tests。
- `Extension Conformance`: 仅当 implementation 选择 ship OPTIONAL features 时才 REQUIRED。
- `Real Integration Profile`: production use 前 RECOMMENDED 的 environment-dependent smoke/integration checks。

除非另有说明，Sections 17.1 through 17.7 属于 `Core Conformance`。以 `If ... is implemented` 开头的 bullets 属于 `Extension Conformance`。

### 17.1 Workflow and Config Parsing

- Workflow file path precedence：
  - 当提供 explicit runtime path 时使用它
  - 未提供 explicit runtime path 时，cwd default 是 `WORKFLOW.md`
- Workflow file changes 被检测到，并触发无需 restart 的 re-read/re-apply
- Invalid workflow reload 会保留 last known good effective configuration，并发出 operator-visible error
- Missing `WORKFLOW.md` 返回 typed error
- Invalid YAML front matter 返回 typed error
- Front matter non-map 返回 typed error
- OPTIONAL values 缺失时应用 config defaults
- `tracker.kind` validation 强制当前支持的 kind（`linear`）
- `tracker.api_key` 可用（包括 `$VAR` indirection）
- `$VAR` resolution 对 tracker API key 和 path values 可用
- `~` path expansion 可用
- `codex.command` 被保留为 shell command string
- Per-state concurrency override map 会 normalize state names 并忽略 invalid values
- Prompt template 渲染 `issue` 和 `attempt`
- Prompt rendering 在 unknown variables 上失败（strict mode）

### 17.2 Workspace Manager and Safety

- 每个 issue identifier 的 workspace path 确定性生成
- Missing workspace directory 会被创建
- Existing workspace directory 会被复用
- workspace location 上 existing non-directory path 会被安全处理（replace 或按 implementation policy fail）
- OPTIONAL workspace population/synchronization errors 会被 surfaced
- `after_create` hook 仅在 new workspace creation 时运行
- `before_run` hook 在每次 attempt 前运行，failure/timeouts 会中止当前 attempt
- `after_run` hook 在每次 attempt 后运行，failure/timeouts 会被 logged and ignored
- `before_remove` hook 在 cleanup 时运行，failures/timeouts 会被 ignored
- Workspace path sanitization 和 root containment invariants 在 agent launch 前强制执行
- Agent launch 使用 per-issue workspace path 作为 cwd，并拒绝 out-of-root paths

### 17.3 Issue Tracker Client

- Candidate issue fetch 使用 active states 和 project slug
- Linear query 使用指定的 project filter field（`slugId`）
- Empty `fetch_issues_by_states([])` 不调用 API 直接返回 empty
- Pagination 在多页之间 preserve order
- Blockers 从 type 为 `blocks` 的 inverse relations 规范化
- Labels 规范化为 lowercase
- Issue state refresh by ID 返回 minimal normalized issues
- Issue state refresh query 使用 Section 11.2 指定的 GraphQL ID typing（`[ID!]`）
- request errors、non-200、GraphQL errors、malformed payloads 的 error mapping

### 17.4 Orchestrator Dispatch, Reconciliation, and Retry

- Dispatch sort order 是 priority，然后 oldest creation time
- 带 non-terminal blockers 的 `Todo` issue 不 eligible
- 带 terminal blockers 的 `Todo` issue eligible
- Active-state issue refresh 会更新 running entry state
- Non-active state 会停止 running agent，但不 cleanup workspace
- Terminal state 会停止 running agent 并 clean workspace
- Reconciliation with no running issues 是 no-op
- Normal worker exit 会 schedule 短 continuation retry（attempt 1）
- Abnormal worker exit 会以 10s 为基础的 exponential backoff 增加 retries
- Retry backoff cap 使用 configured `agent.max_retry_backoff_ms`
- Retry queue entries 包含 attempt、due time、identifier 和 error
- Stall detection 会 kill stalled sessions 并 schedule retry
- Slot exhaustion 会以 explicit error reason requeue retries
- 如果实现 snapshot API，它返回 running rows、retry rows、token totals 和 rate limits
- 如果实现 snapshot API，timeout/unavailable cases 会被 surfaced

### 17.5 Coding-Agent App-Server Client

- Launch command 使用 workspace cwd 并调用 `bash -lc <codex.command>`
- Session startup 遵循目标 Codex app-server protocol。
- 当目标 Codex app-server protocol 要求 client identity/capability payloads 时，它们是 valid 的。
- Policy-related startup payloads 使用 implementation 文档化的 approval/sandbox settings
- 目标 protocol 暴露的 thread 和 turn identities 会被提取并用于 emit `session_started`
- Request/response read timeout 被强制执行
- Turn timeout 被强制执行
- 目标 protocol 要求的 transport framing 被正确处理
- 对于 stdio-based transports，diagnostic stderr handling 与 protocol stream 保持分离
- Command/file-change approvals 按 implementation 文档化 policy 处理
- Unsupported dynamic tool calls 会被拒绝，且不使 session stall
- User input requests 按 implementation 文档化 policy 处理，且不会无限期 stall
- 目标 protocol 暴露的 usage 和 rate-limit telemetry 会被提取
- Approval、user-input-required、usage 和 rate-limit signals 按目标 protocol 解释
- 如果实现 client-side tools，session startup 会使用目标 app-server protocol advertise supported tool specs
- 如果实现 `linear_graphql` client-side tool extension：
  - 该 tool 会被 advertised to the session
  - 有效的 `query` / `variables` inputs 会使用 configured Linear auth 执行
  - top-level GraphQL `errors` 产生 `success=false`，同时保留 GraphQL body
  - invalid arguments、missing auth 和 transport failures 返回 structured failure payloads
  - unsupported tool names 仍会 fail，但不会使 session stall

### 17.6 Observability

- Validation failures 是 operator-visible
- Structured logging 包含 issue/session context fields
- Logging sink failures 不会 crash orchestration
- Token/rate-limit aggregation 在 repeated agent updates 之间保持正确
- 如果实现 human-readable status surface，它由 orchestrator state 驱动，且不影响 correctness
- 如果实现 humanized event summaries，它覆盖关键 wrapper/agent event classes，且不改变 orchestrator behavior

### 17.7 CLI and Host Lifecycle

- CLI 接受 positional workflow path argument（`path-to-WORKFLOW.md`）
- 未提供 workflow path argument 时，CLI 使用 `./WORKFLOW.md`
- 对 nonexistent explicit workflow path 或 missing default `./WORKFLOW.md`，CLI 报错
- CLI 清楚 surfaced startup failure
- 当 application starts and shuts down normally 时，CLI 以 success 退出
- 当 startup fails 或 host process exits abnormally 时，CLI 以 nonzero 退出

### 17.8 Real Integration Profile (RECOMMENDED)

这些 checks 对 production readiness 是 RECOMMENDED；当 credentials、network access 或 external service permissions 不可用时，MAY 在 CI 中跳过。

- 可以使用由 `LINEAR_API_KEY` 或 documented local bootstrap mechanism（例如 `~/.linear_api_key`）提供的 valid credentials 运行 real tracker smoke test。
- Real integration tests SHOULD 使用 isolated test identifiers/workspaces，并在实际可行时 cleanup tracker artifacts。
- Skipped real-integration test SHOULD 被报告为 skipped，而不是静默视为 passed。
- 如果在 CI 或 release validation 中显式启用 real-integration profile，failures SHOULD 使该 job fail。

## 18. Implementation Checklist (Definition of Done)

使用 Section 17 中相同的 validation profiles：

- Section 18.1 = `Core Conformance`
- Section 18.2 = `Extension Conformance`
- Section 18.3 = `Real Integration Profile`

### 18.1 REQUIRED for Conformance

- Workflow path selection 支持 explicit runtime path 和 cwd default
- `WORKFLOW.md` loader 支持 YAML front matter + prompt body split
- Typed config layer 支持 defaults 和 `$` resolution
- Dynamic `WORKFLOW.md` watch/reload/re-apply for config and prompt
- Polling orchestrator with single-authority mutable state
- Issue tracker client with candidate fetch + state refresh + terminal fetch
- Workspace manager with sanitized per-issue workspaces
- Workspace lifecycle hooks（`after_create`、`before_run`、`after_run`、`before_remove`）
- Hook timeout config（`hooks.timeout_ms`，default `60000`）
- Coding-agent app-server subprocess client with JSON line protocol
- Codex launch command config（`codex.command`，default `codex app-server`）
- Strict prompt rendering with `issue` and `attempt` variables
- Exponential retry queue with continuation retries after normal exit
- Configurable retry backoff cap（`agent.max_retry_backoff_ms`，default 5m）
- Reconciliation that stops runs on terminal/non-active tracker states
- Workspace cleanup for terminal issues（startup sweep + active transition）
- Structured logs with `issue_id`, `issue_identifier`, and `session_id`
- Operator-visible observability（structured logs；OPTIONAL snapshot/status surface）

### 18.2 RECOMMENDED Extensions (Not REQUIRED for Conformance)

- HTTP server extension honors CLI `--port` over `server.port`, uses a safe default bind host, and exposes the baseline endpoints/error semantics in Section 13.7 if shipped.
- `linear_graphql` client-side tool extension exposes raw Linear GraphQL access through the app-server session using configured Symphony auth.
- TODO: Persist retry queue and session metadata across process restarts.
- TODO: Make observability settings configurable in workflow front matter without prescribing UI implementation details.
- TODO: Add first-class tracker write APIs (comments/state transitions) in the orchestrator instead of only via agent tools.
- TODO: Add pluggable issue tracker adapters beyond Linear.

### 18.3 Operational Validation Before Production (RECOMMENDED)

- Run the `Real Integration Profile` from Section 17.8 with valid credentials and network access.
- Verify hook execution and workflow path resolution on the target host OS/shell environment.
- If the OPTIONAL HTTP server is shipped, verify the configured port behavior and loopback/default bind expectations on the target environment.

## Appendix A. SSH Worker Extension (OPTIONAL)

本 appendix 描述一种常见 extension profile：Symphony 保持一个 central orchestrator，但通过 SSH 在一个或多个 remote hosts 上执行 worker runs。

Extension config：

- `worker.ssh_hosts` (list of SSH host strings, OPTIONAL)
  - 省略时，work runs locally。
- `worker.max_concurrent_agents_per_host` (positive integer, OPTIONAL)
  - 应用于 configured SSH hosts 的 shared per-host cap。

### A.1 Execution Model

- orchestrator 仍是 polling、claims、retries 和 reconciliation 的 single source of truth。
- `worker.ssh_hosts` 提供 remote execution 的 candidate SSH destinations。
- 每个 worker run 一次分配给一个 host，该 host 与 issue workspace 一起成为 run 的 effective execution identity 的一部分。
- `workspace.root` 在 remote host 上解释，而不是在 orchestrator host 上解释。
- coding-agent app-server 通过 SSH stdio 启动，而不是作为 local subprocess，因此虽然 commands 远程执行，orchestrator 仍拥有 session lifecycle。
- 一个 worker lifetime 内的 continuation turns SHOULD 留在同一个 host 和 workspace 上。
- Remote host SHOULD 满足与 local worker environment 相同的 basic contract：reachable shell、writable workspace root、coding-agent executable，以及任何 required auth 或 repository prerequisites。

### A.2 Scheduling Notes

- SSH hosts MAY 被视为 dispatch pool。
- 当 previously used host 仍 available 时，Implementations MAY 在 retries 中 prefer 该 host。
- `worker.max_concurrent_agents_per_host` 是跨 configured SSH hosts 的 OPTIONAL shared per-host cap。
- 当所有 SSH hosts 都 at capacity 时，dispatch SHOULD wait，而不是静默 fallback 到不同 execution mode。
- 当 original host 在 work 有意义地 started 之前 unavailable 时，Implementations MAY fail over 到另一个 host。
- 一旦 run 已经产生 side effects，另一个 host 上的 transparent rerun SHOULD 被视为 new attempt，而不是 invisible failover。

### A.3 Problems to Consider

- Remote environment drift：
  - 每个 host 都需要 expected shell environment、coding-agent executable、auth 和 repository prerequisites。
- Workspace locality：
  - Workspaces 通常是 host-local，因此除非存在 shared storage，否则将 issue 移到不同 host 通常是 cold restart。
- Path and command safety：
  - 一旦 execution 跨越 machine boundary，remote path resolution、shell quoting 和 workspace-boundary checks 更重要。
- Startup and failover semantics：
  - Implementations SHOULD 区分 host-connectivity/startup failures 和 in-workspace agent failures，避免同一个 ticket 被意外地在多个 hosts 上 re-executed。
- Host health and saturation：
  - Dead 或 overloaded host SHOULD 降低 available capacity，而不是导致 duplicate execution 或 accidental fallback to local work。
- Cleanup and observability：
  - Operators 需要知道哪个 host 拥有 run、workspace 位于何处，以及 cleanup 是否发生在正确机器上。
