# 全量 Gate 聚合错误报告 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 `make all`、`make lint` 和 `mix lint` 的聚合错误报告，让早期检查失败后仍继续执行剩余检查，并在最后统一返回正确失败状态。

**Architecture:** 新增一个 POSIX shell runner 作为 gate 聚合层，负责执行检查、记录每项退出码、打印汇总并 fail closed。`elixir/Makefile` 与 `mix.exs` 的 lint alias 都接入这个 runner，避免 full gate 与 closeout lint 行为分叉。用 fake `mix` 的 ExUnit 测试验证继续执行、退出码和 summary 输出。

**Tech Stack:** POSIX shell, GNU make, Elixir Mix aliases, ExUnit, GitHub Actions `make-all` workflow.

---

## 1. 计划边界

### 1.1 这次计划要做什么

- 新增 `elixir/scripts/run_checks.sh`，提供 `lint` 和 `all` 两个模式。
- 修改 `elixir/Makefile`，让 `make lint` 和 `make all` 使用聚合 runner。
- 修改 `elixir/mix.exs`，让 `mix lint` 使用同一个聚合 runner 的 lint 模式。
- 新增 `elixir/test/scripts/run_checks_test.exs`，用 fake `mix` 验证早期失败后继续执行、summary 输出和最终退出码。
- 更新 `elixir/TESTING.md`，说明 full gate 和 lint 入口是聚合报告，但 gate 路由分层不变。

### 1.2 这次计划明确不做什么

- 不修改 `.github/workflows/make-all.yml`，因为 workflow 已经执行 `make all`，Makefile 接入后远端会继承新行为。
- 不修改 coverage threshold、Credo 配置、dialyzer 配置、ExUnit 配置或测试并发制度。
- 不改变 `mix specs.check` 本身的检查规则。
- 不把 `make all` 变成默认开发命令。
- 不实现 GitHub Actions matrix 或多个 required checks。

### 1.3 允许修改的文件 / 目录

- Create: `elixir/scripts/run_checks.sh`
- Create: `elixir/test/scripts/run_checks_test.exs`
- Modify: `elixir/Makefile`
- Modify: `elixir/mix.exs`
- Modify: `elixir/TESTING.md`

### 1.4 明确禁止修改的文件 / 目录

- Do not modify: `.github/workflows/make-all.yml`
- Do not modify: `.github/pull_request_template.md`
- Do not modify: `elixir/mix.lock`
- Do not modify: `elixir/config/**`
- Do not modify: product runtime modules under `elixir/lib/symphony_elixir/**`
- Do not modify: existing user-edited docs outside this plan unless the user explicitly asks

### 1.5 如果越界怎么办

- 如果 implementation 需要修改 required check 名称、workflow job 拆分或 branch protection 相关内容，停止并回到 SPEC。
- 如果 implementation 需要改变 coverage、dialyzer、Credo 或 ExUnit 的判定规则，停止并回到 SPEC。
- 如果 fake `mix` 测试无法可靠验证 runner 行为，先停下补充 plan，而不是直接改生产入口。
- 如果当前工作树存在无关改动，执行时只 stage 本计划列出的文件，不得覆盖或 revert 用户改动。

## 2. 文件结构与职责

| 文件 | 动作 | 职责 |
| --- | --- | --- |
| `elixir/scripts/run_checks.sh` | Create | 聚合执行 gate 检查，支持 `lint` 和 `all` 模式，保留底层命令输出并最终汇总 |
| `elixir/test/scripts/run_checks_test.exs` | Create | 用 fake `mix` 验证 runner 和入口接入的行为 |
| `elixir/Makefile` | Modify | 保留单项 targets，并让 `lint` / `ci` 调用聚合 runner |
| `elixir/mix.exs` | Modify | 让 `mix lint` 调用聚合 runner 的 lint 模式 |
| `elixir/TESTING.md` | Modify | 记录 full gate 和 lint 聚合报告行为，不改变 gate 路由 |

## 3. 任务拆解

### Task 1: 添加聚合 runner 和直接 runner 测试

**Files:**
- Create: `elixir/scripts/run_checks.sh`
- Create: `elixir/test/scripts/run_checks_test.exs`

- [ ] **Step 1: 创建 runner 直接测试**

Create `elixir/test/scripts/run_checks_test.exs` with this content:

