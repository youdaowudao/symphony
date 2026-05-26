defmodule SymphonyElixir.Workspace.DispatchContext do
  @moduledoc false

  @enforce_keys [:project_key, :issue_id, :issue_identifier, :attempt]
  defstruct [
    :project_key,
    :issue_id,
    :issue_identifier,
    :worker_host,
    :workspace_path,
    :attempt
  ]

  @type t :: %__MODULE__{
          project_key: String.t(),
          issue_id: String.t(),
          issue_identifier: String.t(),
          worker_host: String.t() | nil,
          workspace_path: String.t() | nil,
          attempt: integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(%{} = attrs) do
    with {:ok, project_key} <- validate_project_key(Map.get(attrs, :project_key) || Map.get(attrs, "project_key")),
         {:ok, issue_id} <- validate_present_string(Map.get(attrs, :issue_id) || Map.get(attrs, "issue_id"), :issue_id),
         {:ok, issue_identifier} <-
           validate_present_string(
             Map.get(attrs, :issue_identifier) || Map.get(attrs, "issue_identifier"),
             :issue_identifier
           ),
         {:ok, attempt} <- validate_attempt(Map.get(attrs, :attempt) || Map.get(attrs, "attempt")),
         {:ok, worker_host} <- validate_optional_string(Map.get(attrs, :worker_host) || Map.get(attrs, "worker_host"), :worker_host),
         {:ok, workspace_path} <-
           validate_optional_string(
             Map.get(attrs, :workspace_path) || Map.get(attrs, "workspace_path"),
             :workspace_path
           ) do
      {:ok,
       %__MODULE__{
         project_key: project_key,
         issue_id: issue_id,
         issue_identifier: issue_identifier,
         worker_host: worker_host,
         workspace_path: workspace_path,
         attempt: attempt
       }}
    end
  end

  def new(_attrs), do: {:error, :cleanup_context_missing}

  @spec with_workspace_path(t(), String.t()) :: t()
  def with_workspace_path(%__MODULE__{} = context, workspace_path) when is_binary(workspace_path) do
    %{context | workspace_path: workspace_path}
  end

  @spec cleanup_ready?(t()) :: boolean()
  def cleanup_ready?(%__MODULE__{
        project_key: project_key,
        issue_id: issue_id,
        issue_identifier: issue_identifier,
        workspace_path: workspace_path,
        attempt: attempt
      }) do
    valid_present_string?(project_key) and
      valid_present_string?(issue_id) and
      valid_present_string?(issue_identifier) and
      valid_present_string?(workspace_path) and
      is_integer(attempt)
  end

  @spec path_segment(t()) :: String.t()
  def path_segment(%__MODULE__{issue_identifier: issue_identifier, issue_id: issue_id}) do
    safe_identifier(issue_identifier) <> "__" <> short_issue_id(issue_id)
  end

  @spec safe_identifier(String.t() | nil) :: String.t()
  def safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp short_issue_id(issue_id) when is_binary(issue_id) do
    issue_id
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> case do
      "" -> "issue"
      normalized -> String.slice(normalized, -8, 8) || normalized
    end
  end

  defp validate_project_key(project_key) do
    with {:ok, project_key} <- validate_present_string(project_key, :project_key),
         :ok <- validate_safe_path_segment(project_key) do
      {:ok, project_key}
    end
  end

  defp validate_safe_path_segment(project_key) do
    cond do
      project_key in [".", ".."] ->
        {:error, :invalid_project_key_path_segment}

      String.contains?(project_key, ["/", "\\", "\n", "\r", <<0>>]) ->
        {:error, :invalid_project_key_path_segment}

      true ->
        :ok
    end
  end

  defp validate_attempt(attempt) when is_integer(attempt), do: {:ok, attempt}
  defp validate_attempt(_attempt), do: {:error, :cleanup_context_missing}

  defp validate_optional_string(nil, _field), do: {:ok, nil}

  defp validate_optional_string(value, field) do
    validate_present_string(value, field)
  end

  defp validate_present_string(value, _field) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, :cleanup_context_missing}
    else
      {:ok, trimmed}
    end
  end

  defp validate_present_string(_value, _field), do: {:error, :cleanup_context_missing}

  defp valid_present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_present_string?(_value), do: false
end
