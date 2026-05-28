# 多项目运行入口仍停留在单项目 fetch 模型

## 1. 摘要

本事故描述的是一个已经被代码证据确认的能力缺口：`V0.11` 已经把 `elixir/project_registry.yaml` 落成项目静态真相源，并允许 `Config.validate!/0` 走 registry-first 判定；但运行时真正向 Linear 拉取 candidate issues 和 terminal issues 的入口，仍然直接依赖 `WORKFLOW.md` 里的单一 `tracker.project_slug`。

这意味着：

- 多项目配置并没有丢失，也没有被自动降级回单项目配置。
- 但 orchestrator 的实际取数入口仍然只会围绕一个项目 slug 工作。
- 因此，系统当前还不能宣称“多项目运行闭环已完成”。

这不是文档口径问题，也不是单纯的低优先级运行瑕疵；它是“多项目共享执行池”从配置治理走向真实运行时的阻断项。

## 2. 事故级别判断

建议按“重大已知缺口”管理。

判断依据：

- 对 `V0.11` 这一阶段性交付本身，它不是实现失败，因为当期计划明确排除了 runtime fetch 改造。
- 对“多项目已经可运行”这一更高层目标，它是 blocker，因为不修复就无法让多个项目真正进入同一套 dispatch 流程。

换句话说，这不是 `V0.11` 的返工事故，而是多项目路线中的阶段间闭环事故：上游 registry/config 已完成，下游 runtime fetch 还停留在单项目模型。

## 3. 影响范围

### 3.1 当前不会发生的事

- 不会把 `project_registry.yaml` 自动改写成单项目配置。
- 不会丢失 registry 中的多个项目条目。
- 不会把多项目身份真相重新写回第二份配置源。

### 3.2 当前实际会发生的事

- 如果 `WORKFLOW.md` 里保留单一 `tracker.project_slug`，运行时只会按这一个项目去 fetch。
- registry 中其他项目即使配置合法、`enabled=true`，当前也不会进入 `Tracker.fetch_candidate_issues/0` 的实际取数范围。
- 如果删除 `tracker.project_slug`，`Config.validate!/0` 可能仍然通过，但 runtime fetch 会因为缺少 slug 而失败，导致新的 dispatch 起不来。

### 3.3 对最终目标的影响

在这条缺口修复前，仓库只能说“多项目配置治理已落地”，不能说“多项目共享执行池已具备真实多项目 dispatch 能力”。

## 4. 时间线

1. 需求与合同阶段已经明确：`project_key` 是 canonical 项目身份，下游应先拿到 normalized `ProjectContext`，再进入 tracker、orchestrator、runner、workspace 和观测面。
2. `V0.11` 计划阶段主动收缩范围，只做 registry/config 收口，明确不改 `Linear candidate fetch` 路径，也不做 `ProjectContext` 全链路传递。
3. `V0.11` 实施完成后，配置层已经允许 registry-first。
4. 复核运行时链路时发现：`Linear.Client.fetch_candidate_issues/0` 和 `fetch_issues_by_states/1` 仍直接读取 `tracker.project_slug`，orchestrator 也继续从这个单项目入口取数。
5. 因此形成当前事故：配置层已进入多项目阶段，运行入口仍处于单项目阶段。

## 5. 代码与文档证据

### 5.1 配置层已经接受 registry-first

- [elixir/lib/symphony_elixir/config.ex](/home/ss/projects/symphony/elixir/lib/symphony_elixir/config.ex:137)
  `validate_linear_registry_semantics/1` 通过 `ProjectRegistry.load_normalized/2` 接受 registry 或 legacy bridge 结果。

### 5.2 运行层仍直接读取单一 slug

- [elixir/lib/symphony_elixir/linear/client.ex](/home/ss/projects/symphony/elixir/lib/symphony_elixir/linear/client.ex:107)
  `fetch_candidate_issues/0` 直接读取 `tracker.project_slug`。
- [elixir/lib/symphony_elixir/linear/client.ex](/home/ss/projects/symphony/elixir/lib/symphony_elixir/linear/client.ex:126)
  `fetch_issues_by_states/1` 同样直接读取 `tracker.project_slug`。
- [elixir/lib/symphony_elixir/orchestrator.ex](/home/ss/projects/symphony/elixir/lib/symphony_elixir/orchestrator.ex:252)
  `maybe_dispatch/1` 继续调用 `Tracker.fetch_candidate_issues/0`。
- [elixir/lib/symphony_elixir/orchestrator.ex](/home/ss/projects/symphony/elixir/lib/symphony_elixir/orchestrator.ex:1122)
  启动期 terminal cleanup 继续调用 `Tracker.fetch_issues_by_states/1`。

