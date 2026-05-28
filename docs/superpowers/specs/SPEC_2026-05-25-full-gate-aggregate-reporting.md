# 全量 Gate 聚合错误报告 SPEC

> Status: draft
> Scope: single-change
> Source of truth: 本文件是本次全量 gate 聚合错误报告需求合同的 repo 内主归档
> Related plan: `docs/superpowers/plans/PLAN_2026-05-25-full-gate-aggregate-reporting.md`
> Related verification: 本次不单独新建 verification 文档；验证证据由 implementation plan 的验证顺序和最终 PR 记录承载。

**Goal:** 让本地和远端 full gate 在发现某个检查失败后继续执行剩余检查，并在最后一次性展示所有失败项，同时保持整体失败退出码。

**Architecture:** 本次工作把当前分散在 `Makefile` 和 `mix lint` alias 中的 fail-fast 串行检查收敛到一个仓库内聚合 runner。聚合 runner 负责逐项执行、记录每项退出码、打印汇总，并在存在任一失败时 fail closed。`make all` 与 `mix lint` 应复用同一套聚合语义，避免本地 closeout gate 与远端 full gate 行为分叉。

**Tech Stack:** GNU make, POSIX shell, Elixir Mix aliases, ExUnit, GitHub Actions `make-all` workflow.

---

## 1. 目标 / 需求快照

### 1.1 问题陈述

维护者在运行 full gate 时，当前只能看到第一个失败阶段。现有 `elixir/Makefile` 中的 `ci` 目标按顺序执行 `setup`、`build`、`fmt-check`、`lint`、`coverage` 和 `dialyzer`，GNU make 默认在任一步骤返回非零状态时停止。远端 GitHub Actions 的 `make-all` workflow 也只执行 `make all`，因此远端 required check 继承同样的 fail-fast 行为。

这个行为会让一次验证只能暴露最早失败点。例如 `fmt-check` 失败时，`lint`、coverage 和 dialyzer 不会继续运行；如果后面也有问题，执行人需要多轮修复和重跑才能看全。`mix lint` 内部也有同类问题：当前 alias 是 `specs.check` 后接 `credo --strict`，当 `specs.check` 失败时，`credo` 不会运行。

这件事值得做，是因为 full gate 的价值不是只报告第一个错误，而是在一次高成本验证中尽量暴露全部独立失败点。这样维护者可以一次性修复多个问题，减少 PR required check 红灯后的往返。

### 1.2 目标功能描述

当执行人运行 `make all` 时，系统应该依次尝试所有 full gate 检查项。某个检查项失败后，系统必须记录该失败项和退出码，然后继续执行后续检查项。全部检查项执行结束后，系统必须打印一个汇总，清楚列出哪些检查通过、哪些检查失败。只要存在任一失败项，`make all` 最终必须返回非零退出码。

当执行人运行 `mix lint` 或 `make lint` 时，系统也应该执行聚合 lint 行为。`specs.check` 失败后，`credo --strict` 仍然必须运行；最终汇总必须同时反映 `specs.check` 和 `credo --strict` 的结果。只要其中任一失败，lint 入口最终必须返回非零退出码。

当所有检查都通过时，`make all`、`make lint` 和 `mix lint` 必须返回 0，并保留每个底层工具自己的正常输出。聚合层只能增加清晰的阶段标题和最终汇总，不得隐藏底层工具输出。

### 1.3 成功后的业务结果

维护者在一次 full gate 或远端 required check 失败后，能够从同一段日志中看到所有已执行检查的结果，而不是先修一个错误、再重跑后才发现下一个错误。PR 仍然会在任一 gate 失败时红灯，但红灯日志能提供更完整的修复线索。

### 1.4 明确不做什么

- 不改变单个底层工具的判定规则，例如 `mix format --check-formatted`、`mix specs.check`、`mix credo --strict`、`mix test --cover` 和 `mix dialyzer --format short` 的成功或失败语义。
- 不改变 coverage threshold、dialyzer 配置、Credo 配置、ExUnit 并发策略或测试选择规则。
- 不把 `make all` 重新定义为开发阶段默认命令；`elixir/TESTING.md` 中 gate 路由分层继续有效。
- 不新增外部依赖，不引入非仓库标准工具。
- 不实现 GitHub Actions matrix 拆分；本次目标是单个 `make all` job 内的聚合报告。

### 1.5 固定约束

- 文件操作只能发生在本仓库内。
- 代码实现必须保持 `make all` 和 GitHub Actions required check 的整体失败语义：任一检查失败，最终 check 失败。
- 所有涉及测试的验证命令必须显式带 `SYMPHONY_TEST_MAX_CASES`，默认值使用 `4`。
- `Makefile` 和 GitHub workflow 只承载命令，不承担制度解释；制度说明应更新到 `elixir/TESTING.md`。
- 不能吞掉底层命令输出；执行人必须能看到原始错误上下文。
- 如果实现方案会改变 gate 路由制度、coverage policy 或 PR closeout 流程，必须回到本 SPEC 重新确认。

