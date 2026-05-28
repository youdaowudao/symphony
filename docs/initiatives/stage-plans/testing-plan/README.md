# 测试规划

日期：`2026-05-25`
状态：`讨论解释版`
讨论级别：`Level 2`
主题：日常开发、`make all`、无浏览器闭环、Playwright、真实外部 E2E 和验证工作区

后续拆分提醒：讨论文档留在 `docs/initiatives/stage-plans/`，正式规则进 `elixir/TESTING.md`，素材表给 AI / coder / reviewer 用，不进根目录 `SPEC.md`。

## 一句话结论

当前本地和远端的 `make all` 只跑普通 gate 和普通 ExUnit 测试集合；它不跑 Playwright，也不跑 `make e2e`。平时开发仍然在开发 workspace 里跑最小 targeted tests；只有改到浏览器行为才补浏览器层，只有改到真实 Linear / Codex / SSH / Docker 边界才单独跑真实外部 E2E。

## 先回答最容易混淆的事

### 本地 `make all` 跑什么

当前本地 `make all` 实际等于进入 `elixir/scripts/run_checks.sh all`，顺序是：

1. `setup`
2. `build`
3. `format --check-formatted`
4. `specs.check`
5. `credo --strict`
6. `test --cover`
7. `deps.get`
8. `dialyzer --format short`

所以，本地 `make all` 会跑普通 ExUnit 测试集合，也就是 `mix test --cover` 会覆盖到的测试。

### 本地 `make all` 不跑什么

当前本地 `make all` 不跑这些：

1. 不跑 `make e2e`。
2. 不强制设置 `SYMPHONY_RUN_LIVE_E2E=1`。
3. 不跑 Playwright，因为仓库当前没有 Playwright 工程。
4. 不跑真实浏览器。
5. 不跑真实 Linear / Codex / SSH / Docker 专项链路。

### 远端跑什么

当前远端 `.github/workflows/make-all.yml` 只是在 `elixir/` 目录下执行：

```bash
make all
```

所以远端和本地一样：不跑 Playwright，不跑 `make e2e`，不跑真实外部 E2E。

## 四层测试和 make all 的关系

| 层级 | 这层证明什么 | 现在有没有 | 是否进入本地 `make all` | 是否进入远端 `make all` | 谁来跑 | 是否需要人类参与 |
| --- | --- | --- | --- | --- | --- | --- |
| 第一层：targeted tests | 本次改动直接影响的行为 | 有 | 不固定；如果这些测试属于普通 ExUnit，`make all` 的 `test --cover` 会跑到 | 同本地 | 开发者或 AI coder 选择并执行 | 通常不需要 |
| 第二层：无浏览器真实业务闭环 | 本地真实链路是否通，但不碰真实外部服务和浏览器 | 部分已有，后续应继续补 | 已写成普通 ExUnit 且未 skip 的部分会进 `make all` | 同本地 | 开发者或 AI coder 执行命令 | 通常不需要；边界拿不准时问人 |
| 第三层：Playwright 浏览器层 | 真实浏览器里的点击、加载、可见性、前端连接 | 当前没有工程 | 不进 | 不进 | 未来由开发者或 AI coder 跑 | 视觉、交互、截图是否可接受，需要人类判断 |
| 第四层：真实外部 E2E | 真实 Linear / Codex / SSH / Docker 链路 | 有 `live_e2e_test.exs`，默认 skip | 不进 | 不进 | 开发者、AI coder 或验证卡片执行者显式跑 | 需要人类确认成本、凭据、外部副作用或失败分类 |

这张表是核心：第二层的一部分可以进入 `make all`，第三层和第四层当前都不进入 `make all`。

## 平时开发到底在哪里跑

### 没有新增长期测试工作区

平时测试发生在当前开发 workspace。也就是说，开发者或 AI coder 在当前开发分支上改代码，然后在同一个 workspace 里跑本次改动需要的 targeted tests。

### 什么叫验证工作区

验证工作区不是新系统，不是新配置，不是新数据库字段，不是长期目录，也不是第二套仓库。

它只是某次验证需要隔离时，临时 checkout 指定 branch/head 的执行位置。它用于“证明这个 head 是否通过某个验证”，不用于长期写代码。

如果验证失败，修复回开发分支做；修完后再用新的 head 重跑验证。

## 谁来跑：电脑、AI、人类分别做什么

电脑只执行命令。

