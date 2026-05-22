# Testing and Validation

本文件是测试与校验规则的权威来源。

- `WORKFLOW.md` 和 `AGENTS.md` 只保留运行期必须看到的最短入口，不再各自展开完整测试制度。
- `.github/workflows/*.yml` 和 `Makefile` 只承载命令，不解释制度。
- 修改测试规则时，默认只改本文件；只有运行期必须看到的测试行为发生变化时，才同步修改 `WORKFLOW.md` 或 `AGENTS.md` 的短入口。

## 本地默认

先检查 `git diff`，然后选择能证明本次改动正确性的最轻量校验。

- 开发阶段默认只使用 targeted tests。
- `make all` 不是默认开发命令，也不是复现工具。
- 纯文档、只读调查或 Linear triage/cleanup：开发阶段不要求跑测试；但在 PR create/update push 前，仍要执行选中的 `Next Push Gate`。
- 局部代码改动：运行能直接覆盖被修改行为的 targeted tests。
- 新增或修改测试时，先主动收口噪音：优先复用公共 helper，等待、轮询和 cleanup 不要散写在单个测试正文里。

## Gate 路由级别

每次 push 前，先把这次改动路由到下面 3 级之一。先分级，再决定命令；不要先看到 `elixir/` 就直接上最高级 gate。

- `light validation`
  - 只读调查、纯文档、Linear triage/cleanup，或其他不改变代码行为的轻量改动。
  - 这一级不默认引入 `make all`。
- `closeout gate`
  - 默认代码路径。
  - 普通代码改动、局部测试改动、普通 repo 文档改动，默认都先走这一级。
  - 仅因为文件位于 `elixir/` 目录，或仅因为改到了 `AGENTS.md`、`SPEC.md`、`TESTING.md`、`CHANGE_FLOW.md`，都不足以直接升到 `local make all`。
- `规则文档`
  - 只改 `TESTING.md`、`CHANGE_FLOW.md`、说明文档或其他纯制度文档时，默认仍按 `light validation` 处理。
  - 只有当文档改动会直接改变运行时可见行为，或会改变 `workflow/config contract`，才允许升级。
- `local make all`
  - 只在这次改动已经越过局部 proof 边界时使用。
  - 只有命中下面任一封闭触发器时，才允许进入这一级：
    - build / dependency / gate plumbing：`.github/workflows/*.yml`、`elixir/Makefile`、`elixir/mix.exs`、`elixir/mix.lock`、`elixir/mise.toml`
    - 共享 gate/task 入口：`elixir/lib/mix/tasks/**`
    - 共享 workflow/config loading 或 runtime bootstrap 入口：例如 workflow/config loading、runtime entrypoint、shared control-plane bootstrap
  - 命中这些入口后，也只有在仓库内不存在一组足以覆盖该影响面的 targeted proof / targeted tests 时，才真正升级到 `local make all`。
  - 仅因改到了共享模块、共享 endpoint、`elixir/test/support/**`、coverage/specs 相关 helper，不自动进入 `local make all`；如果局部 proof 能圈住影响面，仍留在 `closeout gate`。

如果你在 `closeout gate` 和 `local make all` 之间拿不准，默认先留在 `closeout gate`；只有当你能明确说出“为什么局部 proof 圈不住这次影响面”时，才升级到 `local make all`。

## Next Push Gate

每次 push 前，先按下面顺序分类：

- 先看这次 push 之后 branch / PR head 相对 PR base 的累计 diff。没有 PR 的 branch 默认以 `origin/main` 为 base。
- 普通开发分支只要将用于创建/更新 PR，就仍然按 PR-bound 处理；不能只根据最新本地 patch 来判断一次已打开 PR 的更新或一次计划中的 PR 创建。
- 先按上面的 `Gate 路由级别` 判断这次改动属于 `light validation`、`closeout gate` 还是 `local make all`。
- 如果这次 push 将创建 PR 或更新已打开 PR，就必须执行当前命中的那一级 gate。
- 如果这不是一次 PR create/update push，就运行与改动范围匹配的最轻量校验。
- 如果更早之前某次 branch push 按非 PR push 处理，但相同的 head 现在将用于创建 PR，那么必须重跑当前适用的 gate，并且在通过前不要创建 PR。

对应动作如下：

- `light validation`：运行与改动范围匹配的最轻量 proof；必要时补 1 条最相关的 targeted test
- `closeout gate`：先跑针对改动面的 targeted proof / targeted tests，再补 `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`、`cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`
- `local make all`：先完成这次改动的 targeted proof / targeted tests，再完成 `closeout gate` 所需的 `fmt/lint` 和当前 diff 所需 review，最后再把 `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all` 作为高等级确认

高等级 gate 永远排在后面；不要一上来就先跑 `make all`。

## 失败后的回退顺序

- 任何一级失败后，都先回到这次修复真正命中的最小正确层级；不要失败在高等级 gate，就直接循环重跑高等级 gate。
- 任何修复一旦产生新的累计 diff，都先按新的累计 diff 重新执行一次 `Gate 路由级别` 判断，再决定下一步。
- 如果 targeted proof / targeted tests 失败：修复后先重跑同一类 proof / tests；不要跳级。
- 如果 review 指出问题：修复后先回到与这次改动相称的 proof / targeted tests，再重过当前 diff 所需 review；不要跳过 review 直接上更高 gate。
- 如果 `closeout gate` 里的 `fmt` / `lint` 失败：修复后先重跑对应项；若修复引入代码行为变化，再补针对该变化的最小 proof 和所需 review。
- 如果 `local make all` 失败：把它视为“发现了新的问题”，不是“要求你立刻再跑一次 make all”。
  - 先定位失败点。
  - 用最小 proof / targeted tests 证明修复。
  - 如果修复改变了 reviewed object、validation input、shared support、gate plumbing，或改变了代码/行为，再重过当前 diff 所需 review。
  - 只有这些都通过后，才回到最后一步重新跑 `make all`。
