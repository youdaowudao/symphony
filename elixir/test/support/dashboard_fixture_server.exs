# Usage: see test/support/dashboard_fixture_visual_review_README.md
System.put_env("MIX_ENV", System.get_env("MIX_ENV") || "test")

defmodule DashboardFixtureServerScript do
  @moduledoc false

  alias SymphonyElixir.TestSupport.DashboardUiFixtureScenarios

  @root Path.expand("../..", __DIR__)

  def run do
    Mix.start()

    Mix.Project.in_project(:symphony_elixir, @root, fn _project ->
      prepare_project!()
      Code.require_file(Path.join(@root, "test/support/dashboard_ui_fixture_scenarios.ex"))

      scenario = fixture_scenario!()
      snapshot = DashboardUiFixtureScenarios.scenario(scenario)

      resources = start_preview!(scenario, snapshot)

      try do
        wait_for_exit()
      after
        cleanup(resources)
      end
    end)
  end

  defp prepare_project! do
    Mix.Task.run("loadconfig", [])
    Mix.Task.run("deps.loadpaths", [])
    Mix.Task.run("compile", [])

    {:ok, _apps} = Application.ensure_all_started(:phoenix_live_view)
  end

  defp fixture_scenario! do
    scenario = System.get_env("SYMPHONY_DASHBOARD_FIXTURE", "small")

    if scenario == "all" do
      raise ArgumentError,
            "preview server supports one scenario at a time; use small, saturated, or extreme"
    end

    DashboardUiFixtureScenarios.normalize_scenario(scenario)
  end

  defp start_preview!(scenario, snapshot) do
    pubsub_supervisor = ensure_pubsub!()
    orchestrator_name = Module.concat(__MODULE__, FixtureOrchestrator)

    {:ok, orchestrator_pid} =
      __MODULE__.FixtureOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    port =
      System.get_env("SYMPHONY_DASHBOARD_FIXTURE_PORT", "0")
      |> parse_port!()

    {:ok, endpoint_pid} =
      SymphonyElixir.HttpServer.start_link(
        host: "127.0.0.1",
        port: port,
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 50
      )

    bound_port = SymphonyElixir.HttpServer.bound_port()
    url = "http://127.0.0.1:#{bound_port}/"

    IO.puts("Dashboard Fixture Visual Review")
    IO.puts("scenario=#{scenario}")
    IO.puts("url=#{url}")
    IO.puts("Press Ctrl+C to stop. UI visual acceptance still requires human confirmation.")

    %{
      pubsub_supervisor: pubsub_supervisor,
      orchestrator_pid: orchestrator_pid,
      endpoint_pid: endpoint_pid
    }
  end

  defp ensure_pubsub! do
    case Process.whereis(SymphonyElixir.PubSub) do
      pid when is_pid(pid) ->
        {:external, pid}

      nil ->
        {:ok, supervisor} =
          Supervisor.start_link([{Phoenix.PubSub, name: SymphonyElixir.PubSub}],
            strategy: :one_for_one
          )

        {:owned, supervisor}
    end
  end

  defp wait_for_exit do
    parent = self()
    trapped_signals = trap_shutdown_signals(parent)

    try do
      receive do
        :stop -> :ok
      end
    after
      Enum.each(trapped_signals, fn {signal, id} -> System.untrap_signal(signal, id) end)
    end
  end

  defp trap_shutdown_signals(parent) do
    [:sigterm, :sighup, :sigquit]
    |> Enum.flat_map(&trap_shutdown_signal(&1, parent))
  end

  defp notify_stop(parent) do
    send(parent, :stop)
    :ok
  end

  defp trap_shutdown_signal(signal, parent) do
    case System.trap_signal(signal, fn -> notify_stop(parent) end) do
      {:ok, id} -> [{signal, id}]
      {:error, _reason} -> []
    end
  end

  defp cleanup(resources) do
    stop_pid(resources.endpoint_pid)
    stop_pid(resources.orchestrator_pid)

    case resources.pubsub_supervisor do
      {:owned, supervisor} -> stop_pid(supervisor)
      {:external, _pid} -> :ok
    end

    IO.puts("Dashboard Fixture Visual Review preview server stopped.")
  end

  defp stop_pid(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end

    :ok
  catch
    :exit, _reason ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :ok
  end

  defp parse_port!(value) do
    case Integer.parse(value) do
      {port, ""} when port >= 0 -> port
      _ -> raise ArgumentError, "SYMPHONY_DASHBOARD_FIXTURE_PORT must be a non-negative integer"
    end
  end

  defmodule FixtureOrchestrator do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts), do: {:ok, %{snapshot: Keyword.fetch!(opts, :snapshot)}}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

    def handle_call(:request_refresh, _from, state) do
      {:reply,
       %{
         queued: false,
         coalesced: true,
         requested_at: DateTime.utc_now(),
         operations: ["fixture-preview"]
       }, state}
    end

    def handle_call(:clear_recovery_events, _from, state) do
      snapshot = Map.put(state.snapshot, :recovery_events, [])
      {:reply, :ok, %{state | snapshot: snapshot}}
    end
  end
end

DashboardFixtureServerScript.run()
