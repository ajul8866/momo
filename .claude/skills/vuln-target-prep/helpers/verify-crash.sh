#!/usr/bin/env bash
# verify-crash.sh — run a binary on an input, classify exit/signal/sanitizer (spec §7.1)
# Usage: verify-crash.sh <binary> <input> <timeout_sec>
# Prints exactly one line: EXIT=<n>|SIGNAL=<name>|ASAN=<bool>
#
# Mirrors vuln-mine run-harness.sh + classify-result.sh signal normalization:
#   - timeout -> 124 -> SIGNAL=TIMEOUT
#   - exit >= 128 -> signal = exit-128 -> mapped name
#   - ASan/MSan/UBSan line in stderr -> ASAN=true
# ASan abort_on_error is forced (when caller hasn't set ASAN_OPTIONS) so an
# instrumented bug surfaces as SIGABRT/134, matching vuln-mine's contract.
set -euo pipefail

binary="${1:?usage: verify-crash.sh <binary> <input> <timeout_sec>}"
input="${2:?usage: verify-crash.sh <binary> <input> <timeout_sec>}"
timeout_sec="${3:?usage: verify-crash.sh <binary> <input> <timeout_sec>}"

[ -x "$binary" ] || { echo "verify-crash: binary not executable: $binary" >&2; exit 2; }
# Accept regular files AND character/block devices (e.g. /dev/null), but still
# reject missing or non-existent paths — input validation at the trust boundary.
if ! [ -e "$input" ] || [ -d "$input" ]; then
  echo "verify-crash: input not found: $input" >&2; exit 2
fi

# Force ASan to abort (->SIGABRT/134) when caller hasn't configured it,
# exactly like vuln-mine/helpers/run-harness.sh does for sanitizer==asan.
if [ -z "${ASAN_OPTIONS:-}" ]; then
  export ASAN_OPTIONS="abort_on_error=1"
fi

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

set +e
timeout "$timeout_sec" "$binary" "$input" >/dev/null 2>"$err_file"
code=$?
set -e

# --- signal normalization (classify-result.sh I3 logic) ---
sig="NONE"
if [ "$code" -eq 124 ]; then
  sig="TIMEOUT"
elif [ "$code" -ge 128 ]; then
  s=$((code - 128))
  case "$s" in
    9)  sig="SIGKILL";;
    11) sig="SIGSEGV";;
    6)  sig="SIGABRT";;
    8)  sig="SIGFPE";;
    7)  sig="SIGBUS";;
    4)  sig="SIGILL";;
    15) sig="SIGTERM";;
    1)  sig="SIGHUP";;
    3)  sig="SIGQUIT";;
    10) sig="SIGUSR1";;
    12) sig="SIGUSR2";;
    *)  sig="SIG$s";;
  esac
fi

# --- sanitizer detection ---
asan=false
if grep -Eq 'ERROR: (AddressSanitizer|MemorySanitizer|UndefinedBehaviorSanitizer)' "$err_file"; then
  asan=true
fi

printf 'EXIT=%s|SIGNAL=%s|ASAN=%s\n' "$code" "$sig" "$asan"