AI coder 或开发者负责选择并执行测试命令，比如选择某个 ExUnit 文件、未来的 Playwright smoke、或显式 `make e2e`。

人类不需要参与每次普通测试。人类主要参与三类情况：

1. 是否允许跑高成本真实外部 E2E，因为它可能耗 token、写真实 Linear、启动 Docker/SSH。
2. 浏览器视觉和交互是否符合预期，因为命令只能证明断言，不能替你判断体验是否可接受。
3. 边界拿不准时，例如“这个编排器改动是否已经触碰真实 Codex 协议边界”。

## 第三层和第四层谁来触发

第三层和第四层不是只能由人类手工说。它们可以由四种方式触发：

1. AI coder 根据 diff 主动建议触发。
2. 人类直接要求触发。
3. reviewer 或 PR gate 要求补触发。
4. 测试卡片提前写好，执行者按卡片触发。

区别是：第三层通常可以在开发中由 AI 直接补跑；第四层因为成本和外部副作用更高，通常要人类确认或卡片明确授权。

### 第三层：浏览器层怎么触发

第三层触发条件是“这次改动需要真实浏览器才能证明”。

当前第三层先调用本机已经安装好的 Playwright / 浏览器能力，不在仓库里重新安装 Playwright，不因为本机是否安装就改仓库依赖，也不现在新增 `package.json`、lockfile 或 Playwright 工程配置。

后续如果决定把第三层升级成仓库正式自动化，再单独讨论是否需要提交配置、测试目录、命令入口和依赖说明。那个动作是“正式接入 Playwright 工程”，不是当前这一步。

### 第三层本机 Playwright 已验证信息

当前机器已经有一个独立 Playwright 工具目录：

```text
/home/ss/software/playwright
```

当前事实：

1. Playwright 版本：`1.60.0`。
2. runner 入口：`/home/ss/software/playwright/node_modules/.bin/playwright`。
3. 配置文件：`/home/ss/software/playwright/playwright.config.ts`。
4. 默认 base URL：`http://127.0.0.1:4100`。
5. 当前仓库路径 `/home/ss/projects/symphony` 解析到 `/home/ss/data/projects/symphony`，与现有脚本中的 elixir 路径一致。

无头模式已验证：

1. 调用方式：本机 Playwright `chromium.launch({ channel: "chrome", headless: true })`。
2. 验证页面：`about:blank`。
3. 结果：Chrome headless 能正常启动，等待后能正常关闭。
4. 没有执行安装、下载、仓库测试或本地服务启动。

有头模式已验证：

1. 调用方式：本机 Playwright `chromium.launch({ channel: "chrome", headless: false })`。
2. 环境：`DISPLAY=:0`，`WAYLAND_DISPLAY=wayland-0`。
3. 验证页面：`about:blank`。
4. 结果：Chrome headed 能正常启动，等待后能正常关闭。
5. 没有执行安装、下载、仓库测试或本地服务启动。

本机业务页面验证也已完成：

1. 本机 Symphony 以 `--port 4100 ./WORKFLOW.md` 启动，`/api/v1/state` 能正常返回。
2. API 返回的关键状态正常：`counts` 中 `running`、`blocked`、`retrying` 都为 `0`，对应列表为空，`codex_totals` 为 `0`。
3. 无头模式打开 `http://127.0.0.1:4100/`，能看到 `Operations Dashboard`，页面正文包含 `Running`、`Blocked`、`Retrying` 信息，浏览器正常关闭。
4. 有头模式打开同一页面，也能看到 `Operations Dashboard` 和同样的状态信息；窗口保留一段时间后正常关闭。
5. 验证结束后已关闭本次 Symphony 服务，`4100` 端口已释放。
6. 本次验证没有安装或下载 Playwright / 浏览器，也没有把 Playwright 配置写入仓库。

### 第三层启动顺序

AI / coder 以后照着这个顺序启动，不要自己补出另一套流程：

1. 先取当前工作区的仓库根目录，再进入 `elixir/`。不要把旧 workspace 的绝对路径当成默认值。
2. 启动本机 Symphony：

```bash
cd <当前仓库>/elixir
mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4100 ./WORKFLOW.md
```