```elixir
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

  defp run_runner(mode, env) do
    System.cmd("sh", [@runner_path, mode], env: env, stderr_to_stdout: true)
  end

  defp command_log(content) do
    content
    |> String.split("\\n", trim: true)
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
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/scripts/run_checks_test.exs
```

Expected: FAIL because `elixir/scripts/run_checks.sh` does not exist yet.

- [ ] **Step 3: 创建聚合 runner**

Create `elixir/scripts/run_checks.sh` with this content:

```sh
#!/bin/sh

set -u

mode="${1:-}"
mix_cmd="${MIX:-mix}"
failed_count=0
overall_status=0
summary=""

run_step() {
  label="$1"
  shift

  printf '\n=== %s ===\n' "$label"

  # Intentionally allow MIX to contain a command with arguments, such as "mise exec -- mix".
  # shellcheck disable=SC2086
  $mix_cmd "$@"
  status=$?

  if [ "$status" -eq 0 ]; then
    summary="${summary}PASS ${label}\n"
  else
    summary="${summary}FAIL ${label} (exit ${status})\n"
    failed_count=$((failed_count + 1))
    overall_status=1
  fi
}

print_summary_and_exit() {
  printf '\n=== Symphony checks summary ===\n'
  printf '%b' "$summary"

  if [ "$failed_count" -eq 0 ]; then
    printf 'All checks passed.\n'
    exit 0
  fi

  printf '%s check(s) failed.\n' "$failed_count"
  exit "$overall_status"
}

case "$mode" in
  lint)
    run_step "specs.check" specs.check
    run_step "credo --strict" credo --strict
    print_summary_and_exit
    ;;
  all)
    run_step "setup" setup
    run_step "build" build
    run_step "fmt-check" format --check-formatted
    run_step "specs.check" specs.check
    run_step "credo --strict" credo --strict
    run_step "coverage" test --cover
    run_step "dialyzer deps" deps.get
    run_step "dialyzer" dialyzer --format short
    print_summary_and_exit
    ;;
  *)
    printf 'Unknown check mode: %s\n' "${mode:-<empty>}" >&2
    printf 'Usage: %s lint|all\n' "$0" >&2
    exit 64
    ;;
esac
```

- [ ] **Step 4: 设置 runner 可执行权限**

Run:

```bash
chmod 755 elixir/scripts/run_checks.sh
```

Expected: command exits 0.

- [ ] **Step 5: 运行 runner 测试确认通过**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/scripts/run_checks_test.exs
```

Expected: PASS. The output reports 5 tests and 0 failures.

- [ ] **Step 6: 提交 Task 1 边界内改动**

Run only if the human has authorized commits and the worktree contains no unrelated staged files:

```bash
git add elixir/scripts/run_checks.sh elixir/test/scripts/run_checks_test.exs
git commit -m "test: 覆盖 gate 聚合 runner"
```

Expected: commit succeeds and includes only the runner plus its tests.

### Task 2: 接入 Makefile 和 Mix lint alias

**Files:**
- Modify: `elixir/Makefile`
- Modify: `elixir/mix.exs`
- Modify: `elixir/test/scripts/run_checks_test.exs`

- [ ] **Step 1: 添加入口接入测试**

Append these tests before the helper functions in `elixir/test/scripts/run_checks_test.exs`:

```elixir
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
```

Add this helper near the other helpers in the same file:

```elixir
  defp project_root do
    Path.expand("../..", __DIR__)
  end
```

- [ ] **Step 2: 运行测试确认入口尚未接入**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/scripts/run_checks_test.exs
```

Expected: FAIL. At least the `make lint`, `make all`, or `mix lint` entrypoint tests still observe current fail-fast behavior.

- [ ] **Step 3: 修改 Makefile 接入 runner**

Modify `elixir/Makefile` so its relevant content matches this:

```make
.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e

MIX ?= mix
CHECK_RUNNER ?= ./scripts/run_checks.sh

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	MIX="$(MIX)" $(CHECK_RUNNER) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	MIX="$(MIX)" $(CHECK_RUNNER) all

all: ci
```

- [ ] **Step 4: 修改 Mix alias 接入 runner**

Modify the `aliases/0` function in `elixir/mix.exs` so it matches this:

```elixir
  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["cmd ./scripts/run_checks.sh lint"]
    ]
  end
```

