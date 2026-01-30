#!/usr/bin/env bash
# test_guardrails.sh - Tests for src/guardrails.sh
#
# Run: ./scripts/tests/test_guardrails.sh

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
mkdir -p "$DSR_STATE_DIR" "$DSR_CACHE_DIR"

# Stub logging functions
log_info() { :; }
log_warn() { :; }
log_error() { echo "ERROR: $*" >&2; }
log_debug() { :; }
export -f log_info log_warn log_error log_debug

# Source the guardrails module
source "$PROJECT_ROOT/src/guardrails.sh"

# ============================================================================
# Bash Version Tests
# ============================================================================

test_require_bash_4_passes() {
  ((TESTS_RUN++))

  # Current shell should be Bash 4+
  if require_bash_4 2>/dev/null; then
    pass "require_bash_4 passes on current shell"
  else
    fail "require_bash_4 should pass (current: $BASH_VERSION)"
  fi
}

# ============================================================================
# Path Resolution Tests
# ============================================================================

test_resolve_path_absolute() {
  ((TESTS_RUN++))

  local result
  result=$(resolve_path "/usr/bin")

  if [[ "$result" == "/usr/bin" ]]; then
    pass "resolve_path handles absolute paths"
  else
    fail "resolve_path absolute: expected /usr/bin, got $result"
  fi
}

test_resolve_path_tilde() {
  ((TESTS_RUN++))

  local result
  result=$(resolve_path "~")

  if [[ "$result" == "$HOME" ]]; then
    pass "resolve_path expands ~"
  else
    fail "resolve_path tilde: expected $HOME, got $result"
  fi
}

test_resolve_path_tilde_subdir() {
  ((TESTS_RUN++))

  local result
  result=$(resolve_path "~/test/path")

  if [[ "$result" == "$HOME/test/path" ]]; then
    pass "resolve_path expands ~/subdir"
  else
    fail "resolve_path tilde subdir: expected $HOME/test/path, got $result"
  fi
}

test_resolve_path_rejects_relative() {
  ((TESTS_RUN++))

  if resolve_path "relative/path" 2>/dev/null; then
    fail "resolve_path should reject relative paths"
  else
    pass "resolve_path rejects relative paths"
  fi
}

test_resolve_path_rejects_empty() {
  ((TESTS_RUN++))

  if resolve_path "" 2>/dev/null; then
    fail "resolve_path should reject empty paths"
  else
    pass "resolve_path rejects empty paths"
  fi
}

test_resolve_path_or_default() {
  ((TESTS_RUN++))

  local result
  result=$(resolve_path_or_default "" "/default/path")

  if [[ "$result" == "/default/path" ]]; then
    pass "resolve_path_or_default uses default"
  else
    fail "resolve_path_or_default: expected /default/path, got $result"
  fi
}

# ============================================================================
# Safe Deletion Tests
# ============================================================================

test_safe_rm_under_state_dir() {
  ((TESTS_RUN++))

  local test_file="$DSR_STATE_DIR/test_file.txt"
  echo "test" > "$test_file"

  if safe_rm "$test_file" && [[ ! -f "$test_file" ]]; then
    pass "safe_rm deletes file under DSR_STATE_DIR"
  else
    fail "safe_rm should delete file under DSR_STATE_DIR"
  fi
}

test_safe_rm_under_cache_dir() {
  ((TESTS_RUN++))

  local test_file="$DSR_CACHE_DIR/test_file.txt"
  echo "test" > "$test_file"

  if safe_rm "$test_file" && [[ ! -f "$test_file" ]]; then
    pass "safe_rm deletes file under DSR_CACHE_DIR"
  else
    fail "safe_rm should delete file under DSR_CACHE_DIR"
  fi
}

test_safe_rm_under_tmp() {
  ((TESTS_RUN++))

  # Create a file explicitly under /tmp (not TMPDIR which may be elsewhere)
  local test_file="/tmp/dsr_test_$$_$(date +%s).txt"
  echo "test" > "$test_file"

  if safe_rm "$test_file" && [[ ! -f "$test_file" ]]; then
    pass "safe_rm deletes file under /tmp"
  else
    fail "safe_rm should delete file under /tmp"
    rm -f "$test_file"
  fi
}

test_safe_rm_refuses_outside() {
  ((TESTS_RUN++))

  # Try to delete something outside allowed roots
  if safe_rm "/usr/bin/ls" 2>/dev/null; then
    fail "safe_rm should refuse paths outside allowed roots"
  else
    pass "safe_rm refuses paths outside allowed roots"
  fi
}

test_safe_rm_refuses_root_dir() {
  ((TESTS_RUN++))

  # Try to delete a root directory itself
  if safe_rm "$DSR_STATE_DIR" 2>/dev/null; then
    fail "safe_rm should refuse to delete root directories"
  else
    pass "safe_rm refuses to delete root directories"
  fi
}

