#!/usr/bin/env bash
# test-recompute-stagnation.sh — assert stagnation bump/reset logic
set -euo pipefail

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helpers_dir="$(dirname "$__dir")"

assert() {
  if [ "$1" = "$2" ]; then echo "PASS: $3";
  else echo "FAIL: $3 (got '$1' want '$2')"; exit 1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- (a) crash:false benign, counter:1 -> expect 2 ---
cat > "$tmp/06-verification.yaml" <<'YAML'
rev: 1
last_run:
  poc_id: poc-x
  crash: false
  why_no_crash: "rejected at magic gate"
verdict: needs_more
YAML
cat > "$tmp/07-next-constraint.yaml" <<'YAML'
rev: 1
stagnation_counter: 1
next_iteration_must: []
open_hypotheses: []
YAML
out="$(bash "$helpers_dir/recompute-stagnation.sh" "$tmp/07-next-constraint.yaml" "$tmp/06-verification.yaml")"
assert "$out" "2" "benign run bumps counter 1->2"

# --- (b) crash:true, counter:3 -> expect 0 ---
cat > "$tmp/06b-verification.yaml" <<'YAML'
rev: 1
last_run:
  poc_id: poc-y
  crash: true
  crash_location: foo.c:10
verdict: converging
YAML
cat > "$tmp/07b-next-constraint.yaml" <<'YAML'
rev: 1
stagnation_counter: 3
next_iteration_must: []
open_hypotheses: []
YAML
out="$(bash "$helpers_dir/recompute-stagnation.sh" "$tmp/07b-next-constraint.yaml" "$tmp/06b-verification.yaml")"
assert "$out" "0" "crash resets counter 3->0"

echo "ALL PASS"