3. 等 `/api/v1/state` 可访问后，再做浏览器验证。
4. 只调用本机已有 Playwright 工具目录 `/home/ss/software/playwright`，不要在仓库里重新安装 Playwright。
5. 无头验证时用 `chromium.launch({ channel: "chrome", headless: true })`，打开 `http://127.0.0.1:4100/`，检查 `Operations Dashboard` 和 `/api/v1/state`。
6. 有头验证时把 `headless` 改成 `false`，同样打开 `http://127.0.0.1:4100/`，检查同样的信息。
7. 验证完先关浏览器，再停 Symphony，最后确认 `4100` 端口释放。

无头和有头怎么选，由 AI / coder 根据本次验证目标自行判断：能用无头证明的优先用无头；需要观察真实窗口、交互体验或人工视觉判断时再用有头。人类不需要为每次第三层提前指定模式。

常见触发条件：

1. 改了按钮、表单、导航、点击流程。
2. 改了 LiveView 前端连接、页面自动刷新、浏览器端事件。
3. 改了 CSS、布局、响应式、可见性。
4. 改了 JS、asset、前端加载方式。
5. reviewer 或人类要求提供真实浏览器证据。

谁发起：

1. AI coder 可以在开发时主动说：“这个改动涉及浏览器行为，建议跑第三层。”
2. 人类可以直接说：“跑一下第三层浏览器验证。”
3. reviewer 可以要求：“这个 UI 改动需要第三层证据。”

谁执行：

1. 当前仓库没有 Playwright 工程时，AI coder 或开发者只能调用本机已有 Playwright 工具做临时浏览器验证，或用现有 LiveViewTest / snapshot / 手工页面检查替代一部分。
2. 这类临时验证可以在当前开发 workspace 执行，但不写入 `make all`，不写入远端 gate，也不要求每个 workspace 都自带 Playwright 安装。
3. 如果需要人工视觉判断，AI coder 只能提供截图、报告或页面结果，人类判断是否接受。

是否需要写卡片：

1. 小 UI 改动不需要单独写卡片，可以开发中直接让 AI 跑。
2. 大 UI 改动、跨多个页面、需要多人复核或需要保留证据时，建议写测试卡片。
3. 视觉验收需要人类判断时，卡片要写清楚看什么，不要只写“跑第三层”。

一句话：第三层可以在开发中临时触发，不一定要写卡片；只有需要保留独立验证证据或人工验收时才写卡片。

### 第四层：真实外部副作用怎么触发

第四层只管一件事：**真实外部系统的副作用验证**。它不是“更重一点的测试”，也不是“只要流程变了就往上抬”。

下面这些通常**不算第四层**，不要自动升级：

1. `workflow.md` 文本、prompt、配置值的小改动。
2. state 枚举、内部流转规则、polling、retry、blocked、调度逻辑。
3. orchestrator、runtime、control-plane、API、dashboard、LiveView 这类本地可验证逻辑。
4. UI 视觉、布局、浏览器交互。这是第三层，不是第四层。
5. 能被第一层、第二层、第三层证明的改动。

下面这些**才考虑第四层**：

1. 真实 Linear 写入、关闭、评论、状态推进。
2. 真实 Codex app-server 的 turn、tool call、approval、timeout、stall。
3. 真实 SSH worker、Docker worker、远端 workspace 的创建、运行、清理。
4. 任何会影响真实外部资源生命周期的 cleanup。
5. 明确授权的周期性 live smoke。它单独维护，不是每个 diff 的默认步骤。

谁发起：

1. AI coder 只能根据 diff 建议第四层，不能把普通 workflow / 状态机 / UI 改动自行判成第四层。
2. 人类必须给出明确授权，最好在当前对话或测试卡片里写清楚。
3. reviewer 可以要求补第四层证据，但仍然要落到明确授权和具体 head。
4. 周期性 live smoke 也要明确授权或卡片，不是自动任务。

谁执行：

1. AI coder 可以执行，但前提是已经拿到明确授权和清楚的 head、输入、cleanup 要求。
2. 人类可以亲自执行，也可以授权 AI coder 执行。
3. 没有明确授权时，AI 只能停在建议和说明成本，不要擅自跑。

是否需要写卡片：

1. 建议写卡片。第四层成本高、失败原因复杂、需要记录 head、原因、cleanup 和结果。
2. 如果人类在当前对话里明确授权，也可以不新建卡片，直接在当前开发任务里跑；但执行结果仍要记录。
3. 周期性 live smoke 建议单独写卡片或单独计划，不要混进普通 diff 的第四层判断里。

一句话：第四层是“真实外部副作用 + 明确授权”，不是“流程看起来变了就自动升级”；周期性真实检查单独维护，不跟普通改动混在一起。

