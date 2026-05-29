# 维护记录

这里记录仓库已经合入或已完成待提交的主要变化，方便后续快速了解每个 PR 或本地收口改动大致做了什么。它不是硬性流程门禁，也不替代 PR、Linear 或详细设计文档。

## 2026-05-28

### 本地完成，待文档复核：V0.2 全自动流转阶段规划草案

- 已完成：新增 `docs/initiatives/stage-plans/v0.2/README.md`，作为 V0.2 阶段规划入口。
- 已完成：新增 `01_AI_Review驱动的Issue生命周期流转.md`，固定 V0.2 主流程：`AI Review`、项目级 `review_mode`、Submission Refresh Gate、AI Review Gate、review worktree、Linear 人类评论优先级和 merge 前刷新。
- 已完成：新增 `02_Todo_Pool人工检查功能.md`，把 `Todo Pool` 固定为首页只读人工检查区，不参与调度、不写 Linear。
- 已完成：新增 `03_项目级健康检查与安全恢复.md`，固定全局 / 项目级健康检查边界和安全恢复动作。
- 已完成：新增 `docs/initiatives/SPEC/03_Symphony_V0.2全自动流转长期SPEC.md`，把 V0.2 已确认的长期合同上提到长期 SPEC。
- 已完成：新增 `docs/initiatives/global-planning/03_Symphony_V0.2阶段变化与路线.md`，说明 V0.2 相对 V0.1 的阶段变化。
- 已完成：按 `elixir/PLANNING_FLOW.md` 对这批规划文档做 Level 3 零上下文复核，并按复核结果修订，统一了 `review_mode` 可在提交前调整、Linear 人类评论优先、`review_attempt_limit` 与 `repeat_count` 语义分离等边界。

## 2026-05-25

### 本地完成，待提交：V0.11 项目登记表与配置治理

- 对应 SPEC：`docs/superpowers/specs/SPEC_2026-05-25_V0.11_多项目共享执行池_项目登记表.md`。
- 对应 PLAN：`docs/superpowers/plans/PLAN_2026-05-25_V0.11_多项目共享执行池_项目登记表与配置治理实施计划.md`。
- 已完成：新增 `elixir/project_registry.yaml` 和 `SymphonyElixir.ProjectRegistry`，把 canonical registry 的读取、YAML 校验、legacy bridge 与 normalized entry 输出收进 registry/config 层。
- 已完成：`Config.validate!` 接入 registry-first 校验入口；registry 存在时允许 legacy `tracker.project_slug` 退居兼容桥，冲突与非法配置按 fail closed 返回错误。
- 已完成：补充 `project_registry_test.exs` 与 `core_test.exs`，锁定 schema 形状、字段类型、默认值 `15`、legacy fallback、冲突、空 registry、workflow 读取错误与本阶段 normalized entry 输出边界。
- 已完成：本阶段只归一化 `project_key`、`enabled`、`max_concurrent_agents` 与 `display_name: nil` 占位，不引入 `ProjectContext`、candidate fetch 改造或 admission/filter 行为。
- 验证通过：`cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/symphony_elixir/project_registry_test.exs test/symphony_elixir/core_test.exs`。

### 本地完成，待收口：测试四层分层口径整理

- 已完成：把测试口径整理成 4 层，分别是第一层 targeted tests、第二层本地真实业务闭环、第三层浏览器层、第四层真实外部副作用层。
- 已完成：正式规则收进 `elixir/TESTING.md`，讨论解释留在 `docs/initiatives/stage-plans/testing-plan/README.md`。
- 已完成：第三层和第四层只保留最小稳定口径，避免把讨论稿当成日常运行手册。
- 未完成：这次整理不代表后续所有测试层级都已经自动落地成固定工具链，具体执行仍按正式规则和各入口文件为准。

### 本地完成，待提交：全量 Gate 聚合错误报告

