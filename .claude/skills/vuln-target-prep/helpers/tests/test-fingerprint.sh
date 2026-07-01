#!/usr/bin/env bash
# test-fingerprint.sh — assert fingerprint.sh detects lang/compiler/build_system (spec §4.1, §7.1)
set -euo pipefail

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helpers_dir="$(dirname "$__dir")"

assert_contains() {
  if printf '%s' "$1" | grep -q -- "$2"; then echo "PASS: $3";
  else echo "FAIL: $3 ('$1' missing '$2')"; exit 1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# (a) tiny C project: CMakeLists.txt + 2 .c files -> cmake
proj_a="$tmp/proj_cmake"
mkdir -p "$proj_a"
cat > "$proj_a/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.10)
project(tiny C)
CMAKE
cat > "$proj_a/a.c" <<'C'
#include <stdio.h>
int a_fn(void) { return 1; }
C
cat > "$proj_a/b.c" <<'C'
#include <stdio.h>
int b_fn(void) { return 2; }
C
out="$(bash "$helpers_dir/fingerprint.sh" "$proj_a")"
assert_contains "$out" '"lang": "c"'           "(a) lang=c"
assert_contains "$out" '"compiler": "cc"'      "(a) compiler=cc"
assert_contains "$out" '"build_system": "cmake"' "(a) build_system=cmake"

# (b) Makefile + .c -> make
proj_b="$tmp/proj_make"
mkdir -p "$proj_b"
cat > "$proj_b/Makefile" <<'MAKE'
all: prog
prog: m.c
	cc -o prog m.c
MAKE
cat > "$proj_b/m.c" <<'C'
#include <stdio.h>
int main(void){ return 0; }
C
out="$(bash "$helpers_dir/fingerprint.sh" "$proj_b")"
assert_contains "$out" '"build_system": "make"' "(b) build_system=make"

# (c) no build file + .c -> raw
proj_c="$tmp/proj_raw"
mkdir -p "$proj_c"
cat > "$proj_c/lonely.c" <<'C'
#include <stdlib.h>
int lonely(void){ return 42; }
C
out="$(bash "$helpers_dir/fingerprint.sh" "$proj_c")"
assert_contains "$out" '"build_system": "raw"' "(c) build_system=raw"

# (d) pure python -> lang=python (NOT c/c++)
proj_d="$tmp/proj_py"
mkdir -p "$proj_d"
cat > "$proj_d/app.py" <<'PY'
print("hi")
PY
out="$(bash "$helpers_dir/fingerprint.sh" "$proj_d")"
assert_contains "$out" '"lang": "python"' "(d) lang=python"

echo "ALL PASS"
