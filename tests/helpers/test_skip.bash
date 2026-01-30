#!/usr/bin/env bash
# test_skip.bash - Skip protocol for tests with actionable messages
#
# Provides structured skip handling with reasons and next steps.
# Never suppresses errors silently - always explains why tests are skipped.
#
# Usage:
#   source test_skip.bash
#   require_command minisign "minisign" "Install minisign: brew install minisign"
#   require_env GITHUB_TOKEN "GitHub API token" "Run: gh auth login"
#   require_file /path/to/file "Config file" "Run: dsr config init"

set -uo pipefail

# Skip state tracking
_SKIP_REASONS=()
_SKIP_COUNT=0

# Skip colors (respect NO_COLOR)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _SKIP_YELLOW=$'\033[0;33m'
    _SKIP_CYAN=$'\033[0;36m'
    _SKIP_NC=$'\033[0m'
else
    _SKIP_YELLOW='' _SKIP_CYAN='' _SKIP_NC=''
fi

# Format a skip message with consistent structure
# Args: reason next_step
_skip_format() {
    local reason="$1"
    local next_step="${2:-}"

    echo "${_SKIP_YELLOW}SKIP${_SKIP_NC}: $reason"
    if [[ -n "$next_step" ]]; then
        echo "  ${_SKIP_CYAN}→ Next step:${_SKIP_NC} $next_step"
    fi
}

# Record a skip reason (for summary at end of test run)
_skip_record() {
    local reason="$1"
    local next_step="${2:-}"

    _SKIP_REASONS+=("$reason|$next_step")
    ((_SKIP_COUNT++))
}

# Check if a command exists, skip test if not
# Args: command description next_step
# Returns: 0 if command exists, 1 if skipped
require_command() {
    local cmd="$1"
    local desc="${2:-$cmd}"
    local next_step="${3:-Install $cmd}"

    if ! command -v "$cmd" &>/dev/null; then
        _skip_format "$desc not installed" "$next_step" >&2
        _skip_record "$desc not installed" "$next_step"
        return 1
    fi
    return 0
}

# Check if an environment variable is set, skip test if not
# Args: var_name description next_step
# Returns: 0 if set and non-empty, 1 if skipped
require_env() {
    local var_name="$1"
    local desc="${2:-$var_name}"
    local next_step="${3:-Set $var_name environment variable}"

    local var_value="${!var_name:-}"

    if [[ -z "$var_value" ]]; then
        _skip_format "$desc not set" "$next_step" >&2
        _skip_record "$desc not set" "$next_step"
        return 1
    fi
    return 0
}

# Check if a file exists, skip test if not
# Args: path description next_step
# Returns: 0 if file exists, 1 if skipped
require_file() {
    local path="$1"
    local desc="${2:-$path}"
    local next_step="${3:-Create the file: $path}"

    if [[ ! -f "$path" ]]; then
        _skip_format "$desc not found" "$next_step" >&2
        _skip_record "$desc not found" "$next_step"
        return 1
    fi
    return 0
}

# Check if a directory exists, skip test if not
# Args: path description next_step
# Returns: 0 if directory exists, 1 if skipped
require_dir() {
    local path="$1"
    local desc="${2:-$path}"
    local next_step="${3:-Create the directory: mkdir -p $path}"

    if [[ ! -d "$path" ]]; then
        _skip_format "$desc directory not found" "$next_step" >&2
        _skip_record "$desc directory not found" "$next_step"
        return 1
    fi
    return 0
}

# Check if network is available (can reach a host)
# Args: host description timeout_seconds
# Returns: 0 if reachable, 1 if skipped
require_network() {
    local host="${1:-github.com}"
    local desc="${2:-Network connection to $host}"
    local timeout="${3:-5}"

    if ! ping -c1 -W"$timeout" "$host" &>/dev/null 2>&1; then
        _skip_format "$desc unavailable" "Check network connection" >&2
        _skip_record "$desc unavailable" "Check network connection"
        return 1
    fi
    return 0
}