- 对应 SPEC：`docs/superpowers/specs/SPEC_2026-05-25-full-gate-aggregate-reporting.md`。
- 对应 PLAN：`docs/superpowers/plans/PLAN_2026-05-25-full-gate-aggregate-reporting.md`。
- 已完成：新增 `elixir/scripts/run_checks.sh`，把 `lint` 和 `all` 两个入口收敛到同一个聚合 runner；runner 会保留底层命令输出，逐项记录退出码，最后打印 `Symphony checks summary`，任一检查失败时最终返回非零。
- 已完成：`make lint`、`make all` 和 `mix lint` 已接入同一个聚合 runner，避免 full gate 与 closeout lint 行为分叉。
- 已完成：新增 `elixir/test/scripts/run_checks_test.exs`，用 fake `mix` 覆盖 runner 直接行为、`make lint`、`make all` 和真实 `mix lint` alias 的接入行为，验证早期失败后仍继续执行后续检查。
- 已完成：更新 `elixir/TESTING.md`，说明聚合报告只改变错误展示完整性，不改变 gate 路由级别，也不把 `make all` 变成默认开发命令。
- 验证通过：`cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/scripts/run_checks_test.exs`、`cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`、`cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`、`cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all`。
- 未完成：本记录对应的代码和文档还没有提交，也没有创建或更新 PR。

### PR #3：首页更多事件显示与运行状态收口

- 已完成：让首页运行列表展示更完整的最近事件信息，补充相对时间提示，并把运行状态区分为 `running`、`stale`、`waiting_input`、`approval_required`、`error`、`completed`、`unknown` 等语义。
- 已完成：新增 `RuntimeStatus` 分类模块和覆盖运行状态语义的合同测试，避免主屏、API 和内部快照对运行状态各说各话。
- 已完成：补充 `StatusDashboard` 相关 snapshot / formatting 测试，让主屏展示从单句摘要收口到事件/行级运行信息。
- 已完成：新增 Codex 会话查看与运行状态展示的长期规划、决策记录、SPEC、plan 和 task，明确这条线只做运行状态展示，不做完整 viewer。
- 已完成：新增多项目共享执行池 V0.1 阶段规划，并在同一主题下补配置模板、需求解释工作说明和可视化说明等讨论材料。
- 已完成：新增 `.gitignore`，忽略 Elixir 构建产物、依赖目录、本地日志、IDE 文件和本地凭证类文件。
- 已完成：删除 PR 描述校验 workflow，不再运行 `validate-pr-description`。
- 已完成：在 `CHANGE_FLOW.md` 增加 GitHub Actions 原始日志获取说明，明确应优先使用本机 GitHub git credential 获取 job log。
- 未完成：多项目共享执行池仍停留在规划和讨论阶段，尚未进入实现。
- 未完成：Codex 运行状态展示只完成主屏和共享状态语义收口，没有实现完整历史浏览器或第三方 viewer 替代。

## 2026-05-22 至 2026-05-23

### PR #2：收紧 Superpowers 文档模板与测试门禁

- 已完成：把 Superpowers 产物统一收敛到 `docs/superpowers/` 体系，新增 specs、plans、tasks、verification 入口。
- 已完成：新增 SPEC 和 PLAN 硬约束模板，要求进入实现前先把目标、成功标准、非目标、风险边界、失败语义和验证映射写清楚。
- 已完成：更新 `AGENTS.md`、`docs/README.md`、`docs/governance/文档分类规则.md` 和相关治理模板，明确 Superpowers 只是方法，不是长期归档轴。
- 已完成：收紧 `elixir/PLANNING_FLOW.md`，把文档复核表述为 fresh zero-context 独立视角，避免把自问自答包装成 review。
- 已完成：收紧 `elixir/TESTING.md` 和 `.codex/skills/push/SKILL.md`，明确开发阶段默认不把 `make all` 当成通用命令，push 前应按当前 gate 选择验证。
- 已完成：把 coverage threshold 从 100 调整为 99，并记录测试方向快照。
- 已完成：增加测试噪音收口任务记录，抽取部分重复等待辅助逻辑。
- 未完成：测试噪音只完成当前范围内的收口，不代表所有历史测试等待写法都已经完全清理。

## 2026-05-22

### PR #1：完成仓库初始化

- 已完成：完成新仓库初始化基线，补齐 `AGENTS.md`、`README.md`、`SPEC.md`、`docs/README.md`、`docs/governance/`、`docs/initiatives/`、`docs/incidents/` 和 Elixir 入口文档。
- 已完成：新增仓库本地 bootstrap skill，用于后续检查仓库身份、文档入口、工具链和初始化状态。
- 已完成：迁入并整理 Elixir 参考实现入口，建立 `elixir/README.md`、`elixir/TESTING.md`、`elixir/CHANGE_FLOW.md` 等运行期文档。
- 已完成：删除原始仓库中的 Apache `LICENSE` 和 `NOTICE` 文件，当前仓库不再保留这两个原始授权文件。
- 未完成：初始化只建立仓库基线和迁移后的文档/代码入口，没有完成后续功能路线的实现。
