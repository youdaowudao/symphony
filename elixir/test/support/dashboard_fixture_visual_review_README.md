# Dashboard Fixture Visual Review

中文名：Dashboard 假数据视觉巡检。

这是人工指定运行的 Dashboard UI 假数据视觉巡检工具。它只使用 `test/support` 下的 fixture 和本地 fake orchestrator，不新增生产 route、生产 API mock、生产配置开关，也不改真实 orchestrator。

只说“跑 Dashboard Fixture Visual Review”时，默认按 `small -> saturated -> extreme` 跑全部三类场景。分场景点名时只跑被点名的场景。

## Scenarios

- `small`：低数据量，覆盖空态、低量态和少量 Todo Pool 卡片。
- `saturated`：设计容量打满，覆盖约 20 条 running、多项目、多异常、恢复事件和不同项目数量不一的“尚未开始”Todo Pool 卡片。
- `extreme`：极端长文本、超大数值、缺失字段、极端 Todo Pool 文案，用于检查显示韧性。

## Preview Server

在仓库的 `elixir/` 目录下运行：

```bash
MIX_ENV=test SYMPHONY_TEST_MAX_CASES=4 SYMPHONY_DASHBOARD_FIXTURE=small elixir test/support/dashboard_fixture_server.exs
MIX_ENV=test SYMPHONY_TEST_MAX_CASES=4 SYMPHONY_DASHBOARD_FIXTURE=saturated elixir test/support/dashboard_fixture_server.exs
MIX_ENV=test SYMPHONY_TEST_MAX_CASES=4 SYMPHONY_DASHBOARD_FIXTURE=extreme elixir test/support/dashboard_fixture_server.exs
```

脚本会打印当前 scenario 和本地访问 URL。结束时用 `Ctrl+C`，preview server 会清理本次启动的 endpoint、fake orchestrator 和 PubSub。

Preview server 是单场景长驻入口。需要人工预览全部场景时，按 `small -> saturated -> extreme` 依次启动、查看、停止三次；自动按全部场景生成证据时使用下面的 screenshot script。

## Screenshot Script

默认跑全部三类场景，并生成 `1440x900` 与 `1920x1080` 截图：

```bash
MIX_ENV=test SYMPHONY_TEST_MAX_CASES=4 SYMPHONY_DASHBOARD_FIXTURE=all elixir test/support/dashboard_fixture_visual_check.exs
```

只跑单个场景：

```bash
MIX_ENV=test SYMPHONY_TEST_MAX_CASES=4 SYMPHONY_DASHBOARD_FIXTURE=saturated elixir test/support/dashboard_fixture_visual_check.exs
```

自定义 viewport 和输出目录：

```bash
MIX_ENV=test SYMPHONY_TEST_MAX_CASES=4 \
  SYMPHONY_DASHBOARD_FIXTURE=extreme \
  SYMPHONY_DASHBOARD_VIEWPORTS=1440x900,1920x1080 \
  SYMPHONY_DASHBOARD_SCREENSHOT_DIR=tmp/dashboard_fixture_visual_review \
  elixir test/support/dashboard_fixture_visual_check.exs
```

截图脚本只证明脚本启动和截图生成；它不会自动宣称 UI 视觉验收通过。AI 可以记录明显溢出、横向滚动、按钮被顶掉、文字不可读等机械问题，但审美合理性和最终视觉验收必须由人类确认。

截图脚本生成的 evidence manifest 会分开记录：脚本已启动、截图已生成、AI 是否记录了明显机械问题、是否已有人工视觉确认。默认值不会把未执行的机械问题检查或未发生的人类确认写成通过。

## Boundaries

- 不进入 CI。
- 不进入 `Next Push Gate`。
- 不进入日常 targeted tests。
- 普通代码实现、普通修 bug、普通 push、普通 PR update 前，AI / coder 不得主动运行。
- 只有人类明确指定 `Dashboard Fixture Visual Review` 或明确点名 `small` / `saturated` / `extreme` dashboard fixture 场景时才运行。
- fixture 只走 test support，不改生产 route/API/orchestrator。
- 没有人类确认时，不得宣称 UI 视觉验收通过。

当前 fixture snapshot 包含 `todo_pool` 视觉数据；它表示“已经存在于待执行池、但尚未开始 running 的卡片”。该字段只服务视觉巡检，不等于新增生产 Todo Pool contract。
