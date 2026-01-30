#!/usr/bin/env bash
# test_exec.bash - Command execution logging for tests
#
# Captures command, arguments, environment, stdout, stderr, and exit code.
# On failure, dumps all captured information for debugging.
#
# Usage:
#   source test_exec.bash
#   exec_run some_command arg1 arg2
#   exec_status      # Get exit code
#   exec_stdout      # Get stdout
#   exec_stderr      # Get stderr
#   exec_dump        # Dump all info on failure

set -uo pipefail

# Execution state
_EXEC_CMD=""
_EXEC_ARGS=()
_EXEC_STATUS=0
_EXEC_STDOUT=""
_EXEC_STDERR=""
_EXEC_STDOUT_FILE=""
_EXEC_STDERR_FILE=""
_EXEC_DURATION_MS=0
_EXEC_ENV_VARS=()
_EXEC_TMPDIR=""

# Colors (respect NO_COLOR)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _EXEC_RED=$'\033[0;31m'
    _EXEC_GREEN=$'\033[0;32m'
    _EXEC_CYAN=$'\033[0;36m'
    _EXEC_GRAY=$'\033[0;90m'
    _EXEC_NC=$'\033[0m'
else
    _EXEC_RED='' _EXEC_GREEN='' _EXEC_CYAN='' _EXEC_GRAY='' _EXEC_NC=''
fi

# Initialize exec logging (call once per test)
# shellcheck disable=SC2120  # Function may be called with arguments by test code
exec_init() {
    _EXEC_TMPDIR="${1:-$(mktemp -d)}"
    _EXEC_STDOUT_FILE="$_EXEC_TMPDIR/stdout"
    _EXEC_STDERR_FILE="$_EXEC_TMPDIR/stderr"
    exec_reset
}

# Reset state between runs
exec_reset() {
    _EXEC_CMD=""
    _EXEC_ARGS=()
    _EXEC_STATUS=0
    _EXEC_STDOUT=""
    _EXEC_STDERR=""
    _EXEC_DURATION_MS=0

    if [[ -n "$_EXEC_STDOUT_FILE" ]]; then
        : > "$_EXEC_STDOUT_FILE"
    fi
    if [[ -n "$_EXEC_STDERR_FILE" ]]; then
        : > "$_EXEC_STDERR_FILE"
    fi
}

# Cleanup (call in teardown)
exec_cleanup() {
    if [[ -n "$_EXEC_TMPDIR" && -d "$_EXEC_TMPDIR" && -z "${DEBUG:-}" ]]; then
        rm -rf "$_EXEC_TMPDIR"
    fi
    _EXEC_TMPDIR=""
}

# Run a command and capture everything
# Args: command [args...]
# Returns: command exit code
exec_run() {
    local cmd="$1"
    shift
    local args=("$@")

    _EXEC_CMD="$cmd"
    _EXEC_ARGS=("${args[@]}")
    _EXEC_STATUS=0
    _EXEC_STDOUT=""
    _EXEC_STDERR=""

    # Ensure temp files exist
    if [[ -z "$_EXEC_STDOUT_FILE" ]]; then
        exec_init
    fi

    # Capture relevant environment variables
    _EXEC_ENV_VARS=()
    local env_vars_to_capture=(
        "PATH" "HOME" "USER" "SHELL"
        "DSR_CONFIG_DIR" "DSR_STATE_DIR" "DSR_CACHE_DIR"
        "DSR_RUN_ID" "DSR_LOG_LEVEL" "DSR_CURRENT_CMD"
        "XDG_CONFIG_HOME" "XDG_STATE_HOME" "XDG_CACHE_HOME"
        "GITHUB_TOKEN" "GH_TOKEN"
        "NON_INTERACTIVE" "NO_COLOR" "DEBUG"
    )
    for var in "${env_vars_to_capture[@]}"; do
        local val="${!var:-}"
        if [[ -n "$val" ]]; then
            # Mask tokens/secrets
            if [[ "$var" == *TOKEN* ]]; then
                val="[REDACTED]"
            fi
            _EXEC_ENV_VARS+=("$var=$val")
        fi
    done

    # Record start time (milliseconds if available)
    local start_ms
    if command -v python3 &>/dev/null; then
        start_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
    else
        start_ms=$(($(date +%s) * 1000))
    fi

    # Run command with output capture
    "$cmd" "${args[@]}" > "$_EXEC_STDOUT_FILE" 2> "$_EXEC_STDERR_FILE" || _EXEC_STATUS=$?

    # Record end time
    local end_ms
    if command -v python3 &>/dev/null; then
        end_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
    else
        end_ms=$(($(date +%s) * 1000))
    fi
    _EXEC_DURATION_MS=$((end_ms - start_ms))

    # Load output into variables
    _EXEC_STDOUT=$(cat "$_EXEC_STDOUT_FILE" 2>/dev/null || true)
    _EXEC_STDERR=$(cat "$_EXEC_STDERR_FILE" 2>/dev/null || true)

    return $_EXEC_STATUS
}

