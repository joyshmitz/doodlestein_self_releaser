#!/usr/bin/env bash
# e2e_release_parity.sh - E2E test for dsr release parity with GH Actions
#
# Run:
#   ./scripts/tests/e2e_release_parity.sh --repo owner/repo --local-path /path/to/repo
#
# Required environment (for real parity runs):
#   DSR_E2E_REPO          owner/repo (GitHub repo)
#   DSR_E2E_LOCAL_PATH    local clone path for the same repo
#
# Optional:
#   DSR_E2E_GHA_TAG       tag with GH Actions release (default: generated)
#   DSR_E2E_DSR_TAG       tag for dsr release (default: generated)
#   DSR_E2E_TARGETS       space-separated targets (default: linux/amd64 darwin/arm64 windows/amd64)
#   DSR_E2E_SCENARIOS     comma-separated scenarios (default: base)
#   DSR_E2E_REQUIRE_GHA   set to 0 to allow scenarios without GHA releases
#   DSR_E2E_CONTINUE_ON_FAIL set to 1 to run all scenarios even if one fails
#   DSR_E2E_TOOL_CONFIG_EXTRA extra YAML appended to repos.d tool config
#   DSR_E2E_TRIGGER_GHA   set to 1 to push a tag and wait for GH Actions release
#   DSR_E2E_ALLOW_TAG_PUSH set to 1 to allow tag push
#   DSR_E2E_DRAFT         set to 1 to create dsr release as draft (default: 1)
#   DSR_E2E_KEEP_LOG      set to 1 to keep log file on success
#   DSR_E2E_KEEP_RELEASES set to 1 to keep created releases/tags
#   DSR_E2E_USE_FIXTURE   set to 1 to copy fixture into temp dir for local path

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="$PROJECT_ROOT/dsr"

VERBOSE=0
DEBUG=0
JSON_MODE=false
SCENARIO_NAME=""
SCENARIOS_RAW="${DSR_E2E_SCENARIOS:-base}"
SCENARIO_RESULTS=()
SCENARIO_PHASES=()
SCENARIO_STATUS="pass"
SCENARIO_SKIP_REASON=""
SCENARIO_START_MS=""
SCENARIO_END_MS=""
SCENARIO_REQUIRE_GHA_DEFAULT="${DSR_E2E_REQUIRE_GHA:-1}"
WORK_ROOT=""
CONTINUE_ON_FAIL="${DSR_E2E_CONTINUE_ON_FAIL:-0}"
SCENARIOS=()
SCENARIO_SET=0

SCENARIO_REQUIRE_GHA=1
SCENARIO_CHECK_PREBUILT=0
SCENARIO_INSTALL_CONTAINERS=0
SCENARIO_ACT_ENV_LINES=""
SCENARIO_INSTALL_ENV_LINES=""
SCENARIO_MODE="parity"

ARTIFACT_NAMING_DEFAULT="\${name}-\${version}-\${os}-\${arch}"
INSTALL_COMPAT_DEFAULT="\${name}-\${os}-\${arch}"
TOOL_CONFIG_EXTRA="${DSR_E2E_TOOL_CONFIG_EXTRA:-}"

REPO="${DSR_E2E_REPO:-}"
LOCAL_PATH="${DSR_E2E_LOCAL_PATH:-}"
TOOL_NAME="${DSR_E2E_TOOL_NAME:-mock_release_tool}"
LANGUAGE="${DSR_E2E_LANGUAGE:-go}"
BUILD_CMD="${DSR_E2E_BUILD_CMD:-go build -o ${TOOL_NAME} ./cmd/${TOOL_NAME}}"
BINARY_NAME="${DSR_E2E_BINARY_NAME:-$TOOL_NAME}"
WORKFLOW_PATH="${DSR_E2E_WORKFLOW:-.github/workflows/release.yml}"
JOB_LINUX="${DSR_E2E_JOB_LINUX:-build-linux}"
JOB_DARWIN="${DSR_E2E_JOB_DARWIN:-build-darwin}"
JOB_WINDOWS="${DSR_E2E_JOB_WINDOWS:-build-windows}"
INSTALL_SCRIPT_PATH="${DSR_E2E_INSTALL_SCRIPT_PATH:-install.sh}"
TARGETS="${DSR_E2E_TARGETS:-linux/amd64 darwin/arm64 windows/amd64}"
GHA_TAG="${DSR_E2E_GHA_TAG:-}"
DSR_TAG="${DSR_E2E_DSR_TAG:-}"
TRIGGER_GHA="${DSR_E2E_TRIGGER_GHA:-0}"
ALLOW_TAG_PUSH="${DSR_E2E_ALLOW_TAG_PUSH:-0}"
DRAFT_RELEASE="${DSR_E2E_DRAFT:-1}"
KEEP_LOG="${DSR_E2E_KEEP_LOG:-0}"
KEEP_RELEASES="${DSR_E2E_KEEP_RELEASES:-0}"
USE_FIXTURE="${DSR_E2E_USE_FIXTURE:-0}"
WAIT_TIMEOUT="${DSR_E2E_WAIT_TIMEOUT:-900}"

LOG_FILE="${DSR_E2E_LOG_FILE:-/tmp/e2e_release_parity_$$.log}"
DSR_OUTPUT_LOG="${DSR_E2E_DSR_LOG_FILE:-/tmp/e2e_release_parity_dsr_$$.log}"

TEST_START_MS=""
PHASE_START_MS=""
CURRENT_PHASE=""
CREATED_GHA_TAG=false
CREATED_DSR_RELEASE=false
checksum_details=()
compat_details=()

usage() {
  cat << 'USAGE'
Usage:
  e2e_release_parity.sh --repo owner/repo --local-path /path/to/repo [options]

Options:
  --repo <owner/repo>         GitHub repo
  --local-path <path>         Local clone path for repo
  --gha-tag <tag>             Tag for GH Actions release
  --dsr-tag <tag>             Tag for dsr release
  --targets <list>            Space-separated targets (default: linux/amd64 darwin/arm64 windows/amd64)
  --scenarios <list>          Comma-separated scenarios (default: base)
  --scenario <name>           Add a scenario (repeatable)
  --trigger-gha               Push tag and wait for GH Actions release
  --use-fixture               Copy fixture into temp dir (still requires --repo)
  --json                      Emit JSON output
  -v                          Verbose output
  -vv                         Debug output
  --keep-log                  Keep log file on success
  --keep-releases             Keep created releases/tags
  --continue-on-fail          Run all scenarios even if one fails
  -h, --help                  Show help
USAGE
}

