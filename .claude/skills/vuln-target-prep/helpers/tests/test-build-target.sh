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

# ---------------------------------------------------------------------------
# Fixture 4 (C1): src dir literally named "src" under parent "mylib"
# => basename would be "src"; walk-up logic must yield "mylib" instead.
# ---------------------------------------------------------------------------
src4="$tmp/srcproj/mylib/src"; mkdir -p "$src4"
cat > "$src4/parser.c" <<'C'
int mylib_parse(const char *b, long n) { return n > 0 ? b[0] : -1; }
C
cat > "$src4/Makefile" <<'MK'
CC?=cc
CFLAGS?=-g
libmylib.a: parser.o
	ar rcs $@ $^
parser.o: parser.c
	$(CC) $(CFLAGS) -c parser.c -o parser.o
MK
cat > "$src4/fingerprint.json" <<'JSON'
{"lang":"c","compiler":"cc","build_system":"make","deps":[],"missing_deps":[],"file_count":1,"loc":2}
JSON
out4="$tmp/out4"; mkdir -p "$out4"
set +e
bash "$build_target" "$src4" "$out4" "$src4/fingerprint.json" >"$out4/run.stdout" 2>"$out4/run.stderr"
rc4=$?
set -e
assert "$rc4" "0" "src-named (no arg4): build-target exits 0"
# the WHOLE POINT: artifact is mylib.a (parent), NOT the literal src.a
assert_file "$out4/mylib.a" "src-named (no arg4): artifact named after parent (mylib.a), not src.a"
if [ -f "$out4/src.a" ]; then echo "FAIL: src-named (no arg4): produced forbidden src.a" ; exit 1; fi
echo "PASS: src-named (no arg4): no src.a produced"

# arg 4 override: explicit name wins over both basename and walk-up
out4b="$tmp/out4b"; mkdir -p "$out4b"
set +e
bash "$build_target" "$src4" "$out4b" "$src4/fingerprint.json" "customname" >"$out4b/run.stdout" 2>"$out4b/run.stderr"
rc4b=$?
set -e
assert "$rc4b" "0" "src-named (arg4 override): build-target exits 0"
assert_file "$out4b/customname.a" "src-named (arg4 override): explicit name customname.a used"
if [ -f "$out4b/src.a" ] || [ -f "$out4b/mylib.a" ]; then
    echo "FAIL: src-named (arg4 override): arg4 should suppress src.a/mylib.a"; exit 1
fi
echo "PASS: src-named (arg4 override): no src.a/mylib.a produced"

# ---------------------------------------------------------------------------
# Fixture 5 (I2): relative out_dir must not break strategy A redirect
# ---------------------------------------------------------------------------
src5="$tmp/relout-lib"; mkdir -p "$src5"
cat > "$src5/parser.c" <<'C'
int relout_parse(const char *b, long n) { return n > 0 ? b[0] : -1; }
C
cat > "$src5/Makefile" <<'MK'
CC?=cc
CFLAGS?=-g
librelout.a: parser.o
	ar rcs $@ $^
parser.o: parser.c
	$(CC) $(CFLAGS) -c parser.c -o parser.o
MK
cat > "$src5/fingerprint.json" <<'JSON'
{"lang":"c","compiler":"cc","build_system":"make","deps":[],"missing_deps":[],"file_count":1,"loc":2}
JSON
# RELATIVE out_dir: build from inside src5's parent so "out_rel" is relative.
out5_rel="out_rel"; rm -rf "$tmp/out_rel_root"; mkdir -p "$tmp/out_rel_root"
set +e
( cd "$tmp/out_rel_root" && bash "$build_target" "$src5" "$out5_rel" "$src5/fingerprint.json" ) \
    >"$tmp/out5.stdout" 2>"$tmp/out5.stderr"
rc5=$?
set -e
assert "$rc5" "0" "relative out_dir: build-target exits 0 (strategy A)"
assert_file "$tmp/out_rel_root/$out5_rel/relout-lib.a" "relative out_dir: <name>.a produced (redirect resolved)"

echo "ALL PASS"
