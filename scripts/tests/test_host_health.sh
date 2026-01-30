#!/usr/bin/env bash
# test_host_health.sh - Tests for src/host_health.sh
#
# Run: ./scripts/tests/test_host_health.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }

# Setup test environment
TEMP_DIR=$(mktemp -d)
export DSR_STATE_DIR="$TEMP_DIR/state"
export DSR_CACHE_DIR="$TEMP_DIR/cache"
export DSR_CONFIG_DIR="$TEMP_DIR/config"
mkdir -p "$DSR_STATE_DIR" "$DSR_CACHE_DIR" "$DSR_CONFIG_DIR"

# Create mock hosts.yaml for testing
cat > "$DSR_CONFIG_DIR/hosts.yaml" << 'EOF'
schema_version: "1.0.0"

hosts:
  testlocal:
    platform: linux/amd64
    connection: local
    capabilities:
      - rust
      - go
      - docker
    concurrency: 2
    description: "Test local host"

  testremote:
    platform: darwin/arm64
    connection: ssh
    ssh_host: nonexistent.example.com
    ssh_timeout: 5
    capabilities:
      - rust
      - go
    concurrency: 1
    description: "Test remote host (will fail)"

platform_mapping:
  linux/amd64: testlocal
  darwin/arm64: testremote
EOF

# Create minimal config.yaml
cat > "$DSR_CONFIG_DIR/config.yaml" << 'EOF'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
EOF

export DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"
export DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"

# Stub logging functions
log_info() { :; }
log_warn() { :; }
log_error() { echo "ERROR: $*" >&2; }
log_debug() { :; }
export -f log_info log_warn log_error log_debug

# Source the modules
source "$PROJECT_ROOT/src/config.sh"
source "$PROJECT_ROOT/src/host_health.sh"

# ============================================================================
# Cache Tests
# ============================================================================

test_cache_init() {
    ((TESTS_RUN++))

    _hh_init_cache

    if [[ -d "$DSR_CACHE_DIR/health" ]]; then
        pass "Cache directory created"
    else
        fail "Cache directory not created at $DSR_CACHE_DIR/health"
    fi
}

test_cache_write_and_read() {
    ((TESTS_RUN++))

    _hh_init_cache
    local test_data='{"hostname": "test", "healthy": true}'
    _hh_cache_write "testhost" "$test_data"

    local read_data
    read_data=$(_hh_cache_read "testhost")

    if [[ "$read_data" == "$test_data" ]]; then
        pass "Cache write and read works"
    else
        fail "Cache mismatch: expected '$test_data', got '$read_data'"
    fi
}

test_cache_validity() {
    ((TESTS_RUN++))

    _hh_init_cache
    _hh_cache_write "freshhost" '{"test": true}'

    if _hh_cache_valid "freshhost"; then
        pass "Fresh cache is valid"
    else
        fail "Fresh cache should be valid"
    fi
}

test_cache_clear() {
    ((TESTS_RUN++))

    _hh_init_cache
    _hh_cache_write "clearme" '{"test": true}'

    host_health_clear_cache "clearme"

    if ! _hh_cache_valid "clearme"; then
        pass "Cache cleared successfully"
    else
        fail "Cache should be invalid after clear"
    fi
}

test_cache_clear_all() {
    ((TESTS_RUN++))

    _hh_init_cache
    _hh_cache_write "host1" '{"test": 1}'
    _hh_cache_write "host2" '{"test": 2}'

    host_health_clear_cache

    if ! _hh_cache_valid "host1" && ! _hh_cache_valid "host2"; then
        pass "All cache cleared"
    else
        fail "Not all cache cleared"
    fi
}

# ============================================================================
# Local Host Check Tests
# ============================================================================

test_local_connectivity() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_check_connectivity "testlocal" "local" "")

    if echo "$result" | jq -e '.reachable == true' &>/dev/null; then
        pass "Local connectivity check returns reachable"
    else
        fail "Local connectivity should always be reachable, got: $result"
    fi
}

test_local_disk_space() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_check_disk_space "testlocal" "local" "")

    if echo "$result" | jq -e '.usage_percent' &>/dev/null; then
        pass "Disk space check returns usage_percent"
    else
        fail "Disk space check failed, got: $result"
    fi
}

test_local_disk_space_has_status() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_check_disk_space "testlocal" "local" "")
    local status
    status=$(echo "$result" | jq -r '.status')

    if [[ "$status" == "ok" || "$status" == "warning" || "$status" == "error" ]]; then
        pass "Disk space has valid status: $status"
    else
        fail "Disk space invalid status: $status"
    fi
}

test_local_toolchains_check() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_check_toolchains "testlocal" "local" "" "rust go docker")

    # Should at least return valid JSON with the capability keys
    if echo "$result" | jq -e 'keys | length > 0' &>/dev/null; then
        pass "Toolchain check returns valid JSON"
    else
        fail "Toolchain check failed, got: $result"
    fi
}

test_local_clock_drift() {
    ((TESTS_RUN++))

    local result
    result=$(_hh_check_clock_drift "testlocal" "local" "")

    if echo "$result" | jq -e '.drift_seconds == 0' &>/dev/null; then
        pass "Local clock drift is 0"
    else
        fail "Local clock drift should be 0, got: $result"
    fi
}

# ============================================================================
# Full Host Health Check Tests
# ============================================================================

test_health_check_local_host() {
    ((TESTS_RUN++))

    # Clear any cached result first
    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_check "testlocal" --no-cache --json 2>/dev/null)

    if echo "$result" | jq -e '.hostname == "testlocal"' &>/dev/null; then
        pass "Health check returns correct hostname"
    else
        fail "Health check hostname mismatch, got: $result"
    fi
}

