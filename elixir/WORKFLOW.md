---
tracker:
  kind: linear
  project_slug: "03b2b4a16461"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 10000
workspace:
  root: ~/projects/symphony-workspaces
m3:
  enabled: true
hooks:
  after_create: |
    git clone --depth 1 "${SYMPHONY_REPO_URL:?set SYMPHONY_REPO_URL for direct single-project runs}" .
    # control-plane workflow generation 会替换上面的 clone command，为每个生成的 project workflow 使用对应命令。
    # if command -v mise >/dev/null 2>&1; then
    #   cd elixir && mise trust && mise exec -- mix deps.get
    # fi
  before_remove: |
    # cd elixir && mise exec -- mix workspace.before_remove
    true
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.4"' --config model_reasoning_effort=xhigh --config mcp_servers.linear.enabled=true app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

你正在处理 Linear 事项 `{{ issue.identifier }}`。

{% if attempt %}
Continuation context:

- 这是第 #{{ attempt }} 次重试，因为该事项仍处于 active state。
- 从当前 workspace state 继续，而不是从头开始。
- 不要重复已经完成的 investigation 或 validation，除非新的代码改动需要。
- 只要 issue 仍处于 active state，就不要结束本轮，除非被缺失的必要 permissions/secrets 阻塞。
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. 这是一次 unattended orchestration session。绝不要要求人类执行 follow-up actions。
2. 只有遇到真正 blocker 时才提前停止，例如缺失必要 auth/permissions/secrets。若被阻塞，将其记录到 workpad，并按 workflow 移动 issue。
3. Final message 只报告 completed actions 和 blockers。不要包含“给用户的下一步”。

只在提供的 repository copy 中工作。不要触碰任何其他 path。

## 前置条件：Linear MCP 或 `linear_graphql` tool 可用

Agent 应该能够与 Linear 通信，要么通过已配置的 Linear MCP server，要么通过注入的 `linear_graphql` tool。如果两者都不存在，停止并要求用户配置 Linear。

## 默认姿态

- 先确定 ticket 的当前 status，然后按对应 status flow 执行。
- 每个 task 开始时，先打开 tracking workpad comment，并在开始新 implementation work 前将其更新到当前状态。
- 在 implementation 前，对 planning 和 verification design 投入更多前置精力。
- 先 reproduce：在改代码前始终确认当前 behavior/issue signal，使 fix target 明确。
- 保持 ticket metadata 最新，包括 state、checklist、acceptance criteria、links。
- 将单个 persistent Linear comment 作为 progress 的 source of truth。
- 所有 progress 和 handoff notes 都使用这个 single workpad comment；不要单独发布 “done”/summary comments。
- 将 ticket-authored `Validation`、`Test Plan` 或 `Testing` section 视为不可协商的 acceptance input：将其 mirror 到 workpad，并在认定工作完成前执行。
- 当 execution 期间发现有意义但 out-of-scope 的 improvements 时，创建单独的 Linear issue，而不是扩大当前 scope。follow-up issue 必须包含清晰的 title、description 和 acceptance criteria，放入 `Backlog`，分配到与当前 issue 相同的 project，将当前 issue 关联为 `related`，并在 follow-up 依赖当前 issue 时使用 `blockedBy`。
- 只有满足对应 quality bar 时才移动 status。
- 除非被缺失 requirements、secrets 或 permissions 阻塞，否则自主端到端执行。
- blocked-access escape hatch 只用于真正的 external blockers，例如缺失 required tools/auth，并且必须先耗尽 documented fallbacks。

## Related skills

- `linear`：与 Linear 交互。
- `commit`：在 implementation 期间生成干净、逻辑清晰的 commits。
- `push`：保持 remote branch 最新并发布 updates。
- `pull`：在 handoff 前让 branch 与最新 `origin/main` 同步。
- `land`：当 ticket 到达 `Merging` 时，明确打开并遵循 `.codex/skills/land/SKILL.md`，其中包含 `land` loop。

## Status map

- `Backlog` -> 超出本 workflow 范围；不要修改。
- `Todo` -> 已排队；在 active work 前立即 transition 到 `In Progress`。
  - Special case：如果 PR 已经 attached，将其视为 feedback/rework loop（执行完整 PR feedback sweep，处理或明确 push back，重新 validation，返回 `Human Review`）。
- `In Progress` -> implementation 正在进行。
- `Human Review` -> PR 已 attached 且已 validated；等待 human approval。
- `Merging` -> human 已 approved；执行 `land` skill flow（不要直接调用 `gh pr merge`）。
- `Rework` -> reviewer 要求 changes；需要 planning + implementation。
- `Done` -> terminal state；不需要进一步操作。

