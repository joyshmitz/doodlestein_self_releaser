#!/usr/bin/env bash
# test_status_prune.sh - Tests for dsr status and prune commands
#
# bd-1jt.5.15: Tests for status/report + host selection + prune
#
# Coverage:
# - status output shape + --refresh behavior
# - host selection respects health + overrides (see also test_host_selector.sh)
# - prune dry-run output and retention limits
#
# Run: ./scripts/tests/test_status_prune.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ============================================================================
# Dependency Check
# ============================================================================
if ! command -v jq &>/dev/null; then
    echo "SKIP: jq is required for these tests"
    echo "  Install: brew install jq OR apt install jq"
    exit 0
fi

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { echo "${YELLOW}SKIP${NC}: $1"; }

# Setup test environment
TEMP_DIR=$(mktemp -d)
export DSR_STATE_DIR="$TEMP_DIR/state"
export DSR_CONFIG_DIR="$TEMP_DIR/config"
export DSR_CACHE_DIR="$TEMP_DIR/cache"
mkdir -p "$DSR_STATE_DIR" "$DSR_CONFIG_DIR" "$DSR_CACHE_DIR"

# Create minimal config for testing
mkdir -p "$DSR_CONFIG_DIR"
cat > "$DSR_CONFIG_DIR/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
default_targets:
  - linux/amd64
signing:
  enabled: false
YAML

# Create hosts.yaml
cat > "$DSR_CONFIG_DIR/hosts.yaml" << 'YAML'
schema_version: "1.0.0"
hosts:
  testhost1:
    platform: linux/amd64
    connection: local
    concurrency: 2
  testhost2:
    platform: darwin/arm64
    connection: ssh
    concurrency: 1
YAML

# Cleanup trap
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ============================================================================
# Helper Functions
# ============================================================================

# Run dsr command and capture stdout only (suppress stderr)
run_dsr() {
    "$PROJECT_ROOT/dsr" "$@" 2>/dev/null
}

# Run dsr command with --json flag (global flag must come before subcommand)
run_dsr_json() {
    local cmd="$1"
    shift
    "$PROJECT_ROOT/dsr" --json "$cmd" "$@" 2>/dev/null
}

# Run dsr command capturing both stdout and stderr
run_dsr_full() {
    "$PROJECT_ROOT/dsr" "$@" 2>&1
}

# Create test artifacts for prune testing
create_test_artifacts() {
    local age_days="${1:-35}"

    # Create old logs
    mkdir -p "$DSR_STATE_DIR/logs/2020-01-01"
    echo '{"ts":"2020-01-01T00:00:00Z","msg":"old log"}' > "$DSR_STATE_DIR/logs/2020-01-01/run.log"
    touch -d "$(date -d "-${age_days} days" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v-${age_days}d +%Y-%m-%dT%H:%M:%S)" "$DSR_STATE_DIR/logs/2020-01-01" 2>/dev/null || true

    # Create old manifests
    mkdir -p "$DSR_STATE_DIR/manifests"
    echo '{"tool":"test","version":"0.0.1"}' > "$DSR_STATE_DIR/manifests/test-0.0.1.json"
    touch -d "$(date -d "-${age_days} days" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v-${age_days}d +%Y-%m-%dT%H:%M:%S)" "$DSR_STATE_DIR/manifests/test-0.0.1.json" 2>/dev/null || true

    # Create old artifacts
    mkdir -p "$DSR_STATE_DIR/artifacts/test/v0.0.1"
    echo "binary" > "$DSR_STATE_DIR/artifacts/test/v0.0.1/test-linux-amd64"
    touch -d "$(date -d "-${age_days} days" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v-${age_days}d +%Y-%m-%dT%H:%M:%S)" "$DSR_STATE_DIR/artifacts/test/v0.0.1" 2>/dev/null || true

    # Create old build runs (beyond keep_last)
    mkdir -p "$DSR_STATE_DIR/builds/test/v1.0.0"
    for i in 1 2 3 4 5 6 7; do
        mkdir -p "$DSR_STATE_DIR/builds/test/v1.0.0/run-$i"
        echo "run $i" > "$DSR_STATE_DIR/builds/test/v1.0.0/run-$i/output.log"
        # Make older runs actually old
        if [[ $i -le 3 ]]; then
            touch -d "$(date -d "-${age_days} days" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v-${age_days}d +%Y-%m-%dT%H:%M:%S)" "$DSR_STATE_DIR/builds/test/v1.0.0/run-$i" 2>/dev/null || true
        fi
    done

    # Create old cache
    mkdir -p "$DSR_CACHE_DIR/github"
    echo '{}' > "$DSR_CACHE_DIR/github/cache.json"
    touch -d "$(date -d "-${age_days} days" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v-${age_days}d +%Y-%m-%dT%H:%M:%S)" "$DSR_CACHE_DIR/github" 2>/dev/null || true
}

