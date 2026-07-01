#!/usr/bin/env bash
# test-classify-result.sh — deterministic crash/benign/hang classification (I1/I3)
set -euo pipefail

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helpers_dir="$(dirname "$__dir")"

assert_contains() {
  if printf '%s' "$1" | grep -q -- "$2"; then echo "PASS: $3";
  else echo "FAIL: $3 ('$1' missing '$2')"; exit 1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# goal with success_condition: crash + acceptable_signals [SIGABRT]
cat > "$tmp/goal.yaml" <<'YAML'
rev: 1
target:
  binary: /bin/true
success_condition:
  kind: crash
  must_reach: null
  acceptable_signals:
    - SIGABRT
YAML

# 1) crash: exit 134 + ASan stderr + SIGABRT acceptable -> verified_crash
cat > "$tmp/asan.err" <<'ERR'
==123==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x...
WRITE of size 4
    #0 0x400b3a in parse_chunk pngread.c:42
    #1 0x400c11 in main main.c:10
ERR
out="$(bash "$helpers_dir/classify-result.sh" "$tmp/goal.yaml" 134 "$tmp/asan.err")"
assert_contains "$out" "crash=true"   "ASan crash: crash=true"
assert_contains "$out" "signal=SIGABRT" "134 normalizes to SIGABRT (I3)"
assert_contains "$out" "sanitizer=heap-buffer-overflow" "sanitizer kind extracted"
assert_contains "$out" "at=parse_chunk pngread.c:42" "crash location extracted"
assert_contains "$out" "verdict=verified_crash" "signal in acceptable_signals -> verified_crash"

# 2) benign: exit 0, empty stderr -> verdict=benign
printf '' > "$tmp/empty.err"
out="$(bash "$helpers_dir/classify-result.sh" "$tmp/goal.yaml" 0 "$tmp/empty.err")"
assert_contains "$out" "crash=false"  "exit 0: crash=false"
assert_contains "$out" "signal="      "exit 0: signal empty"
assert_contains "$out" "verdict=benign" "exit 0: verdict=benign"

# 3) hang: exit 124 -> needs_more
out="$(bash "$helpers_dir/classify-result.sh" "$tmp/goal.yaml" 124 "$tmp/empty.err")"
assert_contains "$out" "crash=true"      "timeout: crash=true"
assert_contains "$out" "signal=TIMEOUT"  "124 normalizes to TIMEOUT (I3)"
assert_contains "$out" "verdict=needs_more" "timeout: verdict=needs_more"

# 4) crash whose signal is NOT in acceptable_signals -> not verified
#    exit 139 = SIGSEGV (128+11), acceptable only SIGABRT
cat > "$tmp/segv.err" <<'ERR'
==456==ERROR: AddressSanitizer: SEGV on unknown address 0x0
    #0 0x400b3a in deref_null ptr.c:7
ERR
out="$(bash "$helpers_dir/classify-result.sh" "$tmp/goal.yaml" 139 "$tmp/segv.err")"
assert_contains "$out" "crash=true"             "SEGV: crash=true"
assert_contains "$out" "signal=SIGSEGV"         "139 normalizes to SIGSEGV"
assert_contains "$out" "verdict=not_verified_crash" "SIGSEGV not in [SIGABRT] -> not verified"

# 5) crash with empty acceptable_signals -> any signal verified
cat > "$tmp/goal-any.yaml" <<'YAML'
rev: 1
target: {binary: /bin/true}
success_condition:
  kind: crash
  must_reach: null
  acceptable_signals: []
YAML
out="$(bash "$helpers_dir/classify-result.sh" "$tmp/goal-any.yaml" 139 "$tmp/segv.err")"
assert_contains "$out" "verdict=verified_crash" "empty acceptable_signals -> any crash verified"

echo "ALL PASS"
