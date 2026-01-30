#!/usr/bin/env bash
# test_harness_demo.sh - Demonstrates the test harness capabilities
#
# This file shows how to use the test harness for:
# - Structured skip messages with actionable next steps
# - Command execution logging with full diagnostics
# - Stream separation verification
#
# Run: ./scripts/tests/test_harness_demo.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the full harness
source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

# Test state
TESTS_RUN=0
TESTS_PASSED=0
TESTS_SKIPPED=0
TESTS_FAILED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }

# ============================================================================
# Tests: Skip Protocol
# ============================================================================

test_skip_require_command_present() {
  ((TESTS_RUN++))
  if require_command bash "bash shell" "Install bash"; then
    pass "require_command returns true for existing command"
  else
    fail "require_command should find bash"
  fi
}

test_skip_require_command_missing() {
  ((TESTS_RUN++))
  # nonexistent_command_xyz should not exist
  if require_command nonexistent_command_xyz "Test Command" "Install via: apt install test" 2>/dev/null; then
    fail "require_command should return false for missing command"
  else
    pass "require_command returns false for missing command"
  fi
}

test_skip_require_env_set() {
  ((TESTS_RUN++))
  export TEST_ENV_VAR="value"
  if require_env TEST_ENV_VAR "Test variable" "Set TEST_ENV_VAR"; then
    pass "require_env returns true for set variable"
  else
    fail "require_env should pass for set variable"
  fi
  unset TEST_ENV_VAR
}

test_skip_require_env_unset() {
  ((TESTS_RUN++))
  unset UNSET_VAR_XYZ 2>/dev/null || true
  if require_env UNSET_VAR_XYZ "Unset variable" "Set UNSET_VAR_XYZ=value" 2>/dev/null; then
    fail "require_env should return false for unset variable"
  else
    pass "require_env returns false for unset variable"
  fi
}

test_skip_explicit() {
  ((TESTS_RUN++))
  if skip_test "Manual skip for demo" "This is expected" 2>/dev/null; then
    fail "skip_test should always return false"
  else
    pass "skip_test returns false as expected"
  fi
}

test_skip_summary_format() {
  ((TESTS_RUN++))
  skip_reset
  require_command fake_cmd1 "Fake 1" "Install fake1" 2>/dev/null || true
  require_command fake_cmd2 "Fake 2" "Install fake2" 2>/dev/null || true
  require_command fake_cmd3 "Fake 3" "Install fake1" 2>/dev/null || true  # Duplicate step

  local count
  count=$(skip_count)
  if [[ "$count" -eq 3 ]]; then
    pass "skip_count tracks skipped tests"
  else
    fail "skip_count: expected 3, got $count"
  fi
  skip_reset
}

# ============================================================================
# Tests: Command Execution
# ============================================================================

test_exec_run_success() {
  ((TESTS_RUN++))
  exec_init
  exec_run echo "hello world"
  local status out
  status=$(exec_status)
  out=$(exec_stdout)

  if [[ "$status" -eq 0 && "$out" == "hello world" ]]; then
    pass "exec_run captures successful command"
  else
    fail "exec_run: status=$status, out=$out"
  fi
}

test_exec_run_failure() {
  ((TESTS_RUN++))
  exec_init
  exec_run false
  local status
  status=$(exec_status)

  if [[ "$status" -ne 0 ]]; then
    pass "exec_run captures failed command"
  else
    fail "exec_run should capture non-zero exit"
  fi
}

test_exec_stdout_stderr() {
  ((TESTS_RUN++))
  exec_init
  exec_run bash -c 'echo "stdout message"; echo "stderr message" >&2'
  local out err
  out=$(exec_stdout)
  err=$(exec_stderr)

  if exec_stdout_contains "stdout message" && exec_stderr_contains "stderr message"; then
    pass "exec_run separates stdout and stderr"
  else
    fail "exec_run stream capture: stdout='$out', stderr='$err'"
  fi
}

test_exec_expect_success() {
  ((TESTS_RUN++))
  exec_init
  if exec_expect_success echo "test" 2>/dev/null; then
    pass "exec_expect_success returns 0 on success"
  else
    fail "exec_expect_success should pass"
  fi
}

test_exec_expect_failure() {
  ((TESTS_RUN++))
  exec_init
  if exec_expect_failure false 2>/dev/null; then
    pass "exec_expect_failure returns 0 when command fails"
  else
    fail "exec_expect_failure should pass when command fails"
  fi
}

test_exec_duration() {
  ((TESTS_RUN++))
  exec_init
  exec_run sleep 0.1
  local duration
  duration=$(exec_duration)

  if [[ "$duration" -ge 50 ]]; then
    pass "exec_duration measures time (${duration}ms)"
  else
    fail "exec_duration too short: ${duration}ms"
  fi
}

# ============================================================================
# Tests: Stream Separation
# ============================================================================

test_stream_separation_clean() {
  ((TESTS_RUN++))
  exec_init
  # Clean output: data to stdout, nothing to stderr
  exec_run bash -c 'echo "{\"status\":\"ok\"}"'
  if exec_check_stream_separation 2>/dev/null; then
    pass "exec_check_stream_separation passes for clean output"
  else
    fail "exec_check_stream_separation should pass"
  fi
}

test_stream_separation_violation() {
  ((TESTS_RUN++))
  exec_init
  # Violating output: log messages to stdout (should be stderr)
  exec_run bash -c 'echo "[INFO] This is a log message"'
  if exec_check_stream_separation 2>/dev/null; then
    fail "exec_check_stream_separation should detect violation"
  else
    pass "exec_check_stream_separation detects log messages in stdout"
  fi
}

# ============================================================================
# Tests: Full Harness Integration
# ============================================================================

test_harness_setup_teardown() {
  ((TESTS_RUN++))
  harness_setup

  local dirs_ok=true
  [[ -d "$DSR_CONFIG_DIR" ]] || dirs_ok=false
  [[ -d "$DSR_STATE_DIR" ]] || dirs_ok=false

  local run_id_ok=false
  [[ -n "$DSR_RUN_ID" && "$DSR_RUN_ID" =~ ^run-[0-9]+-[0-9]+$ ]] && run_id_ok=true

  harness_teardown

  if [[ "$dirs_ok" == "true" && "$run_id_ok" == "true" ]]; then
    pass "harness_setup/teardown creates proper environment"
  else
    fail "harness setup: dirs_ok=$dirs_ok, run_id_ok=$run_id_ok"
  fi
}

# ============================================================================
# Run All Tests
# ============================================================================

main() {
  echo "=== Test Harness Demonstration ==="
  echo ""

  echo "Skip Protocol Tests:"
  test_skip_require_command_present
  test_skip_require_command_missing
  test_skip_require_env_set
  test_skip_require_env_unset
  test_skip_explicit
  test_skip_summary_format

  echo ""
  echo "Command Execution Tests:"
  test_exec_run_success
  test_exec_run_failure
  test_exec_stdout_stderr
  test_exec_expect_success
  test_exec_expect_failure
  test_exec_duration

  echo ""
  echo "Stream Separation Tests:"
  test_stream_separation_clean
  test_stream_separation_violation

  echo ""
  echo "Full Harness Tests:"
  test_harness_setup_teardown

  echo ""
  echo "=========================================="
  echo "Tests run:    $TESTS_RUN"
  echo "Passed:       $TESTS_PASSED"
  echo "Skipped:      $TESTS_SKIPPED"
  echo "Failed:       $TESTS_FAILED"
  echo "=========================================="

  exec_cleanup

  [[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
}

main "$@"