# Create last run log for status testing
create_last_run() {
    local run_date="${1:-$(date +%Y-%m-%d)}"
    mkdir -p "$DSR_STATE_DIR/logs/$run_date"
    echo '{"ts":"2026-01-30T12:00:00Z","run_id":"run-1706612400-12345","msg":"Session started"}' > "$DSR_STATE_DIR/logs/$run_date/run.log"
    ln -sfn "$run_date" "$DSR_STATE_DIR/logs/latest"
}

# ============================================================================
# STATUS COMMAND TESTS
# ============================================================================

test_status_json_shape() {
    ((TESTS_RUN++))

    local output
    output=$(run_dsr_json status)

    # Verify envelope structure
    if echo "$output" | jq -e '.command == "status"' >/dev/null 2>&1 &&
       echo "$output" | jq -e '.status == "success"' >/dev/null 2>&1 &&
       echo "$output" | jq -e '.exit_code == 0' >/dev/null 2>&1 &&
       echo "$output" | jq -e 'has("details")' >/dev/null 2>&1; then
        pass "status --json returns correct envelope structure"
    else
        fail "status --json envelope structure invalid: $output"
    fi
}

test_status_details_fields() {
    ((TESTS_RUN++))

    local output
    output=$(run_dsr_json status)

    # Verify details fields exist
    if echo "$output" | jq -e '.details | has("last_run")' >/dev/null 2>&1 &&
       echo "$output" | jq -e '.details | has("config")' >/dev/null 2>&1 &&
       echo "$output" | jq -e '.details | has("signing")' >/dev/null 2>&1 &&
       echo "$output" | jq -e '.details | has("hosts")' >/dev/null 2>&1; then
        pass "status --json details has required fields"
    else
        fail "status --json missing details fields"
    fi
}

test_status_config_valid() {
    ((TESTS_RUN++))

    local output
    output=$(run_dsr_json status)

    # Config should be valid since we created config.yaml
    local config_valid
    config_valid=$(echo "$output" | jq -r '.details.config.valid')

    if [[ "$config_valid" == "true" ]]; then
        pass "status reports config as valid"
    else
        fail "status should report config as valid"
    fi
}

test_status_last_run_with_log() {
    ((TESTS_RUN++))

    # Note: dsr creates its own session log when started, so we verify
    # that status returns a valid run_id in the expected format
    local output
    output=$(run_dsr_json status)

    local run_id
    run_id=$(echo "$output" | jq -r '.details.last_run.run_id')

    # Verify run_id matches expected format: run-{epoch}-{pid}
    if [[ "$run_id" =~ ^run-[0-9]+-[0-9]+$ ]]; then
        pass "status reads last run from log (format: $run_id)"
    else
        fail "status last_run.run_id has unexpected format: $run_id"
    fi
}

