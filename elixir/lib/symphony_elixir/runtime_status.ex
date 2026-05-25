defmodule SymphonyElixir.RuntimeStatus do
  @moduledoc """
  Shared classifier for Codex runtime status projections.
  """

  @type t :: :running | :stale | :unknown | :waiting_input | :approval_required | :error | :completed

  @stale_threshold_seconds 10 * 60

  @spec classify(term()) :: t()
  def classify(entry), do: classify(entry, DateTime.utc_now())

  @spec classify(term(), DateTime.t() | nil) :: t()
  def classify(%{} = entry, now) do
    case timestamp(entry) do
      nil ->
        :unknown

      %DateTime{} = timestamp ->
        explicit_status(entry) || freshness_status(timestamp, now)
    end
  end

  def classify(_entry, _now), do: :unknown

  defp explicit_status(entry) do
    event = Map.get(entry, :last_codex_event) || Map.get(entry, "last_codex_event")

    normalize_event(event) ||
      if skip_message_status?(event) do
        nil
      else
        normalize_message_method(message_method(Map.get(entry, :last_codex_message) || Map.get(entry, "last_codex_message")))
      end
  end

  defp normalize_event(event) when is_atom(event) do
    case event do
      :turn_input_required -> :waiting_input
      :approval_required -> :approval_required
      :turn_ended_with_error -> :error
      :startup_failed -> :error
      :turn_failed -> :error
      :turn_cancelled -> :error
      :turn_completed -> :completed
      _ -> nil
    end
  end

  defp normalize_event(event) when is_binary(event) do
    event
    |> String.trim()
    |> case do
      "turn_input_required" -> :waiting_input
      "approval_required" -> :approval_required
      "turn_ended_with_error" -> :error
      "startup_failed" -> :error
      "turn_failed" -> :error
      "turn_cancelled" -> :error
      "turn_completed" -> :completed
      _ -> nil
    end
  end

  defp normalize_event(_event), do: nil

  defp skip_message_status?(event) when event in [:approval_auto_approved, :tool_input_auto_answered], do: true
  defp skip_message_status?(event) when event in ["approval_auto_approved", "tool_input_auto_answered"], do: true
  defp skip_message_status?(_event), do: false

  defp normalize_message_method(nil), do: nil

  defp normalize_message_method(method)
       when method in [
              "turn/input_required",
              "turn/needs_input",
              "turn/need_input",
              "turn/request_input",
              "turn/request_response",
              "turn/provide_input",
              "item/tool/requestUserInput",
              "mcpServer/elicitation/request"
            ] do
    :waiting_input
  end

  defp normalize_message_method(method)
       when method in [
              "turn/approval_required",
              "item/commandExecution/requestApproval",
              "item/fileChange/requestApproval",
              "execCommandApproval",
              "applyPatchApproval"
            ] do
    :approval_required
  end

  defp normalize_message_method(method) when method in ["turn/completed", "turn/completed/ack"] do
    :completed
  end

  defp normalize_message_method(method) when method in ["turn/failed", "turn/cancelled"] do
    :error
  end

  defp normalize_message_method(_method), do: nil

  defp freshness_status(%DateTime{} = timestamp, %DateTime{} = now) do
    if stale?(timestamp, now), do: :stale, else: :running
  end

  defp freshness_status(%DateTime{}, _now), do: :running

  defp timestamp(entry) do
    entry
    |> Map.get(:last_codex_timestamp)
    |> normalize_timestamp()
    |> case do
      nil ->
        entry
        |> Map.get("last_codex_timestamp")
        |> normalize_timestamp()

      timestamp ->
        timestamp
    end
  end

  defp normalize_timestamp(%DateTime{} = timestamp), do: DateTime.truncate(timestamp, :second)

  defp normalize_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> DateTime.truncate(parsed, :second)
      _ -> nil
    end
  end

  defp normalize_timestamp(_timestamp), do: nil

  defp message_method(%{message: message}), do: message_method(message)
  defp message_method(%{"message" => message}), do: message_method(message)
  defp message_method(%{payload: payload}), do: message_method(payload)
  defp message_method(%{"payload" => payload}), do: message_method(payload)
  defp message_method(%{"method" => method}) when is_binary(method), do: method
  defp message_method(%{method: method}) when is_binary(method), do: method
  defp message_method(_message), do: nil

  defp stale?(%DateTime{} = timestamp, %DateTime{} = now) do
    DateTime.diff(now, timestamp, :second) > @stale_threshold_seconds
  end
end
