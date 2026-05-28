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
