#!/usr/bin/env bash
# test_act_runner_native.sh - Unit tests for act_runner.sh native build logic
#
# Usage: ./test_act_runner_native.sh
#
# Tests act integration functions with mocks for SSH/SCP

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src"

# Source the module under test
source "$SRC_DIR/act_runner.sh"

# Mock output directory
MOCK_DIR=$(mktemp -d)
export ACT_LOGS_DIR="$MOCK_DIR/logs"
export ACT_ARTIFACTS_DIR="$MOCK_DIR/artifacts"
export ACT_REPOS_DIR="$MOCK_DIR/repos.d"
mkdir -p "$ACT_LOGS_DIR" "$ACT_ARTIFACTS_DIR" "$ACT_REPOS_DIR"

# Test state
SCP_CALLED=false
SSH_CALLED=false
LAST_SCP_ARGS=""
LAST_SSH_ARGS=""

# Mocks
log_error() { echo "ERROR: $*" >&2; }
log_info() { echo "INFO: $*" >&2; }
log_ok() { echo "OK: $*" >&2; }
_log_info() { echo "[act] INFO: $*" >&2; }
_log_error() { echo "[act] ERROR: $*" >&2; }
_log_ok() { echo "[act] OK: $*" >&2; }

# Mock yq for config parsing
yq() {
    local query="$1"
    local file="$2"
    
    # Mock repos config
    if [[ "$file" == *"tool.yaml" ]]
    then
        case "$query" in
            '.tool_name // empty') echo "tool" ;; 
            '.repo // empty') echo "owner/tool" ;; 
            '.local_path // empty') echo "/local/path/tool" ;; 
            '.language // empty') echo "go" ;; 
            '.binary_name // ""') echo "tool" ;; 
            '.host_paths.mmini // empty') echo "/remote/path/tool" ;; # Host path for mmini
            '.host_paths.wlap // empty') echo "" ;; # No host path for wlap (fallback)
            '.build_cmd // ""') echo "go build" ;; 
            '.env // {} | to_entries | map(.key + "=" + .value) | .[]') echo "GOOS=darwin" ;; 
            ".cross_compile.\"darwin/arm64\".env // {}"*) echo "GOARCH=arm64" ;; 
            *) echo "" ;; 
        esac
    fi
}

# Mock act_get_native_host
act_get_native_host() {
    local platform="$1"
    case "$platform" in
        "darwin/arm64") echo "mmini" ;; 
        "windows/amd64") echo "wlap" ;; 
        *) echo "" ;; 
    esac
}

# Mock act_get_local_path
act_get_local_path() { echo "/local/path/tool"; }
# Mock act_get_build_cmd
act_get_build_cmd() { echo "go build"; }
# Mock act_get_build_env
act_get_build_env() { echo "GOOS=darwin GOARCH=arm64"; }

# Mock _act_ssh_exec
_act_ssh_exec() {
    local host="$1"
    local cmd="$2"
    SSH_CALLED=true
    LAST_SSH_ARGS="$host $cmd"
    # Simulate success
    return 0
}

# Mock scp
scp() {
    SCP_CALLED=true
    LAST_SCP_ARGS="$*"
    # Simulate success by touching the target file if it's an upload/download
    # Last arg is target
    local target="${@: -1}"
    touch "$target"
    return 0
}

# Setup
setup() {
    # Create mock config file
    touch "$ACT_REPOS_DIR/tool.yaml"
    SCP_CALLED=false
    SSH_CALLED=false
    LAST_SCP_ARGS=""
    LAST_SSH_ARGS=""
}

# Tests
test_native_build_with_host_path() {
    echo "Test: Native build with host path (mmini)"
    setup
    
    local result
    result=$(act_run_native_build "tool" "darwin/arm64" "v1.0.0" "run1")
    
    # Verify SSH called with correct path
    if [[ "$LAST_SSH_ARGS" == *"cd '/remote/path/tool'"* ]]
    then
        echo "PASS: SSH used correct remote path"
    else
        echo "FAIL: SSH used incorrect path: $LAST_SSH_ARGS"
        exit 1
    fi
    
    # Verify SCP called
    if $SCP_CALLED
    then
        echo "PASS: SCP called"
    else
        echo "FAIL: SCP not called"
        exit 1
    fi
    
    # Verify SCP args (remote path should be /remote/path/tool/tool)
    if [[ "$LAST_SCP_ARGS" == *"mmini:'/remote/path/tool/tool'"* ]]
    then
        echo "PASS: SCP downloaded from correct remote path"
    else
        echo "FAIL: SCP used incorrect remote path: $LAST_SCP_ARGS"
        exit 1
    fi
    
    # Verify result JSON contains local artifact path
    if echo "$result" | grep -q "\"artifact_path\": \".*$MOCK_DIR/artifacts/run1/tool\"";
    then
        echo "PASS: Result JSON contains local artifact path"
    else
        echo "FAIL: Result JSON missing local path: $result"
        exit 1
    fi
}

test_native_build_fallback_path() {
    echo "Test: Native build fallback path (wlap)"
    setup
    
    # Override mock for wlap to return no host path
    # (Already handled in yq mock)
    
    local result
    result=$(act_run_native_build "tool" "windows/amd64" "v1.0.0" "run2")
    
    # Verify SSH called with fallback local path
    if [[ "$LAST_SSH_ARGS" == *"cd '/local/path/tool'"* ]]
    then
        echo "PASS: SSH used fallback local path"
    else
        echo "FAIL: SSH used incorrect path: $LAST_SSH_ARGS"
        exit 1
    fi
    
    # Verify SCP for windows artifact (should have .exe)
    if [[ "$LAST_SCP_ARGS" == *"wlap:'/local/path/tool/tool.exe'"* ]]
    then
        echo "PASS: SCP downloaded correct windows artifact"
    else
        echo "FAIL: SCP used incorrect windows path: $LAST_SCP_ARGS"
        exit 1
    fi
}

# Run tests
test_native_build_with_host_path
test_native_build_fallback_path

echo "All tests passed!"
rm -rf "$MOCK_DIR"