### 第四层讨论顺序

第四层不是“更重一点的测试”，而是“真实外部边界的授权执行”。讨论时先按这个顺序说清楚：

1. 这次到底碰到了哪一个真实外部边界：`Linear`、`Codex app-server`、`SSH worker`、`Docker worker`，还是远端 workspace cleanup。
2. 要验证的精确 head 是什么，输入是什么，环境变量和凭据是什么。
3. 这次是否允许产生外部副作用，例如写真实 Linear、消耗 token、创建/关闭远端资源。
4. 谁授权，谁执行，谁负责回收。
5. 失败怎么分：产品问题、测试问题、环境问题、外部服务问题，还是 cleanup 问题。

如果上面任一项说不清，就先别跑第四层。先把问题收束成一张测试卡片，或者先回到第三层 / 第二层。

### 你实际怎么说

如果你已经知道要跑哪层，可以直接说：

```text
这个 UI 改动跑第三层浏览器验证，记录截图和失败原因。
```

或者：

```text
这个改动碰到真实 Codex/Linear 边界，创建一张第四层验证卡片，按当前 head 跑真实外部 E2E。
```

如果你不知道该跑哪层，可以说：

```text
你先判断这次改动命中哪些测试层级，说明哪些必须跑、哪些不跑、是否需要人类确认。
```

AI coder 应该先给判断，再执行。尤其第四层，AI coder 应先说明成本和外部副作用，再等授权或确认卡片已经写清楚。

## 场景决策：我改了这个，到底跑什么

### 纯文档或规划文字

跑什么：文档自查、链接和落点检查。

不跑什么：不跑 Playwright，不跑真实外部 E2E，不默认跑 `make all`。

人类参与：如果需求边界没有讲清楚，需要人类确认。

### 小的后端函数、状态机、解析逻辑

跑什么：对应模块的 targeted ExUnit。

视情况补什么：如果影响本地闭环，再补第二层无浏览器闭环的 targeted subset。

不跑什么：不跑 Playwright，不跑真实外部 E2E。

人类参与：通常不需要。

### UI / dashboard / LiveView 展示改动

当前跑什么：相关 LiveViewTest、Presenter/API 测试、snapshot 测试。

未来有 Playwright 后补什么：Playwright browser smoke 或对应 browser targeted test。

不跑什么：不跑真实外部 E2E，除非这个 UI 改动同时改变了真实外部链路。

人类参与：如果是视觉、布局、交互体验，需要人类看或确认截图。

结论：UI 小改动通常是第一层；如果涉及真实浏览器行为，才加第三层。它不是第四层。

### 编排器调度、runtime、control-plane、API 状态收敛

跑什么：orchestrator、runtime、control-plane、API 对应 targeted ExUnit。

视情况补什么：第二层无浏览器闭环 targeted subset，因为这类改动可能影响本地真实链路。

不跑什么：默认不跑 Playwright；默认不跑真实外部 E2E。

什么时候触发第四层：只有当改动碰到真实 Codex app-server 协议、真实 Linear 写入、SSH/Docker worker、远端 workspace 或 cleanup 外部边界时，才考虑真实外部 E2E。

人类参与：如果只是内部调度逻辑，通常不需要；如果是否触发第四层拿不准，需要人类确认。

结论：编排器改动通常是第一层加第二层，不自动变成第四层。

### workflow、状态枚举、流转规则

跑什么：workflow/config targeted tests、必要时补第二层无浏览器闭环 targeted subset。

视情况补什么：如果这次修改影响本地真实闭环，再补第二层。

不跑什么：不默认跑 Playwright；不默认跑真实外部 E2E；**不会因为 `workflow.md` 或状态流转规则变化就自动升级到第四层**。

人类参与：通常不需要，除非这次改动真的碰到了真实 Linear / Codex / SSH / Docker 边界。

结论：这类改动是内部规则变化，不是第四层。

### Codex app-server 真实协议、真实命令、turn 超时

跑什么：相关 targeted ExUnit 或集成测试。

补什么：真实外部 E2E 验证卡片，显式跑 `make e2e` 或等价命令。

不跑什么：不跑 Playwright，除非同时改 UI。

人类参与：需要。因为可能耗 token，可能依赖真实 Codex 行为。

### Linear mutation、真实 issue/project 状态推进、评论写入

