# Usage: see test/support/dashboard_fixture_visual_review_README.md
System.put_env("MIX_ENV", System.get_env("MIX_ENV") || "test")

defmodule DashboardFixtureVisualCheckScript do
  @moduledoc false

  alias SymphonyElixir.TestSupport.DashboardUiFixtureScenarios

  @root Path.expand("../..", __DIR__)
  @default_viewports [{1440, 900}, {1920, 1080}]

  def run do
    Mix.start()

    Mix.Project.in_project(:symphony_elixir, @root, fn _project ->
      prepare_project!()
      Code.require_file(Path.join(@root, "test/support/dashboard_ui_fixture_scenarios.ex"))

      scenarios = scenarios!()
      viewports = viewports!()
      output_dir = output_dir!()
      chrome = chrome!()

      File.mkdir_p!(output_dir)
      IO.puts("Dashboard Fixture Visual Review screenshot script started.")
      IO.puts("scenarios=#{Enum.map_join(scenarios, ",", &Atom.to_string/1)}")

      IO.puts("viewports=#{Enum.map_join(viewports, ",", fn {width, height} -> "#{width}x#{height}" end)}")

      IO.puts("output_dir=#{output_dir}")

      results =
        Enum.flat_map(scenarios, fn scenario ->
          run_scenario(chrome, scenario, viewports, output_dir)
        end)

      write_manifest!(output_dir, results)

      IO.puts("Screenshot generation complete. Human confirmation is still required before UI visual acceptance can be claimed.")
    end)
  end

  defp prepare_project! do
    Mix.Task.run("loadconfig", [])
    Mix.Task.run("deps.loadpaths", [])
    Mix.Task.run("compile", [])

    {:ok, _apps} = Application.ensure_all_started(:phoenix_live_view)
    {:ok, _apps} = Application.ensure_all_started(:inets)
  end

  defp scenarios! do
    value = System.get_env("SYMPHONY_DASHBOARD_FIXTURE", "all")

    case String.downcase(String.trim(value)) do
      "all" ->
        DashboardUiFixtureScenarios.scenario_names()

      scenario ->
        [DashboardUiFixtureScenarios.normalize_scenario(scenario)]
    end
  end

  defp viewports! do
    case System.get_env("SYMPHONY_DASHBOARD_VIEWPORTS") do
      nil ->
        @default_viewports

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&parse_viewport!/1)
    end
  end

  defp parse_viewport!(value) do
    case Regex.run(~r/^(\d+)x(\d+)$/, String.trim(value)) do
      [_match, width, height] ->
        {String.to_integer(width), String.to_integer(height)}

      _ ->
        raise ArgumentError, "viewport must use WIDTHxHEIGHT format, got #{inspect(value)}"
    end
  end

  defp output_dir! do
    System.get_env("SYMPHONY_DASHBOARD_SCREENSHOT_DIR") ||
      Path.join(@root, "tmp/dashboard_fixture_visual_review")
  end

  defp chrome! do
    Enum.find_value(
      ["google-chrome", "chromium", "chromium-browser", "google-chrome-stable"],
      &System.find_executable/1
    ) ||
      raise "Chrome executable not found; install Chrome/Chromium or run the preview server manually"
  end

  defp run_scenario(chrome, scenario, viewports, output_dir) do
    snapshot = DashboardUiFixtureScenarios.scenario(scenario)
    resources = start_preview!(scenario, snapshot)

    try do
      wait_for_http!(resources.url)

      Enum.map(viewports, fn {width, height} ->
        path = Path.join(output_dir, "dashboard_fixture_#{scenario}_#{width}x#{height}.png")
        take_screenshot!(chrome, resources.url, width, height, path)

        IO.puts("screenshot_generated scenario=#{scenario} viewport=#{width}x#{height} path=#{path}")

        %{
          scenario: scenario,
          viewport: "#{width}x#{height}",
          path: path,
          script_started: "yes",
          screenshot_generated: "yes",
          obvious_overflow_review: "not_performed_by_script",
          human_confirmation: "required"
        }
      end)
    after
      cleanup(resources)
    end
  end

  defp start_preview!(scenario, snapshot) do
    pubsub_supervisor = ensure_pubsub!()
    orchestrator_name = Module.concat(__MODULE__, :"FixtureOrchestrator#{scenario}")

    {:ok, orchestrator_pid} =
      __MODULE__.FixtureOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

    {:ok, endpoint_pid} =
      SymphonyElixir.HttpServer.start_link(
        host: "127.0.0.1",
        port: 0,
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 50
      )

    port = SymphonyElixir.HttpServer.bound_port()
    url = "http://127.0.0.1:#{port}/"

    IO.puts("script_started scenario=#{scenario} url=#{url}")

    %{
      pubsub_supervisor: pubsub_supervisor,
      orchestrator_pid: orchestrator_pid,
      endpoint_pid: endpoint_pid,
      url: url
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

  defp wait_for_http!(url) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_wait_for_http!(String.to_charlist(url), deadline)
  end

  defp do_wait_for_http!(url, deadline) do
    case :httpc.request(:get, {url, []}, [], []) do
      {:ok, {{_version, status, _reason}, _headers, _body}} when status in 200..399 ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "preview server did not respond before timeout"
        else
          Process.sleep(100)
          do_wait_for_http!(url, deadline)
        end
    end
  end

  defp take_screenshot!(chrome, url, width, height, path) do
    {output, exit_code} =
      System.cmd(
        chrome,
        [
          "--headless=new",
          "--disable-gpu",
          "--no-sandbox",
          "--window-size=#{width},#{height}",
          "--screenshot=#{path}",
          url
        ],
        stderr_to_stdout: true
      )

    if exit_code != 0 or not File.exists?(path) do
      raise "Chrome screenshot failed with exit #{exit_code}: #{output}"
    end

    :ok
  end

  defp write_manifest!(output_dir, results) do
    rows =
      Enum.map(results, fn result ->
        "| #{result.scenario} | #{result.viewport} | #{result.script_started} | #{result.screenshot_generated} | #{result.obvious_overflow_review} | #{result.human_confirmation} | #{result.path} |"
      end)

    content =
      [
        "# Dashboard Fixture Visual Review Evidence",
        "",
        "- script_started: yes",
        "- screenshot_generated: see rows below",
        "- obvious_overflow_review: not_performed_by_script unless a human or AI reviewer records mechanical issues separately",
        "- human_visual_confirmation: required; not confirmed by this script",
        "",
        "| Scenario | Viewport | Script started | Screenshot generated | AI obvious-overflow review | Human visual confirmation | Path |",
        "| --- | --- | --- | --- | --- | --- | --- |",
        rows,
        ""
      ]
      |> List.flatten()
      |> Enum.join("\n")

    manifest_path = Path.join(output_dir, "dashboard_fixture_visual_review_evidence.md")
    File.write!(manifest_path, content)
    IO.puts("evidence_manifest=#{manifest_path}")
  end

  defp cleanup(resources) do
    stop_pid(resources.endpoint_pid)
    stop_pid(resources.orchestrator_pid)

    case resources.pubsub_supervisor do
      {:owned, supervisor} -> stop_pid(supervisor)
      {:external, _pid} -> :ok
    end
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
         operations: ["fixture-screenshot"]
       }, state}
    end

    def handle_call(:clear_recovery_events, _from, state) do
      snapshot = Map.put(state.snapshot, :recovery_events, [])
      {:reply, :ok, %{state | snapshot: snapshot}}
    end
  end
end

DashboardFixtureVisualCheckScript.run()
