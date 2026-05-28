defmodule SymphonyElixir.Tracker.ProjectAggregation do
  @moduledoc """
  Builds read-only project-aware tracker candidates from normalized registry entries.
  """

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Tracker.ProjectCandidate

  @type project_entry :: map()
  @type project_result :: %{
          project_key: String.t() | nil,
          status: :ok | :failed | :skipped,
          fetched_count: non_neg_integer(),
          candidate_count: non_neg_integer(),
          reason: term() | nil
        }
  @type aggregate_result :: %{
          candidates: [ProjectCandidate.t()],
          project_results: [project_result()]
        }

  @spec aggregate([project_entry()], (String.t() -> {:ok, [Issue.t()]} | {:error, term()})) ::
          {:ok, aggregate_result()}
          | {:error, {:all_project_fetches_failed, [project_result()]}}
          | {:error, {:invalid_project_entry, term()}}
  def aggregate(project_entries, fetcher) when is_list(project_entries) and is_function(fetcher, 1) do
    with {:ok, contexts} <- build_project_contexts(project_entries) do
      {candidates, project_results} = aggregate_contexts(contexts, fetcher, [], [])
      finalized_candidates = Enum.reverse(candidates)
      finalized_project_results = Enum.reverse(project_results)
      attempted_results = Enum.reject(finalized_project_results, &(&1.status == :skipped))

      if attempted_results != [] and Enum.all?(attempted_results, &(&1.status == :failed)) do
        {:error, {:all_project_fetches_failed, finalized_project_results}}
      else
        {:ok, %{candidates: finalized_candidates, project_results: finalized_project_results}}
      end
    end
  end

  defp build_project_contexts(project_entries) do
    Enum.reduce_while(project_entries, {:ok, []}, fn entry, {:ok, contexts} ->
      case ProjectContext.from_registry_entry(entry) do
        {:ok, %ProjectContext{} = context} ->
          {:cont, {:ok, [context | contexts]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_project_entry, reason}}}
      end
    end)
    |> case do
      {:ok, contexts} -> {:ok, Enum.reverse(contexts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp aggregate_contexts([], _fetcher, candidates, project_results) do
    {candidates, project_results}
  end

  defp aggregate_contexts([%ProjectContext{enabled: false, project_key: project_key} | rest], fetcher, candidates, project_results) do
    aggregate_contexts(
      rest,
      fetcher,
      candidates,
      [project_result(project_key, :skipped, 0, 0, nil) | project_results]
    )
  end

  defp aggregate_contexts([%ProjectContext{} = context | rest], fetcher, candidates, project_results) do
    case fetcher.(context.project_key) do
      {:ok, issues} when is_list(issues) ->
        case build_candidates(issues, context) do
          {:ok, new_candidates} ->
            aggregate_contexts(
              rest,
              fetcher,
              Enum.reverse(new_candidates, candidates),
              [project_result(context.project_key, :ok, length(issues), length(new_candidates), nil) | project_results]
            )

          {:error, invalid_issue} ->
            aggregate_contexts(
              rest,
              fetcher,
              candidates,
              [
                project_result(
                  context.project_key,
                  :failed,
                  length(issues),
                  0,
                  {:invalid_project_issue, invalid_issue}
                )
                | project_results
              ]
            )
        end

      {:ok, other} ->
        aggregate_contexts(
          rest,
          fetcher,
          candidates,
          [
            project_result(
              context.project_key,
              :failed,
              0,
              0,
              {:invalid_project_fetch_result, other}
            )
            | project_results
          ]
        )

      {:error, reason} ->
        aggregate_contexts(
          rest,
          fetcher,
          candidates,
          [project_result(context.project_key, :failed, 0, 0, reason) | project_results]
        )

      other ->
        aggregate_contexts(
          rest,
          fetcher,
          candidates,
          [
            project_result(
              context.project_key,
              :failed,
              0,
              0,
              {:invalid_project_fetch_result, other}
            )
            | project_results
          ]
        )
    end
  end

  defp build_candidates(issues, context) do
    Enum.reduce_while(issues, {:ok, []}, fn
      %Issue{} = issue, {:ok, candidates} ->
        {:cont, {:ok, [ProjectCandidate.new!(issue, context) | candidates]}}

      issue, _acc ->
        {:halt, {:error, issue}}
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      {:error, issue} -> {:error, issue}
    end
  end

  defp project_result(project_key, status, fetched_count, candidate_count, reason) do
    %{
      project_key: project_key,
      status: status,
      fetched_count: fetched_count,
      candidate_count: candidate_count,
      reason: reason
    }
  end
end
