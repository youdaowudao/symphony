defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}
  alias SymphonyElixir.Workspace.{DispatchContext, OwnerFile}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  @spec prepare_dispatch_workspace(map()) :: {:ok, Path.t()} | {:error, term()}
  def prepare_dispatch_workspace(attrs) when is_map(attrs) do
    with {:ok, context} <- DispatchContext.new(attrs) do
      do_prepare_dispatch_workspace(context)
    end
  end

  @spec cleanup_workspace(map()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def cleanup_workspace(attrs) when is_map(attrs) do
    with {:ok, context} <- DispatchContext.new(attrs),
         true <- DispatchContext.cleanup_ready?(context) || {:error, :cleanup_context_missing, ""},
         raw_workspace_path when is_binary(raw_workspace_path) <- context.workspace_path,
         :ok <- validate_workspace_path(raw_workspace_path, context.worker_host),
         {:ok, context} <- canonicalize_cleanup_context(context),
         {:ok, owner} <- read_owner_for_cleanup(context),
         true <- OwnerFile.ownership_matches?(context, owner) || {:error, :owner_mismatch, ""},
         workspace_path when is_binary(workspace_path) <- context.workspace_path,
         :ok <- maybe_run_before_remove_hook(workspace_path, context.issue_identifier, context.worker_host) do
      remove_workspace_path(workspace_path, context.worker_host)
    else
      {:error, reason, output} ->
        {:error, reason, output}

      {:error, reason} ->
        {:error, reason, ""}

      false ->
        {:error, :cleanup_context_missing, ""}
    end
  end

  @spec cleanup_startup_terminal_issue_workspace(String.t(), String.t()) :: :ok
  def cleanup_startup_terminal_issue_workspace(project_key, issue_identifier)
      when is_binary(project_key) and is_binary(issue_identifier) do
    with {:ok, valid_project_key} <- DispatchContext.validate_project_key(project_key),
         {:ok, valid_issue_identifier} <- validate_startup_issue_identifier(issue_identifier),
         project_root <- Path.join(Config.settings!().workspace.root, valid_project_key),
         :ok <- ensure_project_workspace_root(project_root),
         {:ok, workspace_paths} <- startup_workspace_candidates(project_root) do
      workspace_paths
      |> Enum.each(&cleanup_startup_workspace_path(&1, valid_project_key, valid_issue_identifier, issue_identifier, project_key))

      :ok
    else
      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup for issue_identifier=#{issue_identifier} project_key=#{project_key}: cleanup_failed: #{inspect(reason)}")

        :ok
    end
  end

  def cleanup_startup_terminal_issue_workspace(_project_key, _issue_identifier), do: :ok

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, nil, worker_host)
    remove_workspace_path(workspace, worker_host)
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp do_prepare_dispatch_workspace(%DispatchContext{} = context) do
    workspace_path = dispatch_workspace_path(context)

    with {:ok, canonical_workspace_path} <- canonicalize_workspace_path(workspace_path, context.worker_host),
         context = DispatchContext.with_workspace_path(context, canonical_workspace_path),
         :ok <- validate_workspace_path(canonical_workspace_path, context.worker_host),
         {:ok, canonical_workspace_path, created?} <- ensure_dispatch_workspace(canonical_workspace_path, context),
         :ok <-
           maybe_run_after_create_hook(
             canonical_workspace_path,
             issue_context(context),
             created?,
             context.worker_host
           ) do
      {:ok, canonical_workspace_path}
    end
  end

  defp ensure_dispatch_workspace(workspace_path, %DispatchContext{} = context) do
    case workspace_exists?(workspace_path, context.worker_host) do
      true ->
        with {:ok, owner} <- read_owner_for_workspace(context),
             true <- OwnerFile.ownership_matches?(context, owner) || {:error, :owner_mismatch} do
          {:ok, workspace_path, false}
        else
          {:error, {:owner_unreadable, _reason}} -> {:error, :owner_unreadable}
          {:error, reason} -> {:error, reason}
        end

      false ->
        with {:ok, workspace_path, true} <- ensure_workspace(workspace_path, context.worker_host),
             :ok <- write_owner_file(context) do
          {:ok, workspace_path, true}
        end
    end
  end

  defp read_owner_for_workspace(%DispatchContext{worker_host: nil, workspace_path: workspace_path}) do
    OwnerFile.read(workspace_path)
  end

  defp read_owner_for_workspace(%DispatchContext{} = context) do
    read_owner_for_cleanup(context)
  end

  defp write_owner_file(%DispatchContext{} = context) do
    created_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    if is_nil(context.worker_host) do
      OwnerFile.write!(context, created_at)
      :ok
    else
      write_remote_owner_file(context, created_at)
    end
  end

  defp write_remote_owner_file(%DispatchContext{} = context, created_at) do
    owner_path = OwnerFile.absolute_path(context.workspace_path)

    owner_payload =
      Jason.encode!(%{
        schema_version: 1,
        project_key: context.project_key,
        issue_id: context.issue_id,
        issue_identifier: context.issue_identifier,
        worker_host: context.worker_host,
        workspace_path: context.workspace_path,
        attempt: context.attempt,
        created_at: created_at
      })

    script =
      [
        "set -eu",
        remote_shell_assign("owner_path", owner_path),
        "mkdir -p \"$(dirname \"$owner_path\")\"",
        "cat <<'__SYMPHONY_OWNER__' > \"$owner_path\"",
        owner_payload,
        "__SYMPHONY_OWNER__"
      ]
      |> Enum.join("\n")

    case run_remote_command(context.worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:workspace_prepare_failed, context.worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, issue_identifier, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: issue_identifier || Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, issue_identifier, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: issue_identifier || Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    with :ok <- validate_remote_workspace_path_string(workspace),
         {:ok, canonical_workspace_root} <- canonicalize_remote_root(worker_host),
         {:ok, canonical_workspace} <- canonicalize_remote_path(workspace, worker_host) do
      canonical_root_prefix = canonical_workspace_root <> "/"

      cond do
        canonical_workspace == canonical_workspace_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_workspace_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_workspace_root}}
      end
    else
      {:error, {:workspace_path_unreadable, _path, _reason} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:workspace_path_unreadable, workspace, reason}}
    end
  end

  defp validate_remote_workspace_path_string(workspace) when is_binary(workspace) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    marker_payload = find_remote_workspace_marker(lines)

    case marker_payload do
      {created?, workspace} ->
        {:ok, workspace, created?}

      nil ->
        parse_remote_workspace_fallback(lines, output)
    end
  end

  defp find_remote_workspace_marker(lines) when is_list(lines) do
    Enum.find_value(lines, fn line ->
      case String.split(line, "\t", parts: 3) do
        [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
          {created == "1", path}

        _ ->
          nil
      end
    end)
  end

  defp parse_remote_workspace_fallback(lines, output) when is_list(lines) do
    case lines do
      [workspace] when is_binary(workspace) and workspace != "" ->
        {:ok, workspace, true}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp cleanup_startup_workspace_path(workspace_path, valid_project_key, valid_issue_identifier, issue_identifier, project_key) do
    case maybe_cleanup_startup_workspace(workspace_path, valid_project_key, valid_issue_identifier) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Skipping startup terminal workspace cleanup for issue_identifier=#{issue_identifier} project_key=#{project_key} workspace_path=#{workspace_path}: cleanup_failed: #{inspect(reason)}"
        )
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp remove_workspace_path(workspace, nil) do
    File.rm_rf(workspace)
  end

  defp remove_workspace_path(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp dispatch_workspace_path(%DispatchContext{} = context) do
    Config.settings!().workspace.root
    |> Path.join(context.project_key)
    |> Path.join(DispatchContext.path_segment(context))
  end

  defp canonicalize_workspace_path(workspace_path, nil) when is_binary(workspace_path) do
    PathSafety.canonicalize(workspace_path)
  end

  defp canonicalize_workspace_path(workspace_path, worker_host)
       when is_binary(workspace_path) and is_binary(worker_host) do
    canonicalize_remote_path(workspace_path, worker_host)
  end

  defp canonicalize_remote_path(workspace_path, worker_host)
       when is_binary(workspace_path) and is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace_path),
        "workspace_dir=\"$(dirname \"$workspace\")\"",
        "workspace_base=\"$(basename \"$workspace\")\"",
        "mkdir -p \"$workspace_dir\"",
        "cd \"$workspace_dir\" >/dev/null 2>&1",
        "canonical_parent=\"$(pwd -P)\"",
        "canonical_workspace=\"$canonical_parent/$workspace_base\"",
        "if [ -d \"$workspace\" ]; then",
        "  cd \"$workspace\" >/dev/null 2>&1",
        "  pwd -P",
        "elif [ -L \"$workspace\" ]; then",
        "  if cd \"$workspace\" >/dev/null 2>&1; then",
        "    pwd -P",
        "  else",
        "    printf '%s\\n' \"$canonical_workspace\"",
        "  fi",
        "else",
        "  printf '%s\\n' \"$canonical_workspace\"",
        "fi"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        output
        |> IO.iodata_to_binary()
        |> String.split("\n", trim: true)
        |> List.last()
        |> case do
          nil -> {:error, {:workspace_prepare_failed, :invalid_output, output}}
          expanded -> {:ok, expanded}
        end

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp canonicalize_remote_root(worker_host) when is_binary(worker_host) do
    root = Config.settings!().workspace.root

    script =
      [
        "set -eu",
        remote_shell_assign("workspace_root", root),
        "mkdir -p \"$workspace_root\"",
        "cd \"$workspace_root\" >/dev/null 2>&1",
        "pwd -P"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        output
        |> IO.iodata_to_binary()
        |> String.split("\n", trim: true)
        |> List.last()
        |> case do
          nil -> {:error, :invalid_output}
          expanded -> {:ok, expanded}
        end

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_exists?(workspace_path, nil), do: File.dir?(workspace_path)

  defp workspace_exists?(workspace_path, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace_path),
        "if [ -d \"$workspace\" ]; then printf '1'; else printf '0'; fi"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} -> String.trim(IO.iodata_to_binary(output)) == "1"
      _ -> false
    end
  end

  defp canonicalize_cleanup_context(%DispatchContext{workspace_path: workspace_path, worker_host: worker_host} = context) do
    with {:ok, canonical_workspace_path} <- canonicalize_workspace_path(workspace_path, worker_host) do
      {:ok, DispatchContext.with_workspace_path(context, canonical_workspace_path)}
    end
  end

  defp read_owner_for_cleanup(%DispatchContext{worker_host: nil, workspace_path: workspace_path}) do
    OwnerFile.read(workspace_path)
  end

  defp read_owner_for_cleanup(%DispatchContext{} = context) do
    owner_path = OwnerFile.absolute_path(context.workspace_path)

    script =
      [
        "set -eu",
        remote_shell_assign("owner_path", owner_path),
        "cat \"$owner_path\""
      ]
      |> Enum.join("\n")

    case run_remote_command(context.worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        OwnerFile.decode(IO.iodata_to_binary(output))

      {:ok, {_output, _status}} ->
        {:error, :owner_missing}

      {:error, reason} ->
        {:error, {:owner_unreadable, reason}}
    end
  end

  defp ensure_project_workspace_root(project_root) when is_binary(project_root) do
    case File.dir?(project_root) do
      true -> validate_workspace_path(project_root, nil)
      false -> :ok
    end
  end

  defp startup_workspace_candidates(project_root) when is_binary(project_root) do
    case File.ls(project_root) do
      {:ok, entries} -> {:ok, Enum.map(entries, &Path.join(project_root, &1))}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:workspace_path_unreadable, project_root, reason}}
    end
  end

  defp maybe_cleanup_startup_workspace(workspace_path, project_key, issue_identifier) do
    with true <- File.dir?(workspace_path) || {:error, :workspace_missing},
         :ok <- validate_workspace_path(workspace_path, nil),
         {:ok, canonical_workspace_path} <- canonicalize_workspace_path(workspace_path, nil),
         {:ok, owner} <- OwnerFile.read(canonical_workspace_path),
         true <-
           startup_owner_matches?(owner, project_key, issue_identifier, canonical_workspace_path) ||
             {:error, :owner_mismatch},
         :ok <- maybe_run_before_remove_hook(canonical_workspace_path, issue_identifier, nil),
         {:ok, _removed_paths} <- remove_workspace_path(canonical_workspace_path, nil) do
      :ok
    else
      false ->
        {:error, :workspace_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp startup_owner_matches?(owner, project_key, issue_identifier, workspace_path)
       when is_map(owner) and is_binary(project_key) and is_binary(issue_identifier) and is_binary(workspace_path) do
    owner["project_key"] == project_key and
      owner["issue_identifier"] == issue_identifier and
      owner["worker_host"] == nil and
      owner["workspace_path"] == workspace_path
  end

  defp startup_owner_matches?(_owner, _project_key, _issue_identifier, _workspace_path), do: false

  defp validate_startup_issue_identifier(issue_identifier) do
    trimmed = String.trim(issue_identifier)

    if trimmed == "" do
      {:error, :cleanup_context_missing}
    else
      {:ok, trimmed}
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(%DispatchContext{} = context) do
    %{
      issue_id: context.issue_id,
      issue_identifier: context.issue_identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
