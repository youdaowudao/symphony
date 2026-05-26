defmodule SymphonyElixir.ProjectRegistryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProjectRegistry

  test "default_path resolves next to the current workflow file" do
    assert ProjectRegistry.default_path() ==
             Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml")
  end

  test "load reads the default project registry and preserves missing max_concurrent_agents as nil" do
    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      projects: [
        %{
          project_key: "project-a",
          enabled: true
        }
      ]
    })

    assert {:ok,
            %{
              schema_version: 1,
              projects: [
                %{
                  project_key: "project-a",
                  enabled: true,
                  max_concurrent_agents: nil
                }
              ]
            }} = ProjectRegistry.load()
  end

  test "load returns missing when the default registry file does not exist" do
    assert :missing = ProjectRegistry.load()
  end

  test "load returns a parse error when the registry yaml is invalid" do
    write_project_registry_file!(ProjectRegistry.default_path(), "schema_version: [\n")

    assert {:error, {:invalid_project_registry, message}} = ProjectRegistry.load()
    assert message =~ "failed to parse YAML"
  end

  test "load rejects invalid registry shapes and forbidden project fields" do
    invalid_cases = [
      {%{projects: [%{project_key: "project-a", enabled: true}]}, "schema_version"},
      {%{schema_version: 1}, "projects"},
      {%{schema_version: 1, projects: %{}}, "projects"},
      {%{schema_version: 1, projects: [%{enabled: true}]}, "projects[0].project_key"},
      {%{schema_version: 1, projects: [%{project_key: 123, enabled: true}]}, "projects[0].project_key"},
      {%{schema_version: 1, projects: [123]}, "projects[0] must be a map"},
      {%{schema_version: 1, projects: [%{project_key: "project-a"}]}, "projects[0].enabled"},
      {%{schema_version: 1, projects: [%{project_key: "project-a", enabled: "true"}]}, "projects[0].enabled"},
      {%{
         schema_version: 1,
         projects: [%{project_key: "project-a", enabled: true, max_concurrent_agents: "15"}]
       }, "projects[0].max_concurrent_agents"},
      {%{
         schema_version: 1,
         projects: [%{project_key: "project-a", enabled: true, max_concurrent_agents: 0}]
       }, "projects[0].max_concurrent_agents"},
      {%{
         schema_version: 1,
         projects: [%{project_key: "project-a", enabled: true, max_concurrent_agents: nil}]
       }, "projects[0].max_concurrent_agents"},
      {%{
         schema_version: 1,
         projects: [%{project_key: "project-a", enabled: true, linear_project_slug: "legacy"}]
       }, "projects[0].linear_project_slug"},
      {%{
         schema_version: 1,
         projects: [
           %{project_key: "project-a", enabled: true},
           %{project_key: "project-a", enabled: false}
         ]
       }, "duplicate project_key"},
      {%{schema_version: 2, projects: [%{project_key: "project-a", enabled: true}]}, "schema_version"}
    ]

    for {registry, expected_message} <- invalid_cases do
      write_project_registry_file!(ProjectRegistry.default_path(), registry)

      assert {:error, {:invalid_project_registry, message}} = ProjectRegistry.load()
      assert message =~ expected_message
    end
  end

  test "load_normalized reports registry source when registry is present and valid" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: nil)

    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      projects: [
        %{
          project_key: "project-a",
          enabled: true
        }
      ]
    })

    assert {:ok,
            {:registry,
             [
               %{
                 project_key: "project-a",
                 enabled: true,
                 max_concurrent_agents: 15,
                 display_name: nil
               }
             ]}} = ProjectRegistry.load_normalized()
  end

  test "load_normalized reports legacy source when registry is missing and tracker.project_slug is available" do
    assert {:ok,
            {:legacy,
             [
               %{
                 project_key: "project",
                 enabled: true,
                 max_concurrent_agents: 15,
                 display_name: nil
               }
             ]}} = ProjectRegistry.load_normalized()
  end

  test "load_normalized reports missing when registry and legacy slug are both absent" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: nil)

    assert :missing = ProjectRegistry.load_normalized()
  end

  test "load_normalized with an explicit path does not implicitly consult the current workflow legacy slug" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    assert :missing = ProjectRegistry.load_normalized(ProjectRegistry.default_path())
  end

  test "load_normalized reports a conflict when registry and legacy slug disagree" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      projects: [
        %{
          project_key: "project-a",
          enabled: true
        }
      ]
    })

    assert {:error, {:project_registry_conflict, %{legacy_project_slug: "legacy-project"}}} =
             ProjectRegistry.load_normalized()
  end

  test "load_normalized reports a conflict when registry is empty and a legacy slug is still present" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      projects: []
    })

    assert {:error, {:project_registry_conflict, %{legacy_project_slug: "legacy-project"}}} =
             ProjectRegistry.load_normalized()
  end

  test "load_normalized forwards registry parse failures" do
    write_project_registry_file!(ProjectRegistry.default_path(), "schema_version: [\n")

    assert {:error, {:invalid_project_registry, message}} = ProjectRegistry.load_normalized()
    assert message =~ "failed to parse YAML"
  end

  test "load_normalized forwards workflow read failures instead of swallowing them" do
    original_workflow_path = Workflow.workflow_file_path()
    missing_workflow_path = Path.join(Path.dirname(original_workflow_path), "MISSING_WORKFLOW.md")

    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.set_workflow_file_path(missing_workflow_path)

    assert {:error, {:missing_workflow_file, ^missing_workflow_path, _reason}} =
             ProjectRegistry.load_normalized()
  end

  test "load_normalized surfaces invalid legacy tracker.project_slug types" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: 123)

    assert {:error, {:invalid_workflow_config, message}} = ProjectRegistry.load_normalized()
    assert message =~ "tracker.project_slug"
  end

  test "normalized_entries fills the default max_concurrent_agents for registry entries" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: nil)

    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      projects: [
        %{
          project_key: "project-a",
          enabled: true
        }
      ]
    })

    assert {:ok,
            [
              %{
                project_key: "project-a",
                enabled: true,
                max_concurrent_agents: 15,
                display_name: nil
              }
            ]} = ProjectRegistry.normalized_entries()
  end

  test "normalized_entries only expose the stage output contract for disabled projects" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: nil)

    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      projects: [
        %{
          project_key: "project-a",
          enabled: false
        }
      ]
    })

    assert {:ok, [entry]} = ProjectRegistry.normalized_entries()
    assert entry == %{project_key: "project-a", enabled: false, max_concurrent_agents: 15, display_name: nil}
    assert Map.keys(entry) |> Enum.sort() == [:display_name, :enabled, :max_concurrent_agents, :project_key]
    refute Map.has_key?(entry, :linear_project_slug)
    refute Map.has_key?(entry, :linear_project_id)
  end

  test "normalized_entries falls back to the legacy tracker.project_slug when the registry is missing" do
    assert {:ok,
            [
              %{
                project_key: "project",
                enabled: true,
                max_concurrent_agents: 15,
                display_name: nil
              }
            ]} = ProjectRegistry.normalized_entries()
  end

  test "normalized_entries with an explicit path does not consult the current workflow legacy slug" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    assert {:error, {:missing_project_registry, path}} =
             ProjectRegistry.normalized_entries(ProjectRegistry.default_path())

    assert path == ProjectRegistry.default_path()
  end

  test "normalized_entries returns a missing legacy slug error when neither registry nor tracker.project_slug exists" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: nil)

    assert {:error, :missing_linear_project_slug} = ProjectRegistry.normalized_entries()
  end

  test "normalized_entries keeps tracker.project_slug only as a compatibility bridge when registry exists" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "project-a")

    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      projects: [
        %{
          project_key: "project-a",
          enabled: true,
          max_concurrent_agents: 30
        }
      ]
    })

    assert {:ok,
            [
              %{
                project_key: "project-a",
                enabled: true,
                max_concurrent_agents: 30,
                display_name: nil
              }
            ]} = ProjectRegistry.normalized_entries()
  end

  test "normalized_entries rejects a conflicting legacy tracker.project_slug when the registry has one project" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      projects: [
        %{
          project_key: "project-a",
          enabled: true
        }
      ]
    })

    assert {:error, {:project_registry_conflict, %{legacy_project_slug: "legacy-project"}}} =
             ProjectRegistry.normalized_entries()
  end

  test "normalized_entries rejects any non-empty legacy tracker.project_slug when the registry has multiple projects" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "legacy-project")

    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      projects: [
        %{
          project_key: "project-a",
          enabled: true
        },
        %{
          project_key: "project-b",
          enabled: false,
          max_concurrent_agents: 22
        }
      ]
    })

    assert {:error, {:project_registry_conflict, %{legacy_project_slug: "legacy-project"}}} =
             ProjectRegistry.normalized_entries()
  end

  test "normalized_entries surfaces invalid legacy tracker.project_slug types" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: 123)

    assert {:error, {:invalid_workflow_config, message}} = ProjectRegistry.normalized_entries()
    assert message =~ "tracker.project_slug"
  end

  test "normalized_entries keep display_name as a nil projection placeholder for this stage" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: nil)

    write_project_registry_file!(ProjectRegistry.default_path(), %{
      schema_version: 1,
      projects: [
        %{
          project_key: "project-a",
          enabled: true,
          max_concurrent_agents: 30
        }
      ]
    })

    assert {:ok, [%{project_key: "project-a", enabled: true, max_concurrent_agents: 30, display_name: nil}]} =
             ProjectRegistry.normalized_entries()
  end
end
