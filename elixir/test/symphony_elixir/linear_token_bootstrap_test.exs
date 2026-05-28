defmodule SymphonyElixir.LinearTokenBootstrapTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LinearTokenBootstrap
  alias SymphonyElixir.Workflow

  test "bootstrap fails closed when project_registry.yaml is missing" do
    registry_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml")

    assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
    assert message == "Linear token bootstrap failed: missing project_registry.yaml at #{registry_path}"
  end

  test "bootstrap surfaces invalid project registry validation errors" do
    registry_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml")

    write_project_registry_file!(registry_path, %{
      schema_version: 1,
      linear_token_relative_path: ".config/linear/project.token",
      projects: "invalid"
    })

    assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
    assert message =~ "invalid project_registry.yaml: projects must be a list"
  end

  test "bootstrap surfaces project registry read errors" do
    registry_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml")
    File.mkdir_p!(registry_path)

    assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
    assert message =~ "failed to read project_registry.yaml at #{registry_path}: :eisdir"
  end

  test "bootstrap fails closed when token-resolution registry lookup returns missing" do
    registry_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml")

    with_stubbed_project_registry(
      [
        {:ok, %{schema_version: 1, linear_token_relative_path: ".config/linear/project.token", projects: []}},
        :missing
      ],
      fn ->
        assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
        assert message == "Linear token bootstrap failed: missing project_registry.yaml at #{registry_path}"
      end
    )
  end

  test "bootstrap surfaces token-resolution project registry read errors from alternate paths" do
    registry_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml")
    alternate_path = registry_path <> ".shadow"

    with_stubbed_project_registry(
      [
        {:ok, %{schema_version: 1, linear_token_relative_path: ".config/linear/project.token", projects: []}},
        {:error, {:project_registry_read_error, alternate_path, :eacces}}
      ],
      fn ->
        assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())

        assert message ==
                 "Linear token bootstrap failed: failed to read project_registry.yaml at #{alternate_path}: :eacces"
      end
    )
  end

  test "bootstrap surfaces token-resolution generic registry errors" do
    registry_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml")

    with_stubbed_project_registry(
      [
        {:ok, %{schema_version: 1, linear_token_relative_path: ".config/linear/project.token", projects: []}},
        {:error, :unexpected_registry_state}
      ],
      fn ->
        assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())

        assert message ==
                 "Linear token bootstrap failed: project_registry.yaml error at #{registry_path}: :unexpected_registry_state"
      end
    )
  end

  test "bootstrap fails when HOME is missing" do
    previous_home = System.get_env("HOME")
    on_exit(fn -> restore_env("HOME", previous_home) end)
    System.delete_env("HOME")

    write_project_registry_file!(Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml"), %{
      schema_version: 1,
      linear_token_relative_path: ".config/linear/project.token",
      projects: [
        %{project_key: "project-a", display_name: "Project A", enabled: true}
      ]
    })

    assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
    assert message =~ "HOME is missing; cannot resolve .config/linear/project.token"
  end

  test "bootstrap rejects empty token files" do
    home_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-token-empty-home-#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("HOME")

    on_exit(fn ->
      restore_env("HOME", previous_home)
      File.rm_rf(home_root)
    end)

    System.put_env("HOME", home_root)

    token_relative_path = ".config/linear/empty.token"
    token_path = Path.join(home_root, token_relative_path)

    File.mkdir_p!(Path.dirname(token_path))
    File.write!(token_path, " \n")

    write_project_registry_file!(Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml"), %{
      schema_version: 1,
      linear_token_relative_path: token_relative_path,
      projects: [
        %{project_key: "project-a", display_name: "Project A", enabled: true}
      ]
    })

    assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
    assert message =~ "token file is empty or invalid at #{token_path}"
  end

  test "bootstrap surfaces token read errors outside not-found and permission cases" do
    home_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-token-eisdir-home-#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("HOME")

    on_exit(fn ->
      restore_env("HOME", previous_home)
      File.rm_rf(home_root)
    end)

    System.put_env("HOME", home_root)

    token_relative_path = ".config/linear/as-directory"
    token_path = Path.join(home_root, token_relative_path)

    File.mkdir_p!(token_path)

    write_project_registry_file!(Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml"), %{
      schema_version: 1,
      linear_token_relative_path: token_relative_path,
      projects: [
        %{project_key: "project-a", display_name: "Project A", enabled: true}
      ]
    })

    assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
    assert message =~ "failed to read token file at #{token_path}: :eisdir"
  end

  test "bootstrap loads a token from HOME and stores the trimmed value" do
    home_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-token-success-home-#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("HOME")
    previous_token = Application.get_env(:symphony_elixir, :linear_api_token)

    on_exit(fn ->
      restore_env("HOME", previous_home)
      Application.put_env(:symphony_elixir, :linear_api_token, previous_token)
      File.rm_rf(home_root)
    end)

    System.put_env("HOME", home_root)

    token_relative_path = ".config/linear/project.token"
    token_path = Path.join(home_root, token_relative_path)
    File.mkdir_p!(Path.dirname(token_path))
    File.write!(token_path, "  linear-secret-token \n")

    write_project_registry_file!(Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml"), %{
      schema_version: 1,
      linear_token_relative_path: token_relative_path,
      projects: [
        %{project_key: "project-a", display_name: "Project A", enabled: true}
      ]
    })

    assert :ok = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
    assert Application.get_env(:symphony_elixir, :linear_api_token) == "linear-secret-token"
  end

  test "bootstrap overwrites an existing env token on success" do
    home_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-token-overwrite-home-#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("HOME")
    previous_token = Application.get_env(:symphony_elixir, :linear_api_token)

    on_exit(fn ->
      restore_env("HOME", previous_home)
      Application.put_env(:symphony_elixir, :linear_api_token, previous_token)
      File.rm_rf(home_root)
    end)

    System.put_env("HOME", home_root)
    Application.put_env(:symphony_elixir, :linear_api_token, "stale-token")

    token_relative_path = ".config/linear/project.token"
    token_path = Path.join(home_root, token_relative_path)
    File.mkdir_p!(Path.dirname(token_path))
    File.write!(token_path, "fresh-token\n")

    write_project_registry_file!(Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml"), %{
      schema_version: 1,
      linear_token_relative_path: token_relative_path,
      projects: [
        %{project_key: "project-a", display_name: "Project A", enabled: true}
      ]
    })

    assert :ok = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
    assert Application.get_env(:symphony_elixir, :linear_api_token) == "fresh-token"
  end

  test "bootstrap rejects token paths that escape HOME" do
    home_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-token-escape-home-#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("HOME")

    on_exit(fn ->
      restore_env("HOME", previous_home)
      File.rm_rf(home_root)
    end)

    System.put_env("HOME", home_root)

    write_project_registry_file!(Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml"), %{
      schema_version: 1,
      linear_token_relative_path: "../outside.token",
      projects: [
        %{project_key: "project-a", display_name: "Project A", enabled: true}
      ]
    })

    assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
    assert message =~ "linear_token_relative_path must stay within HOME: ../outside.token"
  end

  test "bootstrap reports a missing token file" do
    home_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-token-missing-home-#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("HOME")

    on_exit(fn ->
      restore_env("HOME", previous_home)
      File.rm_rf(home_root)
    end)

    System.put_env("HOME", home_root)

    token_relative_path = ".config/linear/missing.token"
    token_path = Path.join(home_root, token_relative_path)

    write_project_registry_file!(Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml"), %{
      schema_version: 1,
      linear_token_relative_path: token_relative_path,
      projects: [
        %{project_key: "project-a", display_name: "Project A", enabled: true}
      ]
    })

    assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
    assert message =~ "token file not found at #{token_path}"
  end

  test "bootstrap reports unreadable token files" do
    home_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-token-unreadable-home-#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("HOME")

    on_exit(fn ->
      restore_env("HOME", previous_home)
      File.rm_rf(home_root)
    end)

    System.put_env("HOME", home_root)

    token_relative_path = ".config/linear/unreadable.token"
    token_path = Path.join(home_root, token_relative_path)

    File.mkdir_p!(Path.dirname(token_path))
    File.write!(token_path, "secret-token\n")
    File.chmod!(token_path, 0o000)

    on_exit(fn ->
      if File.exists?(token_path) do
        File.chmod!(token_path, 0o600)
      end
    end)

    write_project_registry_file!(Path.join(Path.dirname(Workflow.workflow_file_path()), "project_registry.yaml"), %{
      schema_version: 1,
      linear_token_relative_path: token_relative_path,
      projects: [
        %{project_key: "project-a", display_name: "Project A", enabled: true}
      ]
    })

    assert {:error, message} = LinearTokenBootstrap.bootstrap(Workflow.workflow_file_path())
    assert message =~ "token file is not readable at #{token_path}"
  end

  defp with_stubbed_project_registry(responses, fun) when is_list(responses) and is_function(fun, 0) do
    stub_key = :symphony_test_project_registry_load_responses
    module = SymphonyElixir.ProjectRegistry
    {^module, original_binary, original_path} = :code.get_object_code(module)
    previous_ignore_conflict = Code.get_compiler_option(:ignore_module_conflict)

    try do
      Code.put_compiler_option(:ignore_module_conflict, true)
      :code.purge(module)
      :code.delete(module)

      Code.compile_string("""
      defmodule SymphonyElixir.ProjectRegistry do
        def load(path) when is_binary(path) do
          case Process.get(:symphony_test_project_registry_load_responses, []) do
            [response | rest] ->
              Process.put(:symphony_test_project_registry_load_responses, rest)
              response

            [] ->
              raise "unexpected ProjectRegistry.load/1 call for \#{path}"
          end
        end
      end
      """)

      Process.put(stub_key, responses)
      fun.()
    after
      Process.delete(stub_key)
      :code.purge(module)
      :code.delete(module)
      :code.load_binary(module, original_path, original_binary)
      Code.put_compiler_option(:ignore_module_conflict, previous_ignore_conflict)
    end
  end
end