# Run a command expecting success
# Args: command [args...]
# Returns: 0 if command succeeded, 1 if failed (and dumps debug info)
exec_expect_success() {
    exec_run "$@"
    if [[ $_EXEC_STATUS -ne 0 ]]; then
        exec_dump >&2
        return 1
    fi
    return 0
}

# Run a command expecting failure
# Args: command [args...]
# Returns: 0 if command failed (non-zero exit), 1 if succeeded
exec_expect_failure() {
    exec_run "$@"
    if [[ $_EXEC_STATUS -eq 0 ]]; then
        echo "Expected command to fail but it succeeded" >&2
        exec_dump >&2
        return 1
    fi
    return 0
}

# Get last command's exit status
exec_status() {
    echo "$_EXEC_STATUS"
}

# Get last command's stdout
exec_stdout() {
    echo "$_EXEC_STDOUT"
}

# Get last command's stderr
exec_stderr() {
    echo "$_EXEC_STDERR"
}

# Get last command's duration in milliseconds
exec_duration() {
    echo "$_EXEC_DURATION_MS"
}

# Check if stdout contains pattern
exec_stdout_contains() {
    local pattern="$1"
    [[ "$_EXEC_STDOUT" == *"$pattern"* ]]
}

# Check if stderr contains pattern
exec_stderr_contains() {
    local pattern="$1"
    [[ "$_EXEC_STDERR" == *"$pattern"* ]]
}

# Check if stdout is empty
exec_stdout_empty() {
    [[ -z "$_EXEC_STDOUT" ]]
}

# Check if stderr is empty
exec_stderr_empty() {
    [[ -z "$_EXEC_STDERR" ]]
}

