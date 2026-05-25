defmodule Scripts.RunChecksTest do
  use ExUnit.Case, async: false

  @runner_path Path.expand("../../scripts/run_checks.sh", __DIR__)

  test "all mode keeps running after early failures and reports every failing check" do
    fake_mix = """
    #!/bin/sh
    cmd="$*"
    printf '%s\\n' "$cmd" >> "$CHECK_RUNNER_LOG"

    case "$cmd" in
      "format --check-formatted")
        exit 2
        ;;
      "specs.check")
        exit 3
        ;;
      "test --cover")
        exit 4
        ;;
      *)
        exit 0
        ;;
    esac
    """

    with_fake_mix(fake_mix, fn log_path, env ->
      {output, status} = run_runner("all", env)

      assert status == 1

      assert File.read!(log_path) |> command_log() == [
               "setup",
               "build",
               "format --check-formatted",
               "specs.check",
               "credo --strict",
               "test --cover",
               "deps.get",
               "dialyzer --format short"
             ]

      assert output =~ "FAIL fmt-check (exit 2)"
      assert output =~ "FAIL specs.check (exit 3)"
      assert output =~ "FAIL coverage (exit 4)"
      assert output =~ "PASS dialyzer"
      assert output =~ "=== Symphony checks summary ==="
      assert output =~ "3 check(s) failed."
    end)
  end

  test "lint mode runs credo after specs.check fails" do
    fake_mix = """
    #!/bin/sh
    cmd="$*"
    printf '%s\\n' "$cmd" >> "$CHECK_RUNNER_LOG"
    printf 'fake stdout for %s\\n' "$cmd"
    printf 'fake stderr for %s\\n' "$cmd" >&2

    case "$cmd" in
      "specs.check")
        exit 7
        ;;
      *)
        exit 0
        ;;
    esac
    """

    with_fake_mix(fake_mix, fn log_path, env ->
      {output, status} = run_runner("lint", env)

      assert status == 1
      assert File.read!(log_path) |> command_log() == ["specs.check", "credo --strict"]
      assert output =~ "=== Symphony checks summary ==="
      assert output =~ "FAIL specs.check (exit 7)"
      assert output =~ "PASS credo --strict"
      assert output =~ "fake stdout for specs.check"
      assert output =~ "fake stderr for credo --strict"
      assert output =~ "1 check(s) failed."
    end)
  end

  test "all mode returns zero when every check passes" do
    fake_mix = """
    #!/bin/sh
    cmd="$*"
    printf '%s\\n' "$cmd" >> "$CHECK_RUNNER_LOG"
    exit 0
    """

    with_fake_mix(fake_mix, fn _log_path, env ->
      {output, status} = run_runner("all", env)

      assert status == 0
      assert output =~ "PASS setup"
      assert output =~ "PASS dialyzer"
      assert output =~ "=== Symphony checks summary ==="
      assert output =~ "All checks passed."
    end)
  end

  test "lint mode returns zero when every check passes" do
    fake_mix = """
    #!/bin/sh
    cmd="$*"
    printf '%s\\n' "$cmd" >> "$CHECK_RUNNER_LOG"
    exit 0
    """

    with_fake_mix(fake_mix, fn log_path, env ->
      {output, status} = run_runner("lint", env)

      assert status == 0
      assert File.read!(log_path) |> command_log() == ["specs.check", "credo --strict"]
      assert output =~ "PASS specs.check"
      assert output =~ "PASS credo --strict"
      assert output =~ "=== Symphony checks summary ==="
      assert output =~ "All checks passed."
    end)
  end

  test "unknown mode fails closed" do
    {output, status} = System.cmd("sh", [@runner_path, "unknown"], stderr_to_stdout: true)

    assert status == 64
    assert output =~ "Unknown check mode: unknown"
    assert output =~ "Usage:"
  end

  test "make lint delegates to lint mode and fails after running credo" do
    fake_mix = """
    #!/bin/sh
    cmd="$*"
    printf '%s\\n' "$cmd" >> "$CHECK_RUNNER_LOG"

    case "$cmd" in
      "specs.check")
        exit 8
        ;;
      *)
        exit 0
        ;;
    esac
    """

    with_fake_mix(fake_mix, fn log_path, env ->
      {output, status} =
        System.cmd("make", ["lint"], cd: project_root(), env: env, stderr_to_stdout: true)

      assert status == 2
      assert File.read!(log_path) |> command_log() == ["specs.check", "credo --strict"]
      assert output =~ "=== Symphony checks summary ==="
      assert output =~ "FAIL specs.check (exit 8)"
      assert output =~ "PASS credo --strict"
    end)
  end

  test "make lint returns zero when lint checks pass" do
    fake_mix = """
    #!/bin/sh
    cmd="$*"
    printf '%s\\n' "$cmd" >> "$CHECK_RUNNER_LOG"
    exit 0
    """

    with_fake_mix(fake_mix, fn log_path, env ->
      {output, status} =
        System.cmd("make", ["lint"], cd: project_root(), env: env, stderr_to_stdout: true)

      assert status == 0
      assert File.read!(log_path) |> command_log() == ["specs.check", "credo --strict"]
      assert output =~ "PASS specs.check"
      assert output =~ "PASS credo --strict"
      assert output =~ "=== Symphony checks summary ==="
      assert output =~ "All checks passed."
    end)
  end

  test "make all delegates to all mode and keeps running after fmt failure" do
    fake_mix = """
    #!/bin/sh
    cmd="$*"
    printf '%s\\n' "$cmd" >> "$CHECK_RUNNER_LOG"

    case "$cmd" in
      "format --check-formatted")
        exit 9
        ;;
      *)
        exit 0
        ;;
    esac
    """

    with_fake_mix(fake_mix, fn log_path, env ->
      {output, status} =
        System.cmd("make", ["all"], cd: project_root(), env: env, stderr_to_stdout: true)

      assert status == 2

      assert File.read!(log_path) |> command_log() == [
               "setup",
               "build",
               "format --check-formatted",
               "specs.check",
               "credo --strict",
               "test --cover",
               "deps.get",
               "dialyzer --format short"
             ]

      assert output =~ "FAIL fmt-check (exit 9)"
      assert output =~ "PASS dialyzer"
      assert output =~ "=== Symphony checks summary ==="
    end)
  end

  test "mix lint alias delegates to lint mode with the configured MIX command" do
    fake_mix = """
    #!/bin/sh
    cmd="$*"
    printf '%s\\n' "$cmd" >> "$CHECK_RUNNER_LOG"

    case "$cmd" in
      "specs.check")
        exit 10
        ;;
      *)
        exit 0
        ;;
    esac
    """

    with_fake_mix(fake_mix, fn log_path, env ->
      real_mix = System.find_executable("mix")
      assert is_binary(real_mix)

      {output, status} =
        System.cmd(real_mix, ["lint"], cd: project_root(), env: env, stderr_to_stdout: true)

      assert status == 1
      assert File.read!(log_path) |> command_log() == ["specs.check", "credo --strict"]
      assert output =~ "=== Symphony checks summary ==="
      assert output =~ "FAIL specs.check (exit 10)"
      assert output =~ "PASS credo --strict"
    end)
  end

  defp run_runner(mode, env) do
    System.cmd("sh", [@runner_path, mode], env: env, stderr_to_stdout: true)
  end

  defp project_root do
    Path.expand("../..", __DIR__)
  end

  defp command_log(content) do
    content
    |> String.split("\n", trim: true)
  end

  defp with_fake_mix(script, fun) do
    root = Path.join(System.tmp_dir!(), "run-checks-test-#{System.unique_integer([:positive, :monotonic])}")
    bin_dir = Path.join(root, "bin")
    log_path = Path.join(root, "commands.log")
    mix_path = Path.join(bin_dir, "mix")
    original_path = System.get_env("PATH") || ""

    File.rm_rf!(root)
    File.mkdir_p!(bin_dir)
    File.write!(log_path, "")
    File.write!(mix_path, script)
    File.chmod!(mix_path, 0o755)

    env = [
      {"PATH", Enum.join([bin_dir, original_path], ":")},
      {"MIX", "mix"},
      {"CHECK_RUNNER_LOG", log_path}
    ]

    try do
      fun.(log_path, env)
    after
      File.rm_rf!(root)
    end
  end
end
