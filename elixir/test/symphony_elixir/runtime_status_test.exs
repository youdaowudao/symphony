defmodule SymphonyElixir.RuntimeStatusTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RuntimeStatus

  test "classify/1 uses the current time for freshness fallback" do
    assert RuntimeStatus.classify(runtime_entry(~U[2099-05-24 21:39:38Z], :notification, turn_started_message())) ==
             :running

    assert RuntimeStatus.classify(runtime_entry(~U[2000-05-24 21:39:38Z], :notification, turn_started_message())) ==
             :stale
  end

  test "returns unknown for non-map entries" do
    assert RuntimeStatus.classify(nil, ~U[2026-05-24 21:39:38Z]) == :unknown
    assert RuntimeStatus.classify("not an entry", ~U[2026-05-24 21:39:38Z]) == :unknown
  end

  test "returns unknown when last codex timestamp is missing" do
    assert RuntimeStatus.classify(runtime_entry(nil, :notification, turn_started_message())) == :unknown
  end

  test "classifies string-key entries with ISO8601 timestamps" do
    assert RuntimeStatus.classify(
             %{
               "last_codex_timestamp" => "2026-05-24T21:39:38Z",
               "last_codex_event" => "approval_required"
             },
             ~U[2026-05-24 21:39:38Z]
           ) == :approval_required
  end

  test "returns unknown for invalid string timestamps" do
    assert RuntimeStatus.classify(
             %{
               "last_codex_timestamp" => "not-a-date",
               "last_codex_event" => "turn_completed"
             },
             ~U[2026-05-24 21:39:38Z]
           ) == :unknown
  end

  test "returns unknown when explicit codex status lacks a timestamp" do
    for entry <- [
          runtime_entry(nil, :turn_input_required, %{"method" => "turn/input_required"}),
          runtime_entry(nil, :approval_required, %{"method" => "turn/approval_required"}),
          runtime_entry(nil, :turn_ended_with_error, %{"method" => "turn/failed"}),
          runtime_entry(nil, :turn_completed, %{"method" => "turn/completed"})
        ] do
      assert RuntimeStatus.classify(entry, ~U[2026-05-24 21:39:38Z]) == :unknown
    end
  end

  test "returns running for a recent generic codex update" do
    now = ~U[2026-05-24 21:39:38Z]

    assert RuntimeStatus.classify(
             runtime_entry(now, :notification, turn_started_message()),
             now
           ) == :running
  end

  test "returns running for timestamped generic updates when now is unavailable" do
    assert RuntimeStatus.classify(
             runtime_entry(~U[2026-05-24 21:39:38Z], :notification, turn_started_message()),
             nil
           ) == :running
  end

  test "returns stale when the last codex update is older than ten minutes" do
    now = ~U[2026-05-24 21:39:38Z]

    assert RuntimeStatus.classify(
             runtime_entry(~U[2026-05-24 21:28:38Z], :notification, turn_started_message()),
             now
           ) == :stale
  end

  test "returns waiting_input for turn input required signals" do
    now = ~U[2026-05-24 21:39:38Z]

    for entry <- [
          runtime_entry(now, :turn_input_required, %{"method" => "turn/input_required"}),
          runtime_entry(now, "turn_input_required", %{"method" => "item/tool/requestUserInput"}),
          runtime_entry(now, :notification, %{"method" => "mcpServer/elicitation/request"})
        ] do
      assert RuntimeStatus.classify(entry, now) == :waiting_input
    end
  end

  test "returns approval_required for approval request signals" do
    now = ~U[2026-05-24 21:39:38Z]

    for entry <- [
          runtime_entry(now, :approval_required, %{"method" => "turn/approval_required"}),
          runtime_entry(now, :notification, %{"method" => "item/commandExecution/requestApproval"})
        ] do
      assert RuntimeStatus.classify(entry, now) == :approval_required
    end
  end

  test "classifies string event failure and completion signals" do
    now = ~U[2026-05-24 21:39:38Z]

    for event <- ["turn_ended_with_error", "turn_failed", "turn_cancelled"] do
      assert RuntimeStatus.classify(runtime_entry(now, event, nil), now) == :error
    end

    assert RuntimeStatus.classify(runtime_entry(now, "turn_completed", nil), now) == :completed
  end

  test "does not treat auto-handled input and approval events as still waiting" do
    now = ~U[2026-05-24 21:39:38Z]

    for entry <- [
          runtime_entry(now, :approval_auto_approved, %{"method" => "item/commandExecution/requestApproval"}),
          runtime_entry(now, :tool_input_auto_answered, %{"method" => "item/tool/requestUserInput"})
        ] do
      assert RuntimeStatus.classify(entry, now) == :running
    end
  end

  test "does not treat string auto-handled events as still waiting" do
    now = ~U[2026-05-24 21:39:38Z]

    for entry <- [
          runtime_entry(now, "approval_auto_approved", %{"method" => "item/commandExecution/requestApproval"}),
          runtime_entry(now, "tool_input_auto_answered", %{"method" => "item/tool/requestUserInput"})
        ] do
      assert RuntimeStatus.classify(entry, now) == :running
    end
  end

  test "returns error for terminal failure signals" do
    now = ~U[2026-05-24 21:39:38Z]

    for entry <- [
          runtime_entry(now, :turn_ended_with_error, %{"method" => "turn/failed"}),
          runtime_entry(now, "startup_failed", nil),
          runtime_entry(now, :turn_failed, %{"method" => "turn/failed"}),
          runtime_entry(now, :turn_cancelled, %{"method" => "turn/cancelled"})
        ] do
      assert RuntimeStatus.classify(entry, now) == :error
    end
  end

  test "returns completed for turn completed signals" do
    now = ~U[2026-05-24 21:39:38Z]

    for entry <- [
          runtime_entry(now, :turn_completed, %{"method" => "turn/completed"}),
          runtime_entry(now, :notification, %{"method" => "turn/completed"})
        ] do
      assert RuntimeStatus.classify(entry, now) == :completed
    end
  end

  test "classifies nested string-key message and payload envelopes" do
    now = ~U[2026-05-24 21:39:38Z]

    for entry <- [
          runtime_entry(now, :notification, %{"message" => %{"method" => "turn/failed"}}),
          runtime_entry(now, :notification, %{"payload" => %{"method" => "turn/cancelled"}})
        ] do
      assert RuntimeStatus.classify(entry, now) == :error
    end
  end

  test "classifies atom-key method payloads" do
    now = ~U[2026-05-24 21:39:38Z]

    assert RuntimeStatus.classify(
             runtime_entry(now, :notification, %{method: "turn/completed/ack"}),
             now
           ) == :completed
  end

  defp runtime_entry(last_codex_timestamp, last_codex_event, last_codex_message) do
    %{
      last_codex_timestamp: last_codex_timestamp,
      last_codex_event: last_codex_event,
      last_codex_message: last_codex_message
    }
  end

  defp turn_started_message do
    %{"method" => "turn/started"}
  end
end