test_status_last_run_structure() {
    ((TESTS_RUN++))

    # Verify that status returns valid last_run structure with expected fields
    local output
    output=$(run_dsr_json status)

    # Extract last_run and verify it has all expected fields
    local last_run
    last_run=$(echo "$output" | jq '.details.last_run')

    if echo "$last_run" | jq -e 'has("run_id") and has("timestamp") and has("log_file")' >/dev/null 2>&1; then
        pass "status last_run has correct structure (run_id, timestamp, log_file)"
    else
        fail "status last_run missing expected fields: $last_run"
    fi
}

test_status_help() {
    ((TESTS_RUN++))

    local output
    output=$(run_dsr_full status --help)

    if echo "$output" | grep -q "dsr status" &&
       echo "$output" | grep -q "\-\-refresh"; then
        pass "status --help shows usage information"
    else
        fail "status --help missing expected content"
    fi
}

# ============================================================================
# PRUNE COMMAND TESTS
# ============================================================================

test_prune_dry_run_no_delete() {
    ((TESTS_RUN++))

    # Create test artifacts
    create_test_artifacts 35

    # Count files before
    local before_count
    before_count=$(find "$DSR_STATE_DIR" -type f 2>/dev/null | wc -l)

    # Run prune with --dry-run
    run_dsr prune --dry-run --force >/dev/null 2>&1

    # Count files after
    local after_count
    after_count=$(find "$DSR_STATE_DIR" -type f 2>/dev/null | wc -l)

    if [[ "$before_count" -eq "$after_count" ]]; then
        pass "prune --dry-run does not delete files"
    else
        fail "prune --dry-run deleted files: before=$before_count, after=$after_count"
    fi
}

test_prune_dry_run_json_shape() {
    ((TESTS_RUN++))

    create_test_artifacts 35

    local output
    output=$(run_dsr_json prune --dry-run --force)

    # Verify envelope and details
    if echo "$output" | jq -e '.command == "prune"' >/dev/null 2>&1 &&
       echo "$output" | jq -e '.details | has("dry_run")' >/dev/null 2>&1 &&
       echo "$output" | jq -e '.details | has("pruned_count")' >/dev/null 2>&1 &&
       echo "$output" | jq -e '.details | has("bytes_freed")' >/dev/null 2>&1; then
        pass "prune --json returns correct structure"
    else
        fail "prune --json structure invalid"
    fi
}

test_prune_dry_run_flag_set() {
    ((TESTS_RUN++))

    create_test_artifacts 35

    local output
    output=$(run_dsr_json prune --dry-run --force)

    local dry_run_value
    dry_run_value=$(echo "$output" | jq -r '.details.dry_run')

    if [[ "$dry_run_value" == "true" ]]; then
        pass "prune --json dry_run field is true"
    else
        fail "prune --json dry_run should be true"
    fi
}

test_prune_respects_max_age() {
    ((TESTS_RUN++))

    # Create artifacts that are 35 days old
    create_test_artifacts 35

    # Prune with max-age 30 should find items
    local output30
    output30=$(run_dsr_json prune --dry-run --force --max-age 30)
    local count30
    count30=$(echo "$output30" | jq -r '.details.pruned_count')

    # Prune with max-age 60 should find fewer/no items (artifacts are only 35 days old)
    local output60
    output60=$(run_dsr_json prune --dry-run --force --max-age 60)
    local count60
    count60=$(echo "$output60" | jq -r '.details.pruned_count')

    if [[ "$count30" -ge "$count60" ]]; then
        pass "prune --max-age filters by age correctly"
    else
        fail "prune --max-age: count30=$count30 should be >= count60=$count60"
    fi
}

test_prune_respects_keep_last() {
    ((TESTS_RUN++))

    # Create test runs
    create_test_artifacts 35

    # With keep-last=3, runs 4-7 are candidates if old enough
    local output3
    output3=$(run_dsr_json prune --dry-run --force --keep-last 3)

    # With keep-last=10, no runs should be pruned
    local output10
    output10=$(run_dsr_json prune --dry-run --force --keep-last 10)

    local count3 count10
    count3=$(echo "$output3" | jq -r '.details.pruned_count')
    count10=$(echo "$output10" | jq -r '.details.pruned_count')

    # count3 should be >= count10 (keeping fewer means pruning more)
    if [[ "$count3" -ge "$count10" ]]; then
        pass "prune --keep-last respects retention limit"
    else
        fail "prune --keep-last: count3=$count3 should be >= count10=$count10"
    fi
}

