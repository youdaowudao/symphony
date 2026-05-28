defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, RuntimeStatus}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()

    socket =
      socket
      |> assign_payload(payload, nil)
      |> assign(:running_sort, {:last_update, :asc})
      |> assign(:todo_pool_expanded, %{})
      |> assign(:todo_pool_checked, false)
      |> assign(:refresh_feedback, nil)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    payload = load_payload()

    {:noreply, socket |> assign_payload(payload, socket.assigns.running_order) |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("set_running_sort", %{"sort" => sort}, socket) do
    next_sort = next_running_sort(socket.assigns.running_sort, normalize_running_sort(sort))
    {:noreply, assign(socket, :running_sort, next_sort)}
  end

  def handle_event("toggle_todo_pool", %{"project" => project_key}, socket) do
    expanded =
      Map.update(socket.assigns.todo_pool_expanded, project_key, true, &(!&1))

    {:noreply, assign(socket, :todo_pool_expanded, expanded)}
  end

  def handle_event("manual_check_todo_pool", _params, socket) do
    refresh_feedback = %{
      kind: :local_only,
      message: "仅更新本地占位状态，未触发后台刷新。",
      requested_at: nil
    }

    {:noreply,
     socket
     |> assign(:todo_pool_checked, true)
     |> assign(:todo_pool_expanded, expand_all_projects(socket.assigns.payload))
     |> assign(:refresh_feedback, refresh_feedback)}
  end

  def handle_event("clear_recovery_events", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <%= if @payload[:error] && @last_good_payload do %>
        <section class="stale-banner" role="status">
          <div>
            <h2 class="stale-banner-title"><%= stale_banner_title(@payload.error.code) %></h2>
            <p class="stale-banner-copy">
              <strong><%= @payload.error.message %></strong>
              最近成功更新 <%= relative_time(@last_good_payload.generated_at, @now) %>。
            </p>
          </div>
        </section>
      <% end %>

      <%= if display_payload(@payload, @last_good_payload)[:error] do %>
        <section class="error-card">
          <h2 class="error-title">首页快照暂不可用</h2>
          <p class="error-copy">
            <strong><%= display_payload(@payload, @last_good_payload).error.code %>:</strong> <%= display_payload(@payload, @last_good_payload).error.message %>
          </p>
        </section>
      <% else %>
        <% payload = display_payload(@payload, @last_good_payload) %>
        <% current_exception_entries = current_exceptions(payload, @now) %>
        <% running_entries = healthy_running(payload, @now, @running_order, @running_sort) %>
        <% recovery_events = recent_recovery_events(payload) %>
        <div class="formal-shell">
          <div class="topbar">
            <div class="brand">
              <div class="brand-mark">MP</div>
              <div>
                <h2>Multi-Project Operations Home</h2>
                <p>多项目共享执行池</p>
              </div>
            </div>

            <div class="nav-row">
              <span class="nav-pill active">总览</span>
              <span class="nav-pill">Sessions</span>
              <span class="nav-pill">Issues</span>
              <span class="nav-pill muted" aria-disabled="true">Todo Pool</span>
              <span class="nav-pill muted" aria-disabled="true">事件</span>
              <span class="nav-pill muted" aria-disabled="true">日志</span>
            </div>
          </div>

          <div class="meta-strip">
            <div class="meta-badges">
              <span
                id="poll-countdown-chip"
                class="meta-chip"
                phx-hook="LiveTicker"
                phx-update="ignore"
                data-ticker="poll-countdown"
                data-poll-interval-seconds={poll_interval_seconds(payload)}
                data-poll-state={poll_countdown_state(payload)}
                data-next-poll-in-seconds={poll_countdown_seconds(payload)}
              ><span data-ticker-owner="poll-countdown"></span></span>
              <span class="meta-chip">手动排序</span>
              <span class="meta-chip warn">稳定位置</span>
              <span class="meta-chip muted">copy session 仅在 running 行可用</span>
            </div>

            <div class="meta-updated">
              最近成功更新 <%= latest_success_label(payload, @last_good_payload, @now) %>
            </div>
          </div>

          <div class="shell-body">
            <div class="metric-row">
              <article class="metric-card">
                <h3>Running</h3>
                <p class="metric-value numeric"><%= payload.counts.running %></p>
                <p class="metric-detail">正常进行中的 issue</p>
              </article>

              <article class={metric_card_class(length(current_exception_entries) > 0)}>
                <h3>待处理</h3>
                <p class="metric-value numeric"><%= length(current_exception_entries) %></p>
                <p class="metric-detail">Blocked / retrying / stale</p>
              </article>

              <article class="metric-card">
                <h3>Tokens</h3>
                <p class="metric-value numeric"><%= format_token_millions(payload.codex_totals.total_tokens) %></p>
                <p class="metric-detail numeric">
                  In <%= format_token_millions(payload.codex_totals.input_tokens) %> / Out <%= format_token_millions(payload.codex_totals.output_tokens) %>
                </p>
              </article>

              <article class="metric-card">
                <h3>Runtime</h3>
                <p
                  id="runtime-total-metric"
                  class="metric-value numeric"
                  phx-hook="LiveTicker"
                  phx-update="ignore"
                  data-live-duration="runtime-total"
                  data-base-seconds={runtime_anchor_total_seconds(payload, running_entries, @now)}
                  data-anchor-unix={DateTime.to_unix(@now)}
                  data-growth-per-second={length(running_entries)}
                ><span data-ticker-owner="runtime-total"></span></p>
                <p class="metric-detail">历史累计 + 当前活跃增量</p>
              </article>

              <article class={metric_card_class(oldest_update_alert?(payload, @now))}>
                <h3>最久未更新</h3>
                <p class="metric-value numeric"><%= oldest_update_metric(payload, @now) %></p>
                <p class="metric-detail">当前 running 中最久未更新时长</p>
              </article>

              <article class="metric-card">
                <h3>Projects</h3>
                <p class="metric-value numeric"><%= length(payload.projects) %></p>
                <p class="metric-detail">共享 payload 项目数</p>
              </article>
            </div>

            <div class="main-grid">
              <div class="column column-sidebar" id="dashboard-sidebar">
                <section class="panel">
                  <div class="panel-head alert">
                    <div>
                      <h3>当前异常</h3>
                    <p>Blocked / retrying / stale</p>
                    </div>
                  </div>

                  <div class={current_exception_body_class(current_exception_entries)} id="current-exceptions-list">
                    <%= if current_exception_entries == [] do %>
                      <p class="empty-state">当前没有需要处理的异常。</p>
                    <% else %>
                      <article :for={entry <- current_exception_entries} class="anomaly-item">
                        <div class="item-head">
                          <div>
                            <div class="item-id"><%= entry.issue_identifier %></div>
                            <div class="item-sub"><%= entry.project_display_name || entry.project_key %></div>
                          </div>
                          <div class="item-tags">
                            <span class={exception_tag_class(entry)}><%= exception_status(entry) %></span>
                          </div>
                        </div>
                        <div class="item-main"><%= exception_summary(entry) %></div>
                        <div class="item-sub"><%= exception_session_label(entry) %> · <%= exception_time_label(entry, @now) %></div>
                      </article>
                    <% end %>
                  </div>
                </section>

                <section class="panel">
                  <div class="panel-head">
                    <div>
                      <h3>最近恢复事件</h3>
                    </div>
                    <div class="panel-meta">
                      <span><%= length(recovery_events) %> 条</span>
                    </div>
                  </div>

                  <div class={recovery_events_body_class(recovery_events)} id="recovery-events-list">
                    <%= if recovery_events == [] do %>
                        <p class="empty-state">当前还没有最近恢复事件。这里只记录已恢复回 running 的项。</p>
                    <% else %>
                      <div :for={entry <- recovery_events} class="history-line">
                        <%= recovery_event_label(entry) %>
                      </div>
                    <% end %>
                  </div>
                </section>

                <section class="panel" id="todo-pool-panel">
                  <div class="panel-head">
                    <div>
                      <h3>Todo Pool</h3>
                      <p>待执行任务池占位</p>
                    </div>
                    <div class="panel-meta">
                      <button type="button" class="ghost-button" phx-click="manual_check_todo_pool">手动检查</button>
                    </div>
                  </div>

                  <div class="panel-body">
                    <div class="projects-grid todo-project-list projects-scroll panel-scroll panel-scroll-secondary" id="todo-project-cards">
                      <article :for={project <- payload.projects} class="project-card todo-project-row">
                        <div class="collapsed-head">
                          <div>
                            <p class="metric-label todo-project-name"><%= project.project_display_name || project.project_key %></p>
                            <p class="project-counts">待执行任务 0</p>
                          </div>
                          <% project_expanded = project_todo_expanded?(@todo_pool_expanded, project.project_key) %>
                          <button type="button" class="ghost-button" phx-click="toggle_todo_pool" phx-value-project={project.project_key}>
                            <%= if project_expanded, do: "收回摘要", else: "展开摘要" %>
                          </button>
                        </div>

                        <%= if project_expanded do %>
                          <div class="footer-note">待执行任务详情占位</div>
                        <% end %>
                      </article>
                    </div>

                    <%= if @todo_pool_checked && @refresh_feedback do %>
                      <div class="footer-note">
                        <%= @refresh_feedback.message %>
                        <%= if @refresh_feedback.requested_at do %>
                          最近请求 <%= format_ui_timestamp(@refresh_feedback.requested_at) %>。
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </section>
              </div>

              <div class="column column-primary" id="dashboard-primary">
                <section class="panel">
                  <div class="panel-head">
                    <div>
                      <h3>正常 Running</h3>
                      <p><%= running_panel_subtitle(running_entries) %></p>
                    </div>
                    <div class="panel-meta"><%= length(running_entries) %> 条</div>
                  </div>

                  <div class="panel-body" id="running-list">
                    <div class="toolbar">
                      <div class="sort-pills">
                        <button
                          :for={sort <- running_sort_options()}
                          type="button"
                          class={sort_pill_class(@running_sort, sort.key)}
                          phx-click="set_running_sort"
                          phx-value-sort={sort.key}
                        >
                          <%= running_sort_label(sort.key, @running_sort) %>
                        </button>
                      </div>

                      <div class="view-notes">
                        <span class="view-note active">紧凑列表</span>
                        <span class="view-note">copy session 在行内</span>
                      </div>
                    </div>

                    <%= if running_entries == [] do %>
                      <p class="empty-state">当前没有正常 running 项。</p>
                    <% else %>
                      <div class="running-table">
                        <div class="running-head">
                          <div>Issue</div>
                          <div>项目</div>
                          <div>运行时长</div>
                          <div>Session</div>
                          <div>Token</div>
                          <div>最新更新</div>
                          <div>摘要</div>
                        </div>

                        <div
                          class={running_rows_class(running_entries)}
                          id="running-rows"
                          onwheel={running_rows_onwheel(running_entries)}
                        >
                          <div :for={entry <- running_entries} class="running-entry" id={running_entry_dom_id(entry)}>
                            <div class="running-row">
                              <div class="running-cell running-cell-issue"><div class="mono"><%= entry.issue_identifier %></div></div>
                              <div class="running-cell"><span class="tag blue ellipsis"><%= entry.project_display_name || entry.project_key %></span></div>
                              <div class="running-cell">
                                <div
                                  id={"running-runtime-" <> running_entry_dom_id(entry)}
                                  class="plain nowrap"
                                  phx-hook="LiveTicker"
                                  phx-update="ignore"
                                  data-live-duration="running-entry"
                                  data-base-seconds={runtime_seconds_from_started_at(entry.started_at, @now)}
                                  data-anchor-unix={DateTime.to_unix(@now)}
                                  data-turn-count={max(entry.turn_count || 0, 0)}
                                ><span data-ticker-owner="running-entry"></span></div>
                              </div>
                              <div class="running-cell">
                                <%= if entry.session_id do %>
                                  <button
                                    type="button"
                                    class="copy-chip"
                                    data-copy={entry.session_id}
                                    data-label="copy session"
                                    onclick="navigator.clipboard.writeText(this.dataset.copy).then(() => { this.classList.add('copy-chip-success'); this.classList.remove('copy-chip-failed'); this.textContent = '已复制'; }).catch(() => { this.classList.add('copy-chip-failed'); this.classList.remove('copy-chip-success'); this.textContent = '复制失败'; }).finally(() => { clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.classList.remove('copy-chip-success'); this.classList.remove('copy-chip-failed'); this.textContent = this.dataset.label; }, 1200); });"
                                  >
                                    copy session
                                  </button>
                                <% else %>
                                  <button
                                    type="button"
                                    class="copy-chip copy-chip-missing"
                                    data-label="无可复制 session"
                                    onclick="this.textContent = '无可复制 session'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label; }, 1200);"
                                  >
                                    无可复制 session
                                  </button>
                                <% end %>
                              </div>
                              <div class="running-cell"><div class="plain"><%= compact_total_tokens(entry.tokens.total_tokens) %></div></div>
                              <div class="running-cell"><div class="plain freshness"><%= compact_relative_time(entry.last_event_at, @now) %></div></div>
                              <div class="running-cell running-cell-summary"><div class="message event-block"><%= entry.summary_text || entry.last_message || to_string(entry.last_event || "n/a") %></div></div>
                            </div>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </section>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp assign_payload(socket, payload, running_order) do
    next_last_good_payload = last_good_payload(socket.assigns[:last_good_payload], payload)

    socket
    |> assign(:payload, payload)
    |> assign(:last_good_payload, next_last_good_payload)
    |> assign(:running_order, next_running_order(payload, running_order))
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp runtime_anchor_total_seconds(payload, running_entries, now) do
    runtime_base_seconds(payload) +
      Enum.reduce(running_entries, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp runtime_base_seconds(payload) when is_map(payload) do
    payload
    |> Map.get(:codex_totals, %{})
    |> Map.get(:seconds_running, 0)
    |> normalize_runtime_seconds()
  end

  defp runtime_base_seconds(_payload), do: 0

  defp normalize_runtime_seconds(seconds) when is_number(seconds), do: max(trunc(seconds), 0)
  defp normalize_runtime_seconds(_seconds), do: 0

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    max(DateTime.diff(now, started_at, :second), 0)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp current_exceptions(payload, now) do
    [
      payload.blocked
      |> Enum.map(&Map.put(&1, :status, "blocked")),
      payload.retrying
      |> Enum.map(&Map.put(&1, :status, "retrying")),
      payload.running
      |> Enum.filter(&(runtime_status_now(&1, now) == "stale"))
      |> Enum.map(&Map.put(&1, :status, "stale"))
    ]
    |> List.flatten()
    |> Enum.group_by(&exception_key/1)
    |> Enum.map(fn {_key, entries} -> pick_exception_entry(entries) end)
    |> Enum.sort_by(fn entry -> {exception_priority(entry), last_event_sort_key(entry)} end)
  end

  defp healthy_running(payload, now, running_order, running_sort) do
    order_positions =
      running_order
      |> Enum.with_index()
      |> Map.new()

    payload.running
    |> Enum.reject(&(runtime_status_now(&1, now) == "stale"))
    |> sort_running_entries(now, order_positions, running_sort)
  end

  defp exception_summary(entry) do
    Map.get(entry, :error) ||
      Map.get(entry, :last_message) ||
      to_string(Map.get(entry, :last_event) || Map.get(entry, :status) || "needs attention")
  end

  defp exception_status(entry) do
    Map.get(entry, :status) ||
      Map.get(entry, :runtime_status) ||
      Map.get(entry, :state) ||
      "unknown"
  end

  defp runtime_status_now(entry, now) when is_map(entry) do
    entry
    |> presenter_runtime_entry()
    |> RuntimeStatus.classify(now)
    |> Atom.to_string()
  end

  defp presenter_runtime_entry(entry) do
    %{
      last_codex_event: Map.get(entry, :last_event),
      last_codex_message: Map.get(entry, :last_message),
      last_codex_timestamp: Map.get(entry, :last_event_at)
    }
  end

  defp display_payload(payload, nil), do: payload
  defp display_payload(%{error: _error}, last_good_payload) when is_map(last_good_payload), do: last_good_payload
  defp display_payload(payload, _last_good_payload), do: payload

  defp last_good_payload(last_good_payload, %{error: _error}), do: last_good_payload
  defp last_good_payload(_last_good_payload, payload), do: payload

  defp stale_banner_title("snapshot_timeout"), do: "Snapshot stale"
  defp stale_banner_title(_code), do: "Snapshot unavailable"

  defp relative_time(nil, _now), do: "时间未知"

  defp relative_time(%DateTime{} = timestamp, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, timestamp, :second), 0)

    cond do
      seconds < 60 -> "刚刚"
      seconds < 3_600 -> "#{div(seconds, 60)} 分钟前"
      seconds < 86_400 -> "#{div(seconds, 3_600)} 小时前"
      true -> "#{div(seconds, 86_400)} 天前"
    end
  end

  defp relative_time(timestamp, %DateTime{} = now) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> relative_time(parsed, now)
      _ -> "时间未知"
    end
  end

  defp relative_time(_timestamp, _now), do: "时间未知"

  defp format_ui_timestamp(nil), do: "时间未知"

  defp format_ui_timestamp(%DateTime{} = timestamp),
    do: timestamp |> shift_to_shanghai() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

  defp format_ui_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> format_ui_timestamp(parsed)
      _ -> "时间未知"
    end
  end

  defp format_ui_timestamp(_timestamp), do: "时间未知"

  defp exception_key(entry) do
    Map.get(entry, :issue_id) || Map.get(entry, :issue_identifier)
  end

  defp pick_exception_entry(entries) do
    Enum.min_by(entries, fn entry ->
      {exception_priority(entry), last_event_sort_key(entry)}
    end)
  end

  defp exception_priority(entry) do
    case Map.get(entry, :status) do
      "blocked" -> 0
      "retrying" -> 1
      "stale" -> 2
      _ -> 3
    end
  end

  defp last_event_sort_key(entry) do
    case parse_datetime(Map.get(entry, :last_event_at)) do
      %DateTime{} = timestamp -> {0, DateTime.to_unix(timestamp, :microsecond)}
      _ -> {1, 0}
    end
  end

  defp next_running_order(%{error: _error}, running_order), do: running_order || []

  defp next_running_order(payload, nil) do
    payload.running
    |> Enum.sort_by(&last_event_sort_key/1)
    |> Enum.map(&running_entry_key/1)
    |> Enum.reject(&is_nil/1)
  end

  defp next_running_order(payload, running_order) do
    current_keys =
      payload.running
      |> Enum.map(&running_entry_key/1)
      |> Enum.reject(&is_nil/1)

    current_key_set = MapSet.new(current_keys)

    persisted_keys =
      running_order
      |> Enum.filter(&MapSet.member?(current_key_set, &1))

    new_keys =
      payload.running
      |> Enum.sort_by(&last_event_sort_key/1)
      |> Enum.map(&running_entry_key/1)
      |> Enum.reject(&(is_nil(&1) || &1 in persisted_keys))

    persisted_keys ++ new_keys
  end

  defp running_entry_key(entry) do
    with nil <- present_running_issue_id(entry),
         nil <- present_project_issue_key(entry) do
      present_session_key(entry)
    end
  end

  defp entry_timestamp(entry) do
    (Map.get(entry, :blocked_at) ||
       Map.get(entry, :last_event_at) ||
       Map.get(entry, :due_at))
    |> parse_datetime()
  end

  defp parse_datetime(%DateTime{} = timestamp), do: timestamp

  defp parse_datetime(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp parse_datetime(_timestamp), do: nil

  defp exception_session_label(entry) do
    Map.get(entry, :session_id) || "session n/a"
  end

  defp exception_time_label(entry, now) do
    relative_time(entry_timestamp(entry), now)
  end

  defp latest_success_label(%{error: _error}, last_good_payload, now) when is_map(last_good_payload) do
    latest_success_label(last_good_payload, nil, now)
  end

  defp latest_success_label(payload, last_good_payload, now) do
    source =
      cond do
        is_binary(payload[:generated_at]) -> payload.generated_at
        is_map(last_good_payload) and is_binary(last_good_payload[:generated_at]) -> last_good_payload.generated_at
        true -> nil
      end

    relative_time(source, now)
  end

  defp oldest_update_metric(payload, now) do
    timestamps =
      payload.running
      |> Enum.reject(&(runtime_status_now(&1, now) == "stale"))
      |> Enum.map(&entry_timestamp/1)
      |> Enum.reject(&is_nil/1)

    case timestamps do
      [] ->
        "n/a"

      list ->
        list
        |> Enum.min(DateTime)
        |> relative_duration(now)
    end
  end

  defp recent_recovery_events(payload) when is_map(payload) do
    Map.get(payload, :recovery_events, [])
  end

  defp recent_recovery_events(_payload), do: []

  defp recovery_event_label(entry) do
    project_name = Map.get(entry, :project_display_name) || Map.get(entry, :project_key) || "未知项目"
    issue_identifier = Map.get(entry, :issue_identifier) || Map.get(entry, :issue_id) || "unknown issue"
    attempt = max(Map.get(entry, :recovery_attempt_count, 0), 0)
    timestamp = Map.get(entry, :last_event_at) |> format_ui_timestamp()

    "#{timestamp} UTC+8 · #{project_name} · #{issue_identifier} · 重试第 #{attempt} 次后重新进入 running"
  end

  defp poll_interval_seconds(payload) when is_map(payload) do
    payload
    |> Map.get(:polling, %{})
    |> Map.get(:poll_interval_ms, fallback_poll_interval_ms())
    |> normalize_poll_interval_seconds()
  end

  defp poll_interval_seconds(_payload), do: normalize_poll_interval_seconds(fallback_poll_interval_ms())

  defp poll_countdown_state(payload) when is_map(payload) do
    polling = Map.get(payload, :polling, %{})

    cond do
      polling[:checking?] == true -> "checking"
      is_integer(polling[:next_poll_in_ms]) and polling[:next_poll_in_ms] >= 0 -> "countdown"
      true -> "unknown"
    end
  end

  defp poll_countdown_state(_payload), do: "unknown"

  defp poll_countdown_seconds(payload) when is_map(payload) do
    case Map.get(payload, :polling, %{}) do
      %{checking?: true} ->
        nil

      %{next_poll_in_ms: value} when is_integer(value) and value >= 0 ->
        Integer.to_string(max(div(value + 999, 1_000), 0))

      _ ->
        nil
    end
  end

  defp poll_countdown_seconds(_payload), do: nil

  defp fallback_poll_interval_ms do
    Config.settings!()
    |> Map.get(:polling, %{})
    |> Map.get(:interval_ms, 10_000)
  end

  defp normalize_poll_interval_seconds(value) when is_integer(value) do
    max(div(max(value, 1_000), 1_000), 1)
  end

  defp normalize_poll_interval_seconds(_value), do: normalize_poll_interval_seconds(fallback_poll_interval_ms())

  defp running_panel_subtitle([]), do: "主列表仅展示当前正常 running"
  defp running_panel_subtitle(_running_entries), do: "主列表仅展示当前正常 running"

  defp metric_card_class(true), do: "metric-card alert"
  defp metric_card_class(false), do: "metric-card"

  defp oldest_update_alert?(payload, now), do: oldest_update_metric(payload, now) != "n/a"

  defp normalize_running_sort("project"), do: :project
  defp normalize_running_sort("runtime"), do: :runtime
  defp normalize_running_sort("tokens"), do: :tokens
  defp normalize_running_sort(_sort), do: :last_update

  defp running_sort_options do
    [
      %{key: :last_update},
      %{key: :project},
      %{key: :runtime},
      %{key: :tokens}
    ]
  end

  defp running_sort_label(sort_key, {sort_key, :asc}), do: base_running_sort_label(sort_key) <> " ↑"
  defp running_sort_label(sort_key, {sort_key, :desc}), do: base_running_sort_label(sort_key) <> " ↓"
  defp running_sort_label(sort_key, _active), do: base_running_sort_label(sort_key)

  defp sort_pill_class(active_sort, sort_key) do
    if elem(active_sort, 0) == sort_key, do: "sort-pill active", else: "sort-pill"
  end

  defp next_running_sort({sort_key, :asc}, sort_key), do: {sort_key, :desc}
  defp next_running_sort({sort_key, :desc}, sort_key), do: {sort_key, :asc}
  defp next_running_sort(_current_sort, sort_key), do: {sort_key, default_sort_direction(sort_key)}

  defp default_sort_direction(:runtime), do: :desc
  defp default_sort_direction(:tokens), do: :desc
  defp default_sort_direction(_sort_key), do: :asc

  defp base_running_sort_label(:last_update), do: "最后更新"
  defp base_running_sort_label(:project), do: "项目"
  defp base_running_sort_label(:runtime), do: "运行时长"
  defp base_running_sort_label(:tokens), do: "Token"

  defp compact_total_tokens(value) when is_integer(value), do: compact_number(value)
  defp compact_total_tokens(_value), do: "n/a"

  defp compact_number(value) when value >= 1_000_000, do: :erlang.float_to_binary(value / 1_000_000, decimals: 2) <> "M"
  defp compact_number(value) when value >= 1_000, do: :erlang.float_to_binary(value / 1_000, decimals: 1) <> "k"
  defp compact_number(value), do: Integer.to_string(value)

  defp compact_relative_time(timestamp, now), do: relative_duration(timestamp, now)

  defp format_token_millions(value) when is_integer(value) and value >= 0 do
    :erlang.float_to_binary(value / 1_000_000, decimals: 2) <> "M"
  end

  defp format_token_millions(_value), do: "n/a"

  defp shift_to_shanghai(%DateTime{} = timestamp) do
    DateTime.add(timestamp, 8 * 60 * 60, :second)
  end

  defp relative_duration(nil, _now), do: "n/a"

  defp relative_duration(%DateTime{} = timestamp, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, timestamp, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp relative_duration(timestamp, %DateTime{} = now) when is_binary(timestamp) do
    case parse_datetime(timestamp) do
      %DateTime{} = parsed -> relative_duration(parsed, now)
      _ -> "n/a"
    end
  end

  defp relative_duration(_timestamp, _now), do: "n/a"

  defp running_entry_dom_id(entry) do
    case running_entry_key(entry) do
      {:issue_id, issue_id} -> "running-entry-" <> issue_id
      {:project_issue_identifier, project_key, issue_identifier} -> "running-entry-" <> project_key <> "-" <> issue_identifier
      {:session_id, session_id} -> "running-entry-" <> session_id
      _ -> "running-entry-unknown"
    end
  end

  defp project_todo_expanded?(expanded_map, project_key) when is_map(expanded_map),
    do: Map.get(expanded_map, project_key, false)

  defp project_todo_expanded?(_expanded_map, _project_key), do: false

  defp expand_all_projects(%{projects: projects}) when is_list(projects) do
    Map.new(projects, fn project -> {project.project_key, true} end)
  end

  defp expand_all_projects(_payload), do: %{}

  defp exception_tag_class(entry) do
    case Map.get(entry, :status) do
      "blocked" -> "tag red"
      "retrying" -> "tag amber"
      "stale" -> "tag blue"
      _ -> "tag blue"
    end
  end

  defp current_exception_body_class([]), do: "panel-body"
  defp current_exception_body_class(_entries), do: "panel-body panel-scroll panel-scroll-critical exceptions-scroll-ready"

  defp recovery_events_body_class([]), do: "panel-body"
  defp recovery_events_body_class(_entries), do: "panel-body panel-scroll panel-scroll-secondary"

  defp running_rows_class(entries) do
    if scrollable_running_rows?(entries), do: "running-rows scrollable", else: "running-rows"
  end

  defp running_rows_onwheel(entries) do
    if scrollable_running_rows?(entries) do
      "window.scrollBy({ top: event.deltaY, left: 0, behavior: 'auto' }); return false;"
    else
      nil
    end
  end

  defp token_sort_key(entry), do: Map.get(entry.tokens, :total_tokens, 0)

  defp runtime_sort_key(entry, now) do
    runtime_seconds_from_started_at(entry.started_at, now)
  end

  defp last_update_seconds(entry) do
    case parse_datetime(Map.get(entry, :last_event_at)) do
      %DateTime{} = timestamp -> DateTime.to_unix(timestamp, :second)
      _ -> 0
    end
  end

  defp sort_running_entries(running, _now, _order_positions, {:project, direction})
       when direction in [:asc, :desc] do
    Enum.sort_by(running, &project_sort_key/1, direction)
  end

  defp sort_running_entries(running, now, _order_positions, {:runtime, direction})
       when direction in [:asc, :desc] do
    Enum.sort_by(running, &runtime_sort_key(&1, now), direction)
  end

  defp sort_running_entries(running, _now, _order_positions, {:tokens, direction})
       when direction in [:asc, :desc] do
    Enum.sort_by(running, &token_sort_key/1, direction)
  end

  defp sort_running_entries(running, _now, order_positions, _running_sort) do
    fallback_index = map_size(order_positions)

    Enum.sort_by(running, fn entry ->
      {Map.get(order_positions, running_entry_key(entry), fallback_index), last_event_sort_key(entry)}
    end)
  end

  defp project_sort_key(entry) do
    {
      String.downcase(to_string(entry.project_display_name || entry.project_key || "")),
      last_update_seconds(entry)
    }
  end

  defp present_running_issue_id(entry) do
    case Map.get(entry, :issue_id) do
      issue_id when is_binary(issue_id) and issue_id != "" -> {:issue_id, issue_id}
      _ -> nil
    end
  end

  defp present_project_issue_key(entry) do
    case {Map.get(entry, :project_key), Map.get(entry, :issue_identifier)} do
      {project_key, issue_identifier}
      when is_binary(project_key) and project_key != "" and is_binary(issue_identifier) and
             issue_identifier != "" ->
        {:project_issue_identifier, project_key, issue_identifier}

      _ ->
        nil
    end
  end

  defp present_session_key(entry) do
    case Map.get(entry, :session_id) do
      session_id when is_binary(session_id) and session_id != "" -> {:session_id, session_id}
      _ -> nil
    end
  end

  defp scrollable_running_rows?(entries) when is_list(entries), do: length(entries) > 20
end
