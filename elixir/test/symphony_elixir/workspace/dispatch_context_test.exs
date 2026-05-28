defmodule SymphonyElixir.Workspace.DispatchContextTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workspace.DispatchContext

  test "new trims strings and cleanup_ready? requires a workspace path" do
    assert {:ok, context} =
             DispatchContext.new(%{
               "project_key" => "  project-a  ",
               "issue_id" => "  issue-1234  ",
               "issue_identifier" => "  MT-123  ",
               "attempt" => 2,
               "worker_host" => "  worker-a  "
             })

    assert context.project_key == "project-a"
    assert context.issue_id == "issue-1234"
    assert context.issue_identifier == "MT-123"
    assert context.worker_host == "worker-a"
    refute DispatchContext.cleanup_ready?(context)

    ready_context = DispatchContext.with_workspace_path(context, "/tmp/project-a/MT-123__1234")
    assert DispatchContext.cleanup_ready?(ready_context)
  end

  test "new rejects invalid project keys and path_segment keeps the final eight normalized characters" do
    assert {:error, :invalid_project_key_path_segment} =
             DispatchContext.new(%{
               project_key: "../project-a",
               issue_id: "issue-1234567890",
               issue_identifier: "MT/123",
               attempt: 1
             })

    assert {:ok, context} =
             DispatchContext.new(%{
               project_key: "project-a",
               issue_id: "issue-1234567890",
               issue_identifier: "MT/123",
               attempt: 1
             })

    assert DispatchContext.path_segment(context) == "MT_123__34567890"
    assert DispatchContext.safe_identifier(nil) == "issue"
  end

  test "new rejects non-map attrs, non-integer attempts, and non-string fields" do
    assert {:error, :cleanup_context_missing} = DispatchContext.new(nil)

    assert {:error, :cleanup_context_missing} =
             DispatchContext.new(%{
               project_key: "project-a",
               issue_id: "issue-123",
               issue_identifier: "MT-123",
               attempt: "1"
             })

    assert {:error, :cleanup_context_missing} =
             DispatchContext.new(%{
               project_key: "project-a",
               issue_id: 123,
               issue_identifier: "MT-123",
               attempt: 1
             })
  end

  test "cleanup_ready? returns false when required strings are blank" do
    context = %DispatchContext{
      project_key: "   ",
      issue_id: "issue-123",
      issue_identifier: "MT-123",
      workspace_path: "/tmp/project-a/MT-123__123",
      attempt: 1
    }

    refute DispatchContext.cleanup_ready?(context)
  end

  test "cleanup_ready? short-circuits on the first invalid field and path_segment falls back to issue" do
    refute DispatchContext.cleanup_ready?(%DispatchContext{
             project_key: nil,
             issue_id: "issue-123",
             issue_identifier: "MT-123",
             workspace_path: "/tmp/project-a/MT-123__123",
             attempt: 1
           })

    assert {:ok, context} =
             DispatchContext.new(%{
               project_key: "project-a",
               issue_id: "!@#$",
               issue_identifier: "MT-123",
               attempt: 1
             })

    assert DispatchContext.path_segment(context) == "MT-123__issue"
  end

  test "new rejects blank and non-string required fields through each validator" do
    assert {:error, :cleanup_context_missing} =
             DispatchContext.new(%{
               project_key: "project-a",
               issue_id: "issue-123",
               issue_identifier: "MT-123",
               attempt: 1,
               worker_host: 123
             })

    assert {:error, :cleanup_context_missing} =
             DispatchContext.new(%{
               project_key: "project-a",
               issue_id: "issue-123",
               issue_identifier: 123,
               attempt: 1
             })

    assert {:error, :cleanup_context_missing} =
             DispatchContext.validate_project_key("   ")
  end
end