## 2. 关键场景合同

| 场景编号 | 前置条件 | 触发动作 | 系统必须做什么 | 系统不得做什么 | 失败时怎么表现 |
| --- | --- | --- | --- | --- | --- |
| S1 | `fmt-check` 失败，后续 lint、coverage 或 dialyzer 仍可启动 | 执行 `make all` | 记录 `fmt-check` 失败，继续执行后续 full gate 检查，最后汇总失败项并返回非零 | 不得在 `fmt-check` 失败后直接停止整个 full gate | 日志包含 `fmt-check` 失败和后续检查结果；最终退出码非零 |
| S2 | `specs.check` 失败，Credo 仍可启动 | 执行 `mix lint` 或 `make lint` | 执行 `specs.check` 后继续执行 `credo --strict`，最后汇总 lint 内部结果 | 不得因为 `specs.check` 失败而跳过 Credo | 日志包含 `specs.check` 失败和 Credo 结果；最终退出码非零 |
| S3 | full gate 中多个检查失败 | 执行 `make all` | 把每个失败检查及其退出码列入最终汇总 | 不得只报告第一个失败项 | 最终汇总列出全部失败项；最终退出码非零 |
| S4 | 所有检查通过 | 执行 `make all`、`make lint` 或 `mix lint` | 每个检查正常执行，最终汇总显示无失败，入口返回 0 | 不得误报失败，不得隐藏底层工具输出 | 无失败表现；最终退出码为 0 |
| S5 | 聚合 runner 收到未知模式或缺失必要参数 | 执行无效 runner 调用 | 直接 fail closed，打印可读错误并返回非零 | 不得默默跳过检查后返回成功 | 日志说明未知模式；最终退出码非零 |

## 3. 成功标准

| 编号 | 成功标准 | 通过判定 | 不通过判定 |
| --- | --- | --- | --- |
| AC1 | 聚合 runner 的 full mode 不再在第一个检查失败时停止 | 使用可控 fake `mix` 直接执行 runner full mode；早期检查失败时，后续 full gate 检查仍出现在执行日志中 | 早期检查失败后，后续检查没有执行 |
| AC2 | `make all` 接入聚合 runner 的 full mode | 使用可控 fake `mix` 执行 `make all`；早期检查失败时，后续 full gate 检查仍出现在执行日志中，且最终退出码非零 | `make all` 仍 fail-fast，或有失败检查但最终退出码为 0 |
| AC3 | 聚合 runner 的 lint mode 不再在 `specs.check` 失败后停止 | 使用可控 fake `mix` 直接执行 runner lint mode；`specs.check` 失败时，`credo --strict` 仍出现在执行日志中 | `specs.check` 失败后 Credo 没有执行 |
| AC4 | `make lint` 接入聚合 runner 的 lint mode | 使用可控 fake `mix` 执行 `make lint`；`specs.check` 失败时，`credo --strict` 仍出现在执行日志中，且最终退出码非零 | `make lint` 仍 fail-fast，或有失败检查但最终退出码为 0 |
| AC5 | `mix lint` alias 接入聚合 runner 的 lint mode | 使用可控 fake `mix` 作为 runner 内部 `MIX` 命令执行真实 `mix lint` alias；`specs.check` 失败时，`credo --strict` 仍出现在执行日志中，且最终退出码非零 | `mix lint` 仍 fail-fast，或有失败检查但最终退出码为 0 |
| AC6 | 最终汇总能让执行人一次性看到失败项 | runner 直接测试和 public entrypoint 接入测试都能在日志中看到明确 summary 区域，并列出失败检查名称和退出码 | 日志只保留底层错误，没有最终失败汇总 |
| AC7 | 所有检查通过时不引入假失败 | fake 检查全部返回 0 时，runner full mode 和 runner lint mode 最终返回 0；public entrypoint 接入不改变全通过语义 | 所有检查返回 0，但入口返回非零 |
| AC8 | 文档与运行行为一致 | `elixir/TESTING.md` 说明 `make all` 和 lint 聚合行为，且不改变 gate 路由分层 | 文档仍描述或暗示 full gate fail-fast，或把 `make all` 写成默认开发命令 |

## 4. 非目标

- 不做：把 full gate 拆成多个 GitHub Actions jobs 或 matrix。
- 不做：修改 required check 名称、branch protection、auto-merge 规则或 PR closeout 顺序。
- 不做：新增 coverage policy、diff coverage 或新的质量门禁。
- 不做：改变 `mix test` 内部失败收集行为；本次问题不在 ExUnit 单个 suite 的失败上限。
- 不做：在 `make all` 失败后自动重跑失败项。

## 5. 风险边界