_now_ms() {
  local ms
  ms=$(date +%s%3N 2>/dev/null || true)
  if [[ "$ms" =~ ^[0-9]+$ ]]; then
    echo "$ms"
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

log_line() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local prefix="E2E"
  [[ -n "$SCENARIO_NAME" ]] && prefix="E2E:${SCENARIO_NAME}"

  if $JSON_MODE; then
    local esc_msg esc_level
    esc_msg=$(_json_escape "$msg")
    esc_level=$(_json_escape "$level")
    local esc_scenario
    esc_scenario=$(_json_escape "$SCENARIO_NAME")
    local line
    line=$(printf '{"ts":"%s","level":"%s","scenario":"%s","msg":"%s"}' "$ts" "$esc_level" "$esc_scenario" "$esc_msg")
    echo "$line"
    echo "$line" >> "$LOG_FILE"
  else
    printf '[%s] %s: %s\n' "$ts" "$prefix" "$msg" | tee -a "$LOG_FILE" >&2
  fi
}

phase_start() {
  CURRENT_PHASE="$1"
  PHASE_START_MS="$(_now_ms)"
  log_line "INFO" "Starting phase: $CURRENT_PHASE"
}

phase_end() {
  local status="$1"
  local extra_json="${2:-{}}"
  local end_ms duration_ms
  end_ms="$(_now_ms)"
  duration_ms=$((end_ms - PHASE_START_MS))

  log_line "INFO" "Phase $CURRENT_PHASE: $status (${duration_ms}ms)"

  local phase_json
  phase_json=$(jq -nc \
    --arg name "$CURRENT_PHASE" \
    --arg status "$status" \
    --argjson duration "$duration_ms" \
    --arg scenario "$SCENARIO_NAME" \
    --argjson extra "$extra_json" \
    '$extra + {name: $name, status: $status, duration_ms: $duration, scenario: $scenario}')
  SCENARIO_PHASES+=("$phase_json")
}