# Dump full execution information (for debugging failures)
exec_dump() {
    echo ""
    echo "=== COMMAND EXECUTION DUMP ===" >&2
    echo "" >&2

    # Command line
    echo "${_EXEC_CYAN}Command:${_EXEC_NC} $_EXEC_CMD ${_EXEC_ARGS[*]:-}" >&2
    echo "" >&2

    # Exit status
    if [[ $_EXEC_STATUS -eq 0 ]]; then
        echo "${_EXEC_CYAN}Exit Status:${_EXEC_NC} ${_EXEC_GREEN}$_EXEC_STATUS${_EXEC_NC}" >&2
    else
        echo "${_EXEC_CYAN}Exit Status:${_EXEC_NC} ${_EXEC_RED}$_EXEC_STATUS${_EXEC_NC}" >&2
    fi
    echo "${_EXEC_CYAN}Duration:${_EXEC_NC} ${_EXEC_DURATION_MS}ms" >&2
    echo "" >&2

    # Environment
    echo "${_EXEC_CYAN}Environment:${_EXEC_NC}" >&2
    for env_var in "${_EXEC_ENV_VARS[@]:-}"; do
        echo "  ${_EXEC_GRAY}$env_var${_EXEC_NC}" >&2
    done
    echo "" >&2

    # Stdout
    echo "${_EXEC_CYAN}STDOUT (${#_EXEC_STDOUT} chars):${_EXEC_NC}" >&2
    if [[ -n "$_EXEC_STDOUT" ]]; then
        echo "${_EXEC_GRAY}---${_EXEC_NC}" >&2
        echo "$_EXEC_STDOUT" >&2
        echo "${_EXEC_GRAY}---${_EXEC_NC}" >&2
    else
        echo "  ${_EXEC_GRAY}(empty)${_EXEC_NC}" >&2
    fi
    echo "" >&2

    # Stderr
    echo "${_EXEC_CYAN}STDERR (${#_EXEC_STDERR} chars):${_EXEC_NC}" >&2
    if [[ -n "$_EXEC_STDERR" ]]; then
        echo "${_EXEC_GRAY}---${_EXEC_NC}" >&2
        echo "$_EXEC_STDERR" >&2
        echo "${_EXEC_GRAY}---${_EXEC_NC}" >&2
    else
        echo "  ${_EXEC_GRAY}(empty)${_EXEC_NC}" >&2
    fi

    echo "" >&2
    echo "=== END EXECUTION DUMP ===" >&2
}

# Stream separation check: verify stdout is data, stderr is messages
# Args: (none - uses last exec_run result)
# Returns: 0 if properly separated, 1 if mixed
exec_check_stream_separation() {
    local issues=()

    # Check for human messages in stdout (should be JSON or data)
    if [[ "$_EXEC_STDOUT" =~ (ERROR|WARN|INFO|DEBUG)\] ]] || \
       [[ "$_EXEC_STDOUT" =~ ^\[.*\] ]]; then
        issues+=("Human-readable log messages found in stdout (should be in stderr)")
    fi

    # Check for JSON in stderr (should be in stdout)
    if [[ "$_EXEC_STDERR" =~ ^\{.*\}$ ]]; then
        issues+=("JSON data found in stderr (should be in stdout)")
    fi

    if [[ ${#issues[@]} -gt 0 ]]; then
        echo "${_EXEC_RED}Stream separation violations:${_EXEC_NC}" >&2
        for issue in "${issues[@]}"; do
            echo "  • $issue" >&2
        done
        exec_dump >&2
        return 1
    fi

    return 0
}

# Assert stdout equals expected value
# Args: expected [message]
assert_exec_stdout() {
    local expected="$1"
    local message="${2:-stdout should match expected value}"

    if [[ "$_EXEC_STDOUT" != "$expected" ]]; then
        echo "FAIL: $message" >&2
        echo "  Expected: $expected" >&2
        echo "  Actual:   $_EXEC_STDOUT" >&2
        exec_dump >&2
        return 1
    fi
}

# Assert stderr contains pattern
# Args: pattern [message]
assert_exec_stderr_contains() {
    local pattern="$1"
    local message="${2:-stderr should contain: $pattern}"

    if ! exec_stderr_contains "$pattern"; then
        echo "FAIL: $message" >&2
        exec_dump >&2
        return 1
    fi
}

# Assert exit status equals expected
# Args: expected [message]
assert_exec_status() {
    local expected="$1"
    local message="${2:-exit status should be $expected}"

    if [[ "$_EXEC_STATUS" -ne "$expected" ]]; then
        echo "FAIL: $message" >&2
        echo "  Expected: $expected" >&2
        echo "  Actual:   $_EXEC_STATUS" >&2
        exec_dump >&2
        return 1
    fi
}

# Export functions
export -f exec_init exec_reset exec_cleanup exec_run
export -f exec_expect_success exec_expect_failure
export -f exec_status exec_stdout exec_stderr exec_duration
export -f exec_stdout_contains exec_stderr_contains
export -f exec_stdout_empty exec_stderr_empty
export -f exec_dump exec_check_stream_separation
export -f assert_exec_stdout assert_exec_stderr_contains assert_exec_status