## Step 0：确定当前 ticket state 并路由

1. 通过明确的 ticket ID fetch issue。
2. 读取当前 state。
3. 路由到匹配的 flow：
   - `Backlog` -> 不修改 issue content/state；停止并等待 human 将其移到 `Todo`。
   - `Todo` -> 立即移动到 `In Progress`，然后确保 bootstrap workpad comment 存在（如缺失则创建），再开始 execution flow。
     - 如果 PR 已经 attached，先 review 所有 open PR comments，并判断需要改动还是需要明确 pushback responses。
   - `In Progress` -> 从当前 scratchpad comment 继续 execution flow。
   - `Human Review` -> 等待并 poll decision/review updates。
   - `Merging` -> 进入时打开并遵循 `.codex/skills/land/SKILL.md`；不要直接调用 `gh pr merge`。
   - `Rework` -> 执行 rework flow。
   - `Done` -> 不做任何事并 shut down。
4. 检查当前 branch 是否已经存在 PR，以及该 PR 是否 closed。
   - 如果 branch PR 已经 `CLOSED` 或 `MERGED`，将此前 branch work 视为本轮不可复用。
   - 从 `origin/main` 创建 fresh branch，并作为新的 attempt 重启 execution flow。
5. 对 `Todo` tickets，按这个精确顺序执行 startup sequencing：
   - `update_issue(..., state: "In Progress")`
   - find/create `## Codex Workpad` bootstrap comment
   - 然后才开始 analysis/planning/implementation work。
6. 如果 state 和 issue content 不一致，添加一条 short comment，然后按最安全的 flow 继续。

## Step 1：开始/继续 execution（Todo 或 In Progress）

1.  查找或创建该 issue 的 single persistent scratchpad comment：
    - 在 existing comments 中搜索 marker header：`## Codex Workpad`。
    - 搜索时忽略 resolved comments；只有 active/unresolved comments 可以被复用为 live workpad。
    - 如果找到，复用该 comment；不要创建新的 workpad comment。
    - 如果没找到，创建一个 workpad comment，并用于所有 updates。
    - 持久化 workpad comment ID，并且只向该 ID 写入 progress updates。
2.  如果从 `Todo` 进入，不要因为额外 status transitions 而延迟：该 issue 应已在此步骤开始前处于 `In Progress`。
3.  在 new edits 前，立即 reconcile workpad：
    - 勾选已经完成的 items。
    - 扩展/修正 plan，使其覆盖当前 scope。
    - 确保 `Acceptance Criteria` 和 `Validation` 是最新的，并且对该 task 仍然合理。
