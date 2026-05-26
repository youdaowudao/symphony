defmodule SymphonyElixir.Workspace.OwnerFile do
  @moduledoc false

  alias SymphonyElixir.Workspace.DispatchContext

  @schema_version 1
  @owner_filename "workspace-owner.json"
  @required_string_fields ~w(project_key issue_id issue_identifier workspace_path created_at)
  @required_fields @required_string_fields ++ ~w(worker_host attempt)

  @spec relative_path() :: String.t()
  def relative_path, do: Path.join(".symphony", @owner_filename)

  @spec absolute_path(String.t()) :: String.t()
  def absolute_path(workspace_path) when is_binary(workspace_path) do
    Path.join(workspace_path, relative_path())
  end

  @spec write!(DispatchContext.t(), String.t()) :: :ok
  def write!(%DispatchContext{} = context, created_at) when is_binary(created_at) do
    owner_path = absolute_path(context.workspace_path)
    File.mkdir_p!(Path.dirname(owner_path))
    File.write!(owner_path, Jason.encode!(encode(context, created_at), pretty: true))
    :ok
  end

  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(workspace_path) when is_binary(workspace_path) do
    owner_path = absolute_path(workspace_path)

    case File.read(owner_path) do
      {:ok, contents} ->
        decode(contents)

      {:error, :enoent} ->
        {:error, :owner_missing}

      {:error, reason} ->
        {:error, {:owner_unreadable, reason}}
    end
  end

  @spec ownership_matches?(DispatchContext.t(), map()) :: boolean()
  def ownership_matches?(%DispatchContext{} = context, %{} = owner) do
    owner["project_key"] == context.project_key and
      owner["issue_id"] == context.issue_id and
      owner["worker_host"] == context.worker_host and
      owner["workspace_path"] == context.workspace_path
  end

  @spec decode(String.t()) :: {:ok, map()} | {:error, term()}
  def decode(contents) when is_binary(contents) do
    with {:ok, decoded} <- Jason.decode(contents),
         :ok <- validate_schema(decoded) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{}} ->
        {:error, :owner_invalid_json}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_schema(%{"schema_version" => @schema_version} = decoded) when is_map(decoded) do
    if required_fields_valid?(decoded) do
      :ok
    else
      {:error, :owner_schema_mismatch}
    end
  end

  defp validate_schema(%{}), do: {:error, :owner_schema_mismatch}
  defp validate_schema(_decoded), do: {:error, :owner_invalid_json}

  defp required_fields_valid?(decoded) when is_map(decoded) do
    Enum.all?(@required_string_fields, fn field ->
      case Map.get(decoded, field) do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end) and
      (is_nil(decoded["worker_host"]) or is_binary(decoded["worker_host"])) and
      is_integer(decoded["attempt"]) and
      Enum.all?(@required_fields, &Map.has_key?(decoded, &1))
  end

  defp encode(%DispatchContext{} = context, created_at) do
    %{
      schema_version: @schema_version,
      project_key: context.project_key,
      issue_id: context.issue_id,
      issue_identifier: context.issue_identifier,
      worker_host: context.worker_host,
      workspace_path: context.workspace_path,
      attempt: context.attempt,
      created_at: created_at
    }
  end
end
