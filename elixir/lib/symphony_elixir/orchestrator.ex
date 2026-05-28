defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, ProjectRegistry, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker.ProjectCandidate

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @recovery_event_limit 20
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      recovery_events: [],
      codex_totals: nil,
      codex_rate_limits: nil,
      codex_rate_limits_observed_at_ms: nil,
      worker_host_backoffs: %{}
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil,
      codex_rate_limits_observed_at_ms: nil,
      worker_host_backoffs: %{}
    }

    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_runtime_key_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      runtime_key ->
        issue_id = runtime_issue_id(runtime_key)
        {running_entry, state} = pop_running_entry(state, runtime_key)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry) || "n/a"

        state = handle_agent_down(reason, state, runtime_key, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case resolve_runtime_key(running, issue_id, runtime_info[:project_key]) do
      nil ->
        {:noreply, state}

      current_runtime_key ->
        updated_running_entry =
          running
          |> Map.fetch!(current_runtime_key)
          |> maybe_put_runtime_value(:project_key, runtime_info[:project_key])
          |> maybe_put_runtime_value(:issue_id, runtime_info[:issue_id])
          |> maybe_put_runtime_value(:issue_identifier, runtime_info[:issue_identifier])
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> maybe_put_runtime_value(:attempt, runtime_info[:attempt])

        next_runtime_key =
          runtime_key_from_metadata(
            runtime_info[:project_key],
            runtime_info[:issue_id] || issue_id,
            current_runtime_key
          )

        running =
          running
          |> Map.delete(current_runtime_key)
          |> Map.put(next_runtime_key, updated_running_entry)

        notify_dashboard()

        {:noreply,
         %{
           state
           | running: running,
             claimed: migrate_runtime_identity(state.claimed, current_runtime_key, next_runtime_key)
         }}
    end
  end

  def handle_info({:codex_runtime_binding, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case resolve_runtime_key(running, issue_id, runtime_info[:project_key]) do
      nil ->
        {:noreply, state}

      runtime_key ->
        updated_running_entry =
          running
          |> Map.fetch!(runtime_key)
          |> maybe_put_runtime_value(:project_key, runtime_info[:project_key])
          |> maybe_put_runtime_value(:codex_app_server_pid, runtime_info[:codex_app_server_pid])
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, runtime_key, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case resolve_runtime_key_for_update(running, issue_id, update) do
      nil ->
        {:noreply, state}

      runtime_key ->
        running_entry = Map.fetch!(running, runtime_key)
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, runtime_key, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, runtime_identity, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, runtime_identity, retry_token) do
        {:ok, runtime_key, attempt, metadata, state} ->
          handle_retry_issue(state, runtime_key, attempt, metadata)

        :missing ->
          {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _runtime_identity}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(:normal, state, runtime_key, running_entry, session_id) do
    issue_id = runtime_issue_id(runtime_key)
    continuation_attempt = Map.get(running_entry, :attempt, 1)

    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, runtime_key, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(runtime_key)
      |> schedule_issue_retry(runtime_key, 1, %{
        identifier: running_entry.identifier,
        delay_type: :continuation,
        project_key: Map.get(running_entry, :project_key),
        issue_id: issue_id,
        issue_identifier: Map.get(running_entry, :issue_identifier, running_entry.identifier),
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        attempt: continuation_attempt
      })
    end
  end

  defp handle_agent_down(reason, state, runtime_key, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, runtime_key, running_entry, session_id, reason)
    else
      retry_agent_down(state, runtime_key, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, runtime_key, running_entry, session_id, reason) do
    issue_id = runtime_issue_id(runtime_key)
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, runtime_key, running_entry, error)
  end

  defp retry_agent_down(state, runtime_key, running_entry, session_id, reason) do
    issue_id = runtime_issue_id(runtime_key)
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)
    state = maybe_pause_worker_host_for_failure(state, running_entry, reason, next_attempt)

    schedule_issue_retry(state, runtime_key, next_attempt, %{
      identifier: running_entry.identifier,
      error: "agent exited: #{inspect(reason)}",
      project_key: Map.get(running_entry, :project_key),
      issue_id: issue_id,
      issue_identifier: Map.get(running_entry, :issue_identifier, running_entry.identifier),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      attempt: next_attempt
    })
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> refresh_codex_rate_limits()
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()

    with :ok <- Config.validate!(),
         {:ok, project_result} <- Tracker.fetch_project_candidates(),
         true <- available_slots(state) > 0,
         true <- codex_dispatch_allowed?(state) do
      choose_project_issues(project_result, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing from project_registry.yaml token path bootstrap")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_runtime_keys = Map.keys(state.running)
    {project_runtime_keys, legacy_runtime_keys} = Enum.split_with(running_runtime_keys, &project_runtime_identity?/1)

    state =
      reconcile_project_running_runtime_keys(
        state,
        project_runtime_keys,
        active_state_set(),
        terminal_state_set()
      )

    reconcile_legacy_running_runtime_keys(
      state,
      legacy_runtime_keys,
      active_state_set(),
      terminal_state_set()
    )
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_runtime_keys = Map.keys(state.blocked)
    {project_runtime_keys, legacy_runtime_keys} = Enum.split_with(blocked_runtime_keys, &project_runtime_identity?/1)

    state =
      reconcile_project_blocked_runtime_keys(
        state,
        project_runtime_keys,
        active_state_set(),
        terminal_state_set()
      )

    reconcile_legacy_blocked_runtime_keys(
      state,
      legacy_runtime_keys,
      active_state_set(),
      terminal_state_set()
    )
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_blocked_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_project_candidate_for_test(Issue.t(), String.t(), pos_integer(), term()) ::
          boolean()
  def should_dispatch_project_candidate_for_test(
        %Issue{} = issue,
        project_key,
        project_limit,
        %State{} = state
      ) do
    should_dispatch_project_candidate?(
      issue,
      project_key,
      project_limit,
      state,
      active_state_set(),
      terminal_state_set()
    )
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec revalidate_project_issue_for_dispatch_for_test(
          Issue.t(),
          String.t(),
          (String.t() -> {:ok, term()} | {:error, term()})
        ) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_project_issue_for_dispatch_for_test(%Issue{} = issue, project_key, project_fetcher)
      when is_binary(project_key) and is_function(project_fetcher, 1) do
    revalidate_project_issue_for_dispatch(issue, project_key, project_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec runtime_key_for_test(String.t(), String.t()) :: {String.t(), String.t()}
  def runtime_key_for_test(project_key, issue_id), do: runtime_key(project_key, issue_id)

  @doc false
  @spec project_slots_available_for_test(String.t(), pos_integer(), map()) :: boolean()
  def project_slots_available_for_test(project_key, project_limit, running) do
    project_slots_available?(project_key, project_limit, running)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    running_runtime_keys = reconcile_runtime_keys(state.running, issue.id, issue_project_key(issue))

    Enum.reduce(running_runtime_keys, state, fn runtime_key, state_acc ->
      reconcile_runtime_issue_state(runtime_key, issue, state_acc, active_states, terminal_states)
    end)
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    blocked_runtime_keys = reconcile_runtime_keys(state.blocked, issue.id, issue_project_key(issue))

    Enum.reduce(blocked_runtime_keys, state, fn runtime_key, state_acc ->
      reconcile_blocked_runtime_issue_state(runtime_key, issue, state_acc, active_states, terminal_states)
    end)
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_project_running_runtime_keys(state, [], _active_states, _terminal_states), do: state

  defp reconcile_project_running_runtime_keys(state, runtime_keys, active_states, terminal_states) do
    all_states = Config.settings!().tracker.active_states ++ Config.settings!().tracker.terminal_states

    case Tracker.fetch_project_issues_by_states(all_states) do
      {:ok, %{candidates: candidates, project_results: project_results}} ->
        Enum.reduce(runtime_keys, state, fn runtime_key, state_acc ->
          reconcile_project_running_runtime_key(
            state_acc,
            runtime_key,
            candidates,
            project_results,
            active_states,
            terminal_states
          )
        end)

      {:error, reason} ->
        Logger.debug("Failed to refresh project-aware running issue states: #{inspect(reason)}; keeping active workers")
        state
    end
  end

  defp reconcile_project_running_runtime_key(state, runtime_key, candidates, project_results, active_states, terminal_states) do
    project_key = runtime_project_key(runtime_key)
    issue_id = runtime_issue_id(runtime_key)

    case project_result_status(project_results, project_key) do
      :failed ->
        state

      nil ->
        state

      _ ->
        case find_project_issue_by_key_and_id(candidates, project_key, issue_id) do
          %Issue{} = issue ->
            reconcile_runtime_issue_state(runtime_key, issue, state, active_states, terminal_states)

          nil ->
            log_missing_running_issue(state, runtime_key)
            terminate_running_issue(state, runtime_key, false)
        end
    end
  end

  defp reconcile_legacy_running_runtime_keys(state, [], _active_states, _terminal_states), do: state

  defp reconcile_legacy_running_runtime_keys(state, runtime_keys, active_states, terminal_states) do
    issue_ids = Enum.map(runtime_keys, &runtime_issue_id/1) |> Enum.uniq()

    case Tracker.fetch_issue_states_by_ids(issue_ids) do
      {:ok, issues} ->
        issues
        |> reconcile_running_issue_states(
          state,
          active_states,
          terminal_states
        )
        |> reconcile_missing_running_issue_ids(runtime_keys, issues)

      {:error, reason} ->
        Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")
        state
    end
  end

  defp reconcile_project_blocked_runtime_keys(state, [], _active_states, _terminal_states), do: state

  defp reconcile_project_blocked_runtime_keys(state, runtime_keys, active_states, terminal_states) do
    all_states = Config.settings!().tracker.active_states ++ Config.settings!().tracker.terminal_states

    case Tracker.fetch_project_issues_by_states(all_states) do
      {:ok, %{candidates: candidates, project_results: project_results}} ->
        Enum.reduce(runtime_keys, state, fn runtime_key, state_acc ->
          reconcile_project_blocked_runtime_key(
            state_acc,
            runtime_key,
            candidates,
            project_results,
            active_states,
            terminal_states
          )
        end)

      {:error, reason} ->
        Logger.debug("Failed to refresh project-aware blocked issue states: #{inspect(reason)}; keeping blocked issues")
        state
    end
  end

  defp reconcile_project_blocked_runtime_key(state, runtime_key, candidates, project_results, active_states, terminal_states) do
    project_key = runtime_project_key(runtime_key)
    issue_id = runtime_issue_id(runtime_key)

    case project_result_status(project_results, project_key) do
      :failed ->
        state

      nil ->
        state

      _ ->
        case find_project_issue_by_key_and_id(candidates, project_key, issue_id) do
          %Issue{} = issue ->
            reconcile_blocked_runtime_issue_state(runtime_key, issue, state, active_states, terminal_states)

          nil ->
            Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
            release_issue_claim(state, runtime_key)
        end
    end
  end

  defp reconcile_legacy_blocked_runtime_keys(state, [], _active_states, _terminal_states), do: state

  defp reconcile_legacy_blocked_runtime_keys(state, runtime_keys, active_states, terminal_states) do
    issue_ids = Enum.map(runtime_keys, &runtime_issue_id/1) |> Enum.uniq()

    case Tracker.fetch_issue_states_by_ids(issue_ids) do
      {:ok, issues} ->
        issues
        |> reconcile_blocked_issue_states(
          state,
          active_states,
          terminal_states
        )
        |> reconcile_missing_blocked_issue_ids(runtime_keys, issues)

      {:error, reason} ->
        Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")
        state
    end
  end

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn runtime_identity, state_acc ->
      issue_id = runtime_issue_id(runtime_identity)

      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, runtime_identity)
        terminate_running_issue(state_acc, runtime_identity, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn runtime_identity, state_acc ->
      issue_id = runtime_issue_id(runtime_identity)

      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, runtime_identity)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, runtime_identity) do
    issue_id = runtime_issue_id(runtime_identity)

    case resolve_runtime_key(state.running, issue_id, runtime_project_key(runtime_identity)) do
      nil ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")

      runtime_key ->
        case Map.get(state.running, runtime_key) do
          %{identifier: identifier} ->
            Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

          _ ->
            Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
        end
    end
  end

  defp log_missing_running_issue(_state, _runtime_identity), do: :ok

  defp update_running_runtime_key(%State{} = state, runtime_key, %Issue{} = issue) do
    case Map.get(state.running, runtime_key) do
      %{issue: _} = running_entry ->
        updated_entry = running_entry |> Map.put(:issue, issue) |> ensure_runtime_entry_identity(runtime_key)
        %{state | running: Map.put(state.running, runtime_key, updated_entry)}

      _ ->
        state
    end
  end

  defp update_blocked_runtime_key(%State{} = state, runtime_key, %Issue{} = issue) do
    case Map.get(state.blocked, runtime_key) do
      %{issue: _} = blocked_entry ->
        updated_entry = blocked_entry |> Map.put(:issue, issue) |> ensure_runtime_entry_identity(runtime_key)
        %{state | blocked: Map.put(state.blocked, runtime_key, updated_entry)}

      _ ->
        state
    end
  end

  defp runtime_entry_identity_consistent?(runtime_key, entry) when is_tuple(runtime_key) and is_map(entry) do
    stable_project_key?(runtime_project_key(runtime_key)) and
      Map.get(entry, :project_key) == runtime_project_key(runtime_key) and
      Map.get(entry, :issue_id, runtime_issue_id(runtime_key)) == runtime_issue_id(runtime_key)
  end

  defp runtime_entry_identity_consistent?(runtime_key, entry) when is_binary(runtime_key) and is_map(entry) do
    issue_id = runtime_issue_id(runtime_key)
    entry_project_key = Map.get(entry, :project_key)
    entry_issue_id = Map.get(entry, :issue_id, issue_id)

    entry_issue_id == issue_id and (is_nil(entry_project_key) or entry_project_key == "")
  end

  defp runtime_entry_identity_consistent?(_runtime_key, _entry), do: false

  defp ensure_runtime_entry_identity(entry, runtime_key) when is_map(entry) do
    entry
    |> Map.put(:issue_id, runtime_issue_id(runtime_key))
    |> maybe_put_runtime_project_key(runtime_project_key(runtime_key))
  end

  defp maybe_put_runtime_project_key(entry, project_key) when is_binary(project_key), do: Map.put(entry, :project_key, project_key)
  defp maybe_put_runtime_project_key(entry, _project_key), do: Map.delete(entry, :project_key)

  defp drop_malformed_runtime_entry(%State{} = state, runtime_key, container) do
    issue_id = runtime_issue_id(runtime_key)
    project_key = runtime_project_key(runtime_key)

    Logger.warning("Malformed runtime identity detected; stopping automatic progression issue_id=#{issue_id} project_key=#{inspect(project_key)} container=#{container}")

    release_issue_claim(state, runtime_key)
  end

  defp runtime_snapshot_issue_id({_, issue_id}) when is_binary(issue_id), do: issue_id
  defp runtime_snapshot_issue_id(issue_id) when is_binary(issue_id), do: issue_id
  defp runtime_snapshot_issue_id(runtime_identity), do: inspect(runtime_identity)

  defp retry_snapshot_entry(now_ms, runtime_identity, %{attempt: attempt, due_at_ms: due_at_ms} = retry) do
    %{
      issue_id: runtime_snapshot_issue_id(runtime_identity),
      project_key: Map.get(retry, :project_key) || runtime_project_key(runtime_identity),
      attempt: attempt,
      due_in_ms: max(0, due_at_ms - now_ms),
      identifier: Map.get(retry, :identifier),
      error: Map.get(retry, :error),
      last_codex_timestamp: Map.get(retry, :last_codex_timestamp),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp retry_snapshot_entry(_now_ms, _runtime_identity, _retry), do: nil

  defp snapshot_projects(running, retrying, blocked) do
    project_registry_entries()
    |> Enum.filter(&Map.get(&1, :enabled, false))
    |> Enum.map(fn entry ->
      project_key = entry.project_key

      %{
        project_key: project_key,
        project_display_name: entry.display_name || project_key,
        running_count: Enum.count(running, &(Map.get(&1, :project_key) == project_key)),
        retrying_count: Enum.count(retrying, &(Map.get(&1, :project_key) == project_key)),
        blocked_count: Enum.count(blocked, &(Map.get(&1, :project_key) == project_key))
      }
    end)
  end

  defp project_registry_entries do
    case canonical_project_registry_entries() do
      {:ok, entries} when is_list(entries) -> entries
      _ -> []
    end
  end

  defp reconcile_runtime_issue_state(runtime_key, %Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")
        terminate_running_issue(state, runtime_key, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")
        terminate_running_issue(state, runtime_key, false)

      active_issue_state?(issue.state, active_states) ->
        update_running_runtime_key(state, runtime_key, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")
        terminate_running_issue(state, runtime_key, false)
    end
  end

  defp reconcile_blocked_runtime_issue_state(runtime_key, %Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        cleanup_blocked_issue_workspace(state, runtime_key, issue)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, runtime_key)

      active_issue_state?(issue.state, active_states) ->
        update_blocked_runtime_key(state, runtime_key, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, runtime_key)
    end
  end

  defp terminate_running_issue(%State{} = state, runtime_identity, cleanup_workspace) do
    case Map.get(state.running, runtime_identity) do
      nil ->
        release_issue_claim(state, runtime_identity)

      %{pid: pid, ref: ref} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        stop_running_task(pid, ref)

        cleanup_result =
          if cleanup_workspace do
            cleanup_running_issue_workspace(state, runtime_identity, running_entry)
          else
            :ok
          end

        finalize_running_termination(state, runtime_identity, running_entry, cleanup_result)

      _ ->
        release_issue_claim(state, runtime_identity)
    end
  end

  defp finalize_running_termination(state, runtime_identity, _running_entry, :ok) do
    removal_keys = exact_runtime_identity_keys(runtime_identity)

    %{
      state
      | running: drop_runtime_keys(state.running, removal_keys),
        claimed: drop_runtime_keys(state.claimed, removal_keys),
        blocked: drop_runtime_keys(state.blocked, removal_keys),
        retry_attempts: drop_runtime_keys(state.retry_attempts, removal_keys)
    }
  end

  defp finalize_running_termination(state, runtime_identity, running_entry, {:error, reason}) do
    state =
      block_issue_from_entry(
        state,
        runtime_identity,
        running_entry,
        "cleanup_failed: #{inspect(reason)}"
      )

    %{state | running: drop_runtime_keys(state.running, [runtime_identity])}
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {runtime_identity, running_entry}, state_acc ->
          maybe_restart_stalled_issue(state_acc, runtime_identity, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_restart_stalled_issue(state, runtime_identity, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, runtime_identity) do
      state
    else
      restart_stalled_issue(state, runtime_identity, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, runtime_identity, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      issue_id = runtime_issue_id(runtime_identity)
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry) || "n/a"

      if input_required_blocker?(running_entry) do
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(runtime_identity, running_entry, error)
      else
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state
        |> terminate_running_issue(runtime_identity, false)
        |> schedule_issue_retry(runtime_identity, next_attempt, %{
          identifier: identifier,
          error: "stalled for #{elapsed_ms}ms without codex activity",
          project_key: Map.get(running_entry, :project_key),
          issue_id: issue_id,
          issue_identifier: Map.get(running_entry, :issue_identifier, identifier),
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path),
          attempt: next_attempt
        })
      end
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp stop_running_task(pid, ref) do
    if is_pid(pid) do
      terminate_task(pid)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, runtime_identity, running_entry, error) do
    stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref))
    block_issue_from_entry(state, runtime_identity, running_entry, error)
  end

  defp block_issue_from_entry(%State{} = state, runtime_identity, running_entry, error) do
    runtime_key =
      runtime_key_from_metadata(
        Map.get(running_entry, :project_key),
        Map.get(running_entry, :issue_id, runtime_issue_id(runtime_identity)),
        runtime_identity
      )

    if runtime_entry_identity_consistent?(runtime_key, running_entry) do
      do_block_issue_from_entry(state, runtime_identity, runtime_key, running_entry, error)
    else
      drop_malformed_runtime_entry(state, runtime_key, :blocked)
    end
  end

  defp do_block_issue_from_entry(%State{} = state, runtime_identity, runtime_key, running_entry, error) do
    issue_id = runtime_issue_id(runtime_key)

    blocked_entry =
      %{
        issue_id: issue_id,
        identifier: Map.get(running_entry, :identifier, issue_id),
        issue_identifier: Map.get(running_entry, :issue_identifier, Map.get(running_entry, :identifier, issue_id)),
        issue: Map.get(running_entry, :issue),
        project_key: Map.get(running_entry, :project_key),
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        attempt: Map.get(running_entry, :attempt, Map.get(running_entry, :retry_attempt)),
        session_id: running_entry_session_id(running_entry),
        error: error,
        blocked_at: DateTime.utc_now(),
        last_codex_message: Map.get(running_entry, :last_codex_message),
        last_codex_event: Map.get(running_entry, :last_codex_event),
        last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
      }
      |> ensure_runtime_entry_identity(runtime_key)

    removal_keys = runtime_identity_keys_from_state(state, runtime_identity)

    %{
      state
      | running: drop_runtime_keys(state.running, removal_keys),
        retry_attempts: drop_runtime_keys(state.retry_attempts, removal_keys),
        claimed: ensure_runtime_identity_claimed(drop_runtime_keys(state.claimed, removal_keys), runtime_key),
        blocked: state.blocked |> drop_runtime_keys(removal_keys) |> Map.put(runtime_key, blocked_entry)
    }
  end

  defp choose_project_issues(%{candidates: candidates}, state) when is_list(candidates) do
    candidates
    |> sort_project_candidates_for_dispatch()
    |> Enum.reduce(state, fn candidate, state_acc ->
      case candidate do
        %ProjectCandidate{
          issue: %Issue{} = issue,
          project_context: %{project_key: project_key, max_concurrent_agents: project_limit}
        } ->
          maybe_dispatch_project_candidate(state_acc, issue, project_key, project_limit)

        _ ->
          state_acc
      end
    end)
  end

  defp choose_project_issues(_project_result, state), do: state

  defp sort_project_candidates_for_dispatch(candidates) when is_list(candidates) do
    Enum.sort_by(candidates, fn
      %ProjectCandidate{issue: %Issue{} = issue} ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp maybe_dispatch_project_candidate(state, issue, project_key, project_limit) do
    if should_dispatch_project_candidate?(
         issue,
         project_key,
         project_limit,
         state,
         active_state_set(),
         terminal_state_set()
       ) do
      dispatch_issue(state, issue, nil, nil, project_key)
    else
      state
    end
  end

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      codex_dispatch_allowed?(state) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp should_dispatch_project_candidate?(
         %Issue{} = issue,
         project_key,
         project_limit,
         %State{running: running, claimed: claimed, blocked: blocked, retry_attempts: retry_attempts} = state,
         active_states,
         terminal_states
       ) do
    runtime_identity = runtime_key(project_key, issue.id)

    candidate_issue?(issue, active_states, terminal_states) and
      stable_project_key?(project_key) and
      valid_project_limit?(project_limit) and
      project_candidate_runtime_available?(runtime_identity, claimed, running, blocked, retry_attempts) and
      dispatch_capacity_available?(state, issue, running, project_key, project_limit)
  end

  defp should_dispatch_project_candidate?(
         _issue,
         _project_key,
         _project_limit,
         _state,
         _active_states,
         _terminal_states
       ),
       do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, project_key) do
    case revalidate_project_issue_for_dispatch(
           issue,
           project_key,
           &fetch_project_issues_by_states/1,
           terminal_state_set()
         ) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, project_key)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, project_key) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, project_key)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, project_key) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(
             issue,
             recipient,
             attempt: attempt,
             worker_host: worker_host,
             project_key: project_key
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        runtime_key = runtime_key(project_key, issue.id)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, runtime_key, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue_identifier: issue.identifier,
            issue_id: issue.id,
            issue: issue,
            project_key: project_key,
            worker_host: worker_host,
            workspace_path: nil,
            attempt: normalize_retry_attempt(attempt),
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: ensure_runtime_identity_claimed(state.claimed, runtime_key),
            retry_attempts: drop_runtime_keys(state.retry_attempts, [runtime_key, issue.id])
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, runtime_key(project_key, issue.id), next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          project_key: project_key,
          issue_id: issue.id,
          issue_identifier: issue.identifier,
          worker_host: worker_host,
          attempt: next_attempt
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp revalidate_project_issue_for_dispatch(%Issue{id: issue_id}, project_key, project_fetcher, terminal_states)
       when is_binary(issue_id) and is_binary(project_key) and is_function(project_fetcher, 1) do
    case project_fetcher.(project_key) do
      {:ok, %{candidates: candidates, project_results: project_results}} ->
        handle_project_dispatch_revalidation(
          candidates,
          project_results,
          project_key,
          issue_id,
          terminal_states
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_project_issue_for_dispatch(issue, _project_key, _project_fetcher, _terminal_states),
    do: {:ok, issue}

  defp complete_issue(%State{} = state, runtime_identity) do
    issue_id = runtime_issue_id(runtime_identity)
    removal_keys = exact_runtime_identity_keys(runtime_identity)

    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: drop_runtime_keys(state.retry_attempts, removal_keys)
    }
  end

  defp schedule_issue_retry(%State{} = state, runtime_identity, attempt, metadata)
       when is_map(metadata) do
    issue_id = metadata[:issue_id] || runtime_issue_id(runtime_identity)
    retry_runtime_key = runtime_key_from_metadata(metadata[:project_key], issue_id, runtime_identity)

    if is_tuple(retry_runtime_key) and stable_project_key?(runtime_project_key(retry_runtime_key)) do
      do_schedule_issue_retry(state, retry_runtime_key, attempt, Map.put(metadata, :issue_id, issue_id))
    else
      Logger.warning("Retry poll missing stable project identity for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}; stopping automatic retry")

      state
    end
  end

  defp do_schedule_issue_retry(%State{} = state, runtime_key, attempt, metadata)
       when is_tuple(runtime_key) and is_map(metadata) do
    issue_id = runtime_issue_id(runtime_key)
    previous_runtime_key = previous_retry_runtime_key(state.retry_attempts, issue_id, runtime_key)
    previous_retry = Map.get(state.retry_attempts, previous_runtime_key, %{attempt: 0})
    next_attempt = normalize_retry_attempt(attempt, previous_retry)
    delay_ms = retry_delay(next_attempt, metadata)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    cancel_retry_timer(Map.get(previous_retry, :timer_ref))

    timer_ref = Process.send_after(self(), {:retry_issue, runtime_key, retry_token}, delay_ms)
    error_suffix = retry_error_suffix(error)

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          state.retry_attempts
          |> drop_runtime_keys([previous_runtime_key, issue_id])
          |> Map.put(runtime_key, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            project_key: metadata[:project_key] || Map.get(previous_retry, :project_key),
            issue_id: metadata[:issue_id] || issue_id,
            issue_identifier: metadata[:issue_identifier] || identifier,
            worker_host: worker_host,
            workspace_path: workspace_path,
            last_codex_timestamp: metadata[:last_codex_timestamp] || Map.get(previous_retry, :last_codex_timestamp),
            last_attempt: metadata[:attempt] || next_attempt
          }),
        claimed:
          ensure_runtime_identity_claimed(
            migrate_runtime_identity(state.claimed, previous_runtime_key, runtime_key),
            runtime_key
          )
    }
  end

  defp pop_retry_attempt_state(%State{} = state, runtime_identity, retry_token) when is_reference(retry_token) do
    issue_id = runtime_issue_id(runtime_identity)

    retry_runtime_key =
      resolve_runtime_key(state.retry_attempts, issue_id, runtime_project_key(runtime_identity)) ||
        runtime_identity

    case Map.get(state.retry_attempts, retry_runtime_key) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          project_key: Map.get(retry_entry, :project_key),
          issue_id: Map.get(retry_entry, :issue_id, runtime_issue_id(retry_runtime_key)),
          issue_identifier: Map.get(retry_entry, :issue_identifier, Map.get(retry_entry, :identifier)),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          attempt: Map.get(retry_entry, :last_attempt, attempt)
        }

        updated_state = %{state | retry_attempts: drop_runtime_keys(state.retry_attempts, [retry_runtime_key])}

        {:ok, retry_runtime_key, attempt, metadata, updated_state}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, runtime_key, attempt, metadata) do
    issue_id = runtime_issue_id(runtime_key)
    normalized_runtime_key = runtime_key_from_metadata(metadata[:project_key], issue_id, runtime_key)

    case normalized_runtime_key do
      {project_key, ^issue_id} when is_binary(project_key) and project_key != "" ->
        state =
          %{
            state
            | claimed:
                ensure_runtime_identity_claimed(
                  migrate_runtime_identity(state.claimed, runtime_key, normalized_runtime_key),
                  normalized_runtime_key
                )
          }

        handle_retry_issue_with_project(state, normalized_runtime_key, attempt, metadata, project_key)

      _ ->
        Logger.warning("Retry poll missing stable project identity for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}; stopping automatic retry")
        {:noreply, state}
    end
  end

  defp handle_retry_issue_with_project(state, runtime_key, attempt, metadata, project_key) do
    all_states = Config.settings!().tracker.active_states ++ Config.settings!().tracker.terminal_states

    all_states
    |> Tracker.fetch_project_issues_by_states()
    |> handle_retry_issue_project_fetch_result(state, runtime_key, attempt, metadata, project_key)
  end

  defp handle_retry_issue_project_fetch_result(
         {:ok, %{candidates: candidates, project_results: project_results}},
         state,
         runtime_key,
         attempt,
         metadata,
         project_key
       ) do
    issue_id = runtime_issue_id(runtime_key)

    case project_result_status(project_results, project_key) do
      :failed ->
        schedule_retry_after_project_poll_failure(state, runtime_key, attempt, metadata, project_key)

      nil ->
        schedule_retry_after_missing_project_result(state, runtime_key, attempt, metadata, project_key)

      _ ->
        candidates
        |> find_project_issue_by_key_and_id(project_key, issue_id)
        |> handle_retry_issue_lookup(state, runtime_key, attempt, metadata)
    end
  end

  defp handle_retry_issue_project_fetch_result(
         {:error, reason},
         state,
         runtime_key,
         attempt,
         metadata,
         _project_key
       ) do
    issue_id = runtime_issue_id(runtime_key)
    Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

    {:noreply,
     schedule_issue_retry(
       state,
       runtime_key,
       attempt + 1,
       Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
     )}
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, runtime_key, attempt, metadata) do
    issue_id = runtime_issue_id(runtime_key)
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")
        handle_terminal_retry_cleanup(state, issue, runtime_key, metadata)

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, runtime_key, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, runtime_key)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, runtime_key, _attempt, _metadata) do
    issue_id = runtime_issue_id(runtime_key)
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, runtime_key)}
  end

  defp cleanup_running_issue_workspace(_state, runtime_identity, running_entry) do
    issue_id = runtime_issue_id(runtime_identity)

    cleanup_attrs = %{
      project_key: Map.get(running_entry, :project_key),
      issue_id: issue_id,
      issue_identifier: Map.get(running_entry, :issue_identifier, Map.get(running_entry, :identifier)),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      attempt: Map.get(running_entry, :attempt, Map.get(running_entry, :retry_attempt))
    }

    case Workspace.cleanup_workspace(cleanup_attrs) do
      {:ok, _} ->
        :ok

      {:error, reason, _output} ->
        {:error, reason}
    end
  end

  defp cleanup_blocked_issue_workspace(state, runtime_key, %Issue{} = issue) do
    if Map.has_key?(state.blocked, runtime_key) do
      blocked_entry = Map.get(state.blocked, runtime_key, %{})

      cleanup_attrs = %{
        project_key: Map.get(blocked_entry, :project_key),
        issue_id: runtime_issue_id(runtime_key),
        issue_identifier: Map.get(blocked_entry, :issue_identifier, issue.identifier),
        worker_host: Map.get(blocked_entry, :worker_host),
        workspace_path: Map.get(blocked_entry, :workspace_path),
        attempt: Map.get(blocked_entry, :attempt)
      }

      case Workspace.cleanup_workspace(cleanup_attrs) do
        {:ok, _} ->
          release_issue_claim(state, runtime_key)

        {:error, reason, _output} ->
          updated_entry = Map.put(blocked_entry, :error, "cleanup_failed: #{inspect(reason)}")

          %{
            state
            | blocked: Map.put(state.blocked, runtime_key, updated_entry),
              claimed: ensure_runtime_identity_claimed(state.claimed, runtime_key)
          }
      end
    else
      release_issue_claim(state, runtime_key)
    end
  end

  defp handle_terminal_retry_cleanup(state, issue, runtime_key, metadata) do
    issue_id = runtime_issue_id(runtime_key)

    cleanup_attrs = %{
      project_key: metadata[:project_key],
      issue_id: metadata[:issue_id] || issue_id,
      issue_identifier: metadata[:issue_identifier] || issue.identifier,
      worker_host: metadata[:worker_host],
      workspace_path: metadata[:workspace_path],
      attempt: metadata[:attempt]
    }

    case Workspace.cleanup_workspace(cleanup_attrs) do
      {:ok, _} ->
        {:noreply, release_issue_claim(state, runtime_key)}

      {:error, reason, _output} ->
        running_entry = %{
          identifier: issue.identifier,
          issue_identifier: metadata[:issue_identifier] || issue.identifier,
          issue: issue,
          project_key: metadata[:project_key],
          worker_host: metadata[:worker_host],
          workspace_path: metadata[:workspace_path],
          attempt: metadata[:attempt]
        }

        {:noreply, block_issue_from_entry(state, runtime_key, running_entry, "cleanup_failed: #{inspect(reason)}")}
    end
  end

  defp cleanup_startup_terminal_issue_workspace(identifier, project_key) do
    Workspace.cleanup_startup_terminal_issue_workspace(project_key, identifier)
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_project_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, %{candidates: candidates}} ->
        candidates
        |> Enum.each(fn
          %ProjectCandidate{
            issue: %Issue{identifier: identifier},
            project_context: %{project_key: project_key}
          }
          when is_binary(identifier) and is_binary(project_key) and project_key != "" ->
            cleanup_startup_terminal_issue_workspace(identifier, project_key)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, runtime_key, issue, attempt, metadata) do
    case project_limit_from_registry(metadata[:project_key]) do
      {:ok, project_limit} ->
        if active_retry_dispatch_ready?(state, issue, metadata, project_limit) do
          recovered_state = maybe_record_recovery_event(state, issue, runtime_key, attempt, metadata)
          {:noreply, dispatch_issue(recovered_state, issue, attempt, metadata[:worker_host], metadata[:project_key])}
        else
          Logger.debug("Retry remains queued for #{issue_context(issue)}; dispatch gate not open yet")

          {:noreply,
           schedule_issue_retry(
             state,
             runtime_key,
             attempt + 1,
             Map.merge(metadata, %{
               identifier: issue.identifier,
               error: active_retry_block_reason(state),
               project_key: metadata[:project_key]
             })
           )}
        end

      {:error, reason} ->
        Logger.warning("Retry poll missing canonical project limit for issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp find_project_issue_by_key_and_id(candidates, project_key, issue_id)
       when is_list(candidates) and is_binary(project_key) and is_binary(issue_id) do
    Enum.find_value(candidates, fn
      %ProjectCandidate{issue: %Issue{id: ^issue_id} = issue, project_context: %{project_key: ^project_key}} ->
        issue

      _ ->
        nil
    end)
  end

  defp find_project_issue_by_key_and_id(_candidates, _project_key, _issue_id), do: nil

  defp project_result_status(project_results, project_key)
       when is_list(project_results) and is_binary(project_key) do
    Enum.find_value(project_results, fn
      %{project_key: ^project_key, status: status} -> status
      _ -> nil
    end)
  end

  defp project_result_status(_project_results, _project_key), do: nil

  defp schedule_retry_after_project_poll_failure(state, runtime_key, attempt, metadata, project_key) do
    issue_id = runtime_issue_id(runtime_key)
    Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id} project_key=#{project_key}: target project fetch failed")

    {:noreply,
     schedule_issue_retry(
       state,
       runtime_key,
       attempt + 1,
       Map.merge(metadata, %{error: "retry poll failed: target project fetch failed"})
     )}
  end

  defp schedule_retry_after_missing_project_result(state, runtime_key, attempt, metadata, project_key) do
    issue_id = runtime_issue_id(runtime_key)
    Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id} project_key=#{project_key}: target project missing from aggregate result")

    {:noreply,
     schedule_issue_retry(
       state,
       runtime_key,
       attempt + 1,
       Map.merge(metadata, %{error: "retry poll failed: target project missing from aggregate result"})
     )}
  end

  defp release_issue_claim(%State{} = state, runtime_identity) do
    removal_keys = exact_runtime_identity_keys(runtime_identity)

    %{
      state
      | claimed: drop_runtime_keys(state.claimed, removal_keys),
        blocked: drop_runtime_keys(state.blocked, removal_keys),
        retry_attempts: drop_runtime_keys(state.retry_attempts, removal_keys)
    }
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp resolve_runtime_key_for_update(running, issue_id, update) when is_map(running) and is_binary(issue_id) and is_map(update) do
    case matching_runtime_keys(running, issue_id) do
      [runtime_key] ->
        runtime_key

      runtime_keys ->
        runtime_keys
        |> Enum.find(fn runtime_key ->
          running
          |> Map.get(runtime_key, %{})
          |> running_entry_matches_update?(update)
        end)
    end
  end

  defp resolve_runtime_key_for_update(_running, _issue_id, _update), do: nil

  defp running_entry_matches_update?(running_entry, update) when is_map(running_entry) and is_map(update) do
    runtime_session_id = running_entry_session_id(running_entry)
    update_session_id = Map.get(update, :session_id)
    update_worker_host = Map.get(update, :worker_host)
    runtime_worker_host = Map.get(running_entry, :worker_host)
    update_codex_pid = normalize_runtime_pid(Map.get(update, :codex_app_server_pid))
    runtime_codex_pid = normalize_runtime_pid(Map.get(running_entry, :codex_app_server_pid))

    cond do
      is_binary(update_session_id) and is_binary(runtime_session_id) ->
        update_session_id == runtime_session_id

      runtime_worker_match?(update_worker_host, runtime_worker_host) ->
        update_worker_host == runtime_worker_host

      is_binary(update_codex_pid) and is_binary(runtime_codex_pid) ->
        update_codex_pid == runtime_codex_pid

      true ->
        false
    end
  end

  defp running_entry_matches_update?(_running_entry, _update), do: false

  defp normalize_runtime_pid(pid) when is_integer(pid), do: Integer.to_string(pid)
  defp normalize_runtime_pid(pid) when is_binary(pid), do: pid
  defp normalize_runtime_pid(pid) when is_list(pid), do: to_string(pid)
  defp normalize_runtime_pid(_pid), do: nil

  defp project_runtime_identity?(runtime_identity) do
    stable_project_key?(runtime_project_key(runtime_identity)) and is_binary(runtime_issue_id(runtime_identity))
  end

  defp issue_project_key(%Issue{} = issue) do
    case Map.get(issue, :project_key) do
      project_key when is_binary(project_key) and project_key != "" -> project_key
      _ -> nil
    end
  end

  defp fetch_project_issues_by_states(project_key) when is_binary(project_key) do
    all_states = Config.settings!().tracker.active_states ++ Config.settings!().tracker.terminal_states

    Tracker.fetch_project_issues_by_states(all_states)
    |> case do
      {:ok, %{candidates: candidates, project_results: project_results}} ->
        project_candidates =
          Enum.filter(candidates, fn
            %ProjectCandidate{project_context: %{project_key: ^project_key}} -> true
            _ -> false
          end)

        {:ok, %{candidates: project_candidates, project_results: project_results}}

      other ->
        other
    end
  end

  defp runtime_key(project_key, issue_id)
       when is_binary(project_key) and project_key != "" and is_binary(issue_id) and issue_id != "" do
    {project_key, issue_id}
  end

  defp runtime_issue_id({_, issue_id}) when is_binary(issue_id), do: issue_id
  defp runtime_issue_id(issue_id) when is_binary(issue_id), do: issue_id
  defp runtime_issue_id(_runtime_identity), do: nil

  defp runtime_project_key({project_key, _issue_id}) when is_binary(project_key), do: project_key
  defp runtime_project_key(_runtime_identity), do: nil

  defp runtime_key_from_metadata(project_key, issue_id, fallback_runtime_identity) do
    if stable_project_key?(project_key) and is_binary(issue_id) and issue_id != "" do
      runtime_key(project_key, issue_id)
    else
      fallback_runtime_identity
    end
  end

  defp container_keys(%MapSet{} = container), do: MapSet.to_list(container)
  defp container_keys(container) when is_map(container), do: Map.keys(container)

  defp container_member?(%MapSet{} = container, runtime_identity),
    do: MapSet.member?(container, runtime_identity)

  defp container_member?(container, runtime_identity) when is_map(container),
    do: Map.has_key?(container, runtime_identity)

  defp matching_runtime_keys(container, issue_id), do: matching_runtime_keys(container, issue_id, nil)

  defp matching_runtime_keys(container, issue_id, project_key) when is_binary(issue_id) do
    if is_map(container) do
      container
      |> container_keys()
      |> Enum.filter(fn runtime_identity ->
        runtime_issue_id(runtime_identity) == issue_id and
          (is_nil(project_key) or runtime_project_key(runtime_identity) in [nil, project_key])
      end)
    else
      []
    end
  end

  defp reconcile_runtime_keys(container, issue_id, project_key) when is_binary(issue_id) do
    if stable_project_key?(project_key) do
      matching_runtime_keys(container, issue_id, project_key)
    else
      reconcile_legacy_runtime_keys(container, issue_id)
    end
  end

  defp reconcile_runtime_keys(_container, _issue_id, _project_key), do: []

  defp resolve_runtime_key(container, issue_id, project_key)

  defp resolve_runtime_key(container, issue_id, project_key) when is_binary(issue_id) do
    if is_map(container) do
      exact_runtime_key =
        if stable_project_key?(project_key), do: runtime_key(project_key, issue_id), else: nil

      cond do
        exact_runtime_key && container_member?(container, exact_runtime_key) ->
          exact_runtime_key

        container_member?(container, issue_id) ->
          issue_id

        true ->
          resolve_matching_runtime_key(container, issue_id, project_key)
      end
    end
  end

  defp resolve_runtime_key(_container, _issue_id, _project_key), do: nil

  defp drop_runtime_keys(%MapSet{} = container, runtime_keys) when is_list(runtime_keys) do
    Enum.reduce(runtime_keys, container, &MapSet.delete(&2, &1))
  end

  defp drop_runtime_keys(container, runtime_keys) when is_map(container) and is_list(runtime_keys) do
    Enum.reduce(runtime_keys, container, &Map.delete(&2, &1))
  end

  defp runtime_identity_keys_from_state(%State{} = state, runtime_identity) do
    issue_id = runtime_issue_id(runtime_identity)
    project_key = runtime_project_key(runtime_identity)

    [state.running, state.retry_attempts, state.blocked, state.claimed]
    |> Enum.flat_map(&container_keys/1)
    |> Enum.uniq()
    |> Enum.filter(fn current_identity ->
      runtime_issue_id(current_identity) == issue_id and
        (is_nil(project_key) or runtime_project_key(current_identity) in [nil, project_key])
    end)
    |> List.insert_at(0, runtime_identity)
    |> Enum.uniq()
  end

  defp exact_runtime_identity_keys(runtime_identity), do: [runtime_identity]

  defp ensure_runtime_identity_claimed(%MapSet{} = claimed, runtime_identity) do
    claimed
    |> MapSet.delete(runtime_issue_id(runtime_identity))
    |> MapSet.put(runtime_identity)
  end

  defp migrate_runtime_identity(%MapSet{} = claimed, old_runtime_identity, new_runtime_identity) do
    claimed
    |> MapSet.delete(old_runtime_identity)
    |> ensure_runtime_identity_claimed(new_runtime_identity)
  end

  defp project_slots_available?(project_key, project_limit, running)
       when is_binary(project_key) and is_integer(project_limit) and project_limit > 0 and
              is_map(running) do
    Enum.count(running, fn
      {{running_project_key, _issue_id}, _entry} ->
        running_project_key == project_key

      {_runtime_identity, %{project_key: ^project_key}} ->
        true

      _ ->
        false
    end) < project_limit
  end

  defp project_slots_available?(_project_key, _project_limit, _running), do: false

  defp valid_project_limit?(project_limit) when is_integer(project_limit) and project_limit > 0,
    do: true

  defp valid_project_limit?(_project_limit), do: false

  defp stable_project_key?(project_key) when is_binary(project_key), do: String.trim(project_key) != ""
  defp stable_project_key?(_project_key), do: false

  defp project_limit_from_registry(project_key) when is_binary(project_key) do
    with true <- stable_project_key?(project_key),
         {:ok, entries} <- canonical_project_registry_entries(),
         %{enabled: true, max_concurrent_agents: project_limit} <-
           Enum.find(entries, &(&1.project_key == project_key)),
         true <- valid_project_limit?(project_limit) do
      {:ok, project_limit}
    else
      false -> {:error, :invalid_project_limit}
      nil -> {:error, :missing_project_registry_entry}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_project_limit}
    end
  end

  defp project_limit_from_registry(_project_key), do: {:error, :invalid_project_key}

  defp canonical_project_registry_entries do
    project_registry_module().normalized_entries()
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    not worker_host_backoff_active?(state, worker_host) and
      case Config.settings!().worker.max_concurrent_agents_per_host do
        limit when is_integer(limit) and limit > 0 ->
          running_worker_host_count(state.running, worker_host) < limit

        _ ->
          true
      end
  end

  defp find_runtime_key_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {runtime_identity, %{ref: running_ref}} ->
      if running_ref == ref, do: runtime_identity
    end)
  end

  defp project_registry_module do
    Application.get_env(:symphony_elixir, :project_registry_module, ProjectRegistry)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: nil

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec clear_recovery_events() :: :ok | :unavailable
  def clear_recovery_events do
    clear_recovery_events(__MODULE__)
  end

  @spec clear_recovery_events(GenServer.server()) :: :ok | :unavailable
  def clear_recovery_events(server) do
    if Process.whereis(server) do
      GenServer.call(server, :clear_recovery_events)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    state = refresh_codex_rate_limits(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {runtime_identity, metadata} ->
        %{
          issue_id: runtime_snapshot_issue_id(runtime_identity),
          identifier: metadata.identifier,
          project_key: Map.get(metadata, :project_key) || runtime_project_key(runtime_identity),
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          attempt: Map.get(metadata, :attempt, Map.get(metadata, :retry_attempt)),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {runtime_identity, retry} -> retry_snapshot_entry(now_ms, runtime_identity, retry) end)
      |> Enum.reject(&is_nil/1)

    blocked =
      state.blocked
      |> Enum.map(fn {runtime_identity, metadata} ->
        %{
          issue_id: runtime_snapshot_issue_id(runtime_identity),
          identifier: Map.get(metadata, :identifier),
          project_key: Map.get(metadata, :project_key) || runtime_project_key(runtime_identity),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       recovery_events: Enum.take(state.recovery_events, @recovery_event_limit),
       projects: snapshot_projects(running, retrying, blocked),
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call(:clear_recovery_events, _from, state) do
    {:reply, :ok, %{state | recovery_events: []}}
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, runtime_identity) do
    {Map.get(state.running, runtime_identity), %{state | running: drop_runtime_keys(state.running, [runtime_identity])}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp refresh_codex_rate_limits(%State{} = state) do
    rate_limits = Map.get(state, :codex_rate_limits)

    cond do
      not is_map(rate_limits) ->
        %{state | codex_rate_limits: nil, codex_rate_limits_observed_at_ms: nil}

      codex_rate_limit_active?(state) ->
        state

      codex_rate_limit_active?(rate_limits) ->
        %{state | codex_rate_limits: nil, codex_rate_limits_observed_at_ms: nil}

      true ->
        state
    end
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{
          state
          | codex_rate_limits: rate_limits,
            codex_rate_limits_observed_at_ms: System.monotonic_time(:millisecond)
        }

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp codex_dispatch_allowed?(%State{} = state) do
    not codex_rate_limit_active?(state)
  end

  defp codex_rate_limit_active?(%State{} = state) do
    rate_limits = Map.get(state, :codex_rate_limits)
    observed_at_ms = Map.get(state, :codex_rate_limits_observed_at_ms)

    cond do
      not is_map(rate_limits) ->
        false

      bucket_active?(rate_limits, observed_at_ms, :primary) ->
        true

      bucket_active?(rate_limits, observed_at_ms, :secondary) ->
        true

      true ->
        false
    end
  end

  defp codex_rate_limit_active?(rate_limits) when is_map(rate_limits) do
    primary = Map.get(rate_limits, :primary) || Map.get(rate_limits, "primary")
    secondary = Map.get(rate_limits, :secondary) || Map.get(rate_limits, "secondary")

    rate_limit_bucket_exhausted?(primary) or rate_limit_bucket_exhausted?(secondary)
  end

  defp codex_rate_limit_active?(_rate_limits), do: false

  defp bucket_active?(rate_limits, observed_at_ms, bucket_key) do
    bucket = Map.get(rate_limits, bucket_key) || Map.get(rate_limits, Atom.to_string(bucket_key))
    rate_limit_bucket_exhausted?(bucket) and not rate_limit_bucket_reset_elapsed?(bucket, observed_at_ms)
  end

  defp rate_limit_bucket_exhausted?(bucket) when is_map(bucket) do
    bucket
    |> Map.get(:remaining, Map.get(bucket, "remaining"))
    |> parse_integer_like()
    |> case do
      remaining when is_integer(remaining) -> remaining <= 0
      _ -> false
    end
  end

  defp rate_limit_bucket_exhausted?(_bucket), do: false

  defp rate_limit_bucket_reset_elapsed?(bucket, observed_at_ms) when is_map(bucket) and is_integer(observed_at_ms) do
    case reset_in_seconds(bucket) do
      reset_seconds when is_integer(reset_seconds) and reset_seconds >= 0 ->
        System.monotonic_time(:millisecond) >= observed_at_ms + reset_seconds * 1_000

      _ ->
        false
    end
  end

  defp rate_limit_bucket_reset_elapsed?(_bucket, _observed_at_ms), do: false

  defp reset_in_seconds(bucket) when is_map(bucket) do
    bucket
    |> Map.get(:reset_in_seconds, Map.get(bucket, "reset_in_seconds"))
    |> parse_integer_like()
  end

  defp parse_integer_like(value) when is_integer(value), do: value

  defp parse_integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer_like(_value), do: nil

  defp maybe_pause_worker_host_for_failure(%State{} = state, running_entry, reason, attempt)
       when is_map(running_entry) do
    worker_host = Map.get(running_entry, :worker_host)

    if worker_host_failure?(worker_host, running_entry, reason) do
      put_worker_host_backoff(state, worker_host, reason, attempt)
    else
      state
    end
  end

  defp maybe_pause_worker_host_for_failure(state, _running_entry, _reason, _attempt), do: state

  defp put_worker_host_backoff(%State{} = state, worker_host, reason, attempt) when is_binary(worker_host) do
    next_attempt =
      case attempt do
        value when is_integer(value) and value > 0 -> value
        _ -> 1
      end

    %{
      state
      | worker_host_backoffs:
          Map.put(state.worker_host_backoffs, worker_host, %{
            until_ms: System.monotonic_time(:millisecond) + failure_retry_delay(next_attempt),
            attempt: next_attempt,
            reason: reason
          })
    }
  end

  defp worker_host_backoff_active?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Map.get(state.worker_host_backoffs, worker_host) do
      %{until_ms: until_ms} when is_integer(until_ms) ->
        until_ms > System.monotonic_time(:millisecond)

      _ ->
        false
    end
  end

  defp worker_host_failure?(worker_host, running_entry, reason) when is_binary(worker_host) do
    startup_failed? =
      Map.get(running_entry, :last_codex_event) == :startup_failed or
        Map.get(running_entry, :session_id) == nil

    case reason do
      {:shutdown, nested_reason} ->
        worker_host_failure?(worker_host, running_entry, nested_reason)

      other ->
        worker_host_failure_reason?(other, worker_host, startup_failed?)
    end
  end

  defp worker_host_failure?(_worker_host, _running_entry, _reason), do: false

  defp worker_host_failure_reason?(
         {:workspace_prepare_failed, worker_host, _status, _output},
         worker_host,
         _startup_failed?
       ),
       do: true

  defp worker_host_failure_reason?(
         {:invalid_workspace_cwd, _kind, worker_host, _workspace},
         worker_host,
         _startup_failed?
       ),
       do: true

  defp worker_host_failure_reason?(%RuntimeError{message: message}, worker_host, startup_failed?),
    do: worker_host_failure_message?(message, worker_host, startup_failed?)

  defp worker_host_failure_reason?({exception, _stacktrace}, worker_host, startup_failed?)
       when is_struct(exception, RuntimeError),
       do: worker_host_failure_message?(exception.message, worker_host, startup_failed?)

  defp worker_host_failure_reason?(other, worker_host, startup_failed?) when is_tuple(other),
    do: worker_host_failure_message?(inspect(other), worker_host, startup_failed?)

  defp worker_host_failure_reason?(_reason, _worker_host, _startup_failed?), do: false

  defp runtime_worker_match?(update_worker_host, runtime_worker_host)
       when is_binary(update_worker_host) and is_binary(runtime_worker_host) do
    runtime_worker_host != ""
  end

  defp runtime_worker_match?(_update_worker_host, _runtime_worker_host), do: false

  defp project_candidate_runtime_available?(runtime_identity, claimed, running, blocked, retry_attempts) do
    not container_member?(claimed, runtime_identity) and
      not container_member?(running, runtime_identity) and
      not container_member?(blocked, runtime_identity) and
      not container_member?(retry_attempts, runtime_identity)
  end

  defp dispatch_capacity_available?(state, issue, running, project_key, project_limit) do
    not todo_issue_blocked_by_non_terminal?(issue, terminal_state_set()) and
      codex_dispatch_allowed?(state) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      project_slots_available?(project_key, project_limit, running) and
      worker_slots_available?(state)
  end

  defp handle_project_dispatch_revalidation(
         candidates,
         project_results,
         project_key,
         issue_id,
         terminal_states
       ) do
    case project_result_status(project_results, project_key) do
      :failed ->
        {:error, :project_fetch_failed}

      nil ->
        {:error, :project_missing_from_aggregate_result}

      _ ->
        project_revalidation_result(candidates, project_key, issue_id, terminal_states)
    end
  end

  defp project_revalidation_result(candidates, project_key, issue_id, terminal_states) do
    case find_project_issue_by_key_and_id(candidates, project_key, issue_id) do
      %Issue{} = refreshed_issue ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      _ ->
        {:skip, :missing}
    end
  end

  defp active_retry_dispatch_ready?(state, issue, metadata, project_limit) do
    codex_dispatch_allowed?(state) and
      retry_candidate_issue?(issue, terminal_state_set()) and
      dispatch_slots_available?(issue, state) and
      project_slots_available?(metadata[:project_key], project_limit, state.running) and
      worker_slots_available?(state, metadata[:worker_host])
  end

  defp active_retry_block_reason(state) do
    if codex_dispatch_allowed?(state) do
      "no available orchestrator slots"
    else
      "codex rate limit active"
    end
  end

  defp reconcile_legacy_runtime_keys(container, issue_id) do
    if container_member?(container, issue_id) do
      [issue_id]
    else
      case matching_runtime_keys(container, issue_id, nil) do
        [runtime_identity] -> [runtime_identity]
        _ -> []
      end
    end
  end

  defp resolve_matching_runtime_key(container, issue_id, project_key) do
    case matching_runtime_keys(container, issue_id, project_key) do
      [runtime_identity] -> runtime_identity
      _ -> nil
    end
  end

  defp previous_retry_runtime_key(retry_attempts, issue_id, runtime_key) do
    resolve_runtime_key(retry_attempts, issue_id, runtime_project_key(runtime_key)) || runtime_key
  end

  defp normalize_retry_attempt(attempt, _previous_retry) when is_integer(attempt), do: attempt
  defp normalize_retry_attempt(_attempt, previous_retry), do: previous_retry.attempt + 1

  defp maybe_record_recovery_event(%State{} = state, %Issue{} = issue, runtime_key, attempt, metadata) do
    recovery_attempt_count =
      metadata[:attempt] ||
        metadata[:last_attempt] ||
        attempt ||
        0

    if recovery_attempt_count > 0 do
      record_recovery_event(state, %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        project_key: metadata[:project_key] || runtime_project_key(runtime_key),
        recovery_attempt_count: recovery_attempt_count,
        last_event_at: DateTime.utc_now(),
        last_message: metadata[:error],
        session_id: nil
      })
    else
      state
    end
  end

  defp record_recovery_event(%State{} = state, event) when is_map(event) do
    %{state | recovery_events: [event | Enum.take(state.recovery_events, @recovery_event_limit - 1)]}
  end

  defp cancel_retry_timer(timer_ref) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
  end

  defp cancel_retry_timer(_timer_ref), do: :ok

  defp retry_error_suffix(error) when is_binary(error), do: " error=#{error}"
  defp retry_error_suffix(_error), do: ""

  defp worker_host_failure_message?(message, worker_host, _startup_failed?)
       when is_binary(message) and is_binary(worker_host) do
    (String.contains?(message, "workspace_prepare_failed") and String.contains?(message, worker_host)) or
      (String.contains?(message, "invalid_workspace_cwd") and String.contains?(message, worker_host))
  end

  defp worker_host_failure_message?(_message, _worker_host, _startup_failed?), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
