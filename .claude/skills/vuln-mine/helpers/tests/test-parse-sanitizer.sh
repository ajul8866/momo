#!/usr/bin/env bash
# test-parse-sanitizer.sh — assert kind + crash_location extraction
set -euo pipefail

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helpers_dir="$(dirname "$__dir")"

assert() {
  if [ "$1" = "$2" ]; then echo "PASS: $3";
  else echo "FAIL: $3 (got '$1' want '$2')"; exit 1; fi
}
assert_contains() {
  if printf '%s' "$1" | grep -q -- "$2"; then echo "PASS: $3";
  else echo "FAIL: $3 ('$1' missing '$2')"; exit 1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- fixture 1: trimmed real ASan report ---
cat > "$tmp/asan.err" <<'EOF'
=================================================================
==12345==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x6020000000f4
READ of size 4 at 0x6020000000f4 thread T0
    #0 0x4a2d3a in png_inflate_IDAT pngread.c:419
    #1 0x4a3010 in png_read_chunk pngread.c:301
    #2 0x4a31ff in main harness.c:50
EOF
line="$(bash "$helpers_dir/parse-sanitizer.sh" "$tmp/asan.err")"
assert "$(printf '%s' "$line" | cut -d'|' -f1)" "kind=heap-buffer-overflow" "ASan kind extracted"
assert_contains "$line" "pngread.c:419" "ASan crash_location contains file:line"

# --- fixture 2: empty file ---
: > "$tmp/empty.err"
line="$(bash "$helpers_dir/parse-sanitizer.sh" "$tmp/empty.err")"
assert "$line" "kind=|at=" "empty stderr -> empty fields"

# --- fixture 3: UBSan only ---
cat > "$tmp/ubsan.err" <<'EOF'
==999==ERROR: UndefinedBehaviorSanitizer: signed-integer-overflow on ...
    #0 0x4a2d3a in do_math math.c:88
EOF
line="$(bash "$helpers_dir/parse-sanitizer.sh" "$tmp/ubsan.err")"
assert "$(printf '%s' "$line" | cut -d'|' -f1)" "kind=signed-integer-overflow" "UBSan kind extracted"

echo "ALL PASS"