跑什么：adapter / contract targeted tests。

补什么：真实外部 E2E 验证卡片。

人类参与：需要。因为会写真实 Linear 或依赖真实 Linear 状态。

### SSH worker、Docker worker、远端 workspace、cleanup

跑什么：worker / workspace / cleanup targeted tests。

补什么：真实外部 E2E 验证卡片，尤其是 SSH 路径。

人类参与：需要。因为会启动外部进程、Docker、SSH，必须关注 cleanup。

### build / gate plumbing，例如 `Makefile`、workflow、mix deps

跑什么：对应脚本或入口 targeted tests。

视情况补什么：当前 gate 可能升级到 `make all`。

不跑什么：不默认跑 Playwright 或真实外部 E2E，除非改到了它们的入口。

人类参与：通常需要 reviewer 关注，因为会影响所有人的验证入口。

## 第一层开发测试检查

### 当前已经清楚的部分

第一层的基本规则已经清楚：开发阶段先看 diff，然后跑能证明本次改动的 targeted tests；所有 ExUnit 测试命令都必须显式带 `SYMPHONY_TEST_MAX_CASES`。

当前可用入口也清楚：

1. 单个测试文件：`SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/some_test.exs`
2. 多个相关测试文件：`SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/a_test.exs test/b_test.exs`
3. closeout gate 里的格式检查：`SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`
4. closeout gate 里的 lint：`SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`
5. 高等级确认：`SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all`

当前代码已有公共测试支撑：

1. `elixir/test/support/test_support.exs`：统一写临时 workflow、清理 env、停止默认 HTTP server。
2. `elixir/test/support/snapshot_support.exs`：统一 dashboard snapshot 断言和更新入口。
3. `elixir/test/scripts/run_checks_test.exs`：覆盖 `make all` / `make lint` 聚合 runner 行为。

### 第一层按改动选测试的速查表

| 改动位置或主题 | 优先 targeted tests |
| --- | --- |
| `StatusDashboard`、终端展示、snapshot 文案 | `test/symphony_elixir/status_dashboard_snapshot_test.exs`、相关 `orchestrator_status_test.exs` |
| `RuntimeStatus` 或运行状态分类 | `test/symphony_elixir/runtime_status_test.exs`、相关 `orchestrator_status_test.exs` |
| Dashboard LiveView、observability API、Presenter | `test/symphony_elixir/extensions_test.exs` |
| Orchestrator、runtime 状态、polling、retry、blocked | `test/symphony_elixir/orchestrator_status_test.exs`，必要时补 `core_test.exs` |
| config、workflow、workspace、Linear 查询结构 | `test/symphony_elixir/workspace_and_config_test.exs`、`test/symphony_elixir/core_test.exs` |
| Codex app-server 解析、事件、tool call | `test/symphony_elixir/app_server_test.exs`、`test/symphony_elixir/dynamic_tool_test.exs` |
| SSH 命令包装、远端执行辅助 | `test/symphony_elixir/ssh_test.exs` |
| CLI 行为 | `test/symphony_elixir/cli_test.exs` |
| log file | `test/symphony_elixir/log_file_test.exs` |
| Mix task | `test/mix/tasks/*_test.exs` |
| gate runner、Makefile 聚合入口 | `test/scripts/run_checks_test.exs` |

这张表不是强制矩阵，只是第一层选择 targeted tests 的起点。真实选择仍然以本次 diff 为准。

### 第一层后续维护项

第一层不需要新增测试工作区，也不需要改变 `make all`。

这里没有需要人类日常手工处理的事项。后续维护只给 AI / coder / reviewer 留两个入口：

1. “按改动选 targeted test”的速查表先留在本讨论文档。后续如果稳定，由 AI / coder 迁入 `elixir/TESTING.md` 或其链接的测试速查文档；人类不需要日常维护这张表。
2. 历史 `Process.sleep` 和局部等待写法不是当前阻塞，也不需要人类亲自处理。以后如果要收口，由 AI / coder 作为单独小任务处理：先用 `rg "Process\\.sleep|assert_eventually"` 找到目标，再判断哪些是异步等待噪音，最后改成公共 helper / polling / `assert_eventually`，并跑对应 targeted tests。

这两个事项都不是新的测试层级，也不是新的开发流程。

### 第一层检查结论

第一层主流程已经可用：开发 workspace、targeted ExUnit、显式 `SYMPHONY_TEST_MAX_CASES`、closeout gate 和 `make all` 的边界都清楚。

