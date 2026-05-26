defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.RuntimeStatus
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:last_good_payload, if(payload[:error], do: nil, else: payload))
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    payload = load_payload()

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(:last_good_payload, last_good_payload(socket.assigns.last_good_payload, payload))
     |> assign(:now, DateTime.utc_now())}
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
              Last successful update <%= relative_time(@last_good_payload.generated_at, @now) %>.
            </p>
          </div>
        </section>
      <% end %>

      <%= if display_payload(@payload, @last_good_payload)[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= display_payload(@payload, @last_good_payload).error.code %>:</strong> <%= display_payload(@payload, @last_good_payload).error.message %>
          </p>
        </section>
      <% else %>
        <% payload = display_payload(@payload, @last_good_payload) %>
        <header class="hero-card">
          <div class="topbar">
            <div>
              <p class="eyebrow">
                Symphony Observability
              </p>
              <h1 class="hero-title">
                Operations Dashboard
              </h1>
            </div>

            <div class="nav-row">
              <span class="nav-pill active">Dashboard</span>
              <span class="nav-pill muted">Runtime</span>
              <span class="nav-pill muted">Projects</span>
            </div>
          </div>

          <div class="hero-grid hero-grid-wide">
            <div>
              <p class="hero-copy">
                Current exceptions stay on the left, stable running work stays wide on the right, and low-priority project summary remains visible below the first response path.
              </p>
            </div>

            <div class="status-stack">
              <span class="status-badge status-badge-live">
                <span class="status-badge-dot"></span>
                Live
              </span>
              <span class="status-badge status-badge-offline">
                <span class="status-badge-dot"></span>
                Offline
              </span>
            </div>
          </div>
        </header>

        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card metric-card-alert">
            <p class="metric-label">Current exceptions</p>
            <p class="metric-value numeric"><%= length(current_exceptions(payload, @now)) %></p>
            <p class="metric-detail">Blocked, retrying, and stale running issues that still need attention.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(payload.codex_totals.input_tokens) %> / Out <%= format_int(payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="main-grid">
          <div class="column column-alerts">
            <section class="panel panel-alerts">
              <div class="panel-head panel-head-alert">
                <div>
                  <h2 class="section-title">Current exceptions</h2>
                  <p class="section-copy">Blocked, retrying, and stale running items only.</p>
                </div>
              </div>

              <div class="panel-body">
                <%= if current_exceptions(payload, @now) == [] do %>
                  <p class="empty-state">No current exceptions.</p>
                <% else %>
                  <article :for={entry <- current_exceptions(payload, @now)} class="alert-item">
                    <div class="item-head">
                      <div class="issue-stack">
                        <span class="muted"><%= entry.project_display_name || entry.project_key %></span>
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                      </div>
                      <span class={state_badge_class(exception_status(entry))}>
                        <%= exception_status(entry) %>
                      </span>
                    </div>
                    <p class="item-copy"><%= exception_summary(entry) %></p>
                    <div class="item-meta">
                      <span class="muted"><%= exception_session_label(entry) %></span>
                      <span class="muted"><%= exception_time_label(entry, @now) %></span>
                    </div>
                  </article>
                <% end %>
              </div>
            </section>

            <section class="panel">
              <div class="panel-head">
                <div>
                  <h2 class="section-title">Recent recovery</h2>
                  <p class="section-copy">Low-priority placeholder until a stable recovery feed exists.</p>
                </div>
              </div>
              <div class="panel-body">
                <p class="empty-state">No recovery feed wired yet.</p>
              </div>
            </section>
          </div>

          <div class="column column-running">
            <section class="panel">
              <div class="panel-head">
                <div>
                  <h2 class="section-title">Running sessions</h2>
                  <p class="section-copy">Stable running work, sorted by age of the latest update.</p>
                </div>
              </div>

              <%= if healthy_running(payload, @now) == [] do %>
                <div class="panel-body">
                  <p class="empty-state">No healthy running sessions.</p>
                </div>
              <% else %>
                <div class="table-wrap">
                  <table class="data-table data-table-running data-table-running-wide">
                    <thead>
                      <tr>
                        <th>Issue</th>
                        <th>Session</th>
                        <th>Runtime</th>
                        <th>Last</th>
                        <th>Tokens</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={entry <- healthy_running(payload, @now)}>
                        <td>
                          <div class="issue-stack">
                            <span class="muted"><%= entry.project_display_name || entry.project_key %></span>
                            <span class="issue-id"><%= entry.issue_identifier %></span>
                            <a class="issue-link" href={"/api/v1/projects/#{entry.project_key}/issues/#{entry.issue_identifier}"}>JSON details</a>
                          </div>
                        </td>
                        <td>
                          <%= if entry.session_id do %>
                            <button
                              type="button"
                              class="subtle-button"
                              data-label="Copy ID"
                              data-copy={entry.session_id}
                              onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                            >
                              Copy ID
                            </button>
                          <% else %>
                            <span class="muted">n/a</span>
                          <% end %>
                        </td>
                        <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                        <td>
                          <div class="detail-stack">
                            <span class="event-text"><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                            <span class="muted event-meta"><%= entry.last_event || "n/a" %></span>
                            <span class="muted event-meta"><%= relative_time(entry.last_event_at, @now) %></span>
                          </div>
                        </td>
                        <td>
                          <div class="token-stack numeric">
                            <span><%= format_int(entry.tokens.total_tokens) %></span>
                            <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                          </div>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </section>
          </div>
        </section>

        <section class="section-card section-card-secondary">
          <div class="section-header">
            <div>
              <h2 class="section-title">Projects</h2>
              <p class="section-copy">Low-priority project summary from the shared state payload.</p>
            </div>
          </div>

          <div class="projects-grid">
            <article :for={project <- payload.projects} class="project-card">
              <p class="metric-label"><%= project.project_display_name || project.project_key %></p>
              <p class="project-key mono"><%= project.project_key %></p>
              <p class="project-counts">Running <%= project.running_count %> · Retrying <%= project.retrying_count %> · Blocked <%= project.blocked_count %></p>
            </article>
          </div>
        </section>

        <section class="section-card section-card-secondary">
          <div class="section-header">
            <div>
              <h2 class="section-title">todo pool / blocked-by</h2>
              <p class="section-copy">Manual-check placeholder only. No automatic polling path is attached.</p>
            </div>
            <button type="button" class="secondary">Manual check</button>
          </div>

          <p class="empty-state">Pending integration. No stable payload is available yet.</p>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["waiting_input", "approval_required"]) -> "#{base} state-badge-warning"
      String.contains?(normalized, ["completed"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

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
    |> Enum.sort_by(fn entry -> {exception_priority(entry), stale_safe_timestamp(entry)} end)
  end

  defp healthy_running(payload, now) do
    payload.running
    |> Enum.reject(&(runtime_status_now(&1, now) == "stale"))
    |> Enum.sort_by(&stale_safe_timestamp/1)
  end

  defp exception_summary(entry) do
    Map.get(entry, :error) ||
      Map.get(entry, :last_message) ||
      to_string(Map.get(entry, :last_event) || Map.get(entry, :status) || "needs attention")
  end

  defp exception_status(entry) do
    Map.get(entry, :runtime_status) ||
      Map.get(entry, :state) ||
      Map.get(entry, :status) ||
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

  defp relative_time(nil, _now), do: "time unavailable"

  defp relative_time(%DateTime{} = timestamp, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, timestamp, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)} minutes ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)} hours ago"
      true -> "#{div(seconds, 86_400)} days ago"
    end
  end

  defp relative_time(timestamp, %DateTime{} = now) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> relative_time(parsed, now)
      _ -> "time unavailable"
    end
  end

  defp relative_time(_timestamp, _now), do: "time unavailable"

  defp exception_key(entry) do
    Map.get(entry, :issue_id) || Map.get(entry, :issue_identifier)
  end

  defp pick_exception_entry(entries) do
    Enum.min_by(entries, fn entry ->
      {exception_priority(entry), stale_safe_timestamp(entry)}
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

  defp stale_safe_timestamp(entry) do
    case entry_timestamp(entry) do
      %DateTime{} = timestamp -> {0, DateTime.to_unix(timestamp, :microsecond)}
      _ -> {1, 0}
    end
  end

  defp entry_timestamp(entry) do
    (
      Map.get(entry, :blocked_at) ||
        Map.get(entry, :last_event_at) ||
        Map.get(entry, :due_at)
    )
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
end