- 如果远端 CI / full gate 失败：本地也按同样顺序处理。先读 CI error，再做最小修复和最小 proof，再重过所需 review，最后才重跑对应高等级 gate。

`make all` 不是通用的 pre-push 命令，也不是失败后的第一反应。它只用于当前路由确实命中 `local make all` 时的最后确认。

## 远端 Gate

- 当 PR 命中本地已判断为 `local make all` 的那类改动时，GitHub Actions 仍然是权威的远端完整 gate。
- 远端 full gate 应扮演最终 reviewer，而不是第一处用来发现 coverage 或 dialyzer 问题的常规场所。
- 如果第一次远端 full gate 仍然暴露这些问题，应视为本地 gate 未执行、执行不合规，或存在需要升级处理的环境漂移。

## 并发与资源压力

- 本地 ExUnit 并发必须始终显式限制。所有测试命令都必须带 `SYMPHONY_TEST_MAX_CASES`。
- 默认使用 `SYMPHONY_TEST_MAX_CASES=4`；如果机器出现压力，就降到 `2`；如果仍不稳定，就降到 `1`。
- 对 heavy tests 和 `make all`，必须监控 memory 增长、swap 增长、无法恢复的 CPU 饱和、异常的 subprocess/port/worker 增长，以及系统卡顿或失去响应的迹象。
- 如果监控显示资源压力，立即停止当前 heavy test，清理现场，把并发从 `4` 降到 `2`，必要时再降到 `1`；如果 `1` 仍然不稳定，就停止并提交报告。

## 测试隔离与 Cleanup

- 不要让测试启动流程自动拉起轮询型 runtime workers 或外部 process chains。
- 凡是会碰到 `Port.open`、`ssh`、`codex app-server`、Docker 或 fake workers 的测试，都必须显式启动，并通过 `on_exit` 或等价方式显式清理。
- 在测试里，不要把仓库根下的 `WORKFLOW.md` 当成默认 runtime config。
- 每次测试运行后，都要清理残留的 workers、fake workers、后台 servers、开放 ports、临时文件/目录/logs，以及测试注入的环境或配置覆盖。

## 时间断言

- 不要用单点时间断言证明正确性。
- 优先用区间断言。
- 优先用 polling 或 `assert_eventually`。
- 不要用一次性 `Process.sleep(...)` 后立刻断言异步状态稳定。
- timeout 统一收进公共 helper，不要把毫秒常量散写在测试正文。
- 除非测试目标本身就是极短超时语义，否则不要使用过紧毫秒窗口。

## fake 的使用边界

- fake 只用于快反馈、边界条件、难复现异常、小范围状态机验证，以及隔离外部依赖边界。
- fake 不作为主正确性证明层。
- 能走真实本地 runtime / control-plane / API / generation 链路的地方，不要用 fake 替代。
- 当测试必须隔离真实 Linear、真实 Codex 远端、真实浏览器或其他外部依赖时，允许使用 contract-shaped fake 或 stub。
- 使用 fake 时，优先验证：输入合同、输出合同、状态收敛和错误路径；不要把 fake 测试写成与真实系统无关的自嗨逻辑。

## 浏览器层

- UI 点击、页面交互、视觉验收不放进真实业务闭环层。
- 浏览器测试如需引入，独立成层。
- 浏览器层不作为第一版本地默认前置。
- 默认先证明 runtime、control-plane、API、生成链和状态收敛正确，再决定是否补浏览器层。

## 真实业务闭环层

- 仓库必须保留一层本地可跑的真实业务闭环测试。
- 这层优先验证真实业务路径，不优先堆 fake。
- 这层默认不依赖真实 Linear。
- 这层默认不依赖真实 Codex 远端。
- 这层默认不依赖真实浏览器。
- 这层内部尽量走真实 orchestration、真实 runtime、真实 control-plane、真实 API 和真实生成链。
- 只有在外部依赖边界无法直接本地运行时，才允许用 contract-shaped fake/stub 补边界。

## 第一版覆盖范围

第一版真实业务闭环层，至少覆盖以下内容：

- 多项目静态配置解析与归一化。
- `WORKFLOW.generated.md` 的项目级生成链。
- 多项目 runtime / control-plane 状态收敛。
- 控制面关键 API：`/api/v1/state`、`/api/v1/refresh`、`/api/v1/health`、项目控制、run timeline。
- issue refresh / diff / context summary 的最小结构化闭环。

执行要求：

- 第一版先服务当前多项目主线，不围绕单项目外扩。
- 第一版先保住最小可用闭环，不顺手扩成浏览器验收平台。
- 第一版先保住真实链路正确性，再谈更细的 fake、视觉层和外部 E2E。

## 常用命令

```bash
# 本地定向校验：
cd elixir
SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/some_targeted_test.exs

# closeout gate 示例：
cd elixir
SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted
SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint

# 仅用于最终确认：
cd elixir
SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all
```
