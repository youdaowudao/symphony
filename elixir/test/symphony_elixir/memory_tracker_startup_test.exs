defmodule SymphonyElixir.MemoryTrackerStartupTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LinearTokenBootstrap

  test "CLI delegates linear token bootstrap for memory tracker workflows" do
    parent = self()
    workflow_path = Workflow.workflow_file_path()
    write_workflow_file!(workflow_path, tracker_kind: "memory")

    deps = %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      bootstrap_linear_token: fn path ->
        send(parent, {:bootstrap_linear_token_called, path})
        LinearTokenBootstrap.bootstrap_if_needed(path)
      end,
      ensure_all_started: fn ->
        send(parent, :ensure_all_started_called)
        {:ok, [:symphony_elixir]}
      end
    }

    assert :ok = CLI.run(workflow_path, deps)
    assert_received {:bootstrap_linear_token_called, ^workflow_path}
    assert_received :ensure_all_started_called
  end

  test "bootstrap_if_needed no-ops for memory tracker workflows without project registry" do
    workflow_path = Workflow.workflow_file_path()
    write_workflow_file!(workflow_path, tracker_kind: "memory")

    registry_path = Path.join(Path.dirname(workflow_path), "project_registry.yaml")

    refute File.exists?(registry_path)
    assert :ok = LinearTokenBootstrap.bootstrap_if_needed(workflow_path)
    assert Application.get_env(:symphony_elixir, :linear_api_token) == "test-linear-token"
  end

  test "bootstrap_if_needed fails closed when workflow cannot be loaded" do
    workflow_path = Workflow.workflow_file_path()
    File.write!(workflow_path, "---\ntracker: [oops\n---\nprompt\n")

    assert {:error, message} = LinearTokenBootstrap.bootstrap_if_needed(workflow_path)
    assert message =~ "Linear token bootstrap failed: failed to load workflow at #{workflow_path}:"
  end

  @tag timeout: 120_000
  test "dev-source matches CLI missing workflow error semantics" do
    project_root = create_dev_source_project_fixture!(link_workflow?: false)

    {cli_output, cli_status} = run_cli_startup_check(project_root, ["0"])
    {script_output, script_status} = run_dev_source(project_root, "0")

    assert cli_status == 1, cli_output
    assert script_status == 1, script_output

    expected_message =
      "Workflow file not found: #{Path.join(project_root, "WORKFLOW.md")}"

    assert cli_output =~ expected_message
    assert script_output =~ expected_message
    refute script_output =~ "Linear token bootstrap failed"
  end

  @tag timeout: 120_000
  test "dev-source matches CLI invalid port failure semantics" do
    project_root = create_dev_source_project_fixture!(link_workflow?: true)

    {cli_output, cli_status} = run_cli_startup_check(project_root, ["abc"])
    {script_output, script_status} = run_dev_source(project_root, "abc")

    assert cli_status == 1, cli_output
    assert script_status == 1, script_output

    expected_message = "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"

    assert cli_output =~ expected_message
    assert script_output =~ expected_message
    refute script_output =~ "Protocol.UndefinedError"
    refute script_output =~ "** (ArgumentError)"
    refute script_output =~ "** (SyntaxError)"
  end

  @tag timeout: 120_000
  test "dev-source matches CLI whitespace-padded port failure semantics" do
    project_root = create_dev_source_project_fixture!(link_workflow?: true)

    {cli_output, cli_status} = run_cli_startup_check(project_root, [" 1 "])
    {script_output, script_status} = run_dev_source(project_root, " 1 ")

    assert cli_status == 1, cli_output
    assert script_status == 1, script_output

    expected_message = "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"

    assert cli_output =~ expected_message
    assert script_output =~ expected_message
    refute script_output =~ "Workflow file not found:"
    refute script_output =~ "Linear token bootstrap failed"
  end

  @tag timeout: 120_000
  test "CLI startup path succeeds for memory tracker workflows without project_registry.yaml" do
    workflow_path = Workflow.workflow_file_path()
    workflow_root = Path.dirname(workflow_path)
    registry_path = Path.join(workflow_root, "project_registry.yaml")
    write_workflow_file!(workflow_path, tracker_kind: "memory")

    refute File.exists?(registry_path)

    expr = """
    case SymphonyElixir.CLI.evaluate([
           "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
           "--port",
           "0",
           #{inspect(workflow_path)}
         ]) do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
    """

    {output, exit_status} =
      System.cmd("mix", ["run", "--no-start", "-e", expr],
        cd: Path.expand("../..", __DIR__),
        env: [{"MIX_ENV", "test"}, {"SYMPHONY_TEST_MAX_CASES", "4"}],
        stderr_to_stdout: true
      )

    assert exit_status == 0, output
    refute output =~ "Linear token bootstrap failed"
    refute output =~ "project_registry.yaml"
  end

  defp run_cli_startup_check(project_root, port_args) do
    expr = """
    case SymphonyElixir.CLI.evaluate_dev_source(hd(System.argv())) do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
    """

    System.cmd("mix", ["run", "--no-start", "-e", expr | port_args],
      cd: project_root,
      env: [{"MIX_ENV", "test"}, {"SYMPHONY_TEST_MAX_CASES", "4"}],
      stderr_to_stdout: true
    )
  end

  defp run_dev_source(project_root, port_arg) do
    System.cmd(Path.join(project_root, "bin/dev-source"), [port_arg],
      cd: project_root,
      env: [{"MIX_ENV", "test"}, {"SYMPHONY_TEST_MAX_CASES", "4"}],
      stderr_to_stdout: true
    )
  end

  defp create_dev_source_project_fixture!(opts) do
    unique = System.unique_integer([:positive, :monotonic])
    project_root = Path.join(System.tmp_dir!(), "symphony-dev-source-fixture-#{unique}")
    source_root = Path.expand("../..", __DIR__)

    File.mkdir_p!(project_root)
    on_exit(fn -> File.rm_rf(project_root) end)

    Enum.each(~w(_build bin config deps lib mix.exs mix.lock mise.toml priv), fn entry ->
      File.ln_s!(Path.join(source_root, entry), Path.join(project_root, entry))
    end)

    if Keyword.get(opts, :link_workflow?, false) do
      File.ln_s!(Path.join(source_root, "WORKFLOW.md"), Path.join(project_root, "WORKFLOW.md"))
    end

    project_root
  end
end