第一层当前已经收口：不新增系统，不新增测试工作区，不改变 `make all`。剩下的是以后 AI / coder 的维护小项，不影响现在继续讨论第二层、第三层和第四层。

## 第二层巡查结论

第二层的定义本身是对的：它是本地真实业务闭环，不是浏览器测试，也不是真实外部 E2E。

这次巡查后，第二层不需要现在新增测试工作区，不需要改 `make all`，不需要引入 Playwright，也不需要人类日常手工参与。需要补清楚的是：第二层当前不是一条固定命令，而是一组根据 diff 选择的本地闭环 targeted tests。

### 第二层现在是什么

第二层证明的是这些本地链路：

1. workflow / config 能加载、归一化、校验。
2. runtime / orchestrator 状态能收敛。
3. control-plane API 能返回正确结构。
4. 本地生成链能产出预期内容。
5. 本地 endpoint、LiveViewTest、pubsub 或 presenter 能证明服务端合同。

第二层默认不依赖真实 Linear，不依赖真实 Codex 远端，不依赖真实浏览器。外部依赖边界如果无法本地运行，可以用 contract-shaped fake / stub，但测试目标仍然要证明 fake 周围的真实本地链路。

### 什么时候触发第二层

AI / coder 在开发时根据 diff 触发第二层。常见触发条件是：

1. 改了 orchestrator、runtime、polling、retry、blocked、状态收敛。
2. 改了 workflow、config、生成链、`WORKFLOW.generated.md` 相关逻辑。
3. 改了 control-plane API、presenter、endpoint、pubsub。
4. 改了本地 workspace、dispatch、依赖阻塞、状态刷新逻辑。
5. 改动虽然不是外部 E2E，但单个纯函数测试已经不能证明本地链路正确。

不触发第二层的情况也要清楚：

1. 纯文档不触发。
2. 单个纯函数或小模块能被第一层 targeted test 证明时，不强行升级。
3. 按钮、布局、真实浏览器 JS 行为属于第三层。
4. 真实 Linear / Codex / SSH / Docker 副作用属于第四层。

一句话：第一层证明“改到的点对不对”，第二层证明“这个点放回本地业务链路后还通不通”。

### 第二层现有可用入口

这些不是强制矩阵，只是当前仓库里第二层常用的候选入口：

| 改动主题 | 优先考虑的本地闭环测试 |
| --- | --- |
| workflow store、配置加载、本地 prompt / workflow 文件 | `test/symphony_elixir/extensions_test.exs`、`test/symphony_elixir/core_test.exs` |
| orchestrator、runtime 状态、polling、retry、blocked | `test/symphony_elixir/orchestrator_status_test.exs`、必要时补 `core_test.exs` |
| control-plane API、presenter、HTTP endpoint | `test/symphony_elixir/extensions_test.exs` |
| observability pubsub / 页面服务端刷新合同 | `test/symphony_elixir/extensions_test.exs`、`test/symphony_elixir/observability_pubsub_test.exs` |
| workspace、dispatch、依赖阻塞、配置组合 | `test/symphony_elixir/workspace_and_config_test.exs`、`test/symphony_elixir/core_test.exs` |
| dashboard 服务端展示合同 | `test/symphony_elixir/extensions_test.exs`、`test/symphony_elixir/status_dashboard_snapshot_test.exs` |

如果这些测试是普通 ExUnit 且没有 skip，它们本来就会被 `make all` 里的 `test --cover` 跑到；但开发阶段仍然优先直接跑命中的 targeted subset。

### 第二层现在不做什么

第二层当前不新增专门命令，不新增长期测试工作区，不把 `make e2e` 当成第二层入口。

如果后续第二层候选测试越来越稳定，再考虑把入口收敛到 `elixir/TESTING.md` 的正式速查表；现在先不扩大制度。

## 第二层和第三层怎么分清楚

第二层不是“更像真实用户”。第二层是“本地真实业务链路”，但不打开真实浏览器，也不碰真实外部服务。

第三层不是“更完整业务链路”。第三层只回答浏览器问题：页面是否真能打开、点击是否有效、前端连接是否正常、内容是否真的可见、浏览器控制台是否报错。

判断方法：

