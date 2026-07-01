#!/usr/bin/env bash
# test-build-target.sh — build-target.sh fallback-chain A->B->C (deterministic)
set -euo pipefail

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helpers_dir="$(dirname "$__dir")"
build_target="$helpers_dir/build-target.sh"

assert() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (got '$1' want '$2')"; exit 1; fi; }
assert_contains() { if printf '%s' "$1" | grep -q -- "$2"; then echo "PASS: $3"; else echo "FAIL: $3 ('$1' missing '$2')"; exit 1; fi; }
assert_file() { if [ -f "$1" ]; then echo "PASS: $2"; else echo "FAIL: $2 (missing $1)"; exit 1; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------
# Fixture 1: tinylib — Makefile builds libtinylib.a  =>  Strategy A wins
# ---------------------------------------------------------------------------
src1="$tmp/tinylib"; mkdir -p "$src1"
cat > "$src1/parser.c" <<'C'
#include <string.h>
int tinylib_parse(const char *buf, long n) {
    if (n < 4) return -1;
    return buf[0] == 'N' && buf[1] == 'P' ? 0 : -1;
}
C
cat > "$src1/parser.h" <<'C'
#ifndef TINYLIB_PARSER_H
#define TINYLIB_PARSER_H
int tinylib_parse(const char *buf, long n);
#endif
C
cat > "$src1/Makefile" <<'MK'
CC?=cc
CFLAGS?=-g
libtinylib.a: parser.o
	ar rcs $@ $^
parser.o: parser.c
	$(CC) $(CFLAGS) -c parser.c -o parser.o
MK
cat > "$src1/fingerprint.json" <<'JSON'
{"lang":"c","compiler":"cc","build_system":"make","deps":[],"missing_deps":[],"file_count":2,"loc":6}
JSON
out1="$tmp/out1"; mkdir -p "$out1"
set +e
bash "$build_target" "$src1" "$out1" "$src1/fingerprint.json" >"$out1/run.stdout" 2>"$out1/run.stderr"
rc1=$?
set -e
assert "$rc1" "0" "tinylib: build-target exits 0 (Strategy A)"
assert_file "$out1/tinylib.a" "tinylib: <name>.a produced"
assert_contains "$(cat "$out1/build.log")" "STRATEGY A" "tinylib: build.log notes Strategy A"
# archive must contain at least one object
members1="$(ar t "$out1/tinylib.a" 2>/dev/null | tr '\n' ' ')"
assert_contains "$members1" "parser" "tinylib: archive contains parser object"

# ---------------------------------------------------------------------------
# Fixture 2: rawlib — two .c, no build file  =>  Strategy B wins
# ---------------------------------------------------------------------------
src2="$tmp/rawlib"; mkdir -p "$src2/include"
cat > "$src2/include/rawlib.h" <<'C'
#ifndef RAWLIB_H
#define RAWLIB_H
long rawlib_sum(const long *p, long n);
#endif
C
cat > "$src2/sum.c" <<'C'
#include "rawlib.h"
long rawlib_sum(const long *p, long n) {
    long s = 0; for (long i = 0; i < n; i++) s += p[i]; return s;
}
C
cat > "$src2/util.c" <<'C'
#include "rawlib.h"
long rawlib_double(long v) { return v * 2; }
C
cat > "$src2/fingerprint.json" <<'JSON'
{"lang":"c","compiler":"cc","build_system":"none","deps":[],"missing_deps":[],"file_count":2,"loc":8}
JSON
out2="$tmp/out2"; mkdir -p "$out2"
set +e
bash "$build_target" "$src2" "$out2" "$src2/fingerprint.json" >"$out2/run.stdout" 2>"$out2/run.stderr"
rc2=$?
set -e
assert "$rc2" "0" "rawlib: build-target exits 0 (Strategy B)"
assert_file "$out2/rawlib.a" "rawlib: <name>.a produced"
assert_contains "$(cat "$out2/build.log")" "STRATEGY B" "rawlib: build.log notes Strategy B"
members2="$(ar t "$out2/rawlib.a" 2>/dev/null | tr '\n' ' ')"
assert_contains "$members2" "sum" "rawlib: archive contains sum object"

# ---------------------------------------------------------------------------
# Fixture 3: badlib — #include <nonexistentlib.h>  =>  all strategies fail
# ---------------------------------------------------------------------------
src3="$tmp/badlib"; mkdir -p "$src3"
cat > "$src3/bad.c" <<'C'
#include <nonexistentlib.h>
int badlib_run(const char *b, long n) { return nonexistent_func(b, n); }
C
cat > "$src3/fingerprint.json" <<'JSON'
{"lang":"c","compiler":"cc","build_system":"none","deps":[],"missing_deps":[],"file_count":1,"loc":3}
JSON
out3="$tmp/out3"; mkdir -p "$out3"
set +e
bash "$build_target" "$src3" "$out3" "$src3/fingerprint.json" >"$out3/run.stdout" 2>"$out3/run.stderr"
rc3=$?
set -e
assert "$rc3" "1" "badlib: build-target exits 1 (all strategies fail)"
assert_file "$out3/build.log" "badlib: build.log written on failure"
log3="$(cat "$out3/build.log")"
assert_contains "$log3" "nonexistentlib.h" "badlib: build.log mentions missing header"
assert_contains "$log3" "apt install" "badlib: build.log suggests apt install"

echo "ALL PASS"