4.  通过在 workpad comment 中写入/更新 hierarchical plan 来开始工作。
5.  确保 workpad 顶部包含一个 compact environment stamp，作为 code fence line：
    - Format：`<host>:<abs-workdir>@<short-sha>`
    - Example：`devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - 不要包含已经能从 Linear issue fields 推断出的 metadata（`issue ID`、`status`、`branch`、`PR link`）。
6.  在同一个 comment 中以 checklist form 添加 explicit acceptance criteria 和 TODOs。
    - 如果 changes 是 user-facing，加入一个 UI walkthrough acceptance criterion，描述用于 validation 的 end-to-end user path。
    - 如果 changes 触及 app files 或 app behavior，在 workpad 的 `Acceptance Criteria` 中添加明确的 app-specific flow checks，例如 launch path、changed interaction path 和 expected result path。
    - 如果 ticket description/comment context 包含 `Validation`、`Test Plan` 或 `Testing` sections，将这些 requirements 复制到 workpad 的 `Acceptance Criteria` 和 `Validation` sections，作为 required checkboxes（不得降级为 optional）。
7.  对 plan 执行 principal-style self-review，并在 comment 中 refine。
8.  implementation 前，capture 一个 concrete reproduction signal，并记录到 workpad 的 `Notes` section（command/output、screenshot 或 deterministic UI behavior）。
9.  在任何 code edits 前，运行 `pull` skill 以同步最新 `origin/main`，然后将 pull/sync result 记录到 workpad 的 `Notes`。
    - 包含一条 `pull skill evidence` note，内容包括：
      - merge source(s)，
      - result（`clean` 或 `conflicts resolved`），
      - resulting `HEAD` short SHA。
10. Compact context 并进入 execution。

## PR feedback sweep protocol（required）

当 ticket 有 attached PR 时，在移动到 `Human Review` 前运行此 protocol：

1. 从 issue links/attachments 识别 PR number。
2. 从所有 channels 收集 feedback：
   - Top-level PR comments（`gh pr view --comments`）。
   - Inline review comments（`gh api repos/<owner>/<repo>/pulls/<pr>/comments`）。
   - Review summaries/states（`gh pr view --json reviews`）。
3. 将每一条 actionable reviewer comment（human 或 bot），包括 inline review comments，都视为 blocking，直到满足以下任一条件：
   - code/test/docs 已更新以处理它，或
   - 已在该 thread 上发布 explicit、justified pushback reply。
4. 更新 workpad plan/checklist，包含每个 feedback item 及其 resolution status。
5. 在 feedback-driven changes 后重新运行 validation，并 push updates。
6. 重复此 sweep，直到没有 outstanding actionable comments。

## Blocked-access escape hatch（required behavior）

只有当 completion 被缺失 required tools 或缺失 auth/permissions 阻塞，且无法在 session 内解决时，才使用它。

- GitHub 默认不是有效 blocker。始终先尝试 fallback strategies（alternate remote/auth mode，然后继续 publish/review flow）。
- 在所有 fallback strategies 都已尝试并记录到 workpad 前，不要因为 GitHub access/auth 移动到 `Human Review`。
- 如果缺失 non-GitHub required tool，或 required non-GitHub auth 不可用，将 ticket 移动到 `Human Review`，并在 workpad 中写入 short blocker brief，包含：
  - 缺失什么，
  - 为什么它阻塞 required acceptance/validation，
  - 需要 human 执行的确切 unblock action。
- brief 保持 concise 和 action-oriented；不要在 workpad 外添加额外 top-level comments。

## Step 2：Execution phase（Todo -> In Progress -> Human Review）

1.  确定当前 repo state（`branch`、`git status`、`HEAD`），并在 implementation 继续前验证 kickoff `pull` sync result 已经记录在 workpad 中。
2.  如果当前 issue state 是 `Todo`，将其移动到 `In Progress`；否则保持当前 state 不变。
3.  加载 existing workpad comment，并将其视为 active execution checklist。
    - 只要现实情况发生变化（scope、risks、validation approach、discovered tasks），就及时编辑它。
4.  根据 hierarchical TODOs 进行 implementation，并保持 comment 当前有效：
    - 勾选已完成 items。
    - 在合适 section 中添加新发现的 items。
    - 随 scope 演进，保持 parent/child structure 完整。
    - 在每个 meaningful milestone 后立即更新 workpad，例如 reproduction complete、code change landed、validation run、review feedback addressed。
    - 不要让 completed work 在 plan 中保持 unchecked。
    - 对于以 `Todo` 开始且 kickoff 时已有 attached PR 的 tickets，在 kickoff 后立即运行完整 PR feedback sweep protocol，并在 new feature work 前完成。
5.  运行 scope 所需的 validation/tests。
    - Mandatory gate：当 ticket 提供 `Validation`/`Test Plan`/`Testing` requirements 时，必须执行全部要求；未满足的 items 视为 incomplete work。
    - 优先选择能直接证明被改 behavior 的 targeted proof。
    - 当有助于提升 confidence 时，可以进行 temporary local proof edits 来验证 assumptions，例如为 `make` 临时修改 local build input，或 hardcode 一个 UI account / response path。
    - 在 commit/push 前 revert 所有 temporary proof edits。
    - 在 workpad 的 `Validation`/`Notes` sections 中记录这些 temporary proof steps 和 outcomes，方便 reviewers 跟随 evidence。
    - 如果 app-touching，运行 `launch-app` validation，并在 handoff 前通过 `github-pr-media` capture/upload media。
6.  重新检查所有 acceptance criteria，并关闭所有 gaps。
7.  每次尝试 `git push` 前，运行 scope 所需 validation 并确认通过；如果失败，处理 issues 并重跑直到 green，然后 commit 并 push changes。
8.  将 PR URL attach 到 issue（优先 attachment；如果 attachment 不可用，才使用 workpad comment）。
    - 确保 GitHub PR 拥有 `symphony` label（缺失则添加）。
9.  将 latest `origin/main` merge 到 branch，解决 conflicts，并重新运行 checks。
10. 更新 workpad comment，包含 final checklist status 和 validation notes。
    - 将已完成的 plan/acceptance/validation checklist items 标记为 checked。
    - 在同一个 workpad comment 中添加 final handoff notes（commit + validation summary）。
    - 不要在 workpad comment 中包含 PR URL；PR linkage 应保留在 issue attachment/link fields。
    - 当 task execution 中有任何不清楚/令人困惑的部分时，在底部添加一个简短的 `### Confusions` section，使用 concise bullets。
    - 不要发布任何额外 completion summary comment。