| 问题 | 属于第二层 | 属于第三层 |
| --- | --- | --- |
| runtime 状态是否收敛 | 是 | 否 |
| control-plane API 是否返回正确 | 是 | 否 |
| 生成链是否按本地规则产出 | 是 | 否 |
| LiveView 服务端渲染合同是否对 | 可用 LiveViewTest 覆盖，偏第二层或第一层 | 不等于真实浏览器 |
| 按钮在真实浏览器里点了是否有效 | 否 | 是 |
| 页面在真实浏览器里是否有 JS 错误 | 否 | 是 |
| 布局、响应式、可见性是否对 | 否 | 是 |

一句话：第二层证明系统链路，第三层证明浏览器行为。

## 第四层怎么跑

第四层当前入口是 `live_e2e_test.exs`，默认 skip。要跑它，需要显式启用。

建议后续使用这种形式，确保符合测试制度里的并发要求：

```bash
cd elixir
SYMPHONY_TEST_MAX_CASES=4 SYMPHONY_RUN_LIVE_E2E=1 mise exec -- mix test test/symphony_elixir/live_e2e_test.exs
```

或者在修正 `make e2e` 入口显式传入并发上限后，用：

```bash
cd elixir
SYMPHONY_TEST_MAX_CASES=4 mise exec -- make e2e
```

第四层不是悄悄自动跑的测试。它应该有明确原因、明确 head、明确 cleanup、明确结果记录。

## 测试卡片怎么用

测试卡片不是测试制度真相源，也不是新的 canonical 配置。它只记录单次验证的执行输入和结果；长期测试规则仍以 `elixir/TESTING.md` 为准。

测试卡片至少写清楚：

| 字段 | 要写什么 | 为什么必须写 |
| --- | --- | --- |
| 测试目标 | 这次到底要证明什么 | 防止只写“跑一下 E2E” |
| repo 与 branch/head | 要验证哪个精确 head | 防止测了 main，却以为测了 PR |
| 测试层级 | 第一层、第二层、第三层或第四层 | 防止跑错成本级别 |
| 触发原因 | 为什么这次要补这个测试 | reviewer 才能判断有没有必要 |
| 成本边界 | 是否会耗 token、写 Linear、启动 Docker/SSH | 防止误跑高成本链路 |
| cleanup 要求 | 需要清理什么进程、端口、workspace 或外部状态 | 防止残留污染后续测试 |
| 结果记录 | 通过、失败、阻塞，以及失败分类 | 防止只留下“跑过了” |

## 测试失败后怎么办

测试失败先分类，不要直接重跑到绿。

| 失败类型 | 怎么处理 |
| --- | --- |
| 产品问题 | 回开发分支修，修完跑最小 proof，再按需要重跑验证 |
| 测试问题 | 修测试或 fixture，先证明测试自己稳定 |
| 环境问题 | 修浏览器依赖、Docker、SSH、端口、凭据或网络，不把它伪装成产品失败 |
| 外部服务问题 | 记录 Linear / Codex 等外部状态，必要时稍后重跑 |
| flaky 问题 | 收口等待、轮询、cleanup 或隔离条件；不能只靠重跑绿了放行 |

## 这次真正新增什么

新增的是理解和后续执行口径：

1. 明确 `make all` 不等于所有层级。
2. 明确第二层可能进入 `make all`，第三层和第四层当前不进入。
3. 明确平时测试发生在开发 workspace，验证工作区只是临时执行位置。
4. 明确 UI 改动、编排器改动、真实外部边界改动分别跑什么。
5. 明确人类只在高成本、真实外部副作用、视觉体验和边界不清时参与。

没有新增这些东西：

1. 没有新增第二套测试平台。
2. 没有新增每项目一套固定测试 workspace。
3. 没有要求 Playwright 进入所有 PR 默认 gate。
4. 没有要求 live external e2e 进入 `make all`。
5. 没有改变 `elixir/TESTING.md` 的权威地位。

## 后续如果要落地

如果后续要把这份解释变成正式制度，建议只做小步落地：

1. 在 `elixir/TESTING.md` 补一段专项测试触发器。
2. 第三层先按本机 Playwright 临时验证处理；只有确认要升格为仓库正式自动化时，才讨论最小 browser smoke suite、配置和依赖说明。
3. 在测试卡片模板里加入目标、head、层级、触发原因、成本、cleanup 和结果字段。
4. 修正 `make e2e`，让入口显式带上或要求外部传入 `SYMPHONY_TEST_MAX_CASES`。

这些都是后续实现或制度修改，不属于本文件已经完成的行为变更。