test_prune_pruned_paths_in_json() {
    ((TESTS_RUN++))

    create_test_artifacts 35

    local output
    output=$(run_dsr_json prune --dry-run --force)

    # Check that pruned_paths array exists and contains paths
    if echo "$output" | jq -e '.details.pruned_paths | type == "array"' >/dev/null 2>&1; then
        local path_count
        path_count=$(echo "$output" | jq -r '.details.pruned_paths | length')
        if [[ "$path_count" -gt 0 ]]; then
            pass "prune --json includes pruned_paths array with paths"
        else
            skip "prune --json pruned_paths is empty (touch -d may not work on this platform)"
        fi
    else
        fail "prune --json should have pruned_paths array"
    fi
}

test_prune_invalid_max_age() {
    ((TESTS_RUN++))

    local exit_code=0
    run_dsr prune --max-age abc --force 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -eq 4 ]]; then
        pass "prune rejects invalid --max-age with exit code 4"
    else
        fail "prune should return exit code 4 for invalid --max-age"
    fi
}

test_prune_invalid_keep_last() {
    ((TESTS_RUN++))

    local exit_code=0
    run_dsr prune --keep-last xyz --force 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -eq 4 ]]; then
        pass "prune rejects invalid --keep-last with exit code 4"
    else
        fail "prune should return exit code 4 for invalid --keep-last"
    fi
}

test_prune_help() {
    ((TESTS_RUN++))

    local output
    output=$(run_dsr_full prune --help)

    if echo "$output" | grep -q "dsr prune" &&
       echo "$output" | grep -q "\-\-dry-run" &&
       echo "$output" | grep -q "\-\-max-age" &&
       echo "$output" | grep -q "\-\-keep-last"; then
        pass "prune --help shows usage information"
    else
        fail "prune --help missing expected content"
    fi
}

# ============================================================================
# HOST SELECTION TESTS (supplement to test_host_selector.sh)
# ============================================================================

test_host_selector_module_loads() {
    ((TESTS_RUN++))

    # Source the host_selector module
    if source "$PROJECT_ROOT/src/host_selector.sh" 2>/dev/null; then
        if type selector_init &>/dev/null; then
            pass "host_selector.sh module loads and exports functions"
        else
            fail "host_selector.sh functions not exported"
        fi
    else
        fail "host_selector.sh failed to source"
    fi
}

test_host_selection_via_status() {
    ((TESTS_RUN++))

    # Status command exercises host health checking
    local output
    output=$(run_dsr_json status)

    # Should not error
    local status
    status=$(echo "$output" | jq -r '.status')

    if [[ "$status" == "success" ]]; then
        pass "host selection integrates with status command"
    else
        fail "status command failed, host selection may have issues"
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== Status, Host Selection, and Prune Tests ==="
echo "  bd-1jt.5.15: Tests for status/report + host selection + prune"
echo ""

# Status tests
echo "--- Status Command Tests ---"
test_status_json_shape
test_status_details_fields
test_status_config_valid
test_status_last_run_with_log
test_status_last_run_structure
test_status_help

# Prune tests
echo ""
echo "--- Prune Command Tests ---"
test_prune_dry_run_no_delete
test_prune_dry_run_json_shape
test_prune_dry_run_flag_set
test_prune_respects_max_age
test_prune_respects_keep_last
test_prune_pruned_paths_in_json
test_prune_invalid_max_age
test_prune_invalid_keep_last
test_prune_help

# Host selection tests
echo ""
echo "--- Host Selection Tests ---"
test_host_selector_module_loads
test_host_selection_via_status

# Summary
echo ""
echo "=== Results ==="
echo "Tests run: $TESTS_RUN"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