### 5.3 上游合同已经要求下游消费 ProjectContext

- [docs/initiatives/stage-plans/multi-project-shared-execution-pool/03_配置治理合同.md](/home/ss/projects/symphony/docs/initiatives/stage-plans/multi-project-shared-execution-pool/03_配置治理合同.md:49)
  已明确“先解析 canonical registry，生成 normalized `ProjectContext`，再把这个 context 交给 tracker、orchestrator、runner、workspace、API 和 dashboard”。
- [docs/initiatives/stage-plans/multi-project-shared-execution-pool/03_配置治理合同.md](/home/ss/projects/symphony/docs/initiatives/stage-plans/multi-project-shared-execution-pool/03_配置治理合同.md:83)
  已明确“issue 进入 tracker 聚合后没有 `ProjectContext`，拒绝 dispatch”。

### 5.4 `V0.11` 计划曾明确排除这一改造

- [docs/superpowers/plans/PLAN_2026-05-25_V0.11_多项目共享执行池_项目登记表与配置治理实施计划.md](/home/ss/projects/symphony/docs/superpowers/plans/PLAN_2026-05-25_V0.11_多项目共享执行池_项目登记表与配置治理实施计划.md:5)
  计划目标只做到 registry/config 收口。
- [docs/superpowers/plans/PLAN_2026-05-25_V0.11_多项目共享执行池_项目登记表与配置治理实施计划.md](/home/ss/projects/symphony/docs/superpowers/plans/PLAN_2026-05-25_V0.11_多项目共享执行池_项目登记表与配置治理实施计划.md:30)
  明确“不做 Linear candidate fetch 路径改造”。

## 6. 根因分析

根因不是单点 bug，而是阶段边界带来的结构性断层：

1. `V0.11` 的目标是先冻结 canonical registry 和配置治理合同，这是有意的分阶段推进。
2. 这一步成功把“项目静态真相源”收口到了 registry/config 层。
3. 但运行期 fetch 链路还没有同步切换到“按项目上下文取数”的模型。
4. 于是系统出现了“上游语义已经多项目化，下游入口仍然单项目化”的跨层不一致。

更直白地说，当前缺的不是一个字段，也不是一个默认值，而是 runtime fetch 的调用边界还没从“全局唯一项目 slug”升级为“按 normalized project entries / ProjectContext 逐项目处理”。

## 7. 建议修复方向

这里给的是修复方向意见，不是完整实施计划。

### 7.1 修复目标

把运行时 fetch 入口从单项目 `tracker.project_slug` 模型，迁移到基于 registry normalized entries / `ProjectContext` 的多项目模型。

### 7.2 最小正确修复应满足什么

1. `Linear.Client.fetch_candidate_issues/0` 不能再把 `tracker.project_slug` 当成唯一项目来源。
2. runtime 必须能枚举 registry 中可参与运行的项目，并按项目身份发起 fetch。
3. `orchestrator` 选择 issue 时，拿到的输入里必须保留项目身份，而不是在下游再猜。
4. terminal cleanup 也必须基于同一份项目上下文工作，不能继续只按单一 slug 查 terminal issues。
5. 当项目缺少合法 `ProjectContext` 时，应 fail closed，而不是静默跳回 legacy 单项目行为。

### 7.3 不建议的伪修复

- 继续把 registry 当静态展示层，而 runtime 仍长期依赖 `WORKFLOW.md` 的单一 slug。
- 通过“保留一个主项目 slug，再把其他项目以后再说”的方式，把单项目入口伪装成多项目能力。
- 在多个下游模块各自读取 registry、各自拼项目身份，制造新的分叉真相。
- 让 `display_name`、issue identifier 或 UI 字段参与项目身份判定。

## 8. 后续动作建议

建议把这项工作单独作为后续主题推进，至少覆盖：

1. tracker 聚合与 `ProjectContext` 只读传递设计。
2. `Linear.Client` 多项目 fetch 改造。
3. orchestrator dispatch 输入模型调整。
4. terminal cleanup 与其他读取链路的项目上下文对齐。
5. 新的定向测试，证明多个项目都能进入真实运行闭环，而不是只证明 registry 可读取。

## 9. 当前结论

当前系统的真实状态应表述为：

- `V0.11` 已完成多项目 registry/config 治理落地。
- 多项目运行入口仍未闭环。
- 在修复 runtime fetch 缺口前，系统不能被定义为“已经支持真实多项目 dispatch”。
