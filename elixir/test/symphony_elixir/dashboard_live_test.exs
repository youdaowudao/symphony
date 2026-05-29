defmodule SymphonyElixir.DashboardLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint
  @dashboard_css_path Path.expand("../../priv/static/dashboard.css", __DIR__)

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call(:clear_recovery_events, _from, state) do
      snapshot =
        state
        |> Keyword.fetch!(:snapshot)
        |> Map.put(:recovery_events, [])

      {:reply, :ok, Keyword.put(state, :snapshot, snapshot)}
    end
  end

  defmodule DisplayNameProjectRegistry do
    @moduledoc false

    def normalized_entries do
      {:ok,
       [
         %{project_key: "proj-a", display_name: "项目甲", enabled: true, max_concurrent_agents: 15},
         %{project_key: "proj-b", display_name: "项目乙", enabled: true, max_concurrent_agents: 15},
         %{project_key: "proj-c", display_name: "项目丙", enabled: true, max_concurrent_agents: 15}
       ]}
    end
  end

  test "dashboard renders layout v8 chinese shell and keeps non-allowlisted nav/display actions inert" do
    orchestrator_name = Module.concat(__MODULE__, :LayoutV8Orchestrator)
    start_static_orchestrator!(orchestrator_name, v8_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Multi-Project Operations Home"
    assert html =~ "多项目共享执行池"
    assert html =~ "总览"
    assert html =~ "Sessions"
    assert html =~ "Issues"
    assert html =~ "Todo Pool"
    assert html =~ "事件"
    assert html =~ "日志"
    assert html =~ "手动排序"
    assert html =~ "稳定位置"
    assert html =~ "copy session 仅在 running 行可用"
    assert html =~ "最近成功更新"
    assert html =~ ">Running<"
    assert html =~ ">待处理<"
    assert html =~ ">Tokens<"
    assert html =~ ">Runtime<"
    assert html =~ ">最久未更新<"
    assert html =~ ">Projects<"
    assert html =~ "当前异常"
    assert html =~ "最近恢复事件"
    assert html =~ "手动检查"
    assert html =~ "0 条"
    assert html =~ "待执行任务池占位"
    assert html =~ "项目甲"
    assert html =~ "项目乙"
    assert html =~ "项目丙"
    assert html =~ "待执行任务 0"
    assert html =~ "当前还没有最近恢复事件。这里只记录已恢复回 running 的项。"
    assert html =~ "等待人工输入"
    assert html =~ "等待下一次重试"
    refute html =~ "项目甲 · MT-RUN-OLDEST · 重试第 3 次后重新进入 running"
    refute html =~ "项目乙 · MT-RUN-NEWER · 重试第 2 次后重新进入 running"
    refute html =~ "Operations Dashboard"
    refute html =~ "phx-click=\"nav"
    refute html =~ "phx-click=\"detail"
    refute html =~ "phx-click=\"logs"
    refute html =~ "只保留纯展示占位"
    refute html =~ "仅允许展开/收回和手动检查的本地 UI 状态变更"
    refute html =~ "主列表只保留正常 running。排序允许手动切换，其他入口保持展示态。"
    assert html =~ ~s(class="nav-pill">Sessions</span>)
    assert html =~ ~s(class="nav-pill">Issues</span>)
    assert html =~ ~s(class="nav-pill muted" aria-disabled="true">Todo Pool</span>)
    assert html =~ ~s(class="meta-chip warn">稳定位置</span>)
    assert html =~ ~s(class="metric-card alert")
    assert html =~ ~s(<h3>最久未更新</h3>)
    refute html =~ "空闲态优先展示项目总览"
    assert html =~ ~s(id="dashboard-primary")
    assert html =~ ~s(id="running-list")
    refute html =~ ~s(id="overview-project-grid")
  end

  test "dashboard recovery panel falls back to honest empty state when snapshot lacks recovery history signals" do
    orchestrator_name = Module.concat(__MODULE__, :RecoveryEmptyOrchestrator)

    start_static_orchestrator!(
      orchestrator_name,
      v8_snapshot_without_recovery_signals(),
      :unavailable
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "最近恢复事件"
    assert html =~ "当前还没有最近恢复事件。这里只记录已恢复回 running 的项。"
    refute html =~ "重试第 2 次后重新进入 running"
    refute html =~ "重试第 3 次后重新进入 running"
    refute html =~ "恢复事件列表保留最近位置"
  end

  test "dashboard running list defaults to last update sort and supports manual sort switching with visible state" do
    orchestrator_name = Module.concat(__MODULE__, :RunningSortOrchestrator)
    start_static_orchestrator!(orchestrator_name, v8_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    running_html = view |> element("#running-list") |> render()

    assert running_html =~ "最后更新 ↑"
    assert running_html =~ "sort-pill active"

    oldest_index = substring_index(running_html, "MT-RUN-OLDEST")
    newer_index = substring_index(running_html, "MT-RUN-NEWER")
    newest_index = substring_index(running_html, "MT-RUN-NEWEST")

    assert oldest_index < newer_index
    assert newer_index < newest_index

    view
    |> element("button[phx-value-sort='project']")
    |> render_click()

    sorted_by_project_html = view |> element("#running-list") |> render()

    assert sorted_by_project_html =~ "项目 ↑"
    assert sorted_by_project_html =~ "phx-value-sort=\"project\""

    project_c_index = substring_index(sorted_by_project_html, "MT-RUN-NEWEST")
    project_b_index = substring_index(sorted_by_project_html, "MT-RUN-NEWER")
    project_a_index = substring_index(sorted_by_project_html, "MT-RUN-OLDEST")

    assert project_c_index < project_b_index
    assert project_b_index < project_a_index

    view
    |> element("button[phx-value-sort='tokens']")
    |> render_click()

    sorted_by_tokens_html = view |> element("#running-list") |> render()

    assert sorted_by_tokens_html =~ "Token ↓"

    newest_token_index = substring_index(sorted_by_tokens_html, "MT-RUN-NEWEST")
    newer_token_index = substring_index(sorted_by_tokens_html, "MT-RUN-NEWER")
    oldest_token_index = substring_index(sorted_by_tokens_html, "MT-RUN-OLDEST")

    assert newest_token_index < newer_token_index
    assert newer_token_index < oldest_token_index

    view
    |> element("button[phx-value-sort='tokens']")
    |> render_click()

    reversed_tokens_html = view |> element("#running-list") |> render()

    assert reversed_tokens_html =~ "Token ↑"

    oldest_token_desc_index = substring_index(reversed_tokens_html, "MT-RUN-OLDEST")
    newer_token_desc_index = substring_index(reversed_tokens_html, "MT-RUN-NEWER")
    newest_token_desc_index = substring_index(reversed_tokens_html, "MT-RUN-NEWEST")

    assert oldest_token_desc_index < newer_token_desc_index
    assert newer_token_desc_index < newest_token_desc_index

    view
    |> element("button[phx-value-sort='project']")
    |> render_click()

    project_default_html = view |> element("#running-list") |> render()
    assert project_default_html =~ "项目 ↑"

    view
    |> element("button[phx-value-sort='project']")
    |> render_click()

    reversed_project_html = view |> element("#running-list") |> render()

    assert reversed_project_html =~ "项目 ↓"

    project_a_desc_index = substring_index(reversed_project_html, "MT-RUN-OLDEST")
    project_b_desc_index = substring_index(reversed_project_html, "MT-RUN-NEWER")
    project_c_desc_index = substring_index(reversed_project_html, "MT-RUN-NEWEST")

    assert project_a_desc_index < project_b_desc_index
    assert project_b_desc_index < project_c_desc_index
  end

  test "dashboard todo pool summary card expands and collapses through liveview state" do
    orchestrator_name = Module.concat(__MODULE__, :TodoPoolToggleOrchestrator)
    start_static_orchestrator!(orchestrator_name, v8_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    todo_html = view |> element("#todo-pool-panel") |> render()
    assert todo_html =~ "Todo Pool"
    assert todo_html =~ "项目甲"
    assert todo_html =~ "项目乙"
    assert todo_html =~ "项目丙"
    assert todo_html =~ "待执行任务 0"
    refute todo_html =~ "Running 1"
    refute todo_html =~ "Retrying 1"
    refute todo_html =~ "Blocked 1"

    view
    |> element("button[phx-click='toggle_todo_pool'][phx-value-project='proj-a']")
    |> render_click()

    expanded_html = view |> element("#todo-pool-panel") |> render()
    assert expanded_html =~ "收回摘要"
    assert expanded_html =~ "待执行任务详情占位"

    view
    |> element("button[phx-click='toggle_todo_pool'][phx-value-project='proj-a']")
    |> render_click()

    collapsed_html = view |> element("#todo-pool-panel") |> render()
    assert collapsed_html =~ "展开摘要"
    refute collapsed_html =~ "待处理摘要来自共享 payload"
  end

  test "dashboard resolves project display names from registry and does not expose project slug as primary ui text" do
    Application.put_env(
      :symphony_elixir,
      :project_registry_module,
      DisplayNameProjectRegistry
    )

    orchestrator_name = Module.concat(__MODULE__, :RegistryDisplayNameOrchestrator)

    start_static_orchestrator!(orchestrator_name, slug_only_snapshot(), :unavailable)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ ">Projects<"
    assert html =~ ~s(<p class="metric-value numeric">3</p>)
    assert html =~ "待执行任务 0"
    assert html =~ "MT-BLOCKED"
    assert html =~ "项目甲"
    assert html =~ "项目乙"
    assert html =~ "项目丙"
    refute html =~ "proj-a · Running 1 · Retrying 1 · Blocked 1"
    refute html =~ "proj-b · Running 1 · Retrying 0 · Blocked 0"
    refute html =~ "proj-c · Running 1 · Retrying 0 · Blocked 0"

    view
    |> element("button[phx-click='toggle_todo_pool'][phx-value-project='proj-a']")
    |> render_click()

    expanded_html = view |> element("#todo-pool-panel") |> render()

    assert expanded_html =~ "项目甲"
    assert expanded_html =~ "项目乙"
    assert expanded_html =~ "项目丙"
    refute expanded_html =~ ~s(<p class="project-key mono">proj-a</p>)
    refute expanded_html =~ ~s(<p class="project-key mono">proj-b</p>)
    refute expanded_html =~ ~s(<p class="project-key mono">proj-c</p>)
  end

  test "api state uses canonical registry projects and display names despite legacy workflow project_slug conflict" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "03b2b4a16461"
    )

    workflow_root = Path.dirname(Workflow.workflow_file_path())
    token_path = Path.join(workflow_root, ".config/linear/linear_api_key.token")
    File.mkdir_p!(Path.dirname(token_path))
    File.write!(token_path, "registry-token\n")

    write_project_registry_file!(Path.join(workflow_root, "project_registry.yaml"), %{
      schema_version: 1,
      linear_token_relative_path: ".config/linear/linear_api_key.token",
      projects: [
        %{project_key: "proj-a", display_name: "项目甲", enabled: true, max_concurrent_agents: 15},
        %{project_key: "proj-b", display_name: "项目乙", enabled: true, max_concurrent_agents: 15}
      ]
    })

    orchestrator_name = Module.concat(__MODULE__, :CanonicalRegistryProjectsOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload["counts"] == %{"blocked" => 0, "retrying" => 0, "running" => 0, "stale" => 0, "pending" => 0}
    assert state_payload["running"] == []
    assert state_payload["retrying"] == []
    assert state_payload["blocked"] == []
    assert state_payload["recovery_events"] == []

    assert state_payload["projects"] == [
             %{
               "project_key" => "proj-a",
               "project_display_name" => "项目甲",
               "running_count" => 0,
               "retrying_count" => 0,
               "blocked_count" => 0
             },
             %{
               "project_key" => "proj-b",
               "project_display_name" => "项目乙",
               "running_count" => 0,
               "retrying_count" => 0,
               "blocked_count" => 0
             }
           ]
  end

  test "dashboard todo pool manual check only changes local placeholder state" do
    orchestrator_name = Module.concat(__MODULE__, :TodoPoolManualCheckOrchestrator)
    refresh_requested_at = DateTime.from_naive!(~N[2026-05-28 00:24:12], "Etc/UTC")

    start_supervised!(
      {StaticOrchestrator,
       name: orchestrator_name,
       snapshot: v8_snapshot(),
       refresh: %{
         queued: true,
         coalesced: false,
         requested_at: refresh_requested_at,
         operations: ["poll", "reconcile"]
       }}
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    initial_html = view |> element("#todo-pool-panel") |> render()
    refute initial_html =~ "已请求后台刷新"
    refute initial_html =~ "最近请求"
    refute initial_html =~ "仅更新本地占位状态"

    view
    |> element("button[phx-click='manual_check_todo_pool']")
    |> render_click()

    checked_html = view |> element("#todo-pool-panel") |> render()
    assert checked_html =~ "仅更新本地占位状态，未触发后台刷新。"
    assert checked_html =~ "待执行任务详情占位"
    refute checked_html =~ "已请求后台刷新"
    refute checked_html =~ "最近请求"
    refute checked_html =~ "当前无法触发后台刷新"
  end

  test "dashboard recovery panel shows asia shanghai timestamps without real clear interaction" do
    orchestrator_name = Module.concat(__MODULE__, :RecoveryClearOrchestrator)
    start_static_orchestrator!(orchestrator_name, wide_load_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "最近恢复事件"
    recovery_html = view |> element("#recovery-events-list") |> render()
    assert recovery_html =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC\+8/
    assert recovery_html =~ "UTC+8"
    refute recovery_html =~ ~r/>\d{2}:\d{2}:\d{2}</
    refute html =~ ~s(phx-click="clear_recovery_events")
    refute html =~ ">清空<"
  end

  test "dashboard copy session wiring uses browser clipboard result and missing-session uses local fallback" do
    orchestrator_name = Module.concat(__MODULE__, :CopySessionOrchestrator)
    start_static_orchestrator!(orchestrator_name, v8_snapshot_with_missing_session(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "copy session"
    assert html =~ "navigator.clipboard.writeText(this.dataset.copy)"
    assert html =~ ".then(() =&gt;"
    assert html =~ ".catch(() =&gt;"
    assert html =~ "this.textContent = &#39;已复制&#39;"
    assert html =~ "this.textContent = &#39;复制失败&#39;"
    assert html =~ "this.textContent = this.dataset.label"
    assert html =~ "data-copy=\"session-oldest\""
    assert html =~ ~s(class="copy-chip")
    assert html =~ ~s(class="copy-chip copy-chip-missing")
    assert html =~ "无可复制 session"
    assert html =~ "setTimeout(() =&gt; { this.textContent = this.dataset.label; }, 1200);"
  end

  test "dashboard keeps running row order stable across refresh when user stays on last update sort" do
    orchestrator_name = Module.concat(__MODULE__, :StableRefreshOrchestrator)

    start_static_orchestrator!(orchestrator_name, v8_snapshot(), :unavailable)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    initial_html = view |> element("#running-list") |> render()
    initial_oldest = substring_index(initial_html, "MT-RUN-OLDEST")
    initial_newer = substring_index(initial_html, "MT-RUN-NEWER")
    initial_newest = substring_index(initial_html, "MT-RUN-NEWEST")

    assert initial_oldest < initial_newer
    assert initial_newer < initial_newest

    :sys.replace_state(orchestrator_name, fn state ->
      Keyword.put(state, :snapshot, v8_snapshot_refresh())
    end)

    send(view.pid, :observability_updated)

    assert_eventually(
      fn ->
        refreshed_html = view |> element("#running-list") |> render()
        refreshed_oldest = substring_index(refreshed_html, "MT-RUN-OLDEST")
        refreshed_newer = substring_index(refreshed_html, "MT-RUN-NEWER")
        refreshed_newest = substring_index(refreshed_html, "MT-RUN-NEWEST")

        refreshed_oldest < refreshed_newer and
          refreshed_newer < refreshed_newest and
          refreshed_html =~ "oldest became newest" and
          refreshed_html =~ "newest became oldest"
      end,
      40
    )
  end

  test "dashboard preserves todo pool expansion state across observability refresh" do
    orchestrator_name = Module.concat(__MODULE__, :RefreshExpandedTodoOrchestrator)

    start_static_orchestrator!(orchestrator_name, v8_snapshot(), :unavailable)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element("button[phx-click='toggle_todo_pool'][phx-value-project='proj-a']")
    |> render_click()

    expanded_html = view |> element("#todo-pool-panel") |> render()
    assert expanded_html =~ "收回摘要"
    assert expanded_html =~ "待执行任务详情占位"

    :sys.replace_state(orchestrator_name, fn state ->
      Keyword.put(state, :snapshot, v8_snapshot_refresh())
    end)

    send(view.pid, :observability_updated)

    assert_eventually(
      fn ->
        refreshed_html = view |> element("#todo-pool-panel") |> render()
        refreshed_html =~ "收回摘要" and refreshed_html =~ "待执行任务详情占位"
      end,
      40
    )
  end

  test "dashboard ticker wrappers keep dynamic text on hook-owned child nodes only" do
    orchestrator_name = Module.concat(__MODULE__, :TickerOwnerWrapperOrchestrator)
    start_static_orchestrator!(orchestrator_name, v8_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html_attr!(html, "#poll-countdown-chip", "phx-update") == "ignore"
    assert html_attr!(html, "#runtime-total-metric", "phx-update") == "ignore"
    assert html_attr!(html, "#running-runtime-running-entry-run-oldest", "phx-update") == "ignore"

    assert owner_count(html, "#poll-countdown-chip [data-ticker-owner='poll-countdown']") == 1
    assert owner_count(html, "#runtime-total-metric [data-ticker-owner='runtime-total']") == 1
    assert owner_count(html, "#running-runtime-running-entry-run-oldest [data-ticker-owner='running-entry']") == 1

    assert html_text!(html, "#poll-countdown-chip") == ""
    assert html_text!(html, "#runtime-total-metric") == ""
    assert html_text!(html, "#running-runtime-running-entry-run-oldest") == ""
  end

  test "dashboard running summary prefers stable event labels over streaming delta fragments" do
    orchestrator_name = Module.concat(__MODULE__, :StreamingSummaryOrchestrator)
    start_static_orchestrator!(orchestrator_name, streaming_summary_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    running_html = view |> element("#running-list") |> render()

    assert running_html =~ "消息输出中"
    refute running_html =~ "逐"
    refute running_html =~ "字"
    refute running_html =~ "agent message streaming: 逐字"
  end

  test "dashboard runtime metric keeps cumulative history even when no running entries remain" do
    orchestrator_name = Module.concat(__MODULE__, :HistoricalRuntimeOnlyOrchestrator)

    start_static_orchestrator!(
      orchestrator_name,
      historical_runtime_only_snapshot(),
      :unavailable
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "<h3>Runtime</h3>"
    assert html =~ "历史累计 + 当前活跃增量"
    assert html_attr!(html, "#runtime-total-metric", "data-base-seconds") == "180"
    assert html_attr!(html, "#runtime-total-metric", "data-growth-per-second") == "0"
    assert html_text!(html, "#runtime-total-metric") == ""
  end

  test "dashboard runtime live growth counts only healthy running entries" do
    orchestrator_name = Module.concat(__MODULE__, :HealthyRuntimeGrowthOrchestrator)
    start_static_orchestrator!(orchestrator_name, wide_load_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(data-growth-per-second="22")
  end

  test "dashboard exposes runtime anchors that already include current running total at render time" do
    orchestrator_name = Module.concat(__MODULE__, :LiveDurationAttrsOrchestrator)
    start_static_orchestrator!(orchestrator_name, v8_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(data-live-duration="runtime-total")
    assert html =~ ~s(data-live-duration="running-entry")
    assert html =~ ~s(data-base-seconds=)
    assert html =~ ~s(data-anchor-unix=)
    assert html =~ ~s(data-growth-per-second="3")

    runtime_base_seconds =
      html_attr!(html, "#runtime-total-metric", "data-base-seconds")
      |> String.to_integer()

    assert runtime_base_seconds >= 1_680
  end

  test "dashboard clamps future started_at to zero so runtime anchor never undercounts" do
    orchestrator_name = Module.concat(__MODULE__, :FutureStartedAtRuntimeOrchestrator)

    start_static_orchestrator!(orchestrator_name, future_started_at_snapshot(), :unavailable)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html_attr!(html, "#runtime-total-metric", "data-base-seconds") == "180"
    assert html_attr!(html, "#running-runtime-running-entry-run-future", "data-base-seconds") == "0"
  end

  test "dashboard uses honest poll countdown states instead of server-owned labels" do
    orchestrator_name = Module.concat(__MODULE__, :PollCountdownHookOrchestrator)
    start_static_orchestrator!(orchestrator_name, v8_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(phx-hook="LiveTicker")
    assert html =~ ~s(data-ticker="poll-countdown")
    assert html_attr!(html, "#poll-countdown-chip", "data-poll-state") == "unknown"
    assert html_attr!(html, "#poll-countdown-chip", "data-poll-interval-seconds") == "30"
    assert missing_attr?(html, "#poll-countdown-chip", "data-next-poll-in-seconds")
    assert html_text!(html, "#poll-countdown-chip") == ""
  end

  test "dashboard poll countdown exposes checking state honestly when orchestrator is in checking window" do
    orchestrator_name = Module.concat(__MODULE__, :PollCheckingStateOrchestrator)
    start_static_orchestrator!(orchestrator_name, checking_poll_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html_attr!(html, "#poll-countdown-chip", "data-poll-state") == "checking"
    assert missing_attr?(html, "#poll-countdown-chip", "data-next-poll-in-seconds")
  end

  test "dashboard running latest update uses elapsed duration rather than absolute clock time" do
    orchestrator_name = Module.concat(__MODULE__, :RunningFreshnessElapsedOrchestrator)
    start_static_orchestrator!(orchestrator_name, v8_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    running_html = view |> element("#running-list") |> render()

    assert running_html =~ "9m"
    refute running_html =~ ~r/\d{2}:\d{2}:\d{2}/
  end

  test "dashboard token metric normalizes totals into M units" do
    orchestrator_name = Module.concat(__MODULE__, :MetricTokenUnitsOrchestrator)
    start_static_orchestrator!(orchestrator_name, metric_token_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "0.04M"
    assert html =~ "In 0.04M / Out 0.00M"
  end

  test "dashboard wide-load scenario keeps running as primary region and bounds auxiliary lists with scroll containers" do
    orchestrator_name = Module.concat(__MODULE__, :WideLoadOrchestrator)

    start_static_orchestrator!(orchestrator_name, wide_load_snapshot(), :unavailable)

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ ~s(id="dashboard-sidebar")
    assert html =~ ~s(id="dashboard-primary")
    assert html =~ ~s(class="column column-sidebar")
    assert html =~ ~s(class="column column-primary")
    assert html =~ ~s(id="current-exceptions-list")
    assert html =~ ~s(id="recovery-events-list")
    assert html =~ ~s(id="todo-project-cards")
    assert html =~ ~s(id="running-rows")
    assert html =~ ~s|onwheel="window.scrollBy({ top: event.deltaY, left: 0, behavior: &#39;auto&#39; }); return false;"|
    assert html =~ "22 条"
    assert html =~ "8 条"
    assert html =~ "MT-WIDE-RUN-01"
    assert html =~ "MT-WIDE-RUN-22"
    assert html =~ "MT-WIDE-BLOCKED-01"
    assert html =~ "MT-WIDE-RETRY-01"
    assert html =~ "MT-WIDE-STALE-01"
    assert html =~ "超长恢复事件 08"
    assert html =~ "项目癸"
    assert count_occurrences(html, ~s(class="running-entry")) == 22
    assert count_occurrences(html, ~s(class="anomaly-item")) == 4

    recovery_html = view |> element("#recovery-events-list") |> render()
    assert count_occurrences(recovery_html, ~s(class="history-line")) == 8

    summary_html = view |> element("#todo-project-cards") |> render()
    assert count_occurrences(summary_html, ~s(class="project-card todo-project-row")) == 10

    view
    |> element("button[phx-click='toggle_todo_pool'][phx-value-project='proj-a']")
    |> render_click()

    expanded_html = view |> element("#todo-pool-panel") |> render()
    assert expanded_html =~ ~s(id="todo-project-cards")
    assert count_occurrences(expanded_html, ~s(class="project-card todo-project-row")) == 10
  end

  test "dashboard idle running state keeps running panel as primary region and leaves project summary in todo pool" do
    orchestrator_name = Module.concat(__MODULE__, :IdleOverviewOrchestrator)
    start_static_orchestrator!(orchestrator_name, idle_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(id="dashboard-primary")
    assert html =~ ~s(id="running-list")
    assert html =~ "当前没有正常 running 项。"
    assert html =~ ~s(id="todo-pool-panel")
    assert html =~ ~s(id="todo-project-cards")
    assert html =~ "Symphony"
    assert html =~ "LinearAgents"
    assert html =~ "待执行任务 0"
    refute html =~ ~s(id="overview-shell")
    refute html =~ ~s(id="overview-project-grid")
    refute html =~ "当前计数来自共享快照"
    refute html =~ ">03b2b4a16461<"
    refute html =~ ">327e2b00c1cd<"
  end

  test "dashboard idle exceptions panel does not reserve tall scroll area" do
    orchestrator_name = Module.concat(__MODULE__, :IdleExceptionsCompactOrchestrator)
    start_static_orchestrator!(orchestrator_name, idle_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(id="current-exceptions-list")
    refute html =~ ~s(id="current-exceptions-list" class="panel-body panel-scroll panel-scroll-critical")
  end

  test "dashboard css keeps layout-v8 width ratios and avoids trapping page scroll in the primary running region" do
    css = File.read!(@dashboard_css_path)

    assert css =~ "width: min(1920px, calc(100vw - 32px));"
    assert css =~ "max-width: 1920px;"
    assert css =~ "grid-template-columns: minmax(300px, 0.78fr) minmax(760px, 1.58fr);"
    assert css =~ ".panel-scroll {"
    assert css =~ "overflow: auto;"
    assert css =~ ".panel-scroll-critical {"
    assert css =~ ".panel-scroll-secondary {"
    assert css =~ ".projects-scroll {"
    assert css =~ ".exceptions-scroll-ready {"
    assert css =~ "max-height: 360px;"
    assert css =~ ".recovery-scroll-ready {"
    assert css =~ "max-height: 320px;"
    assert css =~ "#running-list {"
    assert css =~ ".running-rows {"
    assert css =~ "max-height: 820px;"
    assert css =~ "overflow-y: auto;"
    assert css =~ ".running-cell-issue .mono {"
    assert css =~ "display: -webkit-box;"
    assert css =~ "-webkit-line-clamp: 2;"
    assert css =~ ".history-line {"
    assert css =~ "-webkit-line-clamp: 2;"
    refute css =~ "#running-list {\n  min-height: 820px;"
    refute css =~ ".overview-shell {"
    refute css =~ ".overview-secondary-grid {"
    refute css =~ ".overview-project-grid {"
    refute css =~ ".project-card-large {"
  end

  test "dashboard running issue and recovery event rows expose truncation classes for long content" do
    orchestrator_name = Module.concat(__MODULE__, :LongContentClampOrchestrator)
    start_static_orchestrator!(orchestrator_name, wide_load_snapshot(), :unavailable)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(class="running-cell running-cell-issue")
    assert html =~ ~s(class="history-line")
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp start_static_orchestrator!(orchestrator_name, snapshot, refresh) do
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})
  end

  defp v8_snapshot do
    now = DateTime.utc_now()

    %{
      projects: [
        %{project_key: "proj-a", project_display_name: "项目甲", running_count: 1, retrying_count: 1, blocked_count: 1},
        %{project_key: "proj-b", project_display_name: "项目乙", running_count: 1, retrying_count: 0, blocked_count: 0},
        %{project_key: "proj-c", project_display_name: "项目丙", running_count: 1, retrying_count: 0, blocked_count: 0}
      ],
      running: [
        %{
          project_key: "proj-c",
          project_display_name: "项目丙",
          issue_id: "run-newest",
          identifier: "MT-RUN-NEWEST",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev3",
          workspace_path: "/workspace/proj-c/MT-RUN-NEWEST",
          attempt: 1,
          session_id: "session-newest",
          turn_count: 2,
          last_codex_event: :notification,
          last_codex_message: "newest update",
          started_at: DateTime.add(now, -180, :second),
          last_codex_timestamp: DateTime.add(now, -(2 * 60), :second),
          codex_input_tokens: 100,
          codex_output_tokens: 200,
          codex_total_tokens: 300
        },
        %{
          project_key: "proj-a",
          project_display_name: "项目甲",
          issue_id: "run-oldest",
          identifier: "MT-RUN-OLDEST",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev1",
          workspace_path: "/workspace/proj-a/MT-RUN-OLDEST",
          attempt: 3,
          session_id: "session-oldest",
          turn_count: 6,
          last_codex_event: :notification,
          last_codex_message: "oldest update",
          started_at: DateTime.add(now, -840, :second),
          last_codex_timestamp: DateTime.add(now, -(9 * 60), :second),
          codex_input_tokens: 10,
          codex_output_tokens: 10,
          codex_total_tokens: 20
        },
        %{
          project_key: "proj-b",
          project_display_name: "项目乙",
          issue_id: "run-newer",
          identifier: "MT-RUN-NEWER",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev2",
          workspace_path: "/workspace/proj-b/MT-RUN-NEWER",
          attempt: 2,
          session_id: "session-newer",
          turn_count: 4,
          last_codex_event: :notification,
          last_codex_message: "newer update",
          started_at: DateTime.add(now, -480, :second),
          last_codex_timestamp: DateTime.add(now, -(5 * 60), :second),
          codex_input_tokens: 30,
          codex_output_tokens: 40,
          codex_total_tokens: 70
        }
      ],
      retrying: [
        %{
          project_key: "proj-a",
          project_display_name: "项目甲",
          issue_id: "retrying-1",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 60_000,
          error: "等待下一次重试",
          worker_host: "dm-dev4",
          workspace_path: "/workspace/proj-a/MT-RETRY",
          last_codex_timestamp: DateTime.add(now, -(4 * 60), :second)
        }
      ],
      blocked: [
        %{
          project_key: "proj-a",
          project_display_name: "项目甲",
          issue_id: "blocked-1",
          identifier: "MT-BLOCKED",
          state: "In Progress",
          runtime_status: "waiting_input",
          error: "等待人工输入",
          worker_host: "dm-dev5",
          workspace_path: "/workspace/proj-a/MT-BLOCKED",
          session_id: "session-blocked",
          blocked_at: DateTime.add(now, -(2 * 60), :second),
          last_codex_event: :turn_input_required,
          last_codex_message: "blocked by human",
          last_codex_timestamp: DateTime.add(now, -(2 * 60), :second)
        }
      ],
      codex_totals: %{input_tokens: 140, output_tokens: 250, total_tokens: 390, seconds_running: 180.0},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp idle_snapshot do
    %{
      projects: [
        %{project_key: "03b2b4a16461", project_display_name: "Symphony", running_count: 0, retrying_count: 1, blocked_count: 1},
        %{project_key: "327e2b00c1cd", project_display_name: "LinearAgents", running_count: 0, retrying_count: 0, blocked_count: 0}
      ],
      running: [],
      retrying: [
        %{
          project_key: "03b2b4a16461",
          project_display_name: "Symphony",
          issue_id: "retry-1",
          identifier: "C-55",
          issue_identifier: "C-55",
          attempt: 1,
          error: "boom",
          due_in_ms: 2_000
        }
      ],
      blocked: [
        %{
          project_key: "03b2b4a16461",
          project_display_name: "Symphony",
          issue_id: "blocked-1",
          identifier: "C-56",
          issue_identifier: "C-56",
          state: "In Progress",
          error: "waiting input",
          session_id: nil,
          last_codex_event: :turn_input_required,
          last_codex_message: "waiting input",
          last_codex_timestamp: DateTime.utc_now(),
          blocked_at: DateTime.utc_now()
        }
      ],
      recovery_events: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  end

  defp v8_snapshot_refresh do
    now = DateTime.utc_now()

    %{
      projects: [
        %{project_key: "proj-a", project_display_name: "项目甲", running_count: 1, retrying_count: 1, blocked_count: 1},
        %{project_key: "proj-b", project_display_name: "项目乙", running_count: 1, retrying_count: 0, blocked_count: 0},
        %{project_key: "proj-c", project_display_name: "项目丙", running_count: 1, retrying_count: 0, blocked_count: 0}
      ],
      running: [
        %{
          project_key: "proj-c",
          project_display_name: "项目丙",
          issue_id: "run-newest",
          identifier: "MT-RUN-NEWEST",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev3",
          workspace_path: "/workspace/proj-c/MT-RUN-NEWEST",
          attempt: 1,
          session_id: "session-newest",
          turn_count: 3,
          last_codex_event: :notification,
          last_codex_message: "newest became oldest",
          started_at: DateTime.add(now, -180, :second),
          last_codex_timestamp: DateTime.add(now, -(9 * 60), :second),
          codex_input_tokens: 100,
          codex_output_tokens: 200,
          codex_total_tokens: 300
        },
        %{
          project_key: "proj-a",
          project_display_name: "项目甲",
          issue_id: "run-oldest",
          identifier: "MT-RUN-OLDEST",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev1",
          workspace_path: "/workspace/proj-a/MT-RUN-OLDEST",
          attempt: 3,
          session_id: "session-oldest",
          turn_count: 7,
          last_codex_event: :notification,
          last_codex_message: "oldest became newest",
          started_at: DateTime.add(now, -840, :second),
          last_codex_timestamp: DateTime.add(now, -60, :second),
          codex_input_tokens: 10,
          codex_output_tokens: 10,
          codex_total_tokens: 20
        },
        %{
          project_key: "proj-b",
          project_display_name: "项目乙",
          issue_id: "run-newer",
          identifier: "MT-RUN-NEWER",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev2",
          workspace_path: "/workspace/proj-b/MT-RUN-NEWER",
          attempt: 2,
          session_id: "session-newer",
          turn_count: 5,
          last_codex_event: :notification,
          last_codex_message: "newer stayed middle",
          started_at: DateTime.add(now, -480, :second),
          last_codex_timestamp: DateTime.add(now, -(4 * 60), :second),
          codex_input_tokens: 30,
          codex_output_tokens: 40,
          codex_total_tokens: 70
        }
      ],
      retrying: [
        %{
          project_key: "proj-a",
          project_display_name: "项目甲",
          issue_id: "retrying-1",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 60_000,
          error: "等待下一次重试",
          worker_host: "dm-dev4",
          workspace_path: "/workspace/proj-a/MT-RETRY",
          last_codex_timestamp: DateTime.add(now, -(4 * 60), :second)
        }
      ],
      blocked: [
        %{
          project_key: "proj-a",
          project_display_name: "项目甲",
          issue_id: "blocked-1",
          identifier: "MT-BLOCKED",
          state: "In Progress",
          runtime_status: "waiting_input",
          error: "等待人工输入",
          worker_host: "dm-dev5",
          workspace_path: "/workspace/proj-a/MT-BLOCKED",
          session_id: "session-blocked",
          blocked_at: DateTime.add(now, -(2 * 60), :second),
          last_codex_event: :turn_input_required,
          last_codex_message: "blocked by human",
          last_codex_timestamp: DateTime.add(now, -(2 * 60), :second)
        }
      ],
      codex_totals: %{input_tokens: 140, output_tokens: 250, total_tokens: 390, seconds_running: 180.0},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp v8_snapshot_with_missing_session do
    snapshot = v8_snapshot()

    missing_entry = %{
      project_key: "proj-d",
      project_display_name: "项目丁",
      issue_id: "run-no-session",
      identifier: "MT-RUN-NO-SESSION",
      state: "In Progress",
      runtime_status: "running",
      worker_host: "dm-dev6",
      workspace_path: "/workspace/proj-d/MT-RUN-NO-SESSION",
      session_id: nil,
      turn_count: 1,
      last_codex_event: :notification,
      last_codex_message: "missing session",
      started_at: DateTime.add(DateTime.utc_now(), -120, :second),
      last_codex_timestamp: DateTime.add(DateTime.utc_now(), -60, :second),
      codex_input_tokens: 5,
      codex_output_tokens: 5,
      codex_total_tokens: 10
    }

    Map.update!(snapshot, :running, &(&1 ++ [missing_entry]))
  end

  defp v8_snapshot_without_recovery_signals do
    snapshot = v8_snapshot()

    running =
      Enum.map(snapshot.running, fn entry ->
        Map.put(entry, :attempt, 0)
      end)

    %{snapshot | running: running}
  end

  defp slug_only_snapshot do
    now = DateTime.utc_now()

    %{
      projects: [
        %{project_key: "proj-a", project_display_name: "proj-a", running_count: 1, retrying_count: 1, blocked_count: 1},
        %{project_key: "proj-b", project_display_name: "proj-b", running_count: 1, retrying_count: 0, blocked_count: 0},
        %{project_key: "proj-c", project_display_name: "proj-c", running_count: 1, retrying_count: 0, blocked_count: 0}
      ],
      running: [
        %{
          project_key: "proj-c",
          project_display_name: "proj-c",
          issue_id: "run-newest",
          identifier: "MT-RUN-NEWEST",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev3",
          workspace_path: "/workspace/proj-c/MT-RUN-NEWEST",
          session_id: "session-newest",
          turn_count: 2,
          last_codex_event: :notification,
          last_codex_message: "newest update",
          started_at: DateTime.add(now, -180, :second),
          last_codex_timestamp: DateTime.add(now, -(2 * 60), :second),
          codex_input_tokens: 100,
          codex_output_tokens: 200,
          codex_total_tokens: 300
        },
        %{
          project_key: "proj-a",
          project_display_name: "proj-a",
          issue_id: "run-oldest",
          identifier: "MT-RUN-OLDEST",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev1",
          workspace_path: "/workspace/proj-a/MT-RUN-OLDEST",
          session_id: "session-oldest",
          turn_count: 6,
          last_codex_event: :notification,
          last_codex_message: "oldest update",
          started_at: DateTime.add(now, -840, :second),
          last_codex_timestamp: DateTime.add(now, -(9 * 60), :second),
          codex_input_tokens: 10,
          codex_output_tokens: 10,
          codex_total_tokens: 20
        },
        %{
          project_key: "proj-b",
          project_display_name: "proj-b",
          issue_id: "run-newer",
          identifier: "MT-RUN-NEWER",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev2",
          workspace_path: "/workspace/proj-b/MT-RUN-NEWER",
          session_id: "session-newer",
          turn_count: 4,
          last_codex_event: :notification,
          last_codex_message: "newer update",
          started_at: DateTime.add(now, -480, :second),
          last_codex_timestamp: DateTime.add(now, -(5 * 60), :second),
          codex_input_tokens: 30,
          codex_output_tokens: 40,
          codex_total_tokens: 70
        }
      ],
      retrying: [
        %{
          project_key: "proj-a",
          project_display_name: "proj-a",
          issue_id: "retrying-1",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 60_000,
          error: "等待下一次重试",
          worker_host: "dm-dev4",
          workspace_path: "/workspace/proj-a/MT-RETRY",
          last_codex_timestamp: DateTime.add(now, -(4 * 60), :second)
        }
      ],
      blocked: [
        %{
          project_key: "proj-a",
          project_display_name: "proj-a",
          issue_id: "blocked-1",
          identifier: "MT-BLOCKED",
          state: "In Progress",
          runtime_status: "waiting_input",
          error: "等待人工输入",
          worker_host: "dm-dev5",
          workspace_path: "/workspace/proj-a/MT-BLOCKED",
          session_id: "session-blocked",
          blocked_at: DateTime.add(now, -(2 * 60), :second),
          last_codex_event: :turn_input_required,
          last_codex_message: "blocked by human",
          last_codex_timestamp: DateTime.add(now, -(2 * 60), :second)
        }
      ],
      codex_totals: %{input_tokens: 140, output_tokens: 250, total_tokens: 390, seconds_running: 180.0},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wide_load_snapshot do
    now = DateTime.utc_now()
    projects = wide_load_projects()

    healthy_running =
      Enum.map(1..22, fn index ->
        {project_key, project_name} = Enum.at(projects, rem(index - 1, length(projects)))
        token_total = 1_200 + index * 175
        last_update_minutes = rem(index + 1, 9)

        %{
          project_key: project_key,
          project_display_name: project_name,
          issue_id: "wide-run-#{index}",
          identifier: "MT-WIDE-RUN-#{pad2(index)}",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-wide-#{rem(index, 6) + 1}",
          workspace_path: "/workspace/#{project_key}/MT-WIDE-RUN-#{pad2(index)}",
          attempt: rem(index, 3) + 1,
          session_id: "wide-session-#{pad2(index)}",
          turn_count: 3 + rem(index, 8),
          last_codex_event: :notification,
          last_codex_message: "宽屏满载运行摘要 #{pad2(index)}，用于压测右侧主列表宽度与摘要截断。",
          started_at: DateTime.add(now, -(index * 11 * 60), :second),
          last_codex_timestamp: DateTime.add(now, -(last_update_minutes * 60 + rem(index, 47)), :second),
          codex_input_tokens: div(token_total, 2),
          codex_output_tokens: div(token_total, 2),
          codex_total_tokens: token_total
        }
      end)

    stale_running = [
      %{
        project_key: "proj-j",
        project_display_name: "项目癸",
        issue_id: "wide-stale-1",
        identifier: "MT-WIDE-STALE-01",
        state: "In Progress",
        runtime_status: "running",
        worker_host: "dm-wide-7",
        workspace_path: "/workspace/proj-j/MT-WIDE-STALE-01",
        attempt: 4,
        session_id: "wide-session-stale-01",
        turn_count: 11,
        last_codex_event: :notification,
        last_codex_message: "长时间未更新，应该进入左侧异常辅助列。",
        started_at: DateTime.add(now, -(3_600 + 12 * 60), :second),
        last_codex_timestamp: DateTime.add(now, -(14 * 60), :second),
        codex_input_tokens: 640,
        codex_output_tokens: 510,
        codex_total_tokens: 1_150
      }
    ]

    retrying = [
      %{
        project_key: "proj-h",
        project_display_name: "项目辛",
        issue_id: "wide-retry-1",
        identifier: "MT-WIDE-RETRY-01",
        attempt: 3,
        due_in_ms: 90_000,
        error: "等待下一次重试，重试窗口较长，需要在左侧辅助列出现滚动。",
        worker_host: "dm-wide-8",
        workspace_path: "/workspace/proj-h/MT-WIDE-RETRY-01",
        last_codex_timestamp: DateTime.add(now, -(7 * 60), :second)
      }
    ]

    blocked = [
      %{
        project_key: "proj-c",
        project_display_name: "项目丙",
        issue_id: "wide-blocked-1",
        identifier: "MT-WIDE-BLOCKED-01",
        state: "In Progress",
        runtime_status: "waiting_input",
        error: "等待人工输入，保留在左栏辅助处理。",
        worker_host: "dm-wide-9",
        workspace_path: "/workspace/proj-c/MT-WIDE-BLOCKED-01",
        session_id: "wide-session-blocked-01",
        blocked_at: DateTime.add(now, -(3 * 60), :second),
        last_codex_event: :turn_input_required,
        last_codex_message: "需要人工补充信息",
        last_codex_timestamp: DateTime.add(now, -(3 * 60), :second)
      },
      %{
        project_key: "proj-f",
        project_display_name: "项目己",
        issue_id: "wide-blocked-2",
        identifier: "MT-WIDE-BLOCKED-02",
        state: "In Progress",
        runtime_status: "approval_required",
        error: "等待审批确认，不能继续执行。",
        worker_host: "dm-wide-10",
        workspace_path: "/workspace/proj-f/MT-WIDE-BLOCKED-02",
        session_id: "wide-session-blocked-02",
        blocked_at: DateTime.add(now, -(5 * 60), :second),
        last_codex_event: :approval_required,
        last_codex_message: "等待审批",
        last_codex_timestamp: DateTime.add(now, -(5 * 60), :second)
      }
    ]

    recovery_events =
      Enum.map(1..8, fn index ->
        {project_key, project_name} = Enum.at(projects, rem(index - 1, length(projects)))

        %{
          project_key: project_key,
          project_display_name: project_name,
          issue_identifier: "超长恢复事件 #{pad2(index)}",
          recovery_attempt_count: rem(index, 4) + 1,
          last_event_at: DateTime.add(now, -(index * 90), :second)
        }
      end)

    total_tokens =
      healthy_running
      |> Enum.map(& &1.codex_total_tokens)
      |> Enum.sum()

    %{
      generated_at: DateTime.to_iso8601(now),
      projects: build_project_summaries(projects, healthy_running ++ stale_running, retrying, blocked),
      running: healthy_running ++ stale_running,
      retrying: retrying,
      blocked: blocked,
      recovery_events: recovery_events,
      codex_totals: %{
        input_tokens: div(total_tokens, 2),
        output_tokens: div(total_tokens, 2),
        total_tokens: total_tokens,
        seconds_running: 4_860.0
      },
      rate_limits: %{"primary" => %{"remaining" => 37}}
    }
  end

  defp wide_load_projects do
    [
      {"proj-a", "项目甲"},
      {"proj-b", "项目乙"},
      {"proj-c", "项目丙"},
      {"proj-d", "项目丁"},
      {"proj-e", "项目戊"},
      {"proj-f", "项目己"},
      {"proj-g", "项目庚"},
      {"proj-h", "项目辛"},
      {"proj-i", "项目壬"},
      {"proj-j", "项目癸"}
    ]
  end

  defp streaming_summary_snapshot do
    now = DateTime.utc_now()

    %{
      projects: [
        %{project_key: "proj-a", project_display_name: "项目甲", running_count: 1, retrying_count: 0, blocked_count: 0}
      ],
      running: [
        %{
          project_key: "proj-a",
          project_display_name: "项目甲",
          issue_id: "run-streaming",
          identifier: "MT-RUN-STREAMING",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev1",
          workspace_path: "/workspace/proj-a/MT-RUN-STREAMING",
          attempt: 1,
          session_id: "session-streaming",
          turn_count: 1,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              "method" => "item/agentMessage/delta",
              "params" => %{"textDelta" => "逐字跳动的碎片"}
            }
          },
          started_at: DateTime.add(now, -120, :second),
          last_codex_timestamp: DateTime.add(now, -15, :second),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22
        }
      ],
      retrying: [],
      blocked: [],
      recovery_events: [],
      codex_totals: %{input_tokens: 10, output_tokens: 12, total_tokens: 22, seconds_running: 0},
      rate_limits: nil
    }
  end

  defp historical_runtime_only_snapshot do
    %{
      projects: [
        %{project_key: "proj-a", project_display_name: "项目甲", running_count: 0, retrying_count: 0, blocked_count: 0}
      ],
      running: [],
      retrying: [],
      blocked: [],
      recovery_events: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 180},
      rate_limits: nil
    }
  end

  defp metric_token_snapshot do
    %{
      projects: [
        %{project_key: "proj-a", project_display_name: "项目甲", running_count: 0, retrying_count: 0, blocked_count: 0}
      ],
      running: [],
      retrying: [],
      blocked: [],
      recovery_events: [],
      codex_totals: %{input_tokens: 35_326, output_tokens: 1_984, total_tokens: 37_310, seconds_running: 57},
      rate_limits: nil
    }
  end

  defp future_started_at_snapshot do
    now = DateTime.utc_now()

    %{
      projects: [
        %{project_key: "proj-a", project_display_name: "项目甲", running_count: 1, retrying_count: 0, blocked_count: 0}
      ],
      running: [
        %{
          project_key: "proj-a",
          project_display_name: "项目甲",
          issue_id: "run-future",
          identifier: "MT-RUN-FUTURE",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev-future",
          workspace_path: "/workspace/proj-a/MT-RUN-FUTURE",
          attempt: 1,
          session_id: "session-future",
          turn_count: 1,
          last_codex_event: :notification,
          last_codex_message: "future start timestamp",
          started_at: DateTime.add(now, 120, :second),
          last_codex_timestamp: DateTime.add(now, -15, :second),
          codex_input_tokens: 5,
          codex_output_tokens: 8,
          codex_total_tokens: 13
        }
      ],
      retrying: [],
      blocked: [],
      recovery_events: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 180},
      rate_limits: nil
    }
  end

  defp checking_poll_snapshot do
    idle_snapshot()
    |> Map.put(:polling, %{checking?: true, next_poll_in_ms: nil, poll_interval_ms: 30_000})
  end

  defp build_project_summaries(projects, running, retrying, blocked) do
    Enum.map(projects, fn {project_key, project_name} ->
      %{
        project_key: project_key,
        project_display_name: project_name,
        running_count: count_project_entries(running, project_key),
        retrying_count: count_project_entries(retrying, project_key),
        blocked_count: count_project_entries(blocked, project_key)
      }
    end)
  end

  defp count_project_entries(entries, project_key) do
    Enum.count(entries, &(&1.project_key == project_key))
  end

  defp pad2(value) when is_integer(value) and value < 10, do: "0#{value}"
  defp pad2(value) when is_integer(value), do: Integer.to_string(value)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp count_occurrences(haystack, needle) when is_binary(haystack) and is_binary(needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end

  defp substring_index(haystack, needle) when is_binary(haystack) and is_binary(needle) do
    case :binary.match(haystack, needle) do
      {index, _length} -> index
      :nomatch -> nil
    end
  end

  defp html_attr!(html, selector, attr_name) do
    html
    |> find_selector!(selector)
    |> elem(1)
    |> List.keyfind(attr_name, 0)
    |> case do
      {^attr_name, value} -> value
      nil -> raise KeyError, key: attr_name, term: selector
    end
  end

  defp html_text!(html, selector) do
    html
    |> find_selector!(selector)
    |> Floki.text(sep: " ")
    |> String.trim()
  end

  defp owner_count(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> length()
  end

  defp missing_attr?(html, selector, attr_name) do
    html
    |> find_selector!(selector)
    |> elem(1)
    |> List.keyfind(attr_name, 0)
    |> is_nil()
  end

  defp find_selector!(html, selector) do
    case html |> Floki.parse_document!() |> Floki.find(selector) do
      [node] -> node
      [] -> flunk("selector not found: #{selector}")
      nodes -> flunk("selector returned #{length(nodes)} nodes: #{selector}")
    end
  end
end
