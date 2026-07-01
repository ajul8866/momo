#!/usr/bin/env bash
# parse-sanitizer.sh — extract sanitizer kind + crash_location from an stderr log
# Usage: parse-sanitizer.sh <stderr.log>
# Prints exactly one line: "kind=<k>|at=<loc>"  (fields empty when nothing matched)
set -euo pipefail

log="${1:-/dev/stdin}"
[ -f "$log" ] || log=/dev/stdin

# kind: capture group 2 of "ERROR: <Sanitizer>: <kind>"
kind="$(grep -m1 -oP 'ERROR: (AddressSanitizer|MemorySanitizer|UndefinedBehaviorSanitizer): \K[A-Za-z0-9_-]+' "$log" 2>/dev/null || true)"

# location: first "#0 ... in <fn> <file:line>"
loc_fn="$(grep -m1 -oP '#0 .* in \K\S+' "$log" 2>/dev/null || true)"
loc_fl="$(grep -m1 -oP '#0 .* in \S+ \K\S+:\d+' "$log" 2>/dev/null || true)"

if [ -n "$loc_fn" ] && [ -n "$loc_fl" ]; then
  at="$loc_fn $loc_fl"
elif [ -n "$loc_fl" ]; then
  at="$loc_fl"
else
  at=""
fi

echo "kind=${kind}|at=${at}"
