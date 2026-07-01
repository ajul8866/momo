#!/usr/bin/env bash
# test-verify-crash.sh — assert verify-crash.sh classifies exit/signal/sanitizer (spec §7.1)
set -euo pipefail

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helpers_dir="$(dirname "$__dir")"

assert_eq() {  # assert_eq <actual> <expected> <label>
  if [ "$1" = "$2" ]; then echo "PASS: $3";
  else echo "FAIL: $3 (got '$1' want '$2')"; exit 1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1) /bin/true on /dev/null -> EXIT=0 | SIGNAL=NONE | ASAN=false
line="$(bash "$helpers_dir/verify-crash.sh" /bin/true /dev/null 5)"
assert_eq "$line" "EXIT=0|SIGNAL=NONE|ASAN=false" "true -> clean exit"

# 2) /bin/false on /dev/null -> EXIT=1 | SIGNAL=NONE | ASAN=false
line="$(bash "$helpers_dir/verify-crash.sh" /bin/false /dev/null 5)"
assert_eq "$line" "EXIT=1|SIGNAL=NONE|ASAN=false" "false -> benign nonzero"

# 3) a slow script killed by timeout -> EXIT=124 | SIGNAL=TIMEOUT | ASAN=false
cat > "$tmp/slow.sh" <<'SH'
#!/bin/sh
sleep 30
SH
chmod +x "$tmp/slow.sh"
line="$(bash "$helpers_dir/verify-crash.sh" "$tmp/slow.sh" /dev/null 1)"
assert_eq "$line" "EXIT=124|SIGNAL=TIMEOUT|ASAN=false" "timeout -> 124/TIMEOUT"

# 4) a tiny out-of-bounds heap write compiled with -fsanitize=address
#    -> ASan aborts -> EXIT=134 | SIGNAL=SIGABRT | ASAN=true
cat > "$tmp/oob.c" <<'C'
#include <stdlib.h>
int main(int argc, char **argv) {
    char *p = (char *)malloc(4);
    p[64] = 'x';          /* heap-buffer-overflow, reliably caught by ASan */
    return (int)p[0];
}
C
cc -fsanitize=address -g -O0 -o "$tmp/oob" "$tmp/oob.c"
: > "$tmp/in.bin"        # input file (program ignores argv[1])
line="$(bash "$helpers_dir/verify-crash.sh" "$tmp/oob" "$tmp/in.bin" 10)"
assert_eq "$line" "EXIT=134|SIGNAL=SIGABRT|ASAN=true" "ASan OOB -> 134/SIGABRT"

echo "ALL PASS"