# Check if running as specific user or with specific permissions
# Args: permission_check description next_step
# Returns: 0 if check passes, 1 if skipped
require_permission() {
    local check="$1"
    local desc="${2:-Required permission}"
    local next_step="${3:-Check permissions}"

    if ! eval "$check" &>/dev/null; then
        _skip_format "$desc not available" "$next_step" >&2
        _skip_record "$desc not available" "$next_step"
        return 1
    fi
    return 0
}

# Check minimum version of a command
# Args: command min_version description next_step
# Returns: 0 if version OK, 1 if skipped
require_version() {
    local cmd="$1"
    local min_version="$2"
    local desc="${3:-$cmd >= $min_version}"
    local next_step="${4:-Upgrade $cmd to $min_version or newer}"

    # First check command exists
    if ! command -v "$cmd" &>/dev/null; then
        _skip_format "$cmd not installed" "Install $cmd" >&2
        _skip_record "$cmd not installed" "Install $cmd"
        return 1
    fi

    # Get version (various formats)
    local version
    version=$("$cmd" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

    if [[ -z "$version" ]]; then
        # Can't determine version, skip
        _skip_format "Cannot determine $cmd version" "$next_step" >&2
        _skip_record "Cannot determine $cmd version" "$next_step"
        return 1
    fi

    # Compare versions using sort -V
    local oldest
    oldest=$(printf '%s\n%s' "$min_version" "$version" | sort -V | head -1)

    if [[ "$oldest" != "$min_version" ]]; then
        _skip_format "$cmd version $version < $min_version" "$next_step" >&2
        _skip_record "$cmd version $version < $min_version" "$next_step"
        return 1
    fi

    return 0
}

# Explicit skip with custom reason
# Args: reason next_step
# Always returns 1 (skip)
skip_test() {
    local reason="$1"
    local next_step="${2:-}"

    _skip_format "$reason" "$next_step" >&2
    _skip_record "$reason" "$next_step"
    return 1
}

# Skip if condition is true
# Args: condition reason next_step
skip_if() {
    local condition="$1"
    local reason="$2"
    local next_step="${3:-}"

    if eval "$condition"; then
        _skip_format "$reason" "$next_step" >&2
        _skip_record "$reason" "$next_step"
        return 1
    fi
    return 0
}

# Skip unless condition is true
# Args: condition reason next_step
skip_unless() {
    local condition="$1"
    local reason="$2"
    local next_step="${3:-}"

    if ! eval "$condition"; then
        _skip_format "$reason" "$next_step" >&2
        _skip_record "$reason" "$next_step"
        return 1
    fi
    return 0
}

# Get count of skipped tests in this session
skip_count() {
    echo "$_SKIP_COUNT"
}

# Get all skip reasons (for summary)
skip_reasons() {
    printf '%s\n' "${_SKIP_REASONS[@]}"
}

# Print skip summary (call at end of test run)
skip_summary() {
    if [[ $_SKIP_COUNT -eq 0 ]]; then
        return 0
    fi

    echo "" >&2
    echo "=== SKIP SUMMARY (${_SKIP_COUNT} tests skipped) ===" >&2

    local seen_steps=()
    for entry in "${_SKIP_REASONS[@]}"; do
        local reason="${entry%|*}"
        local next_step="${entry#*|}"

        echo "  • $reason" >&2

        # Collect unique next steps
        if [[ -n "$next_step" ]]; then
            local found=false
            for seen in "${seen_steps[@]:-}"; do
                [[ "$seen" == "$next_step" ]] && found=true && break
            done
            if [[ "$found" == false ]]; then
                seen_steps+=("$next_step")
            fi
        fi
    done

    if [[ ${#seen_steps[@]} -gt 0 ]]; then
        echo "" >&2
        echo "To run all tests, complete these steps:" >&2
        for step in "${seen_steps[@]}"; do
            echo "  ${_SKIP_CYAN}→${_SKIP_NC} $step" >&2
        done
    fi

    echo "=== END SKIP SUMMARY ===" >&2
}

# Reset skip state (for new test run)
skip_reset() {
    _SKIP_REASONS=()
    _SKIP_COUNT=0
}

# Export functions
export -f require_command require_env require_file require_dir
export -f require_network require_permission require_version
export -f skip_test skip_if skip_unless
export -f skip_count skip_reasons skip_summary skip_reset