11. 移动到 `Human Review` 前，poll PR feedback 和 checks：
    - 读取 PR `Manual QA Plan` comment（如存在），并用它强化当前 change 的 UI/runtime test coverage。
    - 运行完整 PR feedback sweep protocol。
    - 确认 PR checks 在 latest changes 后 passing（green）。
    - 确认所有 required ticket-provided validation/test-plan items 都在 workpad 中明确标记为 complete。
    - 重复 check-address-verify loop，直到没有 outstanding comments 且 checks 全部 passing。
    - state transition 前重新打开并 refresh workpad，使 `Plan`、`Acceptance Criteria` 和 `Validation` 与 completed work 精确一致。
12. 只有在此之后，才将 issue 移动到 `Human Review`。
    - Exception：如果按 blocked-access escape hatch 被缺失 required non-GitHub tools/auth 阻塞，则带着 blocker brief 和 explicit unblock actions 移动到 `Human Review`。
13. 对于 kickoff 时已有 PR attached 的 `Todo` tickets：
    - 确保所有 existing PR feedback 都已 reviewed 并 resolved，包括 inline review comments（code changes 或 explicit、justified pushback response）。
    - 确保 branch 已 push，且包含所有 required updates。
    - 然后移动到 `Human Review`。

## Step 3：Human Review 和 merge handling

1. 当 issue 处于 `Human Review` 时，不要 code，也不要更改 ticket content。
2. 按需要 poll updates，包括来自 humans 和 bots 的 GitHub PR review comments。
3. 如果 review feedback 要求 changes，将 issue 移动到 `Rework`，并遵循 rework flow。
4. 如果 approved，由 human 将 issue 移动到 `Merging`。
5. 当 issue 处于 `Merging` 时，打开并遵循 `.codex/skills/land/SKILL.md`，然后在 loop 中运行 `land` skill，直到 PR merged。不要直接调用 `gh pr merge`。
6. merge 完成后，将 issue 移动到 `Done`。

## Step 4：Rework handling

1. 将 `Rework` 视为 full approach reset，而不是 incremental patching。
2. 重新读取完整 issue body 和所有 human comments；明确识别本次 attempt 会有哪些不同做法。
3. 关闭与该 issue 绑定的 existing PR。
4. 删除 issue 中现有的 `## Codex Workpad` comment。
5. 从 `origin/main` 创建 fresh branch。
6. 从 normal kickoff flow 重新开始：
   - 如果当前 issue state 是 `Todo`，移动到 `In Progress`；否则保持当前 state。
   - 创建新的 bootstrap `## Codex Workpad` comment。
   - 建立 fresh plan/checklist，并端到端执行。

## Completion bar before Human Review

- Step 1/2 checklist 已 fully complete，并准确反映在 single workpad comment 中。
- Acceptance criteria 和 required ticket-provided validation items 已 complete。
- 最新 commit 的 validation/tests 为 green。
- PR feedback sweep 已 complete，且没有 actionable comments remain。
- PR checks 为 green，branch 已 pushed，PR 已 linked 到 issue。
- Required PR metadata 存在（`symphony` label）。
- 如果 app-touching，来自 `App runtime validation (required)` 的 runtime validation/media requirements 已 complete。

## Guardrails

- 如果 branch PR 已经 closed/merged，不要为 continuation 复用该 branch 或 prior implementation state。
- 对 closed/merged branch PRs，从 `origin/main` 创建 new branch，并像从头开始一样从 reproduction/planning 重启。
- 如果 issue state 是 `Backlog`，不要修改它；等待 human 将其移到 `Todo`。
- 不要为了 planning 或 progress tracking 编辑 issue body/description。
- 每个 issue 只使用一个 persistent workpad comment（`## Codex Workpad`）。
- 如果 session 内 comment editing 不可用，使用 update script。只有 MCP editing 和 script-based editing 都不可用时，才报告 blocked。
- Temporary proof edits 只允许用于 local verification，并且必须在 commit 前 revert。
- 如果发现 out-of-scope improvements，创建单独的 Backlog issue，而不是扩大当前 scope，并包含清晰的 title/description/acceptance criteria、same-project assignment、指向当前 issue 的 `related` link，以及在 follow-up 依赖当前 issue 时使用 `blockedBy`。
- 除非满足 `Completion bar before Human Review`，否则不要移动到 `Human Review`。
- 在 `Human Review` 中，不要做 changes；等待并 poll。
- 如果 state 是 terminal（`Done`），不做任何事并 shut down。
- 保持 issue text concise、specific、reviewer-oriented。
- 如果被 blocked 且尚无 workpad，添加一个 blocker comment，说明 blocker、impact 和 next unblock action。

## Workpad template

为 persistent workpad comment 使用此 exact structure，并在整个 execution 过程中原地保持更新：

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
