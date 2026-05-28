defmodule SymphonyElixir.ProjectRegistryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProjectRegistry

  test "load validates canonical registry fields and trims strings" do
    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      linear_token_relative_path: "  .config/linear/project.token  ",
      projects: [
        %{
          project_key: "  project-a  ",
          display_name: "  Project A  ",
          enabled: true
        }
      ]
    })

    assert {:ok,
            %{
              schema_version: 1,
              linear_token_relative_path: ".config/linear/project.token",
              projects: [
                %{
                  project_key: "project-a",
                  display_name: "Project A",
                  enabled: true,
                  max_concurrent_agents: nil
                }
              ]
            }} = ProjectRegistry.load()
  end

  test "load returns missing when the registry file does not exist" do
    assert :missing = ProjectRegistry.load()
  end

  test "load wraps file read errors" do
    File.mkdir_p!(ProjectRegistry.default_path())

    assert {:error, {:project_registry_read_error, path, :eisdir}} = ProjectRegistry.load()
    assert path == ProjectRegistry.default_path()
  end

  test "load rejects missing and invalid canonical fields" do
    invalid_cases = [
      {%{
         schema_version: 2,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [%{project_key: "project-a", display_name: "Project A", enabled: true}]
       }, "schema_version must equal 1"},
      {%{
         schema_version: 1,
         projects: [%{project_key: "project-a", display_name: "Project A", enabled: true}]
       }, "linear_token_relative_path is required"},
      {%{
         schema_version: 1,
         linear_token_relative_path: "   ",
         projects: [%{project_key: "project-a", display_name: "Project A", enabled: true}]
       }, "linear_token_relative_path must be a non-empty string"},
      {%{
         schema_version: 1,
         linear_token_relative_path: 123,
         projects: [%{project_key: "project-a", display_name: "Project A", enabled: true}]
       }, "linear_token_relative_path must be a string"},
      {%{
         schema_version: 1,
         linear_token_relative_path: "/tmp/linear.token",
         projects: [%{project_key: "project-a", display_name: "Project A", enabled: true}]
       }, "linear_token_relative_path must be a relative path"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token"
       }, "projects is required"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: "invalid"
       }, "projects must be a list"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: ["invalid"]
       }, "projects[0] must be a map"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [%{display_name: "Project A", enabled: true}]
       }, "projects[0].project_key is required"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [%{project_key: 123, display_name: "Project A", enabled: true}]
       }, "projects[0].project_key must be a string"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [%{project_key: "   ", display_name: "Project A", enabled: true}]
       }, "projects[0].project_key must be a non-empty string"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [%{project_key: "project-a", enabled: true}]
       }, "projects[0].display_name is required"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [%{project_key: "project-a", display_name: " ", enabled: true}]
       }, "projects[0].display_name must be a non-empty string"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [%{project_key: "project-a", display_name: 123, enabled: true}]
       }, "projects[0].display_name must be a string"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [%{project_key: "project-a", display_name: "Project A", enabled: true, extra: 1}]
       }, "projects[0].extra is not allowed"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [%{project_key: "project-a", display_name: "Project A"}]
       }, "projects[0].enabled is required"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [%{project_key: "project-a", display_name: "Project A", enabled: "true"}]
       }, "projects[0].enabled must be a boolean"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [
           %{project_key: "project-a", display_name: "Project A", enabled: true, max_concurrent_agents: nil}
         ]
       }, "projects[0].max_concurrent_agents must be a positive integer"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [
           %{project_key: "project-a", display_name: "Project A", enabled: true, max_concurrent_agents: 0}
         ]
       }, "projects[0].max_concurrent_agents must be a positive integer"},
      {%{
         schema_version: 1,
         linear_token_relative_path: ".config/linear/project.token",
         projects: [
           %{project_key: "project-a", display_name: "Project A", enabled: true},
           %{project_key: "project-a", display_name: "Project A duplicate", enabled: false}
         ]
       }, "duplicate project_key: project-a"}
    ]

    Enum.each(invalid_cases, fn {registry, expected_message} ->
      write_project_registry_file!(ProjectRegistry.default_path(), registry)

      assert {:error, {:invalid_project_registry, message}} = ProjectRegistry.load()
      assert message =~ expected_message
    end)
  end

  test "load rejects unexpected top-level fields" do
    write_project_registry_file!(
      ProjectRegistry.default_path(),
      """
      schema_version: 1
      linear_token_relative_path: ".config/linear/project.token"
      unexpected: true
      projects:
        - project_key: "project-a"
          display_name: "Project A"
          enabled: true
      """
    )

    assert {:error, {:invalid_project_registry, "unexpected is not allowed"}} =
             ProjectRegistry.load()
  end

  test "load rejects YAML parse failures and non-map payloads" do
    registry_path = ProjectRegistry.default_path()

    File.write!(registry_path, "[1, 2, 3]\n")
    assert {:error, {:invalid_project_registry, "project registry must decode to a map"}} = ProjectRegistry.load()

    File.write!(registry_path, "{not: valid")

    assert {:error, {:invalid_project_registry, message}} = ProjectRegistry.load()
    assert message =~ "failed to parse YAML"
  end

  test "load_normalized returns registry entries with default limits" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: nil)

    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      linear_token_relative_path: ".config/linear/project.token",
      projects: [
        %{
          project_key: "project-a",
          display_name: "Project A",
          enabled: true
        },
        %{
          project_key: "project-b",
          display_name: "Project B",
          enabled: false,
          max_concurrent_agents: 7
        }
      ]
    })

    assert {:ok,
            {:registry,
             [
               %{
                 project_key: "project-a",
                 display_name: "Project A",
                 enabled: true,
                 max_concurrent_agents: 15
               },
               %{
                 project_key: "project-b",
                 display_name: "Project B",
                 enabled: false,
                 max_concurrent_agents: 7
               }
             ]}} = ProjectRegistry.load_normalized()
  end

  test "load_normalized falls back to the legacy workflow slug only when the registry is missing" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "  legacy-project  ")

    assert {:ok,
            {:legacy,
             [
               %{
                 project_key: "legacy-project",
                 display_name: nil,
                 enabled: true,
                 max_concurrent_agents: 15
               }
             ]}} = ProjectRegistry.load_normalized()
  end

  test "normalized_entries and load_normalized handle missing and invalid registry paths directly" do
    explicit_registry_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "explicit_registry.yaml")

    write_project_registry_file!(explicit_registry_path, %{
      schema_version: 1,
      linear_token_relative_path: ".config/linear/project.token",
      projects: [
        %{project_key: "project-a", display_name: "Project A", enabled: true}
      ]
    })

    assert {:ok, [%{project_key: "project-a", max_concurrent_agents: 15}]} =
             ProjectRegistry.normalized_entries(explicit_registry_path)

    File.write!(explicit_registry_path, "projects: [\n")

    assert {:error, {:invalid_project_registry, message}} =
             ProjectRegistry.normalized_entries(explicit_registry_path)

    assert message =~ "failed to parse YAML"

    assert {:error, {:invalid_project_registry, message}} =
             ProjectRegistry.load_normalized(explicit_registry_path)

    assert message =~ "failed to parse YAML"
  end

  test "normalized_entries returns explicit path errors and workflow type errors" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    assert {:error, {:missing_project_registry, path}} =
             ProjectRegistry.normalized_entries(ProjectRegistry.default_path())

    assert path == ProjectRegistry.default_path()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: 123)

    assert {:error, {:invalid_workflow_config, message}} = ProjectRegistry.normalized_entries()
    assert message =~ "tracker.project_slug must be a string"
  end

  test "normalized_entries propagates invalid default registry errors" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      linear_token_relative_path: ".config/linear/project.token",
      projects: [
        %{project_key: "project-a", display_name: 123, enabled: true}
      ]
    })

    assert {:error, {:invalid_project_registry, "projects[0].display_name must be a string"}} =
             ProjectRegistry.normalized_entries()
  end

  test "normalized_entries uses legacy fallback only for default path and surfaces workflow load errors" do
    explicit_registry_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "explicit_registry.yaml")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    assert {:error, {:missing_project_registry, ^explicit_registry_path}} =
             ProjectRegistry.normalized_entries(explicit_registry_path)

    File.rm!(Workflow.workflow_file_path())

    assert {:error, {:missing_workflow_file, _, :enoent}} = ProjectRegistry.normalized_entries()
  end

  test "normalized_entries returns a missing legacy slug error when neither source exists" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: nil)

    assert {:error, :missing_linear_project_slug} = ProjectRegistry.normalized_entries()
  end

  test "normalized_entries unwraps legacy and registry sources" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    assert {:ok, [%{project_key: "legacy-project", display_name: nil}]} =
             ProjectRegistry.normalized_entries()

    registry_path = ProjectRegistry.default_path()

    write_project_registry_file!(registry_path, %{
      schema_version: 1,
      linear_token_relative_path: ".config/linear/project.token",
      projects: [
        %{project_key: "project-a", display_name: "Project A", enabled: true}
      ]
    })

    assert {:ok, [%{project_key: "project-a", max_concurrent_agents: 15}]} =
             ProjectRegistry.normalized_entries(registry_path)
  end

  test "normalized entry helpers propagate registry and workflow errors" do
    registry_path = ProjectRegistry.default_path()

    write_project_registry_file!(registry_path, %{
      schema_version: 1,
      linear_token_relative_path: ".config/linear/project.token",
      projects: [%{project_key: "project-a", display_name: "Project A", enabled: true}]
    })

    assert {:ok, {:registry, [%{project_key: "project-a"}]}} =
             ProjectRegistry.load_normalized(registry_path)

    File.rm!(Workflow.workflow_file_path())
    assert {:error, {:missing_workflow_file, _, :enoent}} = ProjectRegistry.load_normalized()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    write_project_registry_file!(registry_path, %{
      schema_version: 1,
      linear_token_relative_path: ".config/linear/project.token",
      projects: [%{project_key: "project-a", display_name: 123, enabled: true}]
    })

    assert {:error, {:invalid_project_registry, "projects[0].display_name must be a string"}} =
             ProjectRegistry.normalized_entries(registry_path)
  end

  test "load_normalized treats missing tracker config as no legacy slug" do
    custom_registry_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "custom_registry.yaml")

    assert :missing = ProjectRegistry.load_normalized(custom_registry_path, nil)

    File.write!(Workflow.workflow_file_path(), "---\nworkspace:\n  root: \"/tmp/workspace\"\n---\nprompt\n")

    assert :missing = ProjectRegistry.load_normalized()
  end

  test "load_normalized reads explicit paths and normalized_entries reads tracker string keys" do
    explicit_registry_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "explicit_registry.yaml")

    write_project_registry_file!(explicit_registry_path, %{
      schema_version: 1,
      linear_token_relative_path: ".config/linear/project.token",
      projects: [
        %{project_key: "project-a", display_name: "Project A", enabled: true}
      ]
    })

    assert {:ok, {:registry, [%{project_key: "project-a", max_concurrent_agents: 15}]}} =
             ProjectRegistry.load_normalized(explicit_registry_path)

    workflow_path = Workflow.workflow_file_path()

    File.write!(
      workflow_path,
      """
      ---
      tracker:
        project_slug: "string-key-project"
      ---
      prompt
      """
    )

    assert {:ok, [%{project_key: "string-key-project"}]} = ProjectRegistry.normalized_entries()
  end

  test "normalize_legacy_project_slug trims strings and rejects non-binaries" do
    assert ProjectRegistry.normalize_legacy_project_slug("  project-a  ") == "project-a"
    assert ProjectRegistry.normalize_legacy_project_slug("   ") == nil
    assert ProjectRegistry.normalize_legacy_project_slug(nil) == nil
    assert ProjectRegistry.normalize_legacy_project_slug(123) == nil
  end
end
