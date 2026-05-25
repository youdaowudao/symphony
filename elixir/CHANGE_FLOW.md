# Change Flow

本文件是变更流程规则的权威来源。

- `AGENTS.md` 只保留入口，不再展开完整变更流程。
- 验证细节、`Next Push Gate` 的定义和测试操作，统一见 `elixir/TESTING.md`。
- 修改变更流程规则时，默认只改本文件；只有运行期必须看到的流程行为发生变化时，才同步修改 `AGENTS.md` 或 `WORKFLOW.md` 的短入口。

## 默认工作法

- 先看 `git diff`，再判断这次改动属于代码变更、文档变更还是只读调查。
- 只要涉及代码新增、删除、重构或行为变更，就按代码变更流程走。
- 只读调查、纯文档和 Linear triage/cleanup，不要硬套完整代码收口流程；只执行与范围相称的验证和记录。
- 进入 PR create/update 之前，先完成本次改动所需的验证；验证怎么跑、gate 怎么选，按 `elixir/TESTING.md` 执行。

## 默认路径与升级分叉

- 先分叉，再收口；不要一上来把所有重型流程全开。
- `只读调查 / 纯文档 / Linear triage-cleanup`：不默认引入代码 reviewer，不默认升级到 full gate，只做与改动范围相称的验证和记录。
- `普通代码变更`：进入 PR create/update 前，先通过当前适用的 `Next Push Gate`，再完成 1 次独立 `final zero-context reviewer`。这是默认代码收口路径。
- `repo plumbing / test support / policy-doc`：默认不按“产品功能代码”处理。先看它是否改变运行时可见行为、`workflow/config contract`、共享 gate 入口或 shared test support contract；没有命中这些面时，仍走轻量或普通路径。
- `高风险代码或流程 / 合同变更`：只有在当前变更明确命中高风险条件，或用户明确要求更重 closeout 时，才允许追加专项升级路径。
- 默认流程不自动引入 `blue analyst`、`red analyst`、`contract checker`、`source-of-truth chain`、`frozen artifact`、`contract matrix`、`closure check`、`baseline lock`、`blocker ledger`。
- 需要升级时，只加当前问题真正需要的那一层；不要把一项高风险信号自动扩成整套重型流程。

高风险升级只在以下情况中考虑：

- 会改变 `workflow / config contract` 或 agent 行为顺序。
- 同一语义会被多个消费面读取，且这次改动改变了摘要、归因、计数、分类或投影口径。
- 复核循环已经出现争议、不收敛或证据与当前 diff 对不上。

命中高风险条件后，仍按最小升级原则处理：

- 只是需要更清楚地说明 source / projection / consumer 时，补一份窄版链路说明，不默认升级成整套合同流程。
- 只是需要冻结目标和边界时，在当前变更文档里补一份简短冻结快照，不默认扩成大而全的 `frozen artifact` 套件。
- 只有确实存在合同口径风险时，才追加 `contract checker`。
- 只有确实存在“验证证据可能已不对应当前 diff”的风险时，才追加更重的 post-validation 确认。

触发信号与新增层级默认对应如下：

- `workflow/config contract` 变化：默认只新增窄版链路说明；不自动新增 `contract checker` 之外的其他重型层。
- 多消费面摘要 / 归因 / 计数 / 分类 / 投影口径变化：默认新增窄版链路说明；只有确实存在合同口径风险时才再加 `contract checker`。
- 高等级验证后证据与当前 diff 不再对应：默认只新增 post-validation 确认；不自动补链路说明、冻结快照或 `contract checker`。
- 目标、边界、固定约束本身需要冻结：默认只补简短冻结快照；不自动带出整套合同流程。

## 失败后的流程回退

- 任何高等级 gate 失败后，都不要直接停留在最高级反复重跑；先回到这次修复真正命中的最小正确层级。
- 任何修复一旦产生新的累计 diff，都先按新的累计 diff 重新判断这次改动属于哪条默认路径或升级分叉，再决定下一步。
- 如果是实现问题或 targeted proof 失败：
  - 先修复。
  - 先重跑最相关的 proof / targeted tests。
  - 如果修复改变了代码或行为，再重过当前 diff 所需的 `final zero-context reviewer`。
  - 只有这些通过后，才回到更高一级 gate。
- 如果是 `closeout gate` 失败：
  - 先修复对应 `fmt` / `lint` / targeted proof 问题。
  - 若修复影响代码或行为，先重过最小 proof 和所需 review。
  - 然后才重新进入 `closeout gate` 的最后确认。
- 如果是 `local make all` 失败：
  - 把它视为“发现了新的问题”，而不是“现在立刻再跑一次 make all”。
  - 先回到最小 proof / targeted tests。
  - 若修复改变了 reviewed object、validation input、shared support、gate plumbing，或影响代码/行为，再重过当前 diff 所需 review。
  - 只有这些都通过后，才把 `make all` 作为最后一步重新执行。
