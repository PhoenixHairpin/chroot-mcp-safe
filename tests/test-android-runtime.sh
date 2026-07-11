#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
script="$repo_dir/chroot-mcp-safe.sh"
failures=0

check_contains() {
  local description="$1" pattern="$2"
  if ! grep -Fq -- "$pattern" "$script"; then
    printf 'FAIL: %s\n' "$description" >&2
    failures=$((failures + 1))
  fi
}

check_contains "Android command path includes product binaries" '/product/bin'
check_contains "Android command path includes system_ext binaries" '/system_ext/bin'
check_contains "Android command path includes odm binaries" '/odm/bin'
check_contains "Android command path includes vendor binaries" '/vendor/bin:/vendor/xbin'
check_contains "persistent Android environment is prepared" 'prepare_android_runtime_env'
check_contains "am and dumpsys remain available through stable wrappers" 'for name in am dumpsys cmd settings pm getprop'
check_contains "vendor_dlkm is exposed when present" '/vendor_dlkm'
check_contains "system_dlkm is exposed when present" '/system_dlkm'
check_contains "odm_dlkm is exposed when present" '/odm_dlkm'

if ((failures > 0)); then
  printf '%d Android runtime integration check(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'Android runtime integration checks passed\n'
