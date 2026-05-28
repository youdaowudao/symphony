# Usage: see test/support/dashboard_fixture_visual_review_README.md
defmodule SymphonyElixir.TestSupport.DashboardUiFixtureScenarios do
  @moduledoc false

  @scenario_names [:small, :saturated, :extreme]

  @spec scenario_names() :: [:small | :saturated | :extreme]
  def scenario_names, do: @scenario_names

  @spec scenario(atom() | String.t()) :: map()
  def scenario(name) do
    case normalize_scenario(name) do
      :small -> small_scenario()
      :saturated -> saturated_scenario()
      :extreme -> extreme_scenario()
    end
  end

  @spec normalize_scenario(atom() | String.t()) :: :small | :saturated | :extreme
  def normalize_scenario(name) when name in @scenario_names, do: name

  def normalize_scenario(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.to_existing_atom()
    |> normalize_scenario()
  rescue
    _error ->
      reraise ArgumentError,
              [message: "unknown Dashboard Fixture Visual Review scenario: #{inspect(name)}"],
              __STACKTRACE__
  end

  def normalize_scenario(name) do
    raise ArgumentError, "unknown Dashboard Fixture Visual Review scenario: #{inspect(name)}"
  end

  defp small_scenario do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    projects = [{"alpha", "Alpha 控制台"}, {"beta", "Beta 空闲项目"}]

    running = [
      running_entry(now, "alpha", "Alpha 控制台", 1,
        identifier: "DASH-SMALL-RUN-01",
        started_seconds_ago: 160,
        last_event_seconds_ago: 35,
        tokens: {32, 54, 86},
        turn_count: 1,
        message: "少量运行项，用于检查低数据量主列表。"
      )
    ]

    %{
      projects: project_summaries(projects, running, [], []),
      running: running,
      retrying: [],
      blocked: [],
      recovery_events: [],
      codex_totals: %{input_tokens: 32, output_tokens: 54, total_tokens: 86, seconds_running: 45},
      rate_limits: %{"primary" => %{"remaining" => 14, "limit" => 60}},
      todo_pool: [
        todo_project("alpha", "Alpha 控制台", [
          todo_item("DASH-SMALL-TODO-01", "检查低量态 Todo Pool 卡片", "来自人工视觉巡检 fixture，尚未进入 running。")
        ]),
        todo_project("beta", "Beta 空闲项目", [])
      ]
    }
  end

  defp saturated_scenario do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    projects = [
      {"alpha", "Alpha 控制台"},
      {"beta", "Beta 任务工厂"},
      {"gamma", "Gamma 数据同步"},
      {"delta", "Delta 审批流"},
      {"epsilon", "Epsilon 客户成功"},
      {"zeta", "Zeta 空闲项目"},
      {"eta", "Eta 搜索索引"},
      {"theta", "Theta 账单"}
    ]

    healthy_running =
      Enum.map(1..20, fn index ->
        {project_key, project_name} = Enum.at(projects, rem(index - 1, length(projects)))
        token_total = 1_000 + index * 211

        running_entry(now, project_key, project_name, index,
          identifier: "DASH-SAT-RUN-#{pad2(index)}",
          started_seconds_ago: 180 + index * 95,
          last_event_seconds_ago: 15 + rem(index * 17, 480),
          tokens: {div(token_total, 2), token_total - div(token_total, 2), token_total},
          turn_count: 2 + rem(index, 7),
          attempt: 1 + rem(index, 3),
          message: "满载运行摘要 #{pad2(index)}，用于检查二十条 running 的密度、排序和摘要截断。"
        )
      end)

    stale_running = [
      running_entry(now, "gamma", "Gamma 数据同步", 21,
        identifier: "DASH-SAT-STALE-01",
        started_seconds_ago: 4_200,
        last_event_seconds_ago: 13 * 60,
        tokens: {720, 690, 1_410},
        turn_count: 10,
        attempt: 4,
        message: "长时间未更新，应作为 stale 出现在当前异常中。"
      )
    ]

    retrying = [
      retrying_entry(now, "beta", "Beta 任务工厂", 1,
        identifier: "DASH-SAT-RETRY-01",
        attempt: 2,
        due_in_ms: 90_000,
        error: "等待下一次重试，观察左侧异常列表的两到三行摘要。"
      ),
      retrying_entry(now, "theta", "Theta 账单", 2,
        identifier: "DASH-SAT-RETRY-02",
        attempt: 3,
        due_in_ms: 180_000,
        error: "上游 rate limit 后退避，保持异常行可读。"
      )
    ]

    blocked = [
      blocked_entry(now, "delta", "Delta 审批流", 1,
        identifier: "DASH-SAT-BLOCKED-01",
        event: :approval_required,
        error: "等待审批确认，不能继续执行。"
      ),
      blocked_entry(now, "epsilon", "Epsilon 客户成功", 2,
        identifier: "DASH-SAT-BLOCKED-02",
        event: :turn_input_required,
        error: "等待人工输入客户上下文。"
      )
    ]

    running = healthy_running ++ stale_running

    todo_counts = %{
      "alpha" => 0,
      "beta" => 2,
      "gamma" => 5,
      "delta" => 8,
      "epsilon" => 3,
      "zeta" => 1
    }

    %{
      projects: project_summaries(projects, running, retrying, blocked),
      running: running,
      retrying: retrying,
      blocked: blocked,
      recovery_events: recovery_events(now, projects, 4, "DASH-SAT-RECOVERED"),
      codex_totals: token_totals(running, 18_240),
      rate_limits: %{
        "primary" => %{"remaining" => 31, "limit" => 60},
        "secondary" => %{"remaining" => 900, "limit" => 1_200}
      },
      todo_pool: todo_pool_from_counts(projects, todo_counts, "DASH-SAT-TODO")
    }
  end

  defp extreme_scenario do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    projects = [
      {"extreme-alpha", "超长项目展示名 Alpha / 多语言 Operations / 需要验证项目名在窄列中不会把按钮挤掉"},
      {"extreme-beta", "Beta 项目"},
      {"extreme-gamma", "Gamma 零待执行项目"}
    ]

    long_identifier =
      "DASH-EXTREME-" <>
        String.duplicate("LONG-ISSUE-IDENTIFIER-", 5) <>
        "END"

    long_session =
      "session-" <>
        String.duplicate("abcdef1234567890-", 8) <>
        "tail"

    long_message =
      "极端长消息 mixed English / 中文 / symbols <> [] {} -- " <>
        String.duplicate("这是一段用于验证溢出、换行和截断的文本。", 8)

    running = [
      running_entry(now, "extreme-alpha", elem(Enum.at(projects, 0), 1), 1,
        identifier: long_identifier,
        session_id: long_session,
        started_seconds_ago: 96 * 60 * 60,
        last_event_seconds_ago: 20,
        tokens: {987_654_321, 123_456_789, 1_111_111_110},
        turn_count: 999,
        attempt: 12,
        message: long_message
      ),
      running_entry(now, "extreme-beta", "Beta 项目", 2,
        identifier: "DASH-EXTREME-MISSING-SESSION",
        session_id: nil,
        started_seconds_ago: 24 * 60 * 60,
        last_event_seconds_ago: 8 * 60,
        tokens: {1_024, 2_048, 3_072},
        turn_count: 0,
        message: "缺失 session_id，验证 copy session fallback。"
      )
    ]

    stale_running = [
      running_entry(now, "extreme-alpha", elem(Enum.at(projects, 0), 1), 3,
        identifier: "DASH-EXTREME-STALE-" <> String.duplicate("X", 48),
        started_seconds_ago: 9 * 24 * 60 * 60,
        last_event_seconds_ago: 3_601,
        tokens: {999_999_999, 888_888_888, 1_888_888_887},
        turn_count: 42,
        message: "极端 stale running：" <> long_message
      )
    ]

    retrying = [
      retrying_entry(now, "extreme-beta", "Beta 项目", 1,
        identifier: "DASH-EXTREME-RETRY-" <> String.duplicate("R", 44),
        attempt: 99,
        due_in_ms: 9_999_999,
        error: "极端长 retry reason：" <> long_message
      )
    ]

    blocked = [
      blocked_entry(now, "extreme-alpha", elem(Enum.at(projects, 0), 1), 1,
        identifier: "DASH-EXTREME-BLOCKED-" <> String.duplicate("B", 40),
        session_id: nil,
        blocked_at: nil,
        last_event_at: nil,
        event: :turn_input_required,
        error: "缺失 blocked_at / last_event_at，且 reason 极长：" <> long_message
      )
    ]

    running_all = running ++ stale_running

    %{
      projects: project_summaries(projects, running_all, retrying, blocked),
      running: running_all,
      retrying: retrying,
      blocked: blocked,
      recovery_events: [
        %{
          project_key: "extreme-alpha",
          project_display_name: elem(Enum.at(projects, 0), 1),
          issue_identifier: "DASH-EXTREME-RECOVERED-" <> String.duplicate("恢复事件-", 12),
          recovery_attempt_count: 123,
          last_event_at: nil,
          last_message: long_message,
          session_id: long_session
        }
      ],
      codex_totals: %{
        input_tokens: 2_147_483_647,
        output_tokens: 1_610_612_736,
        total_tokens: 3_758_096_383,
        seconds_running: 987_654
      },
      rate_limits: %{
        "primary" => %{
          "remaining" => 0,
          "limit" => 60,
          "reset_at" => DateTime.to_iso8601(DateTime.add(now, 3_600, :second))
        }
      },
      todo_pool: [
        todo_project(
          "extreme-alpha",
          elem(Enum.at(projects, 0), 1),
          extreme_todo_items("extreme-alpha", 11, long_message)
        ),
        todo_project(
          "extreme-beta",
          "Beta 项目",
          extreme_todo_items("extreme-beta", 2, "短 reason 与极长 reason 混排。")
        ),
        todo_project("extreme-gamma", "Gamma 零待执行项目", [])
      ]
    }
  end

  defp running_entry(now, project_key, project_name, index, opts) do
    {input_tokens, output_tokens, total_tokens} = Keyword.fetch!(opts, :tokens)

    %{
      project_key: project_key,
      project_display_name: project_name,
      issue_id: "#{project_key}-run-#{index}",
      identifier: Keyword.fetch!(opts, :identifier),
      state: "In Progress",
      worker_host: "fixture-host-#{rem(index, 5) + 1}",
      workspace_path: "/tmp/symphony-dashboard-fixture/#{project_key}/run-#{index}",
      attempt: Keyword.get(opts, :attempt, 1),
      session_id: Keyword.get(opts, :session_id, "fixture-session-#{project_key}-#{index}"),
      turn_count: Keyword.get(opts, :turn_count, 1),
      last_codex_event: Keyword.get(opts, :event, :notification),
      last_codex_message: Keyword.fetch!(opts, :message),
      started_at: DateTime.add(now, -Keyword.fetch!(opts, :started_seconds_ago), :second),
      last_codex_timestamp: DateTime.add(now, -Keyword.fetch!(opts, :last_event_seconds_ago), :second),
      codex_input_tokens: input_tokens,
      codex_output_tokens: output_tokens,
      codex_total_tokens: total_tokens
    }
  end

  defp retrying_entry(now, project_key, project_name, index, opts) do
    %{
      project_key: project_key,
      project_display_name: project_name,
      issue_id: "#{project_key}-retry-#{index}",
      identifier: Keyword.fetch!(opts, :identifier),
      attempt: Keyword.fetch!(opts, :attempt),
      due_in_ms: Keyword.fetch!(opts, :due_in_ms),
      error: Keyword.fetch!(opts, :error),
      worker_host: "fixture-retry-host-#{index}",
      workspace_path: "/tmp/symphony-dashboard-fixture/#{project_key}/retry-#{index}",
      last_codex_timestamp: DateTime.add(now, -(4 * 60 + index * 30), :second)
    }
  end

  defp blocked_entry(now, project_key, project_name, index, opts) do
    event = Keyword.fetch!(opts, :event)

    %{
      project_key: project_key,
      project_display_name: project_name,
      issue_id: "#{project_key}-blocked-#{index}",
      identifier: Keyword.fetch!(opts, :identifier),
      state: "In Progress",
      error: Keyword.fetch!(opts, :error),
      worker_host: "fixture-blocked-host-#{index}",
      workspace_path: "/tmp/symphony-dashboard-fixture/#{project_key}/blocked-#{index}",
      session_id: Keyword.get(opts, :session_id, "fixture-blocked-session-#{project_key}-#{index}"),
      blocked_at: Keyword.get(opts, :blocked_at, DateTime.add(now, -(2 * 60 + index * 45), :second)),
      last_codex_event: event,
      last_codex_message: Keyword.fetch!(opts, :error),
      last_codex_timestamp: Keyword.get(opts, :last_event_at, DateTime.add(now, -(2 * 60 + index * 45), :second))
    }
  end

  defp project_summaries(projects, running, retrying, blocked) do
    Enum.map(projects, fn {project_key, project_name} ->
      %{
        project_key: project_key,
        project_display_name: project_name,
        running_count: Enum.count(running, &(&1.project_key == project_key)),
        retrying_count: Enum.count(retrying, &(&1.project_key == project_key)),
        blocked_count: Enum.count(blocked, &(&1.project_key == project_key))
      }
    end)
  end

  defp token_totals(running, seconds_running) do
    Enum.reduce(
      running,
      %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: seconds_running},
      fn entry, totals ->
        %{
          input_tokens: totals.input_tokens + entry.codex_input_tokens,
          output_tokens: totals.output_tokens + entry.codex_output_tokens,
          total_tokens: totals.total_tokens + entry.codex_total_tokens,
          seconds_running: totals.seconds_running
        }
      end
    )
  end

  defp recovery_events(now, projects, count, prefix) do
    Enum.map(1..count, fn index ->
      {project_key, project_name} = Enum.at(projects, rem(index - 1, length(projects)))

      %{
        project_key: project_key,
        project_display_name: project_name,
        issue_identifier: "#{prefix}-#{pad2(index)}",
        recovery_attempt_count: 1 + rem(index, 3),
        last_event_at: DateTime.add(now, -(index * 95), :second),
        last_message: "恢复事件 #{pad2(index)} 摘要控制在两到三行预算内。",
        session_id: "recovered-session-#{pad2(index)}"
      }
    end)
  end

  defp todo_pool_from_counts(projects, counts, prefix) do
    Enum.map(projects, fn {project_key, project_name} ->
      count = Map.get(counts, project_key, 0)

      items =
        Enum.map(1..count//1, fn index ->
          todo_item(
            "#{prefix}-#{String.upcase(project_key)}-#{pad2(index)}",
            "#{project_name} 待执行卡片 #{pad2(index)}",
            "来自 fixture todo pool，项目 #{project_name} 当前尚未开始 running。"
          )
        end)

      todo_project(project_key, project_name, items)
    end)
  end

  defp extreme_todo_items(project_key, count, reason) do
    Enum.map(1..count, fn index ->
      todo_item(
        "DASH-EXTREME-TODO-#{String.upcase(project_key)}-#{pad2(index)}-" <>
          String.duplicate("ID", rem(index, 4) + 1),
        "极端待执行标题 #{pad2(index)} / " <>
          String.duplicate("very-long-title-segment-", rem(index, 5) + 2),
        reason
      )
    end)
  end

  defp todo_project(project_key, project_name, items) do
    %{
      project_key: project_key,
      project_display_name: project_name,
      items: items
    }
  end

  defp todo_item(identifier, title, reason) do
    %{
      issue_identifier: identifier,
      title: title,
      source: "Dashboard Fixture Visual Review",
      waiting_reason: reason,
      status: "not_started"
    }
  end

  defp pad2(index), do: index |> Integer.to_string() |> String.pad_leading(2, "0")
end
