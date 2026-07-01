#!/usr/bin/env bash
# test-smoke-prep.sh — end-to-end prep smoke test on local fixture (no network).
# Proves: fingerprint -> build -> harness compile -> verify-crash -> manifest emit
#         -> vuln-mine validate-manifest.sh EXIT 0 (cross-skill contract).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="$(cd "$TEST_DIR/.." && pwd)"
PREP_DIR="$(cd "$HELPERS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PREP_DIR/../../.." && pwd)"
MINE_DIR="$REPO_ROOT/.claude/skills/vuln-mine"

FIX="$TEST_DIR/fixtures/sample-repo"

assert() { # assert <description> <command...>
  local desc="$1"; shift
  if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; exit 1; fi
}

run="$(mktemp -d)"
trap 'rm -rf "$run"' EXIT

# 1. fingerprint.sh on the fixture -> lang=c
fp_json="$run/fingerprint.json"
bash "$HELPERS_DIR/fingerprint.sh" "$FIX" > "$fp_json"
echo "info: $(cat "$fp_json")"
# jq is available per brief tooling; used only for a readable assertion.
lang="$(jq -r '.lang' "$fp_json")"
assert "fingerprint lang == c" [ "$lang" = "c" ]
build_system="$(jq -r '.build_system' "$fp_json")"
echo "info: build_system=$build_system"

# 2. build-target.sh -> strategy A (Makefile) should win -> .a produced
build_out="$run/build_out"
mkdir -p "$build_out"
bash "$HELPERS_DIR/build-target.sh" "$FIX" "$build_out" "$fp_json" >&2
# Strategy A copies the produced .a to <name>.a where name=basename(cwd of src).
# src-dir basename is "sample-repo" -> sample-repo.a
lib=""
for cand in "$build_out"/sample-repo.a "$build_out"/*.a; do
  [ -f "$cand" ] || continue
  lib="$cand"; break
done
assert "build produced .a" [ -n "$lib" ] && test -f "$lib"
echo "info: lib=$lib"

# Clean any prior Makefile build artifacts in the fixture dir so the test is
# reproducible across re-runs (build-target leaves parse_thing.o behind via make).
( cd "$FIX" && make clean >/dev/null 2>&1 ) || true

# 3. inline harness.c that calls parse_thing(buf,n), argv[1]=file.
MAN_DIR="$run/manifest"
mkdir -p "$MAN_DIR"
cat > "$MAN_DIR/harness.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include "parse_thing.h"
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(n ? n : 1);
    if (!buf) { fclose(f); return 2; }
    fread(buf, 1, n, f);
    fclose(f);
    parse_thing(buf, n);
    free(buf);
    return 0;
}
C
cc -fsanitize=address -g -O1 -I"$FIX" "$MAN_DIR/harness.c" "$lib" -o "$MAN_DIR/sample_fuzz"
assert "harness binary built" test -x "$MAN_DIR/sample_fuzz"

# 4a. valid input -> verify-crash.sh reports EXIT=0
# PTv1 + len=1 (01 00) + 0x41 -> 7 bytes, fits in 64-byte buffer.
printf 'PTv1\x01\x00A' > "$MAN_DIR/valid.bin"
out=$(bash "$HELPERS_DIR/verify-crash.sh" "$MAN_DIR/sample_fuzz" "$MAN_DIR/valid.bin" 10)
echo "info: valid -> $out"
case "$out" in
  EXIT=0\|*) echo "PASS: valid input EXIT=0" ;;
  *) echo "FAIL: valid input crashed (expected EXIT=0): $out"; exit 1 ;;
esac

# 4b. hostile input -> expect crash (L=128 overflows 64-byte buffer).
# PTv1 + len=128 (80 00) + 128 'A's.
{ printf 'PTv1\x80\x00'; head -c 128 /dev/zero | tr '\0' 'A'; } > "$MAN_DIR/hostile.bin"
out=$(bash "$HELPERS_DIR/verify-crash.sh" "$MAN_DIR/sample_fuzz" "$MAN_DIR/hostile.bin" 10)
echo "info: hostile -> $out"
case "$out" in
  EXIT=134\|*SIGABRT*|EXIT=*SIGSEGV*) echo "PASS: hostile input crashes" ;;
  *) echo "FAIL: hostile input did not crash: $out"; exit 1 ;;
esac

# 5. emit manifest.yaml + format.grammar.yaml into MAN_DIR.
# Binary path is RELATIVE to manifest dir (validate-manifest resolves it that way,
# matching init-memory.sh: run from within the manifest dir).
cat > "$MAN_DIR/manifest.yaml" <<'YAML'
name: sample
binary: sample_fuzz
harness_cmd: "{{binary}} {{input}}"
sanitizer: asan
timeout_sec: 10
input_format:
  spec_file: format.grammar.yaml
success_condition:
  kind: crash
  acceptable_signals: [SIGABRT, SIGSEGV]
budget:
  max_iterations: 6
YAML

cat > "$MAN_DIR/format.grammar.yaml" <<'YAML'
format: PTv1
grammar:
  - magic: "PTv1"
  - len: u16-le
  - payload: bytes[len]
field_constraints:
  - {field: "len", type: u16-le, min: 0, max: 65535, boundary_values: [0, 1, 63, 64, 65, 128, 0xffff]}
known_valid_patterns:
  - "magic 'PTv1' + len=1 (01 00) + 0x41"
known_invalid_patterns:
  - "missing/wrong magic -> rejected at gate, never reaches parser"
  - "len declared but fewer len payload bytes present -> truncated, returns 3 early"
YAML

# 6. FINAL GATE: vuln-mine validate-manifest.sh MUST exit 0.
# validate-manifest.sh resolves binary/spec_file relative to the manifest dir,
# so cd in (same cwd-relative resolution init-memory.sh relies on).
if ( cd "$MAN_DIR" && bash "$MINE_DIR/helpers/validate-manifest.sh" manifest.yaml ); then
  echo "PASS: validate-manifest.sh exit 0 (cross-skill contract holds)"
else
  echo "FAIL: validate-manifest.sh rejected emitted manifest"
  exit 1
fi

echo "smoke-prep: end-to-end OK"