test_safe_rm_directory() {
  ((TESTS_RUN++))

  local test_dir="$DSR_STATE_DIR/test_dir"
  mkdir -p "$test_dir"
  echo "test" > "$test_dir/file.txt"

  if safe_rm "$test_dir" && [[ ! -d "$test_dir" ]]; then
    pass "safe_rm deletes directories"
  else
    fail "safe_rm should delete directories"
    rm -rf "$test_dir"
  fi
}

test_safe_rm_nonexistent() {
  ((TESTS_RUN++))

  if safe_rm "$DSR_STATE_DIR/nonexistent_file_xyz" 2>/dev/null; then
    pass "safe_rm succeeds on nonexistent paths"
  else
    fail "safe_rm should succeed on nonexistent paths"
  fi
}

# ============================================================================
# Safe Tmpdir Tests
# ============================================================================

test_safe_tmpdir_creates_under_tmp() {
  ((TESTS_RUN++))

  local tmpdir
  tmpdir=$(safe_tmpdir "test")

  if [[ -d "$tmpdir" && "$tmpdir" == /tmp/test.* ]]; then
    pass "safe_tmpdir creates directory under /tmp"
    rm -rf "$tmpdir"
  else
    fail "safe_tmpdir should create directory under /tmp, got $tmpdir"
  fi
}

test_safe_tmpdir_default_prefix() {
  ((TESTS_RUN++))

  local tmpdir
  tmpdir=$(safe_tmpdir)

  if [[ -d "$tmpdir" && "$tmpdir" == /tmp/dsr.* ]]; then
    pass "safe_tmpdir uses default prefix"
    rm -rf "$tmpdir"
  else
    fail "safe_tmpdir should use dsr prefix by default, got $tmpdir"
  fi
}

# ============================================================================
# NO_COLOR Tests
# ============================================================================

test_is_color_disabled_with_no_color() {
  ((TESTS_RUN++))

  NO_COLOR=1 is_color_disabled
  local result=$?

  if [[ $result -eq 0 ]]; then
    pass "is_color_disabled returns true when NO_COLOR set"
  else
    fail "is_color_disabled should return true when NO_COLOR set"
  fi
}

test_is_color_disabled_with_flag() {
  ((TESTS_RUN++))

  DSR_NO_COLOR=true is_color_disabled
  local result=$?

  if [[ $result -eq 0 ]]; then
    pass "is_color_disabled returns true when DSR_NO_COLOR=true"
  else
    fail "is_color_disabled should return true when DSR_NO_COLOR=true"
  fi
}

test_color_returns_empty_when_disabled() {
  ((TESTS_RUN++))

  local result
  result=$(NO_COLOR=1 color red)

  if [[ -z "$result" ]]; then
    pass "color returns empty when NO_COLOR set"
  else
    fail "color should return empty when NO_COLOR set"
  fi
}

# ============================================================================
# Non-Interactive Tests
# ============================================================================

test_is_non_interactive_with_ci() {
  ((TESTS_RUN++))

  CI=true is_non_interactive
  local result=$?

  if [[ $result -eq 0 ]]; then
    pass "is_non_interactive returns true when CI set"
  else
    fail "is_non_interactive should return true when CI set"
  fi
}

test_is_non_interactive_with_flag() {
  ((TESTS_RUN++))

  DSR_NON_INTERACTIVE=true is_non_interactive
  local result=$?

  if [[ $result -eq 0 ]]; then
    pass "is_non_interactive returns true with DSR_NON_INTERACTIVE"
  else
    fail "is_non_interactive should return true with DSR_NON_INTERACTIVE"
  fi
}

test_confirm_uses_default_in_ci() {
  ((TESTS_RUN++))

  local result
  CI=true confirm "Test?" y
  result=$?

  if [[ $result -eq 0 ]]; then
    pass "confirm uses default yes in CI"
  else
    fail "confirm should use default yes in CI"
  fi
}

# Cleanup
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "Running guardrails module tests..."
echo ""

# Bash version tests
test_require_bash_4_passes

# Path resolution tests
test_resolve_path_absolute
test_resolve_path_tilde
test_resolve_path_tilde_subdir
test_resolve_path_rejects_relative
test_resolve_path_rejects_empty
test_resolve_path_or_default

# Safe deletion tests
test_safe_rm_under_state_dir
test_safe_rm_under_cache_dir
test_safe_rm_under_tmp
test_safe_rm_refuses_outside
test_safe_rm_refuses_root_dir
test_safe_rm_directory
test_safe_rm_nonexistent

# Safe tmpdir tests
test_safe_tmpdir_creates_under_tmp
test_safe_tmpdir_default_prefix

# NO_COLOR tests
test_is_color_disabled_with_no_color
test_is_color_disabled_with_flag
test_color_returns_empty_when_disabled

# Non-interactive tests
test_is_non_interactive_with_ci
test_is_non_interactive_with_flag
test_confirm_uses_default_in_ci

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
