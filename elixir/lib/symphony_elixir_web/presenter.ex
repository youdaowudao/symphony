defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Orchestrator, ProjectRegistry, RuntimeStatus, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at_datetime = DateTime.utc_now() |> DateTime.truncate(:second)
    generated_at = DateTime.to_iso8601(generated_at_datetime)

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        project_display_names = project_display_names()
        running = Enum.map(snapshot.running, &running_entry_payload(with_project_display_name(&1, project_display_names), generated_at_datetime))
        retrying = Enum.map(snapshot.retrying, &retry_entry_payload(with_project_display_name(&1, project_display_names)))

        blocked =
          Enum.map(
            Map.get(snapshot, :blocked, []),
            &blocked_entry_payload(with_project_display_name(&1, project_display_names), generated_at_datetime)
          )

        stale_count = Enum.count(running, &(&1.runtime_status == "stale"))
        pending_count = pending_count(snapshot, generated_at_datetime)

        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, [])),
            stale: stale_count,
            pending: pending_count
          },
          projects: projects_payload(Map.get(snapshot, :projects, []), running, retrying, blocked, project_display_names),
          running: running,
          retrying: retrying,
          blocked: blocked,
          recovery_events: recovery_events_payload(Map.get(snapshot, :recovery_events, []), project_display_names),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits,
          polling: Map.get(snapshot, :polling, %{})
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found} | {:error, {:project_scope_required, String.t()}}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    generated_at_datetime = DateTime.utc_now() |> DateTime.truncate(:second)

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        case issue_matches(snapshot, issue_identifier) do
          [] ->
            {:error, :issue_not_found}

          :project_scope_required ->
            {:error, {:project_scope_required, "Issue identifier matches one or more entries without stable project scope; use /api/v1/projects/:project_key/issues/:issue_identifier"}}

          [{running, retry, blocked}] ->
            {:ok, issue_payload_body(issue_identifier, running, retry, blocked, generated_at_datetime)}

          _matches ->
            {:error, {:project_scope_required, "Issue identifier matches multiple projects; use /api/v1/projects/:project_key/issues/:issue_identifier"}}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec project_issue_payload(String.t(), String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found}
  def project_issue_payload(project_key, issue_identifier, orchestrator, snapshot_timeout_ms)
      when is_binary(project_key) and is_binary(issue_identifier) do
    generated_at_datetime = DateTime.utc_now() |> DateTime.truncate(:second)

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        {running, retry, blocked} = project_issue_entries(snapshot, project_key, issue_identifier)

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked, generated_at_datetime)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec clear_recovery_events(GenServer.name()) :: :ok | {:error, :unavailable}
  def clear_recovery_events(orchestrator) do
    case Orchestrator.clear_recovery_events(orchestrator) do
      :ok -> :ok
      _ -> {:error, :unavailable}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked, now) do
    project_key = project_key_from_entries(running, retry, blocked)
    project_display_name = project_display_name_from_entries(running, retry, blocked, project_key)

    %{
      project_key: project_key,
      project_display_name: project_display_name,
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      runtime_status: runtime_status(running, retry, blocked, now),
      workspace: %{
        path: workspace_path(running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running, now),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked, now),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp project_key_from_entries(running, retry, blocked),
    do: (running && Map.get(running, :project_key)) || (retry && Map.get(retry, :project_key)) || (blocked && Map.get(blocked, :project_key))

  defp project_display_name_from_entries(running, retry, blocked, fallback) do
    (running && Map.get(running, :project_display_name)) ||
      (retry && Map.get(retry, :project_display_name)) ||
      (blocked && Map.get(blocked, :project_display_name)) ||
      fallback
  end

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp runtime_status(running, retry, blocked, now) do
    RuntimeStatus.classify(running || blocked || retry, now)
    |> Atom.to_string()
  end

  defp runtime_status(entry, now) when is_map(entry), do: RuntimeStatus.classify(entry, now) |> Atom.to_string()

  defp running_entry_payload(entry, now) do
    %{
      project_key: Map.get(entry, :project_key),
      project_display_name: entry_project_display_name(entry),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      runtime_status: runtime_status(entry, now),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      attempt: normalize_attempt(Map.get(entry, :attempt, Map.get(entry, :retry_attempt))),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      summary_text: stable_summary_text(entry),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      project_key: Map.get(entry, :project_key),
      project_display_name: entry_project_display_name(entry),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      last_event_at: iso8601(Map.get(entry, :last_codex_timestamp)),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry, now) do
    %{
      project_key: Map.get(entry, :project_key),
      project_display_name: entry_project_display_name(entry),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      runtime_status: runtime_status(entry, now),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  defp running_issue_payload(running, now) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      runtime_status: runtime_status(running, now),
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked, now) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      runtime_status: runtime_status(blocked, now),
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp workspace_path(running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path))
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp stable_summary_text(entry) when is_map(entry) do
    message = Map.get(entry, :last_codex_message)
    fallback = summarize_message(message)
    streaming_summary = stable_streaming_summary(message)

    cond do
      streaming_summary != nil ->
        streaming_summary

      is_binary(fallback) and String.trim(fallback) != "" ->
        fallback

      true ->
        Map.get(entry, :last_codex_event) |> stable_event_label()
    end
  end

  defp stable_streaming_summary(%{message: message}), do: stable_streaming_summary(message)

  defp stable_streaming_summary(message) when is_map(message) do
    method =
      map_fetch(message, ["method"]) ||
        map_fetch(message, [:method]) ||
        map_fetch(message, ["payload", "method"]) ||
        map_fetch(message, [:payload, :method])

    cond do
      method in ["item/agentMessage/delta", "codex/event/item/agentMessage/delta"] ->
        "消息输出中"

      method in ["item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "codex/event/item/reasoning/textDelta"] ->
        "思考摘要生成中"

      method in ["item/commandExecution/outputDelta", "item/fileChange/outputDelta"] ->
        "命令输出更新中"

      true ->
        nil
    end
  end

  defp stable_streaming_summary(_message), do: nil

  defp stable_event_label(nil), do: "n/a"
  defp stable_event_label(:notification), do: "最近事件已更新"
  defp stable_event_label(:session_started), do: "session 已启动"
  defp stable_event_label(:turn_input_required), do: "等待人工输入"
  defp stable_event_label(:approval_required), do: "等待审批"
  defp stable_event_label(event) when is_atom(event), do: event |> Atom.to_string() |> String.replace("_", " ")
  defp stable_event_label(event) when is_binary(event) and event != "", do: event
  defp stable_event_label(_event), do: "n/a"

  defp map_fetch(data, [key]) when is_map(data), do: Map.get(data, key)

  defp map_fetch(data, [key | rest]) when is_map(data) do
    case Map.get(data, key) do
      nil -> nil
      value -> map_fetch(value, rest)
    end
  end

  defp map_fetch(_data, _path), do: nil

  defp recovery_events_payload(recovery_events, project_display_names) when is_list(recovery_events),
    do: Enum.map(recovery_events, &recovery_event_payload(&1, project_display_names))

  defp project_summary_payload(entry, project_display_names) do
    project_key = entry.project_key

    %{
      project_key: project_key,
      project_display_name: display_name_for_project(project_key, Map.get(entry, :project_display_name), project_display_names),
      running_count: Map.get(entry, :running_count, 0),
      retrying_count: Map.get(entry, :retrying_count, 0),
      blocked_count: Map.get(entry, :blocked_count, 0)
    }
  end

  defp projects_payload([], running, retrying, blocked, _project_display_names) do
    project_keys =
      (running ++ retrying ++ blocked)
      |> Enum.map(&entry_project_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.map(project_keys, fn project_key ->
      %{
        project_key: project_key,
        project_display_name:
          project_display_name_from_entries(
            Enum.find(running, &(entry_project_key(&1) == project_key)),
            Enum.find(retrying, &(entry_project_key(&1) == project_key)),
            Enum.find(blocked, &(entry_project_key(&1) == project_key)),
            project_key
          ),
        running_count: Enum.count(running, &(entry_project_key(&1) == project_key)),
        retrying_count: Enum.count(retrying, &(entry_project_key(&1) == project_key)),
        blocked_count: Enum.count(blocked, &(entry_project_key(&1) == project_key))
      }
    end)
  end

  defp projects_payload(projects, running, retrying, blocked, project_display_names) when is_list(projects) do
    Enum.map(projects, fn entry ->
      payload = project_summary_payload(entry, project_display_names)
      project_key = payload.project_key

      %{
        payload
        | running_count: Enum.count(running, &(entry_project_key(&1) == project_key)),
          retrying_count: Enum.count(retrying, &(entry_project_key(&1) == project_key)),
          blocked_count: Enum.count(blocked, &(entry_project_key(&1) == project_key))
      }
    end)
  end

  defp entry_project_key(entry) when is_map(entry) do
    Map.get(entry, :project_key) || Map.get(entry, "project_key")
  end

  defp entry_project_display_name(entry) when is_map(entry) do
    Map.get(entry, :project_display_name) || Map.get(entry, :project_key)
  end

  defp with_project_display_name(entry, project_display_names) when is_map(entry) do
    Map.put(
      entry,
      :project_display_name,
      display_name_for_project(
        Map.get(entry, :project_key),
        Map.get(entry, :project_display_name),
        project_display_names
      )
    )
  end

  defp recovery_event_payload(entry, project_display_names) when is_map(entry) do
    %{
      project_key: Map.get(entry, :project_key),
      project_display_name:
        display_name_for_project(
          Map.get(entry, :project_key),
          Map.get(entry, :project_display_name),
          project_display_names
        ),
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :issue_identifier) || Map.get(entry, :identifier),
      recovery_attempt_count: normalize_attempt(Map.get(entry, :recovery_attempt_count, Map.get(entry, :attempt))),
      last_event_at: iso8601(Map.get(entry, :last_event_at, Map.get(entry, :last_codex_timestamp))),
      last_message: summarize_message(Map.get(entry, :last_message, Map.get(entry, :last_codex_message))),
      session_id: Map.get(entry, :session_id)
    }
  end

  defp display_name_for_project(project_key, current_display_name, project_display_names) do
    Map.get(project_display_names, project_key) || current_display_name || project_key
  end

  defp pending_count(snapshot, now) do
    [
      Map.get(snapshot, :blocked, []),
      Map.get(snapshot, :retrying, []),
      snapshot.running
      |> Enum.filter(&(runtime_status(&1, now) == "stale"))
    ]
    |> List.flatten()
    |> Enum.map(&pending_entry_key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp pending_entry_key(entry) when is_map(entry) do
    Map.get(entry, :issue_id) || Map.get(entry, :identifier) || Map.get(entry, :issue_identifier)
  end

  defp normalize_attempt(attempt) when is_integer(attempt) and attempt >= 0, do: attempt
  defp normalize_attempt(_attempt), do: 0

  defp project_display_names do
    case canonical_project_registry_entries() do
      {:ok, entries} ->
        Map.new(entries, fn entry -> {entry.project_key, entry.display_name || entry.project_key} end)

      _ ->
        %{}
    end
  end

  defp project_registry_module do
    Application.get_env(:symphony_elixir, :project_registry_module, ProjectRegistry)
  end

  defp canonical_project_registry_entries do
    project_registry_module = project_registry_module()

    case project_registry_module do
      ProjectRegistry ->
        project_registry_module.normalized_entries(ProjectRegistry.default_path())

      _ ->
        project_registry_module.normalized_entries()
    end
  end

  defp issue_matches(snapshot, issue_identifier) do
    running_matches = Enum.filter(snapshot.running, &(Map.get(&1, :identifier) == issue_identifier))
    retry_matches = Enum.filter(snapshot.retrying, &(Map.get(&1, :identifier) == issue_identifier))
    blocked_matches = Enum.filter(Map.get(snapshot, :blocked, []), &(Map.get(&1, :identifier) == issue_identifier))

    matches = running_matches ++ retry_matches ++ blocked_matches
    missing_project_scope? = Enum.any?(matches, &is_nil(Map.get(&1, :project_key)))

    project_keys =
      matches
      |> Enum.map(&Map.get(&1, :project_key))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      matches == [] ->
        []

      missing_project_scope? ->
        :project_scope_required

      true ->
        Enum.map(project_keys, fn project_key -> project_issue_entries(snapshot, project_key, issue_identifier) end)
    end
  end

  defp project_issue_entries(snapshot, project_key, issue_identifier) do
    {
      Enum.find(snapshot.running, &(Map.get(&1, :project_key) == project_key and Map.get(&1, :identifier) == issue_identifier)),
      Enum.find(snapshot.retrying, &(Map.get(&1, :project_key) == project_key and Map.get(&1, :identifier) == issue_identifier)),
      Enum.find(Map.get(snapshot, :blocked, []), &(Map.get(&1, :project_key) == project_key and Map.get(&1, :identifier) == issue_identifier))
    }
  end

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
