# Symphony Elixir

此目录包含当前基于仓库根目录中 [`SPEC.md`](../SPEC.md) 的 Symphony Elixir/OTP 实现。

> [!WARNING]
> Symphony Elixir 是仅用于评估的原型软件，按原样提供。
> 我们建议你基于 `SPEC.md` 实现自己的强化版本。

## 截图

![Symphony Elixir 截图](../.github/media/elixir-screenshot.png)

## 工作方式

1. 轮询 Linear 中的候选工作
2. 为每个事项创建一个 workspace
3. 在该 workspace 内以 [App Server mode](https://developers.openai.com/codex/app-server/) 启动 Codex
4. 向 Codex 发送 workflow prompt
5. 持续让 Codex 处理该事项，直到工作完成

在 app-server 会话期间，Symphony 还会提供一个客户端侧的 `linear_graphql` 工具，使 repo skills 能够发起原始 Linear GraphQL 调用。

如果一个已领取的事项进入终止状态（`Done`、`Closed`、`Cancelled` 或 `Duplicate`），Symphony 会停止该事项的活跃 agent，并清理匹配的 workspaces。

如果 Codex 报告需要 operator input、approval 或 MCP elicitation，Symphony 会保持该事项的 claimed 状态，并在 runtime state、JSON API 和 dashboard 中将其显示为 blocked。Blocked 条目只保存在内存中；重启 orchestrator 会清空该 blocked map，因此任何仍然活跃的 Linear 事项在重启后都可能再次成为 dispatch candidate。

## 使用方法

1. 确保你的 codebase 已经设置为适合 agents 工作：参见 [Harness engineering](https://openai.com/index/harness-engineering/)。
2. 在 Linear 中通过 Settings → Security & access → Personal API keys 获取一个新的 personal token，并将其设置为 `LINEAR_API_KEY` 环境变量。
3. 将此目录中的 `WORKFLOW.md` 复制到你的 repo。
4. 可选：将 `commit`、`push`、`pull`、`land` 和 `linear` skills 复制到你的 repo。
   - `linear` skill 需要 Symphony 的 `linear_graphql` app-server tool，用于执行原始 Linear GraphQL 操作，例如 comment editing 或 upload flows。
5. 为你的项目自定义复制后的 `WORKFLOW.md` 文件。
   - 要获取项目的 slug，请右键点击该 project 并复制其 URL。slug 是 URL 的一部分。
   - 基于此 repo 创建 workflow 时，请注意它依赖非标准 Linear issue statuses："Rework"、"Human Review" 和 "Merging"。你可以在 Linear 的 Team Settings → Workflow 中自定义它们。
6. 按照下面的说明安装所需的 runtime dependencies 并启动服务。

## 前置条件

我们推荐使用 [mise](https://mise.jdx.dev/) 管理 Elixir/Erlang 版本。

```bash
mise install
mise exec -- elixir --version
```

## 运行

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## 配置

启动服务时，可以向 `./bin/symphony` 传入自定义 workflow 文件路径：

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

如果未传入路径，Symphony 默认使用 `./WORKFLOW.md`。

可选 flags：

- `--logs-root` 告诉 Symphony 将 logs 写入另一个目录（默认：`./log`）
- `--port` 同时启动 Phoenix observability service（默认：disabled）

`WORKFLOW.md` 文件使用 YAML front matter 进行配置，并使用 Markdown body 作为 Codex session prompt。

最小示例：

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

说明：

- 如果某个值缺失，会使用 defaults。
- 当 policy fields 被省略时，会使用更安全的 Codex defaults：
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- 支持的 `codex.approval_policy` 值取决于目标 Codex app-server 版本。在当前本地 Codex schema 中，字符串值包括 `untrusted`、`on-failure`、`on-request` 和 `never`，并且也支持 object-form `reject`。
- 支持的 `codex.thread_sandbox` 值：`read-only`、`workspace-write`、`danger-full-access`。
- 当显式设置 `codex.turn_sandbox_policy` 时，Symphony 会将该 map 原样传递给 Codex。兼容性随后取决于目标 Codex app-server 版本，而不是本地 Symphony validation。
- `agent.max_turns` 限制在单次 agent invocation 中 Symphony 连续运行的 Codex turns 数量；前提是某个 turn 正常完成但该事项仍处于 active state。默认值：`20`。
- 如果 Markdown body 为空，Symphony 会使用包含 issue identifier、title 和 body 的默认 prompt template。
- 使用 `hooks.after_create` 引导一个全新的 workspace。对于 Git-backed repo，你可以在那里运行 `git clone ... .`，以及你需要的任何其他 setup commands。
- 如果某个 hook 需要在 freshly cloned workspace 内执行 `mise exec`，请在后续其他 hooks 调用 `mise` 之前，先在 `hooks.after_create` 中 trust repo config 并获取 project dependencies。
- 当 `tracker.api_key` 未设置或值为 `$LINEAR_API_KEY` 时，会从 `LINEAR_API_KEY` 读取。
- 对于 path values，`~` 会展开为 home directory。
- 对于 env-backed path values，请使用 `$VAR`。`workspace.root` 会先解析 `$VAR` 再处理 path，而 `codex.command` 保持为 shell command string，其中任何 `$VAR` expansion 都会发生在 launched shell 中。

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- 如果 `WORKFLOW.md` 缺失或启动时存在 invalid YAML，Symphony 不会 boot。
- 如果之后的 reload 失败，Symphony 会继续使用最后一个 known good workflow 运行，并记录 reload error，直到该文件被修复。
- `server.port` 或 CLI `--port` 会启用可选的 Phoenix LiveView dashboard 和 JSON API，地址包括 `/`、`/api/v1/state`、`/api/v1/<issue_identifier>` 和 `/api/v1/refresh`。

## Web dashboard

observability UI 现在运行在一个最小 Phoenix stack 上：

- dashboard 位于 `/`，使用 LiveView
- operational debugging 的 JSON API 位于 `/api/v1/*`
- 使用 Bandit 作为 HTTP server
- 使用 Phoenix dependency static assets 进行 LiveView client bootstrap

## 项目布局

- `lib/`：application code 和 Mix tasks
- `test/`：runtime behavior 的 ExUnit coverage
- `WORKFLOW.md`：local runs 使用的 in-repo workflow contract
- `../.codex/`：repository-local Codex skills 和 setup helpers

## 测试

```bash
make all
```

只有当你希望 Symphony 创建一次性 Linear resources 并启动真实的 `codex app-server` 会话时，才运行真实的 external end-to-end test：

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

可选 environment variables：

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` 在设置时使用这些 SSH hosts，格式为 comma-separated list

`make e2e` 会运行两个 live scenarios：
- 一个使用 local worker
- 一个使用 SSH workers

如果未设置 `SYMPHONY_LIVE_SSH_WORKER_HOSTS`，SSH scenario 会使用 `docker compose` 在 `localhost:<port>` 启动两个一次性 SSH workers。live test 会生成临时 SSH keypair，将 host `~/.codex/auth.json` mount 到每个 worker 中，验证 Symphony 能够通过真实 SSH 与它们通信，然后针对这些 worker addresses 运行相同的 orchestration flow。这样可以保持 transport 的代表性，同时不依赖长期存在的 external machines。

如果你希望 `make e2e` 目标指向真实 SSH hosts，请设置 `SYMPHONY_LIVE_SSH_WORKER_HOSTS`。

live test 会创建一个临时 Linear project 和 issue，写入临时 `WORKFLOW.md`，运行一次真实 agent turn，验证 workspace side effect，要求 Codex 在 Linear issue 上 comment 并 close，然后将 project 标记为 completed，使该 run 在 Linear 中保持可见。

## FAQ

### 为什么是 Elixir？

Elixir 构建在 Erlang/BEAM/OTP 之上，非常适合 supervising long-running processes。它有活跃的 tools 和 libraries 生态。它还支持 hot code reloading，而无需停止正在活跃运行的 subagents，这在开发期间非常有用。

### 为我自己的 codebase 设置它，最简单的方式是什么？

在你的 repo 中启动 `codex`，把 Symphony repo 的 URL 给它，并让它替你完成设置。

## License

此项目基于 [Apache License 2.0](../LICENSE) 授权。