| 风险编号 | 风险描述 | 触发条件 | 影响 | 当前防法 |
| --- | --- | --- | --- | --- |
| R1 | 聚合层吞掉失败退出码，导致 required check 假绿 | runner 记录失败但最终返回 0 | PR 可能在 gate 失败时被错误放行 | 明确要求任一失败最终非零，并用 fake failure 测试验证 |
| R2 | 早期环境失败引发后续级联失败，日志噪音增加 | `setup` 或依赖安装失败后继续跑后续命令 | 执行人可能看到多个由同一根因引发的失败 | summary 保留每项退出码，最早失败项仍清晰可见 |
| R3 | `mix lint` 与 `make lint` 行为分叉 | 只改 Makefile，不改 Mix alias | 本地 closeout gate 与 full gate 观察结果不一致 | SPEC 要求 lint 内部也聚合，并通过测试覆盖两个入口 |
| R4 | 聚合输出遮挡底层工具原始错误 | runner 捕获输出但不转发 | 执行人无法定位具体错误 | runner 必须直接运行底层命令，保留 stdout/stderr |
| R5 | 实现扩大为测试制度重写 | 借本次改动修改 gate 路由或 coverage/dialyzer 策略 | 改动风险扩大，review 难以收口 | 非目标和固定约束明确禁止改变 gate 路由制度 |

## 6. 失败语义与回退语义

| 情况 | 系统表现 | 是否允许继续 | 下一步回到哪里 |
| --- | --- | --- | --- |
| 某个底层检查返回非零 | 记录失败项和退出码，继续执行后续检查 | 允许继续执行后续检查；最终不允许返回成功 | 实现阶段继续；最终 summary 和退出码必须验证 |
| runner 收到未知模式 | 打印未知模式错误并返回非零 | 不允许继续执行检查 | 回到实现修正 runner 调用或 Makefile/Mix alias |
| fake 测试发现失败被吞掉 | 测试失败 | 不允许继续推进 | 回到实现修正退出码聚合 |
| 实现需要改变 coverage threshold、dialyzer 配置或 gate 路由 | 暂停实现 | 不允许在本 SPEC 下继续 | 回到需求讨论并更新 SPEC |
| full gate 因资源压力不可稳定跑完 | 停止 heavy run，清理现场并报告资源状态 | 不允许继续盲目重跑 | 回到 `elixir/TESTING.md` 的资源压力规则 |

## 7. 验收与证据映射

| 成功标准 | 需要什么验证 | 证据形式 | 缺失时是否阻断 |
| --- | --- | --- | --- |
| AC1 | fake `mix` 驱动的 runner full mode 直接测试 | ExUnit 输出显示早期失败后后续命令仍执行 | 是 |
| AC2 | fake `mix` 驱动的 `make all` 接入测试 | ExUnit 输出显示 `make all` 早期失败后后续命令仍执行，且最终退出码非零 | 是 |
| AC3 | fake `mix` 驱动的 runner lint mode 直接测试 | ExUnit 输出显示 `specs.check` 失败后 Credo 仍执行 | 是 |
| AC4 | fake `mix` 驱动的 `make lint` 接入测试 | ExUnit 输出显示 `make lint` 在 `specs.check` 失败后仍执行 Credo，且最终退出码非零 | 是 |
| AC5 | fake `mix` 驱动的真实 `mix lint` alias 接入测试 | ExUnit 输出显示 `mix lint` 在 `specs.check` 失败后仍执行 Credo，且最终退出码非零 | 是 |
| AC6 | runner summary 输出测试和 public entrypoint 接入测试 | 测试断言 summary 中包含失败检查名称和退出码 | 是 |
| AC7 | fake all-pass runner 测试和至少一个真实 lint smoke | 测试断言全通过时退出码为 0；真实 `mix lint` 输出 summary 并通过 | 是 |
| AC8 | 文档 diff 审查 | `elixir/TESTING.md` 更新与实现行为一致 | 是 |

## 8. 未决问题与阻断项

| 编号 | 问题 | 为什么会阻断 | 由谁裁决 |
| --- | --- | --- | --- |
| B1 | 无未决阻断项 | 本 SPEC 已固定范围：顶层 full gate、`make lint` 和 `mix lint` 内部都必须聚合失败结果 | 不需要裁决 |

## 9. reviewer 快速检查清单

- [ ] `目标 / 需求快照` 使用了自然语言详细、准确、正面描述功能，而不是术语堆砌或方案代替需求
- [ ] 每个关键场景都写了系统必须行为和不得行为
- [ ] 每条成功标准都能二元判定
- [ ] 已明确写出非目标，避免实现阶段自行扩张
- [ ] 已明确写出风险边界、失败语义和回退点
- [ ] 每条成功标准都能映射到至少一种验证证据
- [ ] 所有未决问题都已显式列出，没有藏在正文里
