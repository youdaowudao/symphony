defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      bootstrap_linear_token: fn _workflow_path ->
        send(parent, :bootstrap_linear_token_called)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :bootstrap_linear_token_called
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      bootstrap_linear_token: fn _workflow_path -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      bootstrap_linear_token: fn _workflow_path -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      bootstrap_linear_token: fn _workflow_path -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      bootstrap_linear_token: fn _workflow_path -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "dev-source startup helper returns usage when port is invalid" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      bootstrap_linear_token: fn _workflow_path ->
        send(parent, :bootstrap_linear_token_called)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"} =
             CLI.evaluate_dev_source("abc", deps)

    refute_received :file_checked
    refute_received :workflow_set
    refute_received :port_set
    refute_received :bootstrap_linear_token_called
    refute_received :started
  end

  test "dev-source startup helper rejects whitespace-padded port like CLI" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      bootstrap_linear_token: fn _workflow_path ->
        send(parent, :bootstrap_linear_token_called)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, "Usage: symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]"} =
             CLI.evaluate_dev_source(" 1 ", deps)

    refute_received :file_checked
    refute_received :workflow_set
    refute_received :port_set
    refute_received :bootstrap_linear_token_called
    refute_received :started
  end

  test "dev-source startup helper defaults to WORKFLOW.md and reuses CLI not found semantics" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      bootstrap_linear_token: fn _workflow_path -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate_dev_source("0", deps)
    assert message =~ "Workflow file not found:"
    assert message =~ Path.expand("WORKFLOW.md")
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      bootstrap_linear_token: fn _workflow_path -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "fails closed before ensure_all_started when token bootstrap fails" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      bootstrap_linear_token: fn workflow_path ->
        send(parent, {:bootstrap_linear_token, workflow_path})
        {:error, "Linear token bootstrap failed from project_registry.yaml token path"}
      end,
      ensure_all_started: fn ->
        send(parent, :ensure_all_started_called)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, "Linear token bootstrap failed from project_registry.yaml token path"} =
             CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)

    assert_received {:bootstrap_linear_token, workflow_path}
    assert Path.basename(workflow_path) == "WORKFLOW.md"
    refute_received :ensure_all_started_called
  end

  test "fails closed before startup when workflow cannot be loaded for bootstrap decision" do
    parent = self()
    workflow_root = Path.join(System.tmp_dir!(), "symphony-cli-invalid-workflow-#{System.unique_integer([:positive])}")
    workflow_path = Path.join(workflow_root, "WORKFLOW.md")

    File.mkdir_p!(workflow_root)
    File.write!(workflow_path, "---\ntracker: [oops\n---\nprompt\n")

    on_exit(fn -> File.rm_rf(workflow_root) end)

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      bootstrap_linear_token: fn bootstrap_workflow_path ->
        send(parent, {:bootstrap_linear_token_called, bootstrap_workflow_path})
        SymphonyElixir.LinearTokenBootstrap.bootstrap_if_needed(bootstrap_workflow_path)
      end,
      ensure_all_started: fn ->
        send(parent, :ensure_all_started_called)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, message} = CLI.run(workflow_path, deps)
    assert message =~ "Linear token bootstrap failed: failed to load workflow at #{workflow_path}:"
    assert_received {:bootstrap_linear_token_called, ^workflow_path}
    refute_received :ensure_all_started_called
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      bootstrap_linear_token: fn _workflow_path -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end
end
