defmodule SymphonyElixir.LinearTokenBootstrap do
  @moduledoc false

  alias SymphonyElixir.ProjectRegistry
  alias SymphonyElixir.Workflow

  @app :symphony_elixir
  @linear_tracker_kind "linear"

  @spec bootstrap(Path.t()) :: :ok | {:error, String.t()}
  def bootstrap(workflow_path) when is_binary(workflow_path) do
    with {:ok, registry_path} <- registry_path(workflow_path),
         {:ok, token_path} <- token_path(registry_path),
         {:ok, token} <- read_token(token_path) do
      Application.put_env(@app, :linear_api_token, token)
      :ok
    end
  end

  @spec bootstrap_if_needed(Path.t()) :: :ok | {:error, String.t()}
  def bootstrap_if_needed(workflow_path) when is_binary(workflow_path) do
    case workflow_tracker_kind(workflow_path) do
      {:ok, @linear_tracker_kind} -> bootstrap(workflow_path)
      {:ok, _other} -> :ok
      {:error, _message} = error -> error
    end
  end

  @spec workflow_tracker_kind(Path.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def workflow_tracker_kind(workflow_path) when is_binary(workflow_path) do
    case Workflow.load(workflow_path) do
      {:ok, %{config: config}} when is_map(config) ->
        {:ok,
         config
         |> extract_tracker_kind()
         |> normalize_tracker_kind()}

      {:error, reason} ->
        {:error, format_workflow_load_error(workflow_path, reason)}
    end
  end

  defp registry_path(workflow_path) do
    path = Path.join(Path.dirname(workflow_path), "project_registry.yaml")

    case ProjectRegistry.load(path) do
      {:ok, _registry} ->
        {:ok, path}

      :missing ->
        {:error, "Linear token bootstrap failed: missing project_registry.yaml at #{path}"}

      {:error, reason} ->
        {:error, "Linear token bootstrap failed: #{format_registry_error(path, reason)}"}
    end
  end

  defp token_path(registry_path) do
    case ProjectRegistry.load(registry_path) do
      {:ok, %{linear_token_relative_path: relative_path}} ->
        home = System.get_env("HOME")

        if not is_binary(home) or String.trim(home) == "" do
          {:error, "Linear token bootstrap failed: HOME is missing; cannot resolve #{relative_path}"}
        else
          resolve_home_relative_token_path(home, relative_path)
        end

      :missing ->
        {:error, "Linear token bootstrap failed: missing project_registry.yaml at #{registry_path}"}

      {:error, reason} ->
        {:error, "Linear token bootstrap failed: #{format_registry_error(registry_path, reason)}"}
    end
  end

  defp resolve_home_relative_token_path(home, relative_path) do
    expanded_home = Path.expand(home)
    expanded_token_path = Path.expand(relative_path, expanded_home)

    if expanded_token_path == expanded_home or
         String.starts_with?(expanded_token_path, expanded_home <> "/") do
      {:ok, expanded_token_path}
    else
      {:error, "Linear token bootstrap failed: linear_token_relative_path must stay within HOME: #{relative_path}"}
    end
  end

  defp read_token(token_path) do
    case File.read(token_path) do
      {:ok, content} ->
        case String.trim(content) do
          "" ->
            {:error, "Linear token bootstrap failed: token file is empty or invalid at #{token_path}"}

          token ->
            {:ok, token}
        end

      {:error, :enoent} ->
        {:error, "Linear token bootstrap failed: token file not found at #{token_path}"}

      {:error, :eacces} ->
        {:error, "Linear token bootstrap failed: token file is not readable at #{token_path}"}

      {:error, reason} ->
        {:error, "Linear token bootstrap failed: failed to read token file at #{token_path}: #{inspect(reason)}"}
    end
  end

  defp format_registry_error(path, {:project_registry_read_error, registry_path, reason}) do
    if registry_path == path do
      "failed to read project_registry.yaml at #{path}: #{inspect(reason)}"
    else
      "failed to read project_registry.yaml at #{registry_path}: #{inspect(reason)}"
    end
  end

  defp format_registry_error(_path, {:invalid_project_registry, message}) do
    "invalid project_registry.yaml: #{message}"
  end

  defp format_registry_error(path, reason) do
    "project_registry.yaml error at #{path}: #{inspect(reason)}"
  end

  defp format_workflow_load_error(workflow_path, reason) do
    "Linear token bootstrap failed: failed to load workflow at #{workflow_path}: #{inspect(reason)}"
  end

  defp extract_tracker_kind(config) when is_map(config) do
    tracker =
      Map.get(config, "tracker") ||
        Map.get(config, :tracker)

    case tracker do
      %{} = tracker_config ->
        Map.get(tracker_config, "kind") || Map.get(tracker_config, :kind)

      _other ->
        nil
    end
  end

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_kind(_kind), do: nil
end
