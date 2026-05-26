defmodule SymphonyElixir.ProjectContext do
  @moduledoc """
  Runtime project identity attached to project-aware tracker candidates.
  """

  @enforce_keys [:project_key, :display_name, :enabled, :max_concurrent_agents]
  defstruct [:project_key, :display_name, :enabled, :max_concurrent_agents]

  @type t :: %__MODULE__{
          project_key: String.t(),
          display_name: String.t(),
          enabled: boolean(),
          max_concurrent_agents: pos_integer()
        }

  @spec from_registry_entry(map()) :: {:ok, t()} | {:error, {:invalid_project_context_entry, map()}}
  def from_registry_entry(
        %{project_key: project_key, enabled: enabled, max_concurrent_agents: max_concurrent_agents} =
          entry
      )
      when is_binary(project_key) and is_boolean(enabled) and is_integer(max_concurrent_agents) and
             max_concurrent_agents > 0 do
    case String.trim(project_key) do
      "" ->
        {:error, {:invalid_project_context_entry, entry}}

      trimmed_project_key ->
        {:ok,
         %__MODULE__{
           project_key: trimmed_project_key,
           display_name: normalize_display_name(Map.get(entry, :display_name), trimmed_project_key),
           enabled: enabled,
           max_concurrent_agents: max_concurrent_agents
         }}
    end
  end

  def from_registry_entry(entry) when is_map(entry) do
    {:error, {:invalid_project_context_entry, entry}}
  end

  defp normalize_display_name(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed_value -> trimmed_value
    end
  end

  defp normalize_display_name(_value, fallback), do: fallback
end
