#!/usr/bin/env bash
# e2e_watch.sh - E2E tests for dsr watch command
#
# Tests watch mode with real GH API calls when credentials are available.
# Skips with actionable guidance if gh auth is missing.
#
# Run: ./scripts/tests/e2e_watch.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="$PROJECT_ROOT/dsr"

# Source the test harness
source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }

# ============================================================================
# Dependency Check
# ============================================================================
if ! require_command gh "GitHub CLI" "Install: brew install gh OR apt install gh" 2>/dev/null; then
    echo "SKIP: gh is required for E2E watch tests"
    echo "  Install: brew install gh OR apt install gh"
    exit 0
fi

# Check gh auth
if ! gh auth status &>/dev/null; then
    echo "SKIP: gh authentication is required for E2E watch tests"
    echo "  Authenticate: gh auth login"
    exit 0
fi

# ============================================================================
# Helper: Seed test environment with minimal config
# ============================================================================

seed_minimal_config() {
    # Create minimal repos.yaml
    mkdir -p "$XDG_CONFIG_HOME/dsr"
    cat > "$XDG_CONFIG_HOME/dsr/repos.yaml" << 'YAML'
schema_version: "1.0.0"
tools: {}
YAML

    # Create minimal config.yaml
    cat > "$XDG_CONFIG_HOME/dsr/config.yaml" << 'YAML'
schema_version: "1.0.0"
watch:
  interval: 300
  notify: none
YAML

    # Create minimal hosts.yaml
    cat > "$XDG_CONFIG_HOME/dsr/hosts.yaml" << 'YAML'
schema_version: "1.0.0"
hosts:
  localhost:
    platform: linux/amd64
    connection: local
    concurrency: 2
YAML
}

# ============================================================================
# Tests: Help and Basic Invocation
# ============================================================================

test_watch_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" watch --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "watch"; then
        pass "watch --help shows usage information"
    else
        fail "watch --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_watch_once_runs_without_error() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    # Use --once --dry-run for bounded, safe execution
    exec_run timeout 30 "$DSR_CMD" watch --once --dry-run
    local status
    status=$(exec_status)

    if [[ "$status" -eq 0 ]]; then
        pass "watch --once --dry-run runs without error"
    else
        fail "watch --once should exit 0, got: $status"
        echo "stderr: $(exec_stderr)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Human-Readable Output
# ============================================================================

test_watch_shows_preflight() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    exec_run timeout 30 "$DSR_CMD" watch --once --dry-run

    # Human output goes to stderr
    if exec_stderr_contains "preflight"; then
        pass "watch shows preflight check"
    else
        fail "watch should show preflight check"
        echo "stderr: $(exec_stderr | head -20)"
    fi

    harness_teardown
}

test_watch_shows_check_result() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    exec_run timeout 30 "$DSR_CMD" watch --once --dry-run

    # Should show either throttled or no throttled runs
    if exec_stderr_contains "throttle" || exec_stderr_contains "Throttle"; then
        pass "watch shows throttle check result"
    else
        fail "watch should show throttle check result"
        echo "stderr: $(exec_stderr | head -20)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: JSON Output
# ============================================================================

test_watch_json_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    exec_run timeout 30 "$DSR_CMD" --json watch --once --dry-run
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "watch --json produces valid JSON"
    else
        fail "watch --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_watch_json_has_status_field() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    exec_run timeout 30 "$DSR_CMD" --json watch --once --dry-run
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.status' >/dev/null 2>&1; then
        pass "watch JSON has status field"
    else
        fail "watch JSON should have status field"
    fi

    harness_teardown
}

test_watch_json_has_details() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    exec_run timeout 30 "$DSR_CMD" --json watch --once --dry-run
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.details' >/dev/null 2>&1; then
        pass "watch JSON has details field"
    else
        fail "watch JSON should have details field"
    fi

    harness_teardown
}

test_watch_json_has_mode() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    exec_run timeout 30 "$DSR_CMD" --json watch --once --dry-run
    local output
    output=$(exec_stdout)

    if echo "$output" | jq -e '.details.mode == "once"' >/dev/null 2>&1; then
        pass "watch JSON has mode: once"
    else
        fail "watch JSON should have mode: once"
    fi

    harness_teardown
}

test_watch_json_stderr_empty() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    exec_run timeout 30 "$DSR_CMD" --json watch --once --dry-run
    local stderr_content
    stderr_content=$(exec_stderr)

    # Filter out INFO/DEBUG logs
    local filtered_stderr
    filtered_stderr=$(echo "$stderr_content" | grep -v '^\[INFO\]' | grep -v '^\[DEBUG\]' | grep -v '^$' || true)

    if [[ -z "$filtered_stderr" ]]; then
        pass "watch JSON has empty stderr (except INFO logs)"
    else
        fail "watch JSON stderr should be empty"
        echo "stderr: $filtered_stderr"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Exit Code and Bounded Execution
# ============================================================================

test_watch_once_exits_cleanly() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    local start_time end_time
    start_time=$(date +%s)

    exec_run timeout 30 "$DSR_CMD" watch --once --dry-run

    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Should complete within reasonable time (not hang)
    if [[ "$duration" -lt 25 ]]; then
        pass "watch --once completes quickly (${duration}s)"
    else
        fail "watch --once should complete in <25s, took ${duration}s"
    fi

    harness_teardown
}

test_watch_dry_run_no_triggers() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    exec_run timeout 30 "$DSR_CMD" --json watch --once --dry-run
    local output
    output=$(exec_stdout)

    # Dry run shouldn't trigger any builds (runs object should be empty or indicate dry run)
    if echo "$output" | jq -e '.details.triggered_state' >/dev/null 2>&1; then
        pass "watch --dry-run reports triggered state"
    else
        fail "watch --dry-run should report triggered state"
    fi

    harness_teardown
}

# ============================================================================
# Tests: State Files
# ============================================================================

test_watch_creates_state_dir() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    exec_run timeout 30 "$DSR_CMD" watch --once --dry-run

    # State directory should be created under XDG_STATE_HOME
    if [[ -d "$XDG_STATE_HOME/dsr" ]]; then
        pass "watch creates state directory"
    else
        fail "watch should create state directory"
    fi

    harness_teardown
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    exec_cleanup 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== E2E: dsr watch Tests ==="
echo ""

echo "Help and Basic Invocation:"
test_watch_help
test_watch_once_runs_without_error

echo ""
echo "Human-Readable Output:"
test_watch_shows_preflight
test_watch_shows_check_result

echo ""
echo "JSON Output:"
test_watch_json_valid
test_watch_json_has_status_field
test_watch_json_has_details
test_watch_json_has_mode
test_watch_json_stderr_empty

echo ""
echo "Exit Code and Bounded Execution:"
test_watch_once_exits_cleanly
test_watch_dry_run_no_triggers

echo ""
echo "State Files:"
test_watch_creates_state_dir

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
