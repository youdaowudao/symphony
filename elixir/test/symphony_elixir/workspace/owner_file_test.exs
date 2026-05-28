defmodule SymphonyElixir.Workspace.OwnerFileTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workspace.DispatchContext
  alias SymphonyElixir.Workspace.OwnerFile

  test "decode rejects non-map JSON and invalid owner payloads" do
    assert {:error, :owner_invalid_json} = OwnerFile.decode("[]")
    assert {:error, :owner_invalid_json} = OwnerFile.decode("{")

    invalid_owner =
      Jason.encode!(%{
        "schema_version" => 1,
        "project_key" => " ",
        "issue_id" => "issue-123",
        "issue_identifier" => "MT-123",
        "worker_host" => 123,
        "workspace_path" => "/tmp/project-a/MT-123",
        "attempt" => "1",
        "created_at" => "2026-05-28T00:00:00Z"
      })

    assert {:error, :owner_schema_mismatch} = OwnerFile.decode(invalid_owner)

    wrong_schema =
      Jason.encode!(%{
        "schema_version" => 2,
        "project_key" => "project-a",
        "issue_id" => "issue-123",
        "issue_identifier" => "MT-123",
        "worker_host" => nil,
        "workspace_path" => "/tmp/project-a/MT-123",
        "attempt" => 1,
        "created_at" => "2026-05-28T00:00:00Z"
      })

    assert {:error, :owner_schema_mismatch} = OwnerFile.decode(wrong_schema)
  end

  test "decode rejects owner payloads when required string fields are not strings" do
    invalid_owner =
      Jason.encode!(%{
        "schema_version" => 1,
        "project_key" => "project-a",
        "issue_id" => 123,
        "issue_identifier" => "MT-123",
        "worker_host" => nil,
        "workspace_path" => "/tmp/project-a/MT-123",
        "attempt" => 1,
        "created_at" => "2026-05-28T00:00:00Z"
      })

    assert {:error, :owner_schema_mismatch} = OwnerFile.decode(invalid_owner)
  end

  test "read returns structured errors for missing and unreadable owner files" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-owner-file-read-#{System.unique_integer([:positive])}"
      )

    try do
      assert {:error, :owner_missing} = OwnerFile.read(workspace_root)

      owner_path = OwnerFile.absolute_path(workspace_root)
      File.mkdir_p!(owner_path)

      assert {:error, {:owner_unreadable, :eisdir}} = OwnerFile.read(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "write! persists an owner payload that read can decode" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-owner-file-roundtrip-#{System.unique_integer([:positive])}"
      )

    try do
      assert {:ok, context} =
               DispatchContext.new(%{
                 project_key: "project-a",
                 issue_id: "issue-123",
                 issue_identifier: "MT-123",
                 attempt: 2,
                 worker_host: "worker-01",
                 workspace_path: workspace_root
               })

      assert :ok = OwnerFile.write!(context, "2026-05-28T00:00:00Z")
      assert {:ok, owner} = OwnerFile.read(workspace_root)

      assert owner["schema_version"] == 1
      assert owner["project_key"] == "project-a"
      assert owner["issue_id"] == "issue-123"
      assert owner["issue_identifier"] == "MT-123"
      assert owner["worker_host"] == "worker-01"
      assert owner["workspace_path"] == workspace_root
      assert owner["attempt"] == 2
      assert owner["created_at"] == "2026-05-28T00:00:00Z"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "ownership_matches? requires exact project, issue, host, and workspace matches" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-owner-file-match-#{System.unique_integer([:positive])}"
      )

    assert {:ok, context} =
             DispatchContext.new(%{
               project_key: "project-a",
               issue_id: "issue-123",
               issue_identifier: "MT-123",
               attempt: 2,
               worker_host: "worker-01",
               workspace_path: workspace_root
             })

    matching_owner = %{
      "project_key" => "project-a",
      "issue_id" => "issue-123",
      "worker_host" => "worker-01",
      "workspace_path" => workspace_root
    }

    assert OwnerFile.ownership_matches?(context, matching_owner)
    refute OwnerFile.ownership_matches?(context, Map.put(matching_owner, "workspace_path", workspace_root <> "-other"))
  end
end
