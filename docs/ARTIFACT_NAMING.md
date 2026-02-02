# Artifact Naming Convention

This document defines the standard artifact naming scheme for dsr builds.

## Naming Format

```
{tool}-{version}-{os}-{arch}[.exe][.archive]
```

### Components

| Component | Format | Examples |
|-----------|--------|----------|
| tool | lowercase alphanumeric | `ntm`, `bv`, `cass` |
| version | semver with v prefix | `v1.2.3`, `v0.1.0-beta.1` |
| os | lowercase | `linux`, `darwin`, `windows` |
| arch | lowercase | `amd64`, `arm64`, `386` |
| .exe | Windows only | (suffix for Windows binaries) |
| .archive | optional | `.tar.gz`, `.zip` |

### Examples

**Raw binaries:**
```
ntm-v1.2.3-linux-amd64
ntm-v1.2.3-darwin-arm64
ntm-v1.2.3-windows-amd64.exe
```

**Archived releases:**
```
ntm-v1.2.3-linux-amd64.tar.gz
ntm-v1.2.3-darwin-arm64.tar.gz
ntm-v1.2.3-windows-amd64.zip
```

## Checksum Files

### SHA256SUMS

All checksums are stored in a single file:
```
{tool}-{version}-checksums.sha256
```

Format (BSD-style, compatible with `sha256sum -c`):
```
abc123def456...  ntm-v1.2.3-linux-amd64.tar.gz
def456abc789...  ntm-v1.2.3-darwin-arm64.tar.gz
789abc123def...  ntm-v1.2.3-windows-amd64.zip
```

## Signatures

### minisign signatures

Each artifact can have a corresponding signature:
```
ntm-v1.2.3-linux-amd64.tar.gz.minisig
ntm-v1.2.3-darwin-arm64.tar.gz.minisig
ntm-v1.2.3-windows-amd64.zip.minisig
```

The checksums file is also signed:
```
ntm-v1.2.3-checksums.sha256.minisig
```

## Build Manifest

Every build produces a manifest JSON file:
```
{tool}-{version}-manifest.json
```

The manifest contains:
- Tool name and version
- Git SHA and ref
- Build timestamp and duration
- List of all artifacts with checksums
- Host status for each build target
- SBOM and signature file references

See `schemas/manifest.json` for the full schema.

### Example Manifest

```json
{
  "schema_version": "1.0.0",
  "tool": "ntm",
  "version": "v1.2.3",
  "run_id": "550e8400-e29b-41d4-a716-446655440000",
  "git_sha": "abc123def456789...",
  "git_ref": "v1.2.3",
  "built_at": "2026-01-30T15:00:00Z",
  "duration_ms": 180000,
  "builder": {
    "tool": "dsr",
    "version": "0.1.0",
    "trigger": "throttle-fallback"
  },
  "artifacts": [
    {
      "name": "ntm-v1.2.3-linux-amd64.tar.gz",
      "target": "linux/amd64",
      "sha256": "abc123...",
      "size_bytes": 5242880,
      "archive_format": "tar.gz",
      "signed": true,
      "signature_file": "ntm-v1.2.3-linux-amd64.tar.gz.minisig"
    }
  ],
  "hosts": [
    {
      "host": "trj",
      "platform": "linux/amd64",
      "status": "success",
      "method": "act",
      "duration_ms": 60000,
      "workflow": ".github/workflows/release.yml",
      "job": "build-linux"
    },
    {
      "host": "mmini",
      "platform": "darwin/arm64",
      "status": "success",
      "method": "native-ssh",
      "duration_ms": 45000
    }
  ],
  "checksums_file": "ntm-v1.2.3-checksums.sha256",
  "signature_file": "ntm-v1.2.3-checksums.sha256.minisig",
  "sbom_file": "ntm-v1.2.3-sbom.json"
}
```

## SBOM (Software Bill of Materials)

Generated using `syft`:
```
{tool}-{version}-sbom.json
```

Format: SPDX JSON or CycloneDX JSON.

## Directory Structure