- 如果是远端 CI / full gate 失败：
  - 调查 GitHub Actions 失败时，必须先获取远端 job 原始日志，不得只看 check summary 后直接本地复现。
    - 优先用 GitHub API 读取对应 job log。
    - 如果未认证请求返回 `403 Must have admin rights to Repository`，不要直接判断为“没有权限”。
    - 先检查本机是否已有 repo 的 GitHub git credential：
      `printf 'protocol=https\nhost=github.com\npath=<owner>/<repo>.git\n\n' | git credential fill`
    - 本仓库当前可用凭证来自：
      `credential.helper = store --file ~/.config/git/github-push-credentials`
    - 使用该 credential 认证请求：
      `GET /repos/<owner>/<repo>/actions/jobs/<job_id>/logs`
    - 只有在本机 git credential 缺失、认证后仍 403，或认证身份没有 repo admin / actions log 读取权限时，才报告需要人类补权限。
    - 记录分析时必须区分：
      - check-run summary / annotations
      - job metadata
      - job 原始日志
      - 本地复现输出
  - 本地按同样顺序处理。
  - 不要把 CI 红灯理解成“先重新跑 full gate 就行”。
  - 应先定位问题、做最小修复、重过最小 proof 和所需 review，再回到高等级 gate。

## PR create / update

- 每次 PR create/update 前，先根据 `elixir/TESTING.md` 选择并通过当前适用的 `Next Push Gate`。
- 如果某次 branch push 之前按非 PR push 处理，但之后相同的 head 将用于创建 PR，那么在创建 PR 前必须重新执行当前适用的 gate；不要把后续这次 PR 创建当成一次免费的轻量校验补充。
- PR body 必须严格遵循 `../.github/pull_request_template.md`。
- 需要时，先在本地运行：

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## GitHub 写入路径

- PR create/update、review reply、PR/issue comment 审计、merge 这些关键 GitHub 写操作，默认唯一允许路径是 `../.codex/skills/github_api.py`。
- GitHub UI、`gh`、ad-hoc CLI 和其他 helper，不属于这些动作的常规路径。
- 只有在用户显式授权，或 `github_api.py unavailable` 已被记录为 blocker 时，才允许例外。
- 若发现关键 GitHub 写操作已经通过 GitHub UI、`gh`、ad-hoc CLI 或其他 helper 完成，且不满足上述例外条件，则视为流程违规。
- 出现流程违规时，先停止后续 closeout / merge，用 `../.codex/skills/github_api.py` 在 PR / issue comment stream 记录这次 out-of-band write 的事实与原因，再重新确认 PR 状态、review delta、latest head required checks，并在需要时重新执行对应 gate 后才能继续。

## Review 与放行

- 非代码变更默认不要求 `final zero-context reviewer`，但提交前仍需完成与改动范围相称的独立验证。
- 只要涉及代码新增、删除、重构或行为变更，PR create/update 前必须经过一次 `final zero-context reviewer` 零上下文复核。
- 不要在 review 未完成、验证未完成或 gate 未通过时推进 PR create/update。
- 变更流程只负责决定“什么时候必须 review、什么时候允许 push”；验证本身怎么跑，仍然看 `elixir/TESTING.md`。
- `final zero-context reviewer` 是默认代码收口口，不是高风险专项流程的代称；不要把它自动扩成多角色链条。

## Auto-merge 与 Manual Merge

- 每次成功创建 PR 或成功 push branch-update 之后，在读取 checks、review delta 或 mergeability 之前，第一优先级 GitHub 动作必须是立即尝试开启 auto-merge。
- 对首次 create PR 的场景，允许先创建 PR；但 create PR 一旦成功，第一优先级 GitHub 动作就必须立刻切到该 PR 的 auto-merge 尝试，不得先做其他 GitHub 写操作。
- 若 auto-merge 返回 `already enabled`，视为成功。
- 若 auto-merge 返回 `clean status`，说明 PR 已经来到可直接合并阶段；这不是权限故障，也不是 blocker。此时只要 latest head SHA required checks 全绿，就允许进入手动 merge fallback。
- 只有 auto-merge 因其他原因未开启成功时，才允许保留手动 merge fallback；且必须先在评论区明确汇报失败原因。
- 手动 merge 只作为异常兜底路径，不是常规路径。

## 文档同步

- 如果行为、配置、测试规则、变更流程或 workflow/config contract 发生变化，必须在同一个 PR 中同步更新对应文档。
- 改项目级概念或 goals：更新 `../README.md`
- 改 Elixir 实现使用说明或运行说明：更新 `README.md`
- 改规范、需求定义或实现与规范的一致性：更新 `../SPEC.md`
- 改 workflow / config contract：更新 `WORKFLOW.md`
- 改测试制度：更新 `elixir/TESTING.md`
- 改变更流程制度：更新 `elixir/CHANGE_FLOW.md`
- 入口文档只负责指路；不要把详细制度重新抄回 `AGENTS.md` 或 `WORKFLOW.md`。

## Repo-local 文档流

- 对于 repo-local design docs、specs、implementation plans 以及类似文档，默认视为用户已经授权你起草、编辑、自审，并继续推进到下一个开发步骤。
- 除非用户明确要求这个 gate，否则不要仅仅因为等待用户审阅或明确批准某份已写出的 doc/spec/plan 而停下。
- 只有当文档变化会改变实际行为、合同边界、验证顺序或收口口径时，才把它当作正式变更流程的一部分处理。
