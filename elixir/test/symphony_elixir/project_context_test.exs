defmodule SymphonyElixir.ProjectContextTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Tracker.ProjectCandidate

  test "builds project context from normalized registry entry" do
    assert {:ok, context} =
             ProjectContext.from_registry_entry(%{
               project_key: "project-a",
               display_name: nil,
               enabled: true,
               max_concurrent_agents: 15
             })

    assert context.project_key == "project-a"
    assert context.display_name == "project-a"
    assert context.enabled == true
    assert context.max_concurrent_agents == 15
  end

  test "rejects invalid normalized registry entries" do
    invalid_entries = [
      %{enabled: true, max_concurrent_agents: 15},
      %{project_key: " ", enabled: true, max_concurrent_agents: 15},
      %{project_key: "project-a", enabled: "true", max_concurrent_agents: 15},
      %{project_key: "project-a", enabled: true, max_concurrent_agents: 0}
    ]

    for entry <- invalid_entries do
      assert {:error, {:invalid_project_context_entry, ^entry}} =
               ProjectContext.from_registry_entry(entry)
    end
  end

  test "wraps issue with project context without mutating issue struct" do
    issue = %Issue{id: "issue-1", identifier: "MT-1"}

    context = %ProjectContext{
      project_key: "project-a",
      display_name: "Project A",
      enabled: true,
      max_concurrent_agents: 15
    }

    candidate = ProjectCandidate.new!(issue, context)

    assert candidate.issue == issue
    assert candidate.project_context == context
    refute Map.has_key?(Map.from_struct(candidate.issue), :project_key)
  end
end
