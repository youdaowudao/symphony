defmodule SymphonyElixir.LinearClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  test "fetches candidate issues for explicit project key without reading tracker.project_slug" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    graphql_fun = fn _query, variables ->
      send(self(), {:linear_query_variables, variables})

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-1",
                 "identifier" => "MT-1",
                 "title" => "Task",
                 "state" => %{"name" => "Todo"},
                 "priority" => 1,
                 "createdAt" => "2026-05-25T00:00:00Z",
                 "updatedAt" => "2026-05-25T00:00:00Z"
               }
             ],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    assert {:ok, [issue]} =
             Client.fetch_candidate_issues_for_project_for_test(
               "project-a",
               ["Todo"],
               graphql_fun
             )

    assert issue.id == "issue-1"
    assert_receive {:linear_query_variables, variables}
    assert variables.projectSlug == "project-a"
    assert variables.stateNames == ["Todo"]
  end

  test "production project-aware fetch returns missing token before assignee resolution" do
    Application.delete_env(:symphony_elixir, :linear_api_token)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_project_slug: "legacy-project",
      tracker_api_token: nil,
      tracker_assignee: "me"
    )

    assert {:error, :missing_linear_api_token} =
             Client.fetch_candidate_issues_for_project("project-a", ["Todo"])
  end

  test "production project-aware fetch returns empty list when no states are requested" do
    Application.delete_env(:symphony_elixir, :linear_api_token)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_project_slug: "legacy-project",
      tracker_api_token: nil
    )

    assert {:ok, []} = Client.fetch_candidate_issues_for_project("project-a", [])
  end

  test "fetches issues for explicit project key and explicit states without reading tracker.project_slug" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    graphql_fun = fn _query, variables ->
      send(self(), {:linear_states_query_variables, variables})

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-2",
                 "identifier" => "MT-2",
                 "title" => "Terminal task",
                 "state" => %{"name" => "Done"},
                 "priority" => 1,
                 "createdAt" => "2026-05-25T00:00:00Z",
                 "updatedAt" => "2026-05-25T00:00:00Z"
               }
             ],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_project_with_routing_for_test(
               "project-a",
               ["Done"],
               graphql_fun
             )

    assert issue.id == "issue-2"
    assert_receive {:linear_states_query_variables, variables}
    assert variables.projectSlug == "project-a"
    assert variables.stateNames == ["Done"]
  end

  test "project-aware states fetch test helper exercises assignee routing for me" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_project_slug: "legacy-project",
      tracker_assignee: "me"
    )

    parent = self()

    graphql_fun = fn query, variables ->
      send(parent, {:graphql_call, query, variables})

      cond do
        query =~ "query SymphonyLinearViewer" ->
          {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}}

        query =~ "query SymphonyLinearPoll" ->
          {:ok,
           %{
             "data" => %{
               "issues" => %{
                 "nodes" => [
                   %{
                     "id" => "issue-2",
                     "identifier" => "MT-2",
                     "title" => "Terminal task",
                     "state" => %{"name" => "Done"},
                     "priority" => 1,
                     "assignee" => %{"id" => "viewer-1"},
                     "createdAt" => "2026-05-25T00:00:00Z",
                     "updatedAt" => "2026-05-25T00:00:00Z"
                   }
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }}
      end
    end

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_project_with_routing_for_test(
               "project-a",
               ["Done"],
               graphql_fun
             )

    assert issue.assigned_to_worker == true
    received_calls = [receive_graphql_call(), receive_graphql_call()]

    assert Enum.any?(received_calls, fn
             {:graphql_call, query, %{}} -> query =~ "query SymphonyLinearViewer"
             _ -> false
           end)

    assert Enum.any?(received_calls, fn
             {:graphql_call, query, %{projectSlug: "project-a", stateNames: ["Done"]}} ->
               query =~ "query SymphonyLinearPoll"

             _ ->
               false
           end)
  end

  test "project-aware fetch test helper exercises assignee routing for me" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_project_slug: "legacy-project",
      tracker_assignee: "me"
    )

    parent = self()

    graphql_fun = fn query, variables ->
      send(parent, {:graphql_call, query, variables})

      cond do
        query =~ "query SymphonyLinearViewer" ->
          {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}}

        query =~ "query SymphonyLinearPoll" ->
          {:ok,
           %{
             "data" => %{
               "issues" => %{
                 "nodes" => [
                   %{
                     "id" => "issue-1",
                     "identifier" => "MT-1",
                     "title" => "Task",
                     "state" => %{"name" => "Todo"},
                     "priority" => 1,
                     "assignee" => %{"id" => "viewer-1"},
                     "createdAt" => "2026-05-25T00:00:00Z",
                     "updatedAt" => "2026-05-25T00:00:00Z"
                   }
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }}
      end
    end

    assert {:ok, [issue]} =
             Client.fetch_candidate_issues_for_project_with_routing_for_test(
               "project-a",
               ["Todo"],
               graphql_fun
             )

    assert issue.assigned_to_worker == true
    received_calls = [receive_graphql_call(), receive_graphql_call()]

    assert Enum.any?(received_calls, fn
             {:graphql_call, query, %{}} -> query =~ "query SymphonyLinearViewer"
             _ -> false
           end)

    assert Enum.any?(received_calls, fn
             {:graphql_call, query, %{projectSlug: "project-a", stateNames: ["Todo"]}} ->
               query =~ "query SymphonyLinearPoll"

             _ ->
               false
           end)
  end

  test "project-aware fetch test helper surfaces assignee routing errors" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_project_slug: "legacy-project",
      tracker_assignee: "me"
    )

    assert {:error, :viewer_unavailable} =
             Client.fetch_candidate_issues_for_project_with_routing_for_test(
               "project-a",
               ["Todo"],
               fn _query, _variables -> {:error, :viewer_unavailable} end
             )
  end

  defp receive_graphql_call(timeout \\ 1_000) do
    receive do
      {:graphql_call, query, variables} -> {:graphql_call, query, variables}
    after
      timeout -> flunk("expected graphql call")
    end
  end
end
