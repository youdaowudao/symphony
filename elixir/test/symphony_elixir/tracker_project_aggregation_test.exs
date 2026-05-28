defmodule SymphonyElixir.TrackerProjectAggregationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Tracker.ProjectAggregation
  alias SymphonyElixir.Tracker.ProjectCandidate

  test "aggregates enabled project candidates with project context" do
    projects = [
      %{project_key: "project-a", enabled: true, max_concurrent_agents: 15, display_name: "Project A"},
      %{project_key: "project-b", enabled: false, max_concurrent_agents: 15, display_name: "Project B"}
    ]

    issue = %Issue{id: "issue-a", identifier: "A-1", state: "Todo"}

    fetcher = fn project_key ->
      send(self(), {:fetched_project, project_key})
      {:ok, [issue]}
    end

    assert {:ok, result} = ProjectAggregation.aggregate(projects, fetcher)

    assert [%ProjectCandidate{issue: ^issue, project_context: %ProjectContext{} = context}] =
             result.candidates

    assert context.project_key == "project-a"
    assert_receive {:fetched_project, "project-a"}
    refute_receive {:fetched_project, "project-b"}

    assert Enum.any?(
             result.project_results,
             &match?(%{project_key: "project-b", status: :skipped}, &1)
           )
  end

  test "keeps successful candidates when another project fails" do
    projects = [
      %{project_key: "project-a", enabled: true, max_concurrent_agents: 15},
      %{project_key: "project-b", enabled: true, max_concurrent_agents: 15}
    ]

    fetcher = fn
      "project-a" -> {:ok, [%Issue{id: "issue-a", identifier: "A-1"}]}
      "project-b" -> {:error, :timeout}
    end

    assert {:ok, result} = ProjectAggregation.aggregate(projects, fetcher)

    assert length(result.candidates) == 1

    assert Enum.any?(
             result.project_results,
             &match?(%{project_key: "project-b", status: :failed, reason: :timeout}, &1)
           )
  end

  test "returns aggregate error when all enabled projects fail" do
    projects = [
      %{project_key: "project-a", enabled: true, max_concurrent_agents: 15},
      %{project_key: "project-b", enabled: true, max_concurrent_agents: 15}
    ]

    assert {:error, {:all_project_fetches_failed, project_results}} =
             ProjectAggregation.aggregate(projects, fn _project_key -> {:error, :timeout} end)

    assert Enum.map(project_results, & &1.status) == [:failed, :failed]
  end

  test "returns aggregate error when enabled project fails and disabled project is skipped" do
    projects = [
      %{project_key: "project-a", enabled: true, max_concurrent_agents: 15},
      %{project_key: "project-b", enabled: false, max_concurrent_agents: 15}
    ]

    assert {:error, {:all_project_fetches_failed, project_results}} =
             ProjectAggregation.aggregate(projects, fn "project-a" -> {:error, :timeout} end)

    assert Enum.map(project_results, & &1.status) == [:failed, :skipped]
  end

  test "fails closed before fetching when a normalized entry is invalid" do
    projects = [
      %{project_key: "project-a", enabled: true, max_concurrent_agents: 15},
      %{project_key: "project-b", enabled: "true", max_concurrent_agents: 15}
    ]

    assert {:error, {:invalid_project_entry, {:invalid_project_context_entry, _entry}}} =
             ProjectAggregation.aggregate(projects, fn project_key ->
               send(self(), {:fetched_project, project_key})
               {:ok, []}
             end)

    refute_receive {:fetched_project, _project_key}
  end

  test "returns empty aggregate when every project is disabled" do
    projects = [
      %{project_key: "project-a", enabled: false, max_concurrent_agents: 15},
      %{project_key: "project-b", enabled: false, max_concurrent_agents: 15}
    ]

    assert {:ok, result} =
             ProjectAggregation.aggregate(projects, fn project_key ->
               send(self(), {:fetched_project, project_key})
               {:ok, []}
             end)

    assert result.candidates == []
    assert Enum.map(result.project_results, & &1.status) == [:skipped, :skipped]
    refute_receive {:fetched_project, _project_key}
  end

  test "treats invalid issue payload as a project-scoped failure and keeps other project results" do
    projects = [
      %{project_key: "project-a", enabled: true, max_concurrent_agents: 15},
      %{project_key: "project-b", enabled: true, max_concurrent_agents: 15}
    ]

    fetcher = fn
      "project-a" -> {:ok, [%Issue{id: "issue-a", identifier: "A-1"}]}
      "project-b" -> {:ok, [:invalid_issue]}
    end

    assert {:ok, result} = ProjectAggregation.aggregate(projects, fetcher)

    assert [%ProjectCandidate{project_context: %ProjectContext{project_key: "project-a"}}] =
             result.candidates

    assert Enum.any?(
             result.project_results,
             &match?(
               %{
                 project_key: "project-b",
                 status: :failed,
                 fetched_count: 1,
                 candidate_count: 0,
                 reason: {:invalid_project_issue, :invalid_issue}
               },
               &1
             )
           )
  end

  test "treats invalid fetch result shapes as project-scoped failures" do
    projects = [
      %{project_key: "project-a", enabled: true, max_concurrent_agents: 15},
      %{project_key: "project-b", enabled: true, max_concurrent_agents: 15}
    ]

    fetcher = fn
      "project-a" -> {:ok, :not_a_list}
      "project-b" -> :unexpected
    end

    assert {:error, {:all_project_fetches_failed, project_results}} =
             ProjectAggregation.aggregate(projects, fetcher)

    assert Enum.any?(
             project_results,
             &match?(
               %{project_key: "project-a", status: :failed, reason: {:invalid_project_fetch_result, :not_a_list}},
               &1
             )
           )

    assert Enum.any?(
             project_results,
             &match?(
               %{project_key: "project-b", status: :failed, reason: {:invalid_project_fetch_result, :unexpected}},
               &1
             )
           )
  end
end
