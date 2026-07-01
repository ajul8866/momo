#!/usr/bin/env bash
# test-recompute-stagnation.sh — assert stagnation bump/reset logic + PERSISTENCE
set -euo pipefail

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helpers_dir="$(dirname "$__dir")"

assert() {
  if [ "$1" = "$2" ]; then echo "PASS: $3";
  else echo "FAIL: $3 (got '$1' want '$2')"; exit 1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# helper: read persisted stagnation_counter from a 07 yaml
read_counter() {
  python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['stagnation_counter'])" "$1"
}

# --- (a) crash:false benign, counter:1 -> expect 2 (and persisted) ---
cat > "$tmp/06-verification.yaml" <<'YAML'
rev: 1
runs:
  - poc_id: poc-x
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
assert "$(read_counter "$tmp/07-next-constraint.yaml")" "2" "counter PERSISTED to 07.yaml (benign)"

# --- (b) crash:true, counter:3 -> expect 0 ---
cat > "$tmp/06b-verification.yaml" <<'YAML'
rev: 1
runs:
  - poc_id: poc-y
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
assert "$(read_counter "$tmp/07b-next-constraint.yaml")" "0" "counter PERSISTED to 07.yaml (crash reset)"

# --- (c) persistence across two sequential benign runs: 0->1, then 1->2 ---
cat > "$tmp/06c-verification.yaml" <<'YAML'
rev: 1
runs:
  - poc_id: poc-a
    crash: false
    why_no_crash: "no evidence"
    verdict: needs_more
YAML
cat > "$tmp/07c-next-constraint.yaml" <<'YAML'
rev: 0
stagnation_counter: 0
next_iteration_must: []
open_hypotheses: []
YAML
out1="$(bash "$helpers_dir/recompute-stagnation.sh" "$tmp/07c-next-constraint.yaml" "$tmp/06c-verification.yaml")"
assert "$out1" "1" "first benign run: counter persisted 0->1"
assert "$(read_counter "$tmp/07c-next-constraint.yaml")" "1" "first run counter persisted"
out2="$(bash "$helpers_dir/recompute-stagnation.sh" "$tmp/07c-next-constraint.yaml" "$tmp/06c-verification.yaml")"
assert "$out2" "2" "second benign run reads persisted 1 -> 2 (no reset to 0)"
assert "$(read_counter "$tmp/07c-next-constraint.yaml")" "2" "second run counter persisted"

# --- (d) after benign runs, a crash run resets persisted counter to 0 ---
cat > "$tmp/06d-verification.yaml" <<'YAML'
rev: 1
runs:
  - poc_id: poc-crash
    crash: true
    crash_location: bar.c:55
    verdict: converging
YAML
out3="$(bash "$helpers_dir/recompute-stagnation.sh" "$tmp/07c-next-constraint.yaml" "$tmp/06d-verification.yaml")"
assert "$out3" "0" "crash run resets persisted counter to 0"
assert "$(read_counter "$tmp/07c-next-constraint.yaml")" "0" "crash reset persisted"

echo "ALL PASS"