Release artifacts are organized as:
```
~/.local/state/dsr/artifacts/{tool}/{version}/
├── ntm-v1.2.3-linux-amd64.tar.gz
├── ntm-v1.2.3-linux-amd64.tar.gz.minisig
├── ntm-v1.2.3-darwin-arm64.tar.gz
├── ntm-v1.2.3-darwin-arm64.tar.gz.minisig
├── ntm-v1.2.3-windows-amd64.zip
├── ntm-v1.2.3-windows-amd64.zip.minisig
├── ntm-v1.2.3-checksums.sha256
├── ntm-v1.2.3-checksums.sha256.minisig
├── ntm-v1.2.3-manifest.json
└── ntm-v1.2.3-sbom.json
```

## Platform Targets

Standard targets supported by dsr:

| Target | OS | Arch | Archive | Host |
|--------|-----|------|---------|------|
| linux/amd64 | Linux | x86_64 | tar.gz | trj (act) |
| linux/arm64 | Linux | ARM64 | tar.gz | trj (act/QEMU) |
| darwin/arm64 | macOS | Apple Silicon | tar.gz | mmini |
| darwin/amd64 | macOS | Intel | tar.gz | mmini (Rosetta) |
| windows/amd64 | Windows | x86_64 | zip | wlap |

## Dual Naming for Install Script Compatibility

dsr uploads artifacts with TWO naming conventions to ensure compatibility with both explicit version downloads and install.sh scripts:

1. **Versioned name**: `{tool}-{version}-{os}-{arch}.{ext}` — For explicit version downloads
2. **Compat name**: `{tool}-{os}-{arch}.{ext}` — For install.sh scripts expecting unversioned names

### Configuration

Configure dual naming in `repos.d/{tool}.yaml`:

```yaml
tool_name: cass

# Versioned naming (for explicit downloads)
artifact_naming: "${name}-${version}-${os}_${arch}"

# Option 1: Explicit compat pattern (recommended for edge cases)
install_script_compat: "${name}-${os}-${arch}"

# Option 2: Auto-detect from install.sh (recommended for most cases)
install_script_path: install.sh
```

### Precedence Rules

When generating compat names, dsr uses this precedence:

1. **install_script_compat** — Explicit override, highest priority
2. **install_script_path** — Parse the script to auto-detect the expected pattern
3. **Fallback heuristic** — Strip version from artifact_naming

### Variable Substitution

Patterns support these variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `${name}` | Tool name | `cass` |
| `${version}` | Version (stripped of 'v' prefix) | `0.1.64` |
| `${os}` | Operating system | `darwin` |
| `${arch}` | Architecture | `arm64` |
| `${target}` | Combined os-arch | `darwin-arm64` |
| `${ext}` | File extension | `.tar.gz` |

### Examples

**Versioned downloads (explicit version):**
```
cass-0.1.64-darwin_arm64.tar.gz
rch-1.0.1-linux-amd64.tar.gz
```

**Install.sh compatible (unversioned):**
```
cass-darwin-arm64.tar.gz
rch-linux-amd64.tar.gz
```

### Checksums

Checksum files include entries for BOTH naming variants:
```
abc123...  cass-0.1.64-darwin_arm64.tar.gz
abc123...  cass-darwin-arm64.tar.gz
```

### Validation

Use `dsr repos validate` to check naming consistency:
```bash
# Validate all registered repos
dsr repos validate

# Validate specific repo
dsr repos validate --repo cass
```

## Validation

Artifact names can be validated against the regex:
```regex
^[a-z][a-z0-9_-]+-v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?-(linux|darwin|windows)-(amd64|arm64|386)(\.exe)?(\.tar\.gz|\.zip)?$
```

Example validation in bash:
```bash
validate_artifact_name() {
    local name="$1"
    local pattern='^[a-z][a-z0-9_-]+-v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?-(linux|darwin|windows)-(amd64|arm64|386)(\.exe)?(\.tar\.gz|\.zip)?$'
    [[ "$name" =~ $pattern ]]
}
```