test_health_check_returns_healthy_for_local() {
    ((TESTS_RUN++))

    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_check "testlocal" --no-cache --json 2>/dev/null)

    if echo "$result" | jq -e '.healthy == true' &>/dev/null; then
        pass "Local host is healthy"
    else
        fail "Local host should be healthy, got: $(echo "$result" | jq '.healthy, .status')"
    fi
}

test_health_check_has_all_checks() {
    ((TESTS_RUN++))

    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_check "testlocal" --no-cache --json 2>/dev/null)

    local has_connectivity has_disk has_toolchains has_clock
    has_connectivity=$(echo "$result" | jq -e '.checks.connectivity' &>/dev/null && echo "yes" || echo "no")
    has_disk=$(echo "$result" | jq -e '.checks.disk_space' &>/dev/null && echo "yes" || echo "no")
    has_toolchains=$(echo "$result" | jq -e '.checks.toolchains' &>/dev/null && echo "yes" || echo "no")
    has_clock=$(echo "$result" | jq -e '.checks.clock_drift' &>/dev/null && echo "yes" || echo "no")

    if [[ "$has_connectivity" == "yes" && "$has_disk" == "yes" && "$has_toolchains" == "yes" && "$has_clock" == "yes" ]]; then
        pass "Health check has all check categories"
    else
        fail "Missing checks: connectivity=$has_connectivity disk=$has_disk toolchains=$has_toolchains clock=$has_clock"
    fi
}

test_health_check_unknown_host() {
    ((TESTS_RUN++))

    local result
    result=$(host_health_check "nonexistent_host_xyz" --json 2>/dev/null)

    if echo "$result" | jq -e '.healthy == false' &>/dev/null; then
        pass "Unknown host returns unhealthy"
    else
        fail "Unknown host should be unhealthy, got: $result"
    fi
}

test_health_check_unreachable_host() {
    ((TESTS_RUN++))

    # testremote is configured with a nonexistent SSH host
    host_health_clear_cache "testremote"

    local result
    # This should timeout/fail since the host doesn't exist
    result=$(host_health_check "testremote" --no-cache --json 2>/dev/null)

    if echo "$result" | jq -e '.healthy == false' &>/dev/null; then
        pass "Unreachable host returns unhealthy"
    else
        fail "Unreachable host should be unhealthy, got: $result"
    fi
}

# ============================================================================
# Check All Hosts Tests
# ============================================================================

test_health_check_all_returns_summary() {
    ((TESTS_RUN++))

    local result
    result=$(host_health_check_all --json 2>/dev/null)

    if echo "$result" | jq -e '.summary.total > 0' &>/dev/null; then
        pass "Check all returns summary with total"
    else
        fail "Check all should have summary, got: $result"
    fi
}

test_health_check_all_has_hosts_array() {
    ((TESTS_RUN++))

    local result
    result=$(host_health_check_all --json 2>/dev/null)

    if echo "$result" | jq -e '.hosts | type == "array"' &>/dev/null; then
        pass "Check all has hosts array"
    else
        fail "Check all should have hosts array, got: $result"
    fi
}

# ============================================================================
# Healthy Hosts Tests
# ============================================================================

test_get_healthy_hosts() {
    ((TESTS_RUN++))

    local result
    result=$(host_health_get_healthy_hosts --json 2>/dev/null)

    # Should be a valid JSON array
    if echo "$result" | jq -e 'type == "array"' &>/dev/null; then
        pass "get_healthy_hosts returns array"
    else
        fail "get_healthy_hosts should return array, got: $result"
    fi
}

test_get_healthy_hosts_includes_local() {
    ((TESTS_RUN++))

    host_health_clear_cache "testlocal"

    local result
    result=$(host_health_get_healthy_hosts --json 2>/dev/null)

    if echo "$result" | jq -e 'map(select(. == "testlocal")) | length > 0' &>/dev/null; then
        pass "Healthy hosts includes testlocal"
    else
        fail "Healthy hosts should include testlocal, got: $result"
    fi
}

# ============================================================================
# Host Readiness Tests
# ============================================================================

test_host_is_ready_local() {
    ((TESTS_RUN++))

    host_health_clear_cache "testlocal"

    if host_health_is_ready "testlocal"; then
        pass "testlocal is ready"
    else
        fail "testlocal should be ready"
    fi
}

test_host_is_ready_unreachable() {
    ((TESTS_RUN++))

    host_health_clear_cache "testremote"

    if ! host_health_is_ready "testremote"; then
        pass "Unreachable host is not ready"
    else
        fail "Unreachable host should not be ready"
    fi
}

test_host_is_ready_unknown() {
    ((TESTS_RUN++))

    if ! host_health_is_ready "completely_unknown_host"; then
        pass "Unknown host is not ready"
    else
        fail "Unknown host should not be ready"
    fi
}

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== Host Health Module Tests ==="
echo ""

# Cache tests
test_cache_init
test_cache_write_and_read
test_cache_validity
test_cache_clear
test_cache_clear_all

# Local check tests
test_local_connectivity
test_local_disk_space
test_local_disk_space_has_status
test_local_toolchains_check
test_local_clock_drift

# Full health check tests
test_health_check_local_host
test_health_check_returns_healthy_for_local
test_health_check_has_all_checks
test_health_check_unknown_host
test_health_check_unreachable_host

# Check all tests
test_health_check_all_returns_summary
test_health_check_all_has_hosts_array

# Healthy hosts tests
test_get_healthy_hosts
test_get_healthy_hosts_includes_local

# Readiness tests
test_host_is_ready_local
test_host_is_ready_unreachable
test_host_is_ready_unknown

# Cleanup
rm -rf "$TEMP_DIR"

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
