defmodule SymphonyElixir.DashboardLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

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
  end

  test "dashboard renders wide-screen shell with top summary, dual columns, project summary, and todo pool placeholder" do
    orchestrator_name = Module.concat(__MODULE__, :WideShellOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: wide_snapshot(), refresh: :unavailable})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Operations Dashboard"
    assert html =~ "Current exceptions"
    assert html =~ "Running sessions"
    assert html =~ "Projects"
    assert html =~ "todo pool"
    assert html =~ "blocked-by"
    assert html =~ "Manual check"
  end

  test "dashboard current exceptions only include blocked, retrying, and stale running entries" do
    orchestrator_name = Module.concat(__MODULE__, :CurrentExceptionsOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: wide_snapshot(), refresh: :unavailable})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")
    exceptions_html = view |> element(".column-alerts") |> render()

    assert exceptions_html =~ "MT-BLOCKED"
    assert exceptions_html =~ "MT-RETRY"
    assert exceptions_html =~ "MT-STALE"
    refute exceptions_html =~ "MT-RUN-HEALTHY"
  end

  test "dashboard current exceptions are deduplicated, ordered by source priority and age, and show session plus relative time" do
    orchestrator_name = Module.concat(__MODULE__, :ExceptionOrderingOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: wide_snapshot_with_exception_priority(), refresh: :unavailable})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")
    exceptions_html = view |> element(".column-alerts") |> render()

    blocked_index = substring_index(exceptions_html, "MT-BLOCKED-OLD")
    retry_index = substring_index(exceptions_html, "MT-RETRY-OLD")
    stale_index = substring_index(exceptions_html, "MT-STALE-OLD")

    assert blocked_index
    assert retry_index
    assert stale_index
    assert blocked_index < retry_index
    assert retry_index < stale_index
    assert exceptions_html =~ "thread-blocked-old"
    assert exceptions_html =~ "thread-stale-old"
    assert exceptions_html =~ "2 minutes ago"
    assert exceptions_html =~ "6 minutes ago"
    assert exceptions_html =~ "11 minutes ago"
    assert count_occurrences(exceptions_html, "MT-DUPLICATE") == 1
  end

  test "dashboard running main list excludes stale rows and still keeps low-priority project summary visible" do
    orchestrator_name = Module.concat(__MODULE__, :RunningListOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: wide_snapshot(), refresh: :unavailable})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "MT-RUN-HEALTHY"
    refute html =~ "workspace/project-a/MT-RUN-HEALTHY"
    assert html =~ "project-b"
    assert html =~ "0"
  end

  test "dashboard healthy running list sorts oldest latest update first and shows relative last update time" do
    orchestrator_name = Module.concat(__MODULE__, :RunningOrderOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: wide_snapshot_with_running_order(), refresh: :unavailable})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")
    running_html = view |> element(".column-running") |> render()

    oldest_index = substring_index(running_html, "MT-RUN-OLDEST")
    newer_index = substring_index(running_html, "MT-RUN-NEWER")
    newest_index = substring_index(running_html, "MT-RUN-NEWEST")

    assert oldest_index
    assert newer_index
    assert newest_index
    assert oldest_index < newer_index
    assert newer_index < newest_index
    assert running_html =~ "9 minutes ago"
    assert running_html =~ "5 minutes ago"
    assert running_html =~ "2 minutes ago"
  end

  test "dashboard keeps the last successful frame visible when a later snapshot fails" do
    orchestrator_name = Module.concat(__MODULE__, :StaleBannerOrchestrator)

    start_supervised!(
      {StaticOrchestrator,
       name: orchestrator_name,
       snapshot: wide_snapshot(),
       refresh: :unavailable}
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    send(view.pid, :observability_updated)
    assert render(view) =~ "MT-RUN-HEALTHY"

    :sys.replace_state(orchestrator_name, fn state ->
      Keyword.put(state, :snapshot, :unavailable)
    end)

    send(view.pid, :observability_updated)

    assert_eventually(fn ->
      html = render(view)

      html =~ "Snapshot unavailable" and
        html =~ "Last successful update" and
        html =~ "MT-RUN-HEALTHY"
    end, 40)
  end

  test "runtime tick reclassifies stale running rows into current exceptions" do
    orchestrator_name = Module.concat(__MODULE__, :RuntimeTickStaleOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: wide_snapshot_with_borderline_running(), refresh: :unavailable})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    assert render(view) =~ "MT-BORDERLINE"

    assert_eventually(fn ->
      send(view.pid, :runtime_tick)
      alerts = view |> element(".column-alerts") |> render()
      running = view |> element(".column-running") |> render()

      alerts =~ "MT-BORDERLINE" and not (running =~ "MT-BORDERLINE")
    end, 80)
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

  defp wide_snapshot do
    now = DateTime.utc_now()
    stale_time = DateTime.add(now, -(11 * 60), :second)

    %{
      projects: [
        %{project_key: "project-a", project_display_name: "project-a", running_count: 2, retrying_count: 1, blocked_count: 1},
        %{project_key: "project-b", project_display_name: "project-b", running_count: 0, retrying_count: 0, blocked_count: 0}
      ],
      running: [
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "issue-stale",
          identifier: "MT-STALE",
          state: "In Progress",
          runtime_status: "stale",
          worker_host: "dm-dev1",
          workspace_path: "/workspace/project-a/MT-STALE",
          session_id: "thread-stale",
          turn_count: 3,
          last_codex_event: :notification,
          last_codex_message: "stale update",
          started_at: DateTime.add(now, -900, :second),
          last_codex_timestamp: stale_time,
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22
        },
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "issue-healthy",
          identifier: "MT-RUN-HEALTHY",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev2",
          workspace_path: "/workspace/project-a/MT-RUN-HEALTHY",
          session_id: "thread-healthy",
          turn_count: 7,
          last_codex_event: :notification,
          last_codex_message: "healthy update",
          started_at: DateTime.add(now, -240, :second),
          last_codex_timestamp: now,
          codex_input_tokens: 20,
          codex_output_tokens: 30,
          codex_total_tokens: 50
        }
      ],
      retrying: [
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 60_000,
          error: "boom",
          worker_host: "dm-dev3",
          workspace_path: "/workspace/project-a/MT-RETRY"
        }
      ],
      blocked: [
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          state: "In Progress",
          runtime_status: "waiting_input",
          error: "needs approval",
          worker_host: "dm-dev4",
          workspace_path: "/workspace/project-a/MT-BLOCKED",
          session_id: "thread-blocked",
          blocked_at: DateTime.add(now, -120, :second),
          last_codex_event: :turn_input_required,
          last_codex_message: "waiting for input",
          last_codex_timestamp: DateTime.add(now, -120, :second)
        }
      ],
      codex_totals: %{input_tokens: 30, output_tokens: 42, total_tokens: 72, seconds_running: 180.0},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wide_snapshot_with_exception_priority do
    now = DateTime.utc_now()

    %{
      projects: [
        %{project_key: "project-a", project_display_name: "project-a", running_count: 3, retrying_count: 2, blocked_count: 2}
      ],
      running: [
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "stale-old",
          identifier: "MT-STALE-OLD",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev1",
          workspace_path: "/workspace/project-a/MT-STALE-OLD",
          session_id: "thread-stale-old",
          turn_count: 2,
          last_codex_event: :notification,
          last_codex_message: "stale old",
          started_at: DateTime.add(now, -900, :second),
          last_codex_timestamp: DateTime.add(now, -(11 * 60), :second),
          codex_input_tokens: 4,
          codex_output_tokens: 6,
          codex_total_tokens: 10
        },
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "duplicate-1",
          identifier: "MT-DUPLICATE",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev2",
          workspace_path: "/workspace/project-a/MT-DUPLICATE",
          session_id: "thread-duplicate",
          turn_count: 2,
          last_codex_event: :notification,
          last_codex_message: "duplicate stale source",
          started_at: DateTime.add(now, -700, :second),
          last_codex_timestamp: DateTime.add(now, -(12 * 60), :second),
          codex_input_tokens: 3,
          codex_output_tokens: 4,
          codex_total_tokens: 7
        }
      ],
      retrying: [
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "retry-old",
          identifier: "MT-RETRY-OLD",
          attempt: 2,
          due_in_ms: 60_000,
          error: "retry old",
          worker_host: "dm-dev3",
          workspace_path: "/workspace/project-a/MT-RETRY-OLD",
          last_codex_timestamp: DateTime.add(now, -(6 * 60), :second)
        },
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "duplicate-1",
          identifier: "MT-DUPLICATE",
          attempt: 3,
          due_in_ms: 30_000,
          error: "duplicate retry source",
          worker_host: "dm-dev4",
          workspace_path: "/workspace/project-a/MT-DUPLICATE",
          last_codex_timestamp: DateTime.add(now, -(5 * 60), :second)
        }
      ],
      blocked: [
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "blocked-old",
          identifier: "MT-BLOCKED-OLD",
          state: "In Progress",
          runtime_status: "waiting_input",
          error: "needs approval",
          worker_host: "dm-dev5",
          workspace_path: "/workspace/project-a/MT-BLOCKED-OLD",
          session_id: "thread-blocked-old",
          blocked_at: DateTime.add(now, -(2 * 60), :second),
          last_codex_event: :turn_input_required,
          last_codex_message: "blocked old",
          last_codex_timestamp: DateTime.add(now, -(2 * 60), :second)
        },
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "duplicate-1",
          identifier: "MT-DUPLICATE",
          state: "In Progress",
          runtime_status: "waiting_input",
          error: "duplicate blocked source",
          worker_host: "dm-dev6",
          workspace_path: "/workspace/project-a/MT-DUPLICATE",
          session_id: "thread-duplicate-blocked",
          blocked_at: DateTime.add(now, -(4 * 60), :second),
          last_codex_event: :turn_input_required,
          last_codex_message: "duplicate blocked",
          last_codex_timestamp: DateTime.add(now, -(4 * 60), :second)
        }
      ],
      codex_totals: %{input_tokens: 10, output_tokens: 10, total_tokens: 20, seconds_running: 120.0},
      rate_limits: nil
    }
  end

  defp wide_snapshot_with_running_order do
    now = DateTime.utc_now()

    %{
      projects: [
        %{project_key: "project-a", project_display_name: "project-a", running_count: 3, retrying_count: 0, blocked_count: 0}
      ],
      running: [
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "run-newest",
          identifier: "MT-RUN-NEWEST",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev1",
          workspace_path: "/workspace/project-a/MT-RUN-NEWEST",
          session_id: "thread-run-newest",
          turn_count: 1,
          last_codex_event: :notification,
          last_codex_message: "newest update",
          started_at: DateTime.add(now, -180, :second),
          last_codex_timestamp: DateTime.add(now, -(2 * 60), :second),
          codex_input_tokens: 1,
          codex_output_tokens: 1,
          codex_total_tokens: 2
        },
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "run-oldest",
          identifier: "MT-RUN-OLDEST",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev2",
          workspace_path: "/workspace/project-a/MT-RUN-OLDEST",
          session_id: "thread-run-oldest",
          turn_count: 1,
          last_codex_event: :notification,
          last_codex_message: "oldest update",
          started_at: DateTime.add(now, -840, :second),
          last_codex_timestamp: DateTime.add(now, -(9 * 60), :second),
          codex_input_tokens: 2,
          codex_output_tokens: 3,
          codex_total_tokens: 5
        },
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "run-newer",
          identifier: "MT-RUN-NEWER",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev3",
          workspace_path: "/workspace/project-a/MT-RUN-NEWER",
          session_id: "thread-run-newer",
          turn_count: 1,
          last_codex_event: :notification,
          last_codex_message: "newer update",
          started_at: DateTime.add(now, -480, :second),
          last_codex_timestamp: DateTime.add(now, -(5 * 60), :second),
          codex_input_tokens: 2,
          codex_output_tokens: 2,
          codex_total_tokens: 4
        }
      ],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 5, output_tokens: 6, total_tokens: 11, seconds_running: 120.0},
      rate_limits: nil
    }
  end

  defp wide_snapshot_with_borderline_running do
    now = DateTime.utc_now()

    %{
      projects: [
        %{project_key: "project-a", project_display_name: "project-a", running_count: 1, retrying_count: 0, blocked_count: 0}
      ],
      running: [
        %{
          project_key: "project-a",
          project_display_name: "project-a",
          issue_id: "issue-borderline",
          identifier: "MT-BORDERLINE",
          state: "In Progress",
          runtime_status: "running",
          worker_host: "dm-dev1",
          workspace_path: "/workspace/project-a/MT-BORDERLINE",
          session_id: "thread-borderline",
          turn_count: 2,
          last_codex_event: :notification,
          last_codex_message: "borderline update",
          started_at: DateTime.add(now, -900, :second),
          last_codex_timestamp: DateTime.add(now, -(10 * 60), :second),
          codex_input_tokens: 4,
          codex_output_tokens: 5,
          codex_total_tokens: 9
        }
      ],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 4, output_tokens: 5, total_tokens: 9, seconds_running: 120.0},
      rate_limits: nil
    }
  end

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
end
