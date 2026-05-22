# Symphony Elixir

这个目录包含 Elixir agent orchestration service：它会轮询 Linear、为每个 issue 创建独立 workspace，并以 app-server 模式运行 Codex。

## 环境

- Elixir: `1.19.x` (OTP 28) via `mise`.
- 安装依赖：`mix setup`。


## Codebase 专用约定

- Runtime config 通过 `SymphonyElixir.Workflow` 和 `SymphonyElixir.Config` 从 `WORKFLOW.md` front matter 加载。
- 优先通过 `SymphonyElixir.Config` 增加配置访问，不要随手做 ad-hoc env 读取。
- Workspace 安全很关键：
  - 不要在 source repo 里运行 Codex turn cwd。
  - Workspaces 必须始终位于已配置的 workspace root 下。
- Orchestrator 行为有状态且对并发敏感；要保持 retry、reconciliation 和 cleanup 语义不被破坏。
- 日志约定和必须带上的 issue/session context 字段，遵循 `docs/logging.md`。

## 必须遵守的规则

- `lib/` 里的 public functions（`def`）必须紧邻一个 `@spec`。
- `defp` 的 spec 是可选的。
- 带 `@impl` 的 callback implementation 不受本地 `@spec` 要求约束。
- 遵循 `lib/symphony_elixir/*` 现有的 module/style patterns。

校验命令：

```bash
mix specs.check
```
