#!/usr/bin/env bash
# test_quality_e2e.sh - E2E tests for dsr quality (real behavior)
#
# Exercises quality gate execution with real commands and repos.yaml config.
# Validates pass/fail/skip behavior, JSON output, and stream separation.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test harness
source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Suppress colors for consistent output
export NO_COLOR=1

pass() { ((TESTS_PASSED++)); echo "PASS: $1"; }
fail() { ((TESTS_FAILED++)); echo "FAIL: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "SKIP: $1"; }

setup_quality_repos_yaml() {
  mkdir -p "$DSR_CONFIG_DIR"
  export DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"

  cat > "$DSR_REPOS_FILE" <<'EOF_REPOS'
schema_version: "1.0.0"
tools:
  quality-pass:
    checks:
      - "echo PASS"
      - "sleep 1"
  quality-fail:
    checks:
      - "false"
EOF_REPOS
}

run_quality() {
  local tool_name="$1"
  shift
  exec_run "$PROJECT_ROOT/dsr" --json quality --tool "$tool_name" "$@"
  return 0
}

json_get() {
  local filter="$1"
  echo "$(exec_stdout)" | jq -r "$filter"
}

assert_json_ok() {
  local command
  command=$(json_get '.command')
  if [[ "$command" != "quality" ]]; then
    echo "Expected command=quality, got $command" >&2
    return 1
  fi
  return 0
}

# ==========================================================================
# Tests
# ==========================================================================

test_quality_pass() {
  if ! require_command yq "yq" "Install yq: brew install yq" 2>/dev/null; then
    return 2
  fi
  if ! require_command jq "jq" "Install jq: brew install jq" 2>/dev/null; then
    return 2
  fi

  setup_quality_repos_yaml
  run_quality "quality-pass"

  local status
  status=$(exec_status)
  if [[ "$status" -ne 0 ]]; then
    echo "Expected exit 0, got $status" >&2
    return 1
  fi

  assert_json_ok || return 1

  local result_status total passed failed
  result_status=$(json_get '.status')
  total=$(json_get '.details.total')
  passed=$(json_get '.details.passed')
  failed=$(json_get '.details.failed')

  if [[ "$result_status" != "success" || "$total" -ne 2 || "$passed" -ne 2 || "$failed" -ne 0 ]]; then
    echo "Unexpected summary: status=$result_status total=$total passed=$passed failed=$failed" >&2
    return 1
  fi

  # Ensure durations recorded (sleep command should be >= 900ms)
  local sleep_duration
  sleep_duration=$(json_get '.details.checks[] | select(.command == "sleep 1") | .duration_ms')
  if [[ -z "$sleep_duration" || "$sleep_duration" -lt 900 ]]; then
    echo "Expected sleep duration >= 900ms, got $sleep_duration" >&2
    return 1
  fi

  # Stream separation: stdout JSON only, stderr has logs
  if exec_stdout_contains "[quality]"; then
    echo "Expected no logs on stdout" >&2
    return 1
  fi
  if ! exec_stderr_contains "[quality]"; then
    echo "Expected logs on stderr" >&2
    return 1
  fi

  return 0
}

test_quality_fail() {
  if ! require_command yq "yq" "Install yq: brew install yq" 2>/dev/null; then
    return 2
  fi
  if ! require_command jq "jq" "Install jq: brew install jq" 2>/dev/null; then
    return 2
  fi

  setup_quality_repos_yaml
  run_quality "quality-fail"

  local status
  status=$(exec_status)
  if [[ "$status" -ne 1 ]]; then
    echo "Expected exit 1, got $status" >&2
    return 1
  fi

  assert_json_ok || return 1

  local result_status failed total
  result_status=$(json_get '.status')
  failed=$(json_get '.details.failed')
  total=$(json_get '.details.total')

  if [[ "$result_status" != "failure" || "$failed" -ne 1 || "$total" -ne 1 ]]; then
    echo "Unexpected failure summary: status=$result_status total=$total failed=$failed" >&2
    return 1
  fi

  if ! exec_stderr_contains "FAILED"; then
    echo "Expected failure logs on stderr" >&2
    return 1
  fi

  return 0
}

test_quality_skip_checks() {
  if ! require_command yq "yq" "Install yq: brew install yq" 2>/dev/null; then
    return 2
  fi
  if ! require_command jq "jq" "Install jq: brew install jq" 2>/dev/null; then
    return 2
  fi

  setup_quality_repos_yaml
  run_quality "quality-pass" --skip-checks

  local status
  status=$(exec_status)
  if [[ "$status" -ne 0 ]]; then
    echo "Expected exit 0, got $status" >&2
    return 1
  fi

  assert_json_ok || return 1

  local skipped total
  skipped=$(json_get '.details.skipped')
  total=$(json_get '.details.total')

  if [[ "$skipped" != "true" || "$total" -ne 0 ]]; then
    echo "Unexpected skip summary: skipped=$skipped total=$total" >&2
    return 1
  fi

  return 0
}

run_test() {
  local name="$1"
  local func="$2"

  ((TESTS_RUN++))
  # shellcheck disable=SC2034  # Used by test_harness for logging
  TEST_NAME="$name"
  harness_setup

  if $func; then
    # shellcheck disable=SC2034  # Used by test_harness for failure logging
    TEST_EXIT_CODE=0
    pass "$name"
  else
    local rc=$?
    if [[ $rc -eq 2 ]]; then
      # shellcheck disable=SC2034  # Used by test_harness for failure logging
      TEST_EXIT_CODE=0
      skip "$name (prereqs missing)"
    else
      # shellcheck disable=SC2034  # Used by test_harness for failure logging
      TEST_EXIT_CODE=1
      fail "$name"
    fi
  fi

  harness_teardown
}

main() {
  run_test "quality_pass" test_quality_pass
  run_test "quality_fail" test_quality_fail
  run_test "quality_skip_checks" test_quality_skip_checks

  echo ""
  echo "Tests run: $TESTS_RUN"
  echo "Passed:    $TESTS_PASSED"
  echo "Skipped:   $TESTS_SKIPPED"
  echo "Failed:    $TESTS_FAILED"

  if [[ $TESTS_FAILED -ne 0 ]]; then
    exit 1
  fi
}

main "$@"