log_block() {
  local header="$1"
  local body="$2"
  if $JSON_MODE; then
    local esc_header esc_body
    esc_header=$(_json_escape "$header")
    esc_body=$(_json_escape "$body")
    local line
    line=$(printf '{\"ts\":\"%s\",\"level\":\"ERROR\",\"scenario\":\"%s\",\"section\":\"%s\",\"body\":\"%s\"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCENARIO_NAME" "$esc_header" "$esc_body")
    echo "$line"
    echo "$line" >> "$LOG_FILE"
  else
    {
      echo ""
      echo "=== $header ==="
      echo "$body"
    } | tee -a "$LOG_FILE" >&2
  fi
}

dump_failure_context() {
  if [[ -f "$DSR_OUTPUT_LOG" ]]; then
    log_block "dsr output (last 50 lines)" "$(tail -50 "$DSR_OUTPUT_LOG" 2>/dev/null || true)"
  fi

  if [[ -n "$REPO" && -n "$DSR_TAG" ]]; then
    log_block "gh release view (DSR)" "$(gh release view "$DSR_TAG" --repo "$REPO" 2>/dev/null || echo 'release not found')"
    log_block "DSR release assets" "$(gh api "repos/$REPO/releases/tags/$DSR_TAG" --jq '.assets[] | \"\\(.name)  (\\(.size) bytes)\"' 2>/dev/null || echo 'release not found')"
  fi

  if [[ -n "$REPO" && -n "$GHA_TAG" ]]; then
    log_block "gh release view (GHA)" "$(gh release view "$GHA_TAG" --repo "$REPO" 2>/dev/null || echo 'release not found')"
    log_block "GHA release assets" "$(gh api "repos/$REPO/releases/tags/$GHA_TAG" --jq '.assets[] | \"\\(.name)  (\\(.size) bytes)\"' 2>/dev/null || echo 'release not found')"
  fi

  if [[ ${#checksum_details[@]} -gt 0 ]]; then
    log_block "Checksum mismatches" "$(printf '%s\n' "${checksum_details[@]}")"
  fi
  if [[ ${#compat_details[@]} -gt 0 ]]; then
    log_block "Compat checksum mismatches" "$(printf '%s\n' "${compat_details[@]}")"
  fi
}

fail_phase() {
  local extra_json="${1:-{}}"
  phase_end "fail" "$extra_json"
  dump_failure_context
  return 1
}

skip_test() {
  log_line "WARN" "SKIP: $1"
  exit 0
}

require_cmd() {
  local cmd="$1"
  local desc="$2"
  if ! command -v "$cmd" &>/dev/null; then
    skip_test "$desc not installed (missing $cmd)"
  fi
}

parse_scenarios() {
  local raw="$1"
  raw="${raw//,/ }"
  local -A seen=()
  local -a result=()
  local name
  for name in $raw; do
    [[ -z "$name" ]] && continue
    if [[ -z "${seen[$name]:-}" ]]; then
      result+=("$name")
      seen["$name"]=1
    fi
  done
  printf '%s\n' "${result[@]}"
}

scenario_begin() {
  SCENARIO_NAME="$1"
  SCENARIO_PHASES=()
  SCENARIO_STATUS="pass"
  SCENARIO_SKIP_REASON=""
  SCENARIO_START_MS="$(_now_ms)"
  CREATED_GHA_TAG=false
  CREATED_DSR_RELEASE=false
  checksum_details=()
  compat_details=()
}

scenario_end() {
  SCENARIO_END_MS="$(_now_ms)"
  local duration_ms=$((SCENARIO_END_MS - SCENARIO_START_MS))
  local phases_json="[]"
  if [[ ${#SCENARIO_PHASES[@]} -gt 0 ]]; then
    phases_json=$(printf '%s\n' "${SCENARIO_PHASES[@]}" | jq -s '.')
  fi

  local scenario_json
  scenario_json=$(jq -nc \
    --arg name "$SCENARIO_NAME" \
    --arg status "$SCENARIO_STATUS" \
    --arg skip_reason "$SCENARIO_SKIP_REASON" \
    --argjson duration_ms "$duration_ms" \
    --argjson phases "$phases_json" \
    '{name: $name, status: $status, skip_reason: $skip_reason, duration_ms: $duration_ms, phases: $phases}')
  SCENARIO_RESULTS+=("$scenario_json")
}

scenario_skip() {
  local reason="$1"
  SCENARIO_STATUS="skip"
  SCENARIO_SKIP_REASON="$reason"
  log_line "WARN" "SKIP: $reason"
  return 0
}

scenario_reset_config() {
  ARTIFACT_NAMING="$ARTIFACT_NAMING_DEFAULT"
  INSTALL_SCRIPT_COMPAT="$INSTALL_COMPAT_DEFAULT"
  TOOL_CONFIG_EXTRA="${DSR_E2E_TOOL_CONFIG_EXTRA:-}"
}

run_logged() {
  local log_file="$1"
  shift

  if $JSON_MODE; then
    "$@" >>"$log_file" 2>&1
    return $?
  fi

  if [[ "$DEBUG" -eq 1 ]]; then
    "$@" 2>&1 | tee -a "$log_file"
    return "${PIPESTATUS[0]}"
  fi

  "$@" >>"$log_file" 2>&1
  return $?
}

sha256_file() {
  local file="$1"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

ensure_dsr_modules() {
  if ! declare -F artifact_naming_generate_dual_for_tool &>/dev/null; then
    # shellcheck source=../../src/config.sh
    source "$PROJECT_ROOT/src/config.sh" 2>/dev/null || true
    # shellcheck source=../../src/artifact_naming.sh
    source "$PROJECT_ROOT/src/artifact_naming.sh" 2>/dev/null || true
  fi
}

_ext_from_pattern() {
  local pattern="$1"
  case "$pattern" in
    *.tar.gz) echo "tar.gz" ;;
    *.tar.xz) echo "tar.xz" ;;
    *.tgz) echo "tgz" ;;
    *.zip) echo "zip" ;;
    *.exe) echo "exe" ;;
    *) echo "" ;;
  esac
}

_config_archive_format() {
  local tool="$1"
  local os="$2"
  local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
  local tool_config="$config_dir/repos.d/${tool}.yaml"
  local format=""

  if command -v yq &>/dev/null; then
    if [[ -f "$tool_config" ]]; then
      format=$(yq -r ".archive_format.${os} // \"\"" "$tool_config" 2>/dev/null)
      [[ "$format" == "null" ]] && format=""
      if [[ -n "$format" ]]; then
        echo "$format"
        return 0
      fi
      format=$(yq -r ".archive_format // \"\"" "$tool_config" 2>/dev/null)
      if [[ "$format" != "null" && "$format" != "" && "$format" != "{"* ]]; then
        echo "$format"
        return 0
      fi
    fi
  fi

  case "$os" in
    windows) echo "zip" ;;
    *) echo "tar.gz" ;;
  esac
}

resolve_archive_format() {
  local tool="$1"
  local repo_path="$2"
  local os="$3"

  ensure_dsr_modules

  local format compat_pattern compat_ext
  format=$(_config_archive_format "$tool" "$os")

  compat_pattern=$(artifact_naming_get_compat_pattern "$tool" "$repo_path" 2>/dev/null || echo "")
  compat_ext=$(_ext_from_pattern "$compat_pattern")
  if [[ -n "$compat_ext" && "$format" != "binary" ]]; then
    if [[ "$compat_ext" == "exe" ]]; then
      format="none"
    elif [[ "$format" != "$compat_ext" ]]; then
      format="$compat_ext"
    fi
  fi

  echo "$format"
}

resolve_naming_ext() {
  local format="$1"
  local os="$2"
  if [[ "$format" == "binary" ]]; then
    if [[ "$os" == "windows" ]]; then
      echo "exe"
    else
      echo ""
    fi
    return 0
  fi
  if [[ "$format" == "none" ]]; then
    echo ""
    return 0
  fi
  echo "$format"
}

list_target_triples() {
  local tool="$1"
  local platform="$2"
  local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
  local tool_config="$config_dir/repos.d/${tool}.yaml"
  local value_json=""

  if ! command -v yq &>/dev/null; then
    return 0
  fi
  if [[ ! -f "$tool_config" ]]; then
    return 0
  fi

  value_json=$(yq -o=json ".target_triples.\"$platform\" // null" "$tool_config" 2>/dev/null || echo "null")
  if [[ -z "$value_json" || "$value_json" == "null" ]]; then
    return 0
  fi

  if echo "$value_json" | jq -e 'type == "string"' >/dev/null 2>&1; then
    local value
    value=$(echo "$value_json" | jq -r '.')
    IFS=',' read -ra parts <<< "$value"
    for part in "${parts[@]}"; do
      part="${part## }"
      part="${part%% }"
      [[ -n "$part" ]] && echo "$part"
    done
    return 0
  fi

  if echo "$value_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "$value_json" | jq -r '.[]'
    return 0
  fi
}

with_target_triple() {
  local triple="$1"
  shift
  local original=""
  if declare -F config_get_target_triple &>/dev/null; then
    original=$(declare -f config_get_target_triple)
  fi
  config_get_target_triple() { echo "$triple"; }
  "$@"
  local status=$?
  if [[ -n "$original" ]]; then
    eval "$original"
  else
    unset -f config_get_target_triple 2>/dev/null || true
  fi
  return "$status"
}

expected_assets_for_version() {
  local version="$1"
  local repo_path="$2"
  local target_list="$3"

  ensure_dsr_modules

  local -a rows=()
  local target os arch format naming_ext

  for target in $target_list; do
    os="${target%/*}"
    arch="${target#*/}"
    format=$(resolve_archive_format "$TOOL_NAME" "$repo_path" "$os")
    naming_ext=$(resolve_naming_ext "$format" "$os")

    local -a triples=()
    while IFS= read -r triple; do
      [[ -n "$triple" ]] && triples+=("$triple")
    done < <(list_target_triples "$TOOL_NAME" "$target")

    if [[ ${#triples[@]} -eq 0 ]]; then
      local names_json versioned compat
      names_json=$(artifact_naming_generate_dual_for_tool "$TOOL_NAME" "$version" "$os" "$arch" "$naming_ext" "$repo_path" 2>/dev/null || echo "")
      versioned=$(echo "$names_json" | jq -r '.versioned // empty' 2>/dev/null)
      compat=$(echo "$names_json" | jq -r '.compat // empty' 2>/dev/null)
      rows+=("${target}||${versioned}|${compat}|${format}")
    else
      local triple
      for triple in "${triples[@]}"; do
        local names_json versioned compat
        names_json=$(with_target_triple "$triple" artifact_naming_generate_dual_for_tool "$TOOL_NAME" "$version" "$os" "$arch" "$naming_ext" "$repo_path" 2>/dev/null || echo "")
        versioned=$(echo "$names_json" | jq -r '.versioned // empty' 2>/dev/null)
        compat=$(echo "$names_json" | jq -r '.compat // empty' 2>/dev/null)
        rows+=("${target}|${triple}|${versioned}|${compat}|${format}")
      done
    fi
  done

  printf '%s\n' "${rows[@]}"
}

asset_exists() {
  local assets_json="$1"
  local name="$2"
  echo "$assets_json" | jq -e --arg name "$name" '.[] | select(.name == $name)' >/dev/null 2>&1
}

scenario_safe_name() {
  echo "$1" | tr -c 'a-zA-Z0-9_.-' '_' | tr ' ' '_'
}

scenario_prepare() {
  local name="$1"

  scenario_reset_config

  SCENARIO_REQUIRE_GHA="$SCENARIO_REQUIRE_GHA_DEFAULT"
  SCENARIO_CHECK_PREBUILT=0
  SCENARIO_INSTALL_CONTAINERS=0
  SCENARIO_ACT_ENV_LINES=""
  SCENARIO_INSTALL_ENV_LINES=""
  SCENARIO_MODE="parity"

  case "$name" in
    base)
      ;;
    prebuilt)
      SCENARIO_CHECK_PREBUILT=1
      ;;
    multi_variant)
      SCENARIO_CHECK_PREBUILT=1
      SCENARIO_INSTALL_CONTAINERS=1
      ARTIFACT_NAMING="\${name}-\${version}-\${target_triple}"
      INSTALL_SCRIPT_COMPAT="\${name}-\${target_triple}"
      TOOL_CONFIG_EXTRA=$'archive_format:\\n  linux: tar.xz\\narch_aliases:\\n  amd64: x86_64\\n  arm64: aarch64\\ntarget_triples:\\n  \"linux/amd64\":\\n    - x86_64-unknown-linux-gnu\\n    - x86_64-unknown-linux-musl'
      SCENARIO_ACT_ENV_LINES=$'MOCK_RELEASE_TARGET_TRIPLE_MODE=1\\nMOCK_RELEASE_USE_TAR_XZ=1'
      SCENARIO_INSTALL_ENV_LINES=$'MOCK_RELEASE_USE_TARGET_TRIPLE=1\\nMOCK_RELEASE_USE_TAR_XZ=1'
      ;;
    config_validation)
      SCENARIO_REQUIRE_GHA=0
      SCENARIO_MODE="config_validation"
      ;;
    *)
      scenario_skip "Unknown scenario: $name"
      return 1
      ;;
  esac

  return 0
}

scenario_apply_overrides() {
  local scenario_dir="$1"
  local extra="$TOOL_CONFIG_EXTRA"

  if [[ -n "$SCENARIO_ACT_ENV_LINES" ]]; then
    local env_file="$scenario_dir/act.env"
    printf '%s\n' "$SCENARIO_ACT_ENV_LINES" > "$env_file"
    if [[ -n "$extra" ]]; then
      extra="${extra}"$'\n'
    fi
    extra="${extra}act_overrides:\n  env_file: ${env_file}"
  fi

  TOOL_CONFIG_EXTRA="$extra"
}

run_parity_flow() {
  local require_gha="$SCENARIO_REQUIRE_GHA"
  local target_list="$TARGETS"
  local repo_path="$LOCAL_PATH"

  if [[ -z "$GHA_TAG" ]]; then
    if [[ "$TRIGGER_GHA" == "1" ]]; then
      GHA_TAG="v0.0.1-gha-${SCENARIO_NAME}-$(date +%s)"
    elif [[ "$require_gha" == "1" ]]; then
      scenario_skip "GHA tag not provided and --trigger-gha not set"
      return 0
    fi
  fi

  if [[ -z "$DSR_TAG" ]]; then
    DSR_TAG="v0.0.1-dsr-${SCENARIO_NAME}-$(date +%s)"
  fi

  log_line "INFO" "E2E release parity test starting"
  log_line "INFO" "Scenario: $SCENARIO_NAME"
  log_line "INFO" "Repo: $REPO"
  log_line "INFO" "Local path: $LOCAL_PATH"
  log_line "INFO" "GH tag: $GHA_TAG"
  log_line "INFO" "DSR tag: $DSR_TAG"
  if [[ "$VERBOSE" -eq 1 ]]; then
    log_line "INFO" "Targets: $target_list"
    log_line "INFO" "Config dir: $DSR_CONFIG_DIR"
  fi

  # Ensure dsr tag exists locally (required by dsr release)
  if ! git -C "$LOCAL_PATH" tag -l "$DSR_TAG" | grep -q "^${DSR_TAG}$"; then
    if git -C "$LOCAL_PATH" tag "$DSR_TAG" 2>/dev/null; then
      if [[ "$DEBUG" -eq 1 ]]; then
        log_line "DEBUG" "Created local tag $DSR_TAG"
      fi
    else
      log_line "ERROR" "Failed to create local tag $DSR_TAG"
      return 1
    fi
  fi

  # Optional: trigger GH Actions release
  if [[ "$TRIGGER_GHA" == "1" && "$require_gha" == "1" ]]; then
    if [[ "$ALLOW_TAG_PUSH" != "1" ]]; then
      scenario_skip "DSR_E2E_ALLOW_TAG_PUSH=1 required to push tags"
      return 0
    fi

    phase_start "trigger_gha"

    if git -C "$LOCAL_PATH" tag "$GHA_TAG" 2>/dev/null; then
      if git -C "$LOCAL_PATH" push origin "$GHA_TAG" 2>/dev/null; then
        CREATED_GHA_TAG=true
        if wait_for_release "$REPO" "$GHA_TAG" "$WAIT_TIMEOUT"; then
          phase_end "pass" "{\"tag\": \"$GHA_TAG\"}"
        else
          fail_phase "{\"tag\": \"$GHA_TAG\", \"error\": \"timeout\"}" || return 1
        fi
      else
        fail_phase "{\"error\": \"failed to push tag\"}" || return 1
      fi
    else
      fail_phase "{\"error\": \"failed to create tag\"}" || return 1
    fi
  fi

  # Build with dsr
  phase_start "build"
  if run_logged "$DSR_OUTPUT_LOG" "$DSR_CMD" build --tool "$TOOL_NAME" --version "$DSR_TAG" --targets "$(echo "$target_list" | tr ' ' ',')"; then
    phase_end "pass" "{}"
  else
    fail_phase "{}" || return 1
  fi

  # Release with dsr
  phase_start "release"
  local -a release_args=()
  if [[ "$DRAFT_RELEASE" == "1" ]]; then
    release_args=(--draft)
  else
    release_args=()
  fi

  if run_logged "$DSR_OUTPUT_LOG" "$DSR_CMD" release --tool "$TOOL_NAME" --version "$DSR_TAG" "${release_args[@]}"; then
    CREATED_DSR_RELEASE=true
    phase_end "pass" "{}"
  else
    fail_phase "{}" || return 1
  fi

  # Verify versioned assets exist
  phase_start "verify_versioned"
  local assets_dsr assets_gha
  assets_dsr=$(fetch_release_assets "$REPO" "$DSR_TAG" 2>/dev/null || true)
  assets_gha=$(fetch_release_assets "$REPO" "$GHA_TAG" 2>/dev/null || true)

  if [[ -z "$assets_dsr" || -z "$assets_gha" ]]; then
    fail_phase "{\"error\": \"missing release assets\"}" || return 1
  fi

  local expected_dsr expected_gha
  expected_dsr=$(expected_assets_for_version "$DSR_TAG" "$repo_path" "$target_list")
  expected_gha=$(expected_assets_for_version "$GHA_TAG" "$repo_path" "$target_list")

  local -A dsr_versioned=()
  local -A dsr_compat=()
  local -A gha_versioned=()
  local -A name_owners=()
  local -a duplicate_names=()
  local -a unresolved_names=()

  while IFS='|' read -r target triple versioned compat format; do
    if [[ -z "$versioned" ]]; then
      unresolved_names+=("${target}|${triple}")
      continue
    fi
    local key="${target}|${triple}"
    dsr_versioned["$key"]="$versioned"
    [[ -n "$compat" ]] && dsr_compat["$key"]="$compat"
    if [[ -n "${name_owners[$versioned]:-}" ]]; then
      duplicate_names+=("$versioned")
    else
      name_owners["$versioned"]="$key"
    fi
  done <<< "$expected_dsr"

  while IFS='|' read -r target triple versioned compat format; do
    if [[ -z "$versioned" ]]; then
      unresolved_names+=("${target}|${triple}")
      continue
    fi
    local key="${target}|${triple}"
    gha_versioned["$key"]="$versioned"
  done <<< "$expected_gha"

  if [[ ${#unresolved_names[@]} -gt 0 ]]; then
    fail_phase "{\"error\": \"unresolved naming patterns\", \"targets\": $(printf '%s\n' "${unresolved_names[@]}" | jq -R . | jq -sc '.') }" || return 1
  fi

  if [[ ${#duplicate_names[@]} -gt 0 ]]; then
    fail_phase "{\"error\": \"duplicate expected names\", \"names\": $(printf '%s\n' "${duplicate_names[@]}" | jq -R . | jq -sc '.') }" || return 1
  fi

  local -a missing_versioned=()
  local key
  for key in "${!dsr_versioned[@]}"; do
    local expected="${dsr_versioned[$key]}"
    if [[ "$VERBOSE" -eq 1 ]]; then
      log_line "INFO" "Checking versioned asset: $expected"
    fi
    if ! asset_exists "$assets_dsr" "$expected"; then
      missing_versioned+=("$expected")
    fi
  done
  for key in "${!gha_versioned[@]}"; do
    local expected="${gha_versioned[$key]}"
    if [[ "$VERBOSE" -eq 1 ]]; then
      log_line "INFO" "Checking GHA asset: $expected"
    fi
    if ! asset_exists "$assets_gha" "$expected"; then
      missing_versioned+=("$expected")
    fi
  done

  if [[ ${#missing_versioned[@]} -gt 0 ]]; then
    fail_phase "{\"missing\": $(printf '%s\n' "${missing_versioned[@]}" | jq -R . | jq -sc '.') }" || return 1
  fi
  local assets_checked
  assets_checked=$(echo "$target_list" | wc -w | tr -d ' ')
  phase_end "pass" "{\"assets_checked\": ${assets_checked}}"

  # Verify compat assets exist in dsr release
  phase_start "verify_compat"
  local -a missing_compat=()
  for key in "${!dsr_compat[@]}"; do
    local expected="${dsr_compat[$key]}"
    if [[ "$VERBOSE" -eq 1 ]]; then
      log_line "INFO" "Checking compat asset: $expected"
    fi
    if ! asset_exists "$assets_dsr" "$expected"; then
      missing_compat+=("$expected")
    fi
  done

  if [[ ${#missing_compat[@]} -gt 0 ]]; then
    fail_phase "{\"missing\": $(printf '%s\n' "${missing_compat[@]}" | jq -R . | jq -sc '.') }" || return 1
  fi
  phase_end "pass" "{\"assets_checked\": ${assets_checked}}"

  # Verify install.sh works
  phase_start "verify_install"
  INSTALL_DIR="$WORK_DIR/install"
  mkdir -p "$INSTALL_DIR"

  install_script="$LOCAL_PATH/$INSTALL_SCRIPT_PATH"
  if [[ ! -f "$install_script" ]]; then
    fail_phase "{\"error\": \"install script not found\"}" || return 1
  fi

  local -a install_env=()
  install_env+=("MOCK_RELEASE_CACHE_DIR=$WORK_DIR/install_cache")
  if [[ -n "$SCENARIO_INSTALL_ENV_LINES" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      install_env+=("$line")
    done <<< "$SCENARIO_INSTALL_ENV_LINES"
  fi

  if ! run_logged "$DSR_OUTPUT_LOG" env "${install_env[@]}" MOCK_RELEASE_REPO="$REPO" bash "$install_script" --version "$DSR_TAG" --dir "$INSTALL_DIR"; then
    fail_phase "{\"error\": \"install failed\"}" || return 1
  fi

  if [[ -x "$INSTALL_DIR/$TOOL_NAME" ]]; then
    "$INSTALL_DIR/$TOOL_NAME" >/dev/null 2>&1 || {
      fail_phase "{\"error\": \"installed binary failed to run\"}" || return 1
    }
  fi
  phase_end "pass" "{\"binary_works\": true}"

  # Optional: verify install in glibc + musl containers
  if [[ "$SCENARIO_INSTALL_CONTAINERS" == "1" ]]; then
    phase_start "verify_install_containers"
    if ! command -v docker &>/dev/null; then
      fail_phase "{\"error\": \"docker not available\"}" || return 1
    fi
    local docker_envs=("${install_env[@]}")
    docker_envs+=("MOCK_RELEASE_REPO=$REPO")
    docker_envs+=("MOCK_RELEASE_CACHE_DIR=/tmp/cache")

    if ! run_logged "$DSR_OUTPUT_LOG" docker run --rm \
      -e "${docker_envs[@]}" \
      -v "$LOCAL_PATH:/work:ro" \
      ubuntu:22.04 \
      bash -c "apt-get update -qq && apt-get install -y -qq bash curl ca-certificates tar gzip xz-utils unzip >/dev/null && bash /work/$INSTALL_SCRIPT_PATH --version $DSR_TAG --dir /tmp/bin"; then
      fail_phase "{\"error\": \"glibc container install failed\"}" || return 1
    fi

    if ! run_logged "$DSR_OUTPUT_LOG" docker run --rm \
      -e "${docker_envs[@]}" \
      -v "$LOCAL_PATH:/work:ro" \
      alpine:3.19 \
      sh -c "apk add --no-cache bash curl ca-certificates tar gzip xz unzip >/dev/null && bash /work/$INSTALL_SCRIPT_PATH --version $DSR_TAG --dir /tmp/bin"; then
      fail_phase "{\"error\": \"musl container install failed\"}" || return 1
    fi

    phase_end "pass" "{}"
  fi

  # Prebuilt artifact skip check
  if [[ "$SCENARIO_CHECK_PREBUILT" == "1" ]]; then
    phase_start "verify_prebuilt_skip"
    local skip_count=0
    if [[ -f "$DSR_OUTPUT_LOG" ]]; then
      skip_count=$(grep -c "Archive already produced for" "$DSR_OUTPUT_LOG" 2>/dev/null || true)
    fi
    if [[ "$skip_count" -lt 1 ]]; then
      fail_phase "{\"error\": \"expected prebuilt skip log entries\", \"count\": $skip_count}" || return 1
    fi
    phase_end "pass" "{\"skip_count\": $skip_count}"
  fi

  # Compare checksums between GH Actions and dsr releases
  phase_start "verify_checksums"
  DSR_ASSET_DIR="$WORK_DIR/dsr_assets"
  GHA_ASSET_DIR="$WORK_DIR/gha_assets"

  if ! download_release_assets "$REPO" "$DSR_TAG" "$DSR_ASSET_DIR" "$TOOL_NAME"; then
    fail_phase "{\"error\": \"failed to download dsr assets\"}" || return 1
  fi
  if ! download_release_assets "$REPO" "$GHA_TAG" "$GHA_ASSET_DIR" "$TOOL_NAME"; then
    fail_phase "{\"error\": \"failed to download gha assets\"}" || return 1
  fi

  checksum_mismatches=()
  compat_mismatches=()
  checksum_details=()
  compat_details=()

  for key in "${!dsr_versioned[@]}"; do
    local dsr_name="${dsr_versioned[$key]}"
    local gha_name="${gha_versioned[$key]:-}"
    local dsr_file="$DSR_ASSET_DIR/$dsr_name"
    local gha_file="$GHA_ASSET_DIR/$gha_name"

    if [[ -z "$gha_name" || ! -f "$gha_file" ]]; then
      checksum_mismatches+=("$key")
      checksum_details+=("$key missing gha asset")
      continue
    fi
    if [[ ! -f "$dsr_file" ]]; then
      checksum_mismatches+=("$key")
      checksum_details+=("$key missing dsr asset")
      continue
    fi

    dsr_sum=$(sha256_file "$dsr_file")
    gha_sum=$(sha256_file "$gha_file")
    if [[ "$dsr_sum" != "$gha_sum" ]]; then
      checksum_mismatches+=("$key")
      checksum_details+=("$key dsr=$dsr_sum gha=$gha_sum")
    fi

    local compat_name="${dsr_compat[$key]:-}"
    if [[ -n "$compat_name" && -f "$DSR_ASSET_DIR/$compat_name" ]]; then
      compat_sum=$(sha256_file "$DSR_ASSET_DIR/$compat_name")
      if [[ "$dsr_sum" != "$compat_sum" ]]; then
        compat_mismatches+=("$key")
        compat_details+=("$key dsr=$dsr_sum compat=$compat_sum")
      fi
    fi
  done

  if [[ ${#checksum_mismatches[@]} -gt 0 || ${#compat_mismatches[@]} -gt 0 ]]; then
    fail_phase "{\"checksum_mismatches\": $(printf '%s\n' "${checksum_mismatches[@]}" | jq -R . | jq -sc '.'), \"compat_mismatches\": $(printf '%s\n' "${compat_mismatches[@]}" | jq -R . | jq -sc '.'), \"checksum_details\": $(printf '%s\n' "${checksum_details[@]}" | jq -R . | jq -sc '.'), \"compat_details\": $(printf '%s\n' "${compat_details[@]}" | jq -R . | jq -sc '.') }" || return 1
  fi
  phase_end "pass" "{\"all_match\": true}"

  return 0
}

run_config_validation_flow() {
  local target_list="$TARGETS"
  local original_workflow="$WORKFLOW_PATH"

  log_line "INFO" "Running config validation scenario"

  # Invalid workflow path
  phase_start "config_invalid_workflow"
  WORKFLOW_PATH=".github/workflows/does-not-exist.yml"
  create_repos_config "$REPO" "$LOCAL_PATH" "$DSR_CONFIG_DIR"
  local status=0
  if run_logged "$DSR_OUTPUT_LOG" "$DSR_CMD" build --tool "$TOOL_NAME" --version "${DSR_TAG:-v0.0.1-config-$(date +%s)}" --targets "$(echo "$target_list" | tr ' ' ',')" --only-act; then
    fail_phase "{\"error\": \"expected failure for missing workflow\"}" || return 1
  else
    status=$?
  fi
  if [[ "$status" -ne 4 ]]; then
    fail_phase "{\"error\": \"expected INVALID_ARGS (4)\", \"exit_code\": $status}" || return 1
  fi
  if ! grep -q "workflow" "$DSR_OUTPUT_LOG" 2>/dev/null; then
    fail_phase "{\"error\": \"missing workflow error message\"}" || return 1
  fi
  phase_end "pass" "{}"

  # Invalid local path
  phase_start "config_invalid_local_path"
  WORKFLOW_PATH="${DSR_E2E_WORKFLOW:-.github/workflows/release.yml}"
  create_repos_config "$REPO" "/path/does/not/exist" "$DSR_CONFIG_DIR"
  status=0
  if run_logged "$DSR_OUTPUT_LOG" "$DSR_CMD" build --tool "$TOOL_NAME" --version "${DSR_TAG:-v0.0.1-config-$(date +%s)}" --targets "$(echo "$target_list" | tr ' ' ',')" --only-act; then
    fail_phase "{\"error\": \"expected failure for invalid local path\"}" || return 1
  else
    status=$?
  fi
  if [[ "$status" -ne 4 ]]; then
    fail_phase "{\"error\": \"expected INVALID_ARGS (4)\", \"exit_code\": $status}" || return 1
  fi
  if ! grep -qi "Local path" "$DSR_OUTPUT_LOG" 2>/dev/null; then
    fail_phase "{\"error\": \"missing local path error message\"}" || return 1
  fi
  phase_end "pass" "{}"

  # Valid config sanity check
  phase_start "config_valid"
  WORKFLOW_PATH="${DSR_E2E_WORKFLOW:-.github/workflows/release.yml}"
  create_repos_config "$REPO" "$LOCAL_PATH" "$DSR_CONFIG_DIR"
  if run_logged "$DSR_OUTPUT_LOG" "$DSR_CMD" build --tool "$TOOL_NAME" --version "${DSR_TAG:-v0.0.1-config-$(date +%s)}" --targets "$(echo "$target_list" | tr ' ' ',')" --only-act --allow-dirty; then
    phase_end "pass" "{}"
  else
    fail_phase "{\"error\": \"valid config build failed\"}" || return 1
  fi

  WORKFLOW_PATH="$original_workflow"
  return 0
}

parse_asset_name() {
  local tool="$1"
  local name="$2"

  local ext base
  if [[ "$name" == *.tar.gz ]]; then
    ext="tar.gz"
    base="${name%.tar.gz}"
  elif [[ "$name" == *.tar.xz ]]; then
    ext="tar.xz"
    base="${name%.tar.xz}"
  elif [[ "$name" == *.tgz ]]; then
    ext="tgz"
    base="${name%.tgz}"
  elif [[ "$name" == *.zip ]]; then
    ext="zip"
    base="${name%.zip}"
  elif [[ "$name" == *.exe ]]; then
    ext="exe"
    base="${name%.exe}"
  else
    return 1
  fi

  if [[ "$base" != "${tool}-"* ]]; then
    return 1
  fi

  local rest os arch version_part
  rest="${base#"${tool}"-}"
  arch="${rest##*-}"
  rest="${rest%-"${arch}"}"
  os="${rest##*-}"
  version_part="${rest%-"${os}"}"

  echo "$os|$arch|$ext|$version_part"
}

fetch_release_assets() {
  local repo="$1"
  local tag="$2"
  gh api "repos/$repo/releases/tags/$tag" --jq '.assets'
}

download_release_assets() {
  local repo="$1"
  local tag="$2"
  local dest_dir="$3"
  local tool="$4"
  local failed=0

  mkdir -p "$dest_dir"

  local assets_json
  assets_json=$(fetch_release_assets "$repo" "$tag" 2>/dev/null) || return 1

  echo "$assets_json" | jq -c '.[]' | while IFS= read -r asset; do
    local name id
    name=$(echo "$asset" | jq -r '.name')
    id=$(echo "$asset" | jq -r '.id')

    if [[ "$name" == ${tool}-* || "$name" == SHA256* || "$name" == sha256* ]]; then
      if [[ "$DEBUG" -eq 1 ]]; then
        log_line "DEBUG" "Downloading asset $name"
      fi
      if ! gh api \
        -H "Accept: application/octet-stream" \
        "repos/$repo/releases/assets/$id" \
        > "$dest_dir/$name"; then
        failed=1
      fi
    fi
  done

  return "$failed"
}

wait_for_release() {
  local repo="$1"
  local tag="$2"
  local timeout="$3"
  local start
  start=$(date +%s)

  while true; do
    if gh api "repos/$repo/releases/tags/$tag" &>/dev/null; then
      return 0
    fi

    local now
    now=$(date +%s)
    if (( now - start > timeout )); then
      return 1
    fi

    sleep 10
  done
}

create_repos_config() {
  local repo="$1"
  local local_path="$2"
  local config_dir="$3"
  local targets_yaml=""
  local target

  mkdir -p "$config_dir/repos.d"

  cat > "$config_dir/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
signing:
  enabled: false
YAML

  cat > "$config_dir/hosts.yaml" << 'YAML'
hosts:
  trj:
    platform: linux/amd64
    connection: local
    capabilities:
      - docker
      - act
YAML

  for target in $TARGETS; do
    targets_yaml="${targets_yaml}  - ${target}\n"
  done

  cat > "$config_dir/repos.d/${TOOL_NAME}.yaml" << YAML
tool_name: ${TOOL_NAME}
repo: ${repo}
local_path: ${local_path}
language: ${LANGUAGE}
build_cmd: ${BUILD_CMD}
binary_name: ${BINARY_NAME}
targets:
$(printf '%b' "$targets_yaml")
workflow: ${WORKFLOW_PATH}
act_job_map:
  linux/amd64: ${JOB_LINUX}
  darwin/arm64: ${JOB_DARWIN}
  windows/amd64: ${JOB_WINDOWS}
artifact_naming: "${ARTIFACT_NAMING}"
install_script_compat: "${INSTALL_SCRIPT_COMPAT}"
install_script_path: ${INSTALL_SCRIPT_PATH}
${TOOL_CONFIG_EXTRA}
YAML
}

# shellcheck disable=SC2317
cleanup() {
  local exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    log_line "ERROR" "Test failed. Log preserved at: $LOG_FILE"
  elif [[ "$KEEP_LOG" != "1" ]]; then
    rm -f "$LOG_FILE" 2>/dev/null || true
  fi

  if [[ "$KEEP_RELEASES" != "1" ]]; then
    if $CREATED_DSR_RELEASE; then
      gh release delete "$DSR_TAG" --repo "$REPO" --yes 2>/dev/null || true
    fi
    if $CREATED_GHA_TAG; then
      gh release delete "$GHA_TAG" --repo "$REPO" --yes 2>/dev/null || true
    fi
  fi

  if [[ -n "${WORK_ROOT:-}" && -d "$WORK_ROOT" ]]; then
    rm -rf "$WORK_ROOT" 2>/dev/null || true
  elif [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR" 2>/dev/null || true
  fi

  if [[ -n "${FIXTURE_TMP_DIR:-}" && -d "$FIXTURE_TMP_DIR" ]]; then
    rm -rf "$FIXTURE_TMP_DIR" 2>/dev/null || true
  fi

  return "$exit_code"
}

if [[ "${BASH_SOURCE[0]}" != "$0" && "${DSR_E2E_SOURCE_ONLY:-0}" == "1" ]]; then
  return 0
fi

trap cleanup EXIT

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --local-path)
      LOCAL_PATH="$2"
      shift 2
      ;;
    --gha-tag)
      GHA_TAG="$2"
      shift 2
      ;;
    --dsr-tag)
      DSR_TAG="$2"
      shift 2
      ;;
    --targets)
      TARGETS="$2"
      shift 2
      ;;
    --scenarios)
      SCENARIOS_RAW="$2"
      SCENARIO_SET=1
      shift 2
      ;;
    --scenario)
      SCENARIOS+=("$2")
      SCENARIO_SET=1
      shift 2
      ;;
    --trigger-gha)
      TRIGGER_GHA=1
      shift
      ;;
    --use-fixture)
      USE_FIXTURE=1
      shift
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    -v)
      VERBOSE=1
      shift
      ;;
    -vv)
      VERBOSE=1
      DEBUG=1
      shift
      ;;
    --keep-log)
      KEEP_LOG=1
      shift
      ;;
    --keep-releases)
      KEEP_RELEASES=1
      shift
      ;;
    --continue-on-fail)
      CONTINUE_ON_FAIL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_line "ERROR" "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

TEST_START_MS="$(_now_ms)"

# Prereqs
require_cmd gh "gh"
require_cmd jq "jq"
require_cmd yq "yq"
require_cmd git "git"
require_cmd act "act"
require_cmd docker "docker"
require_cmd curl "curl"

if [[ -z "$REPO" ]]; then
  skip_test "DSR_E2E_REPO not set"
fi

if [[ -z "$LOCAL_PATH" ]]; then
  if [[ "$USE_FIXTURE" == "1" ]]; then
    FIXTURE_TMP_DIR="$(mktemp -d)"
    cp -r "$SCRIPT_DIR/fixtures/mock_release_tool/." "$FIXTURE_TMP_DIR/" || {
      log_line "ERROR" "Failed to copy fixture"
      exit 1
    }
    git -C "$FIXTURE_TMP_DIR" init -q 2>/dev/null || true
    git -C "$FIXTURE_TMP_DIR" add . 2>/dev/null || true
    git -C "$FIXTURE_TMP_DIR" commit -q -m "fixture" 2>/dev/null || true
    LOCAL_PATH="$FIXTURE_TMP_DIR"
  else
    skip_test "DSR_E2E_LOCAL_PATH not set"
  fi
fi

if [[ ! -d "$LOCAL_PATH/.git" ]]; then
  skip_test "Local path is not a git repo: $LOCAL_PATH"
fi

# Best-effort remote validation
remote_url=$(git -C "$LOCAL_PATH" remote get-url origin 2>/dev/null || true)
if [[ -n "$remote_url" && "$remote_url" != *"$REPO"* ]]; then
  log_line "WARN" "Local repo origin does not match $REPO (origin: $remote_url)"
fi

# Resolve scenario list
if [[ "$SCENARIO_SET" -eq 0 ]]; then
  mapfile -t SCENARIOS < <(parse_scenarios "$SCENARIOS_RAW")
fi
if [[ "$SCENARIO_SET" -eq 1 && ${#SCENARIOS[@]} -eq 0 ]]; then
  mapfile -t SCENARIOS < <(parse_scenarios "$SCENARIOS_RAW")
fi
if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
  SCENARIOS=("base")
fi

WORK_ROOT="$(mktemp -d)"
base_gha_tag="$GHA_TAG"
base_dsr_tag="$DSR_TAG"
base_workflow_path="$WORKFLOW_PATH"
base_targets="$TARGETS"
any_fail=0

for scenario in "${SCENARIOS[@]}"; do
  scenario_begin "$scenario"

  local_safe=$(scenario_safe_name "$scenario")
  if [[ -n "${DSR_E2E_LOG_FILE:-}" ]]; then
    LOG_FILE="$DSR_E2E_LOG_FILE"
  else
    LOG_FILE="/tmp/e2e_release_parity_${local_safe}_$$.log"
  fi
  if [[ -n "${DSR_E2E_DSR_LOG_FILE:-}" ]]; then
    DSR_OUTPUT_LOG="$DSR_E2E_DSR_LOG_FILE"
  else
    DSR_OUTPUT_LOG="/tmp/e2e_release_parity_dsr_${local_safe}_$$.log"
  fi

  GHA_TAG="$base_gha_tag"
  DSR_TAG="$base_dsr_tag"
  WORKFLOW_PATH="$base_workflow_path"
  TARGETS="$base_targets"

  if ! scenario_prepare "$scenario"; then
    SCENARIO_STATUS="skip"
    scenario_end
    continue
  fi
  if [[ "$SCENARIO_STATUS" == "skip" ]]; then
    scenario_end
    continue
  fi

  WORK_DIR="$WORK_ROOT/$local_safe"
  mkdir -p "$WORK_DIR"
  export DSR_CONFIG_DIR="$WORK_DIR/config"
  export DSR_STATE_DIR="$WORK_DIR/state"
  export DSR_CACHE_DIR="$WORK_DIR/cache"

  scenario_apply_overrides "$WORK_DIR"

  create_repos_config "$REPO" "$LOCAL_PATH" "$DSR_CONFIG_DIR"

  if [[ "$SCENARIO_MODE" == "config_validation" ]]; then
    if run_config_validation_flow; then
      [[ "$SCENARIO_STATUS" != "skip" ]] && SCENARIO_STATUS="pass"
    else
      SCENARIO_STATUS="fail"
    fi
  else
    if run_parity_flow; then
      [[ "$SCENARIO_STATUS" != "skip" ]] && SCENARIO_STATUS="pass"
    else
      SCENARIO_STATUS="fail"
    fi
  fi

  scenario_end

  if [[ "$SCENARIO_STATUS" == "fail" && "$CONTINUE_ON_FAIL" != "1" ]]; then
    any_fail=1
    break
  fi
  if [[ "$SCENARIO_STATUS" == "fail" ]]; then
    any_fail=1
  fi
done

# Summary
TOTAL_DURATION_MS=$(( $(_now_ms) - TEST_START_MS ))

overall_result="PASS"
[[ "$any_fail" -eq 1 ]] && overall_result="FAIL"

if $JSON_MODE; then
  scenarios_json=$(printf '%s\n' "${SCENARIO_RESULTS[@]}" | jq -s '.')
  jq -nc \
    --arg test "e2e_release_parity" \
    --argjson scenarios "$scenarios_json" \
    --arg result "$overall_result" \
    --argjson total_duration_ms "$TOTAL_DURATION_MS" \
    '{test: $test, scenarios: $scenarios, result: $result, total_duration_ms: $total_duration_ms}'
else
  log_line "INFO" "E2E: Completed (${TOTAL_DURATION_MS}ms total)"
fi

if [[ "$any_fail" -eq 1 && "$CONTINUE_ON_FAIL" != "1" ]]; then
  exit 1
fi

exit 0
