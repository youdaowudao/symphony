defmodule SymphonyElixir.ProjectRegistry do
  @moduledoc """
  Canonical project registry loader, validator, and normalizer.
  """

  alias SymphonyElixir.Workflow

  @default_max_concurrent_agents 15
  @registry_file_name "project_registry.yaml"
  @allowed_project_fields ~w(project_key enabled max_concurrent_agents)

  @type raw_entry :: %{
          project_key: String.t(),
          enabled: boolean(),
          max_concurrent_agents: pos_integer() | nil
        }

  @type normalized_entry :: %{
          project_key: String.t(),
          enabled: boolean(),
          max_concurrent_agents: pos_integer(),
          display_name: nil
        }

  @type registry :: %{
          schema_version: 1,
          projects: [raw_entry()]
        }

  @type normalized_source_result ::
          {:ok, {:registry | :legacy, [normalized_entry()]}} | :missing | {:error, term()}

  @spec default_path() :: Path.t()
  def default_path do
    Workflow.workflow_file_path()
    |> Path.dirname()
    |> Path.join(@registry_file_name)
  end

  @spec load() :: {:ok, registry()} | :missing | {:error, term()}
  def load, do: load(default_path())

  @spec load(Path.t()) :: {:ok, registry()} | :missing | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> decode_yaml()
        |> then(fn
          {:ok, decoded} -> validate_registry(decoded)
          {:error, reason} -> {:error, reason}
        end)

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, {:project_registry_read_error, path, reason}}
    end
  end

  @spec normalized_entries() :: {:ok, [normalized_entry()]} | {:error, term()}
  def normalized_entries do
    with {:ok, legacy_project_slug} <- current_legacy_project_slug() do
      case load_normalized(default_path(), legacy_project_slug) do
        {:ok, {:registry, entries}} -> {:ok, entries}
        {:ok, {:legacy, entries}} -> {:ok, entries}
        :missing -> {:error, :missing_linear_project_slug}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec normalized_entries(Path.t()) :: {:ok, [normalized_entry()]} | {:error, term()}
  def normalized_entries(path) when is_binary(path) do
    case load_normalized(path, nil) do
      {:ok, {:registry, entries}} ->
        {:ok, entries}

      :missing ->
        {:error, {:missing_project_registry, path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec load_normalized() :: normalized_source_result()
  def load_normalized do
    with {:ok, legacy_project_slug} <- current_legacy_project_slug() do
      load_normalized(default_path(), legacy_project_slug)
    end
  end

  @spec load_normalized(Path.t()) :: normalized_source_result()
  def load_normalized(path) when is_binary(path) do
    load_normalized(path, nil)
  end

  @spec load_normalized(Path.t(), String.t() | nil) :: normalized_source_result()
  def load_normalized(path, legacy_project_slug) when is_binary(path) do
    normalized_legacy_project_slug = normalize_legacy_project_slug(legacy_project_slug)

    case load(path) do
      {:ok, registry} ->
        with :ok <- validate_legacy_bridge(registry, normalized_legacy_project_slug) do
          {:ok, {:registry, Enum.map(registry.projects, &normalize_entry/1)}}
        end

      :missing ->
        case normalized_legacy_project_slug do
          nil ->
            :missing

          project_slug ->
            {:ok,
             {:legacy,
              [
                %{
                  project_key: project_slug,
                  enabled: true,
                  max_concurrent_agents: @default_max_concurrent_agents,
                  display_name: nil
                }
              ]}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, {:invalid_project_registry, "project registry must decode to a map"}}
      {:error, reason} -> {:error, {:invalid_project_registry, "failed to parse YAML: #{inspect(reason)}"}}
    end
  end

  defp validate_registry(decoded) do
    with {:ok, schema_version} <- validate_schema_version(Map.get(decoded, "schema_version")),
         {:ok, projects} <- validate_projects(Map.get(decoded, "projects")) do
      {:ok, %{schema_version: schema_version, projects: projects}}
    end
  end

  defp validate_schema_version(1), do: {:ok, 1}

  defp validate_schema_version(_value) do
    {:error, {:invalid_project_registry, "schema_version must equal 1"}}
  end

  defp validate_projects(projects) when is_list(projects) do
    projects
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, {[], MapSet.new()}}, fn {project, index}, {:ok, {entries, seen_keys}} ->
      case validate_project(project, index, seen_keys) do
        {:ok, entry, next_seen_keys} -> {:cont, {:ok, {[entry | entries], next_seen_keys}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, {entries, _seen_keys}} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_projects(nil) do
    {:error, {:invalid_project_registry, "projects is required"}}
  end

  defp validate_projects(_value) do
    {:error, {:invalid_project_registry, "projects must be a list"}}
  end

  defp validate_project(project, index, seen_keys) when is_map(project) do
    location = "projects[#{index}]"

    with :ok <- validate_allowed_project_fields(project, location),
         {:ok, project_key} <- validate_project_key(project, location),
         {:ok, enabled} <- validate_enabled(project, location),
         {:ok, max_concurrent_agents} <- validate_max_concurrent_agents(project, location),
         :ok <- validate_unique_project_key(project_key, seen_keys) do
      {:ok,
       %{
         project_key: project_key,
         enabled: enabled,
         max_concurrent_agents: max_concurrent_agents
       }, MapSet.put(seen_keys, project_key)}
    end
  end

  defp validate_project(_project, index, _seen_keys) do
    {:error, {:invalid_project_registry, "projects[#{index}] must be a map"}}
  end

  defp validate_allowed_project_fields(project, location) do
    invalid_field =
      project
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.find(&(&1 not in @allowed_project_fields))

    if invalid_field do
      {:error, {:invalid_project_registry, "#{location}.#{invalid_field} is not allowed"}}
    else
      :ok
    end
  end

  defp validate_project_key(project, location) do
    case Map.fetch(project, "project_key") do
      {:ok, value} when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          {:error, {:invalid_project_registry, "#{location}.project_key must be a non-empty string"}}
        else
          {:ok, trimmed}
        end

      {:ok, _value} ->
        {:error, {:invalid_project_registry, "#{location}.project_key must be a string"}}

      :error ->
        {:error, {:invalid_project_registry, "#{location}.project_key is required"}}
    end
  end

  defp validate_enabled(project, location) do
    case Map.fetch(project, "enabled") do
      {:ok, value} when is_boolean(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_project_registry, "#{location}.enabled must be a boolean"}}

      :error ->
        {:error, {:invalid_project_registry, "#{location}.enabled is required"}}
    end
  end

  defp validate_max_concurrent_agents(project, location) do
    case Map.fetch(project, "max_concurrent_agents") do
      {:ok, nil} ->
        {:error, {:invalid_project_registry, "#{location}.max_concurrent_agents must be a positive integer"}}

      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_project_registry, "#{location}.max_concurrent_agents must be a positive integer"}}

      :error ->
        {:ok, nil}
    end
  end

  defp validate_unique_project_key(project_key, seen_keys) do
    if MapSet.member?(seen_keys, project_key) do
      {:error, {:invalid_project_registry, "duplicate project_key: #{project_key}"}}
    else
      :ok
    end
  end

  defp normalize_entry(entry) do
    %{
      project_key: entry.project_key,
      enabled: entry.enabled,
      max_concurrent_agents: entry.max_concurrent_agents || @default_max_concurrent_agents,
      display_name: nil
    }
  end

  defp validate_legacy_bridge(%{projects: [_project]}, nil), do: :ok

  defp validate_legacy_bridge(%{projects: [project]}, legacy_project_slug) do
    if project.project_key == legacy_project_slug do
      :ok
    else
      {:error, {:project_registry_conflict, %{legacy_project_slug: legacy_project_slug}}}
    end
  end

  defp validate_legacy_bridge(%{projects: projects}, nil) when is_list(projects), do: :ok

  defp validate_legacy_bridge(%{projects: projects}, legacy_project_slug) when is_list(projects) do
    {:error, {:project_registry_conflict, %{legacy_project_slug: legacy_project_slug}}}
  end

  @spec normalize_legacy_project_slug(term()) :: String.t() | nil
  def normalize_legacy_project_slug(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_legacy_project_slug(_value), do: nil

  defp current_legacy_project_slug do
    case Workflow.load(Workflow.workflow_file_path()) do
      {:ok, %{config: config}} when is_map(config) ->
        extract_legacy_project_slug(config)

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:ok, nil}
    end
  end

  defp extract_legacy_project_slug(config) when is_map(config) do
    case get_in_tracker(config, "project_slug") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        {:ok, normalize_legacy_project_slug(value)}

      _value ->
        {:error, {:invalid_workflow_config, "tracker.project_slug must be a string"}}
    end
  end

  defp get_in_tracker(config, key) do
    tracker =
      Map.get(config, "tracker") ||
        Map.get(config, :tracker) ||
        %{}

    Map.get(tracker, key) || Map.get(tracker, String.to_atom(key))
  end
end