- [ ] **Step 5: 运行入口接入测试确认通过**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/scripts/run_checks_test.exs
```

Expected: PASS. The output reports 9 tests and 0 failures.

- [ ] **Step 6: 提交 Task 2 边界内改动**

Run only if the human has authorized commits and the worktree contains no unrelated staged files:

```bash
git add elixir/Makefile elixir/mix.exs elixir/test/scripts/run_checks_test.exs
git commit -m "feat: 聚合 full gate 和 lint 结果"
```

Expected: commit succeeds and includes only Makefile, Mix alias, and entrypoint tests.

### Task 3: 更新测试制度说明并完成 targeted 验证

**Files:**
- Modify: `elixir/TESTING.md`

- [ ] **Step 1: 更新 full gate 行为说明**

In `elixir/TESTING.md`, under `## Next Push Gate`, keep the existing gate routing text and add this paragraph after the three action bullets:

```markdown
`mix lint`、`make lint` 和 `make all` 使用聚合报告：某个检查失败后，runner 会继续执行同一入口内的后续检查，最后汇总通过项和失败项；只要任一检查失败，入口最终仍返回非零状态。这个行为只改变错误展示完整性，不改变 gate 路由级别，也不把 `make all` 变成默认开发命令。
```

- [ ] **Step 2: 运行 runner targeted tests**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/scripts/run_checks_test.exs
```

Expected: PASS. The output reports 9 tests and 0 failures.

- [ ] **Step 3: 运行真实 lint 入口**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint
```

Expected: PASS. Output includes a `Symphony checks summary` section with `PASS specs.check` and `PASS credo --strict`.

- [ ] **Step 4: 运行格式检查**

Run:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted
```

Expected: PASS.

- [ ] **Step 5: 判断是否需要 local make all**

Because this change touches `elixir/Makefile` and `elixir/mix.exs`, it hits the `local make all` trigger in `elixir/TESTING.md`. Before PR create/update, run high-level confirmation after targeted tests and lint pass:

```bash
cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all
```

Expected: PASS if the repository is otherwise healthy. Output includes a `Symphony checks summary` section. If it fails, use the summary to identify all failing checks, then return to the smallest targeted proof for each fix before re-running `make all`.

- [ ] **Step 6: 提交 Task 3 边界内改动**

Run only if the human has authorized commits and the worktree contains no unrelated staged files:

```bash
git add elixir/TESTING.md
git commit -m "docs: 记录 gate 聚合报告语义"
```

Expected: commit succeeds and includes only the testing documentation change.

## 4. 实施顺序

1. 先执行 Task 1，建立 runner 直接行为和 fake `mix` 测试。
2. 再执行 Task 2，把 `make lint`、`make all` 和 `mix lint` 接到 runner。
3. 最后执行 Task 3，同步测试制度说明并完成 targeted 验证。
4. 如果任一任务发现需要修改 SPEC 禁止范围内的文件，立即暂停并回到 SPEC。

## 5. 验证顺序

1. `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix test test/scripts/run_checks_test.exs`
2. `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix lint`
3. `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- mix format --check-formatted`
4. PR create/update 前，因为修改了 `Makefile` 和 `mix.exs`，最终运行 `cd elixir && SYMPHONY_TEST_MAX_CASES=4 mise exec -- make all`

## 6. 停止条件

- fake `mix` 测试发现 runner 在失败后没有继续执行后续检查。
- fake `mix` 测试发现存在失败检查但最终退出码为 0。
- `mix lint` 不能通过 Mix alias 稳定调用 runner。
- 实现需要修改 `.github/workflows/make-all.yml` 或 required check 结构。
- 实现需要改变底层检查工具的判定规则。
- full gate 运行出现资源压力，按 `elixir/TESTING.md` 停止并清理现场。

## 7. 复核清单

- [ ] 计划没有重复 SPEC 的需求正文
- [ ] 允许修改范围写清楚了
- [ ] 禁止修改范围写清楚了
- [ ] 如果越界，有明确停下和回退规则
- [ ] 任务足够小，不会把多个动作塞进同一步
- [ ] 验证顺序是具体可执行的，不是空话
- [ ] `make all`、`make lint` 和 `mix lint` 都有验证覆盖
- [ ] 任一失败最终非零的 fail closed 语义有测试覆盖
- [ ] 没有改变 gate 路由制度、coverage threshold、dialyzer 配置或 GitHub workflow
