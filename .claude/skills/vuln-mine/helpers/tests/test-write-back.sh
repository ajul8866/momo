#!/usr/bin/env bash
# test-write-back.sh — assert rev+lock append + concurrency safety
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

# helpers to read back YAML
yr() { python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))$1)" "$2"; }

# --- seed 04-candidate-poc.yaml with rev:1 and candidates:[{id:poc-1}] ---
cat > "$tmp/04-candidate-poc.yaml" <<'YAML'
rev: 1
candidates:
  - id: poc-1
verified_crashes: []
YAML

# record appending poc-2
cat > "$tmp/rec-2.json" <<'JSON'
{"candidates":[{"id":"poc-2","rationale":"x"}]}
JSON

bash "$helpers_dir/write-back.sh" "$tmp" candidate-poc "$tmp/rec-2.json" >/dev/null

rev="$(yr "['rev']" "$tmp/04-candidate-poc.yaml")"
assert "$rev" "2" "rev incremented 1->2 after one write"
ids="$(yr "['candidates']" "$tmp/04-candidate-poc.yaml")"
assert_contains "$ids" "poc-1" "poc-1 preserved"
assert_contains "$ids" "poc-2" "poc-2 appended"

# --- concurrency: two parallel writes appending poc-3 and poc-4 ---
cat > "$tmp/rec-3.json" <<'JSON'
{"candidates":[{"id":"poc-3"}]}
JSON
cat > "$tmp/rec-4.json" <<'JSON'
{"candidates":[{"id":"poc-4"}]}
JSON

bash "$helpers_dir/write-back.sh" "$tmp" candidate-poc "$tmp/rec-3.json" >/dev/null &
p1=$!
bash "$helpers_dir/write-back.sh" "$tmp" candidate-poc "$tmp/rec-4.json" >/dev/null &
p2=$!
wait "$p1"; wait "$p2"

rev="$(yr "['rev']" "$tmp/04-candidate-poc.yaml")"
assert "$rev" "4" "rev=4 after 3 total writes (seed was 1, no lost increment)"
ids="$(yr "['candidates']" "$tmp/04-candidate-poc.yaml")"
assert_contains "$ids" "poc-3" "poc-3 survived concurrent write"
assert_contains "$ids" "poc-4" "poc-4 survived concurrent write"
n="$(yr "['candidates']" "$tmp/04-candidate-poc.yaml" | python3 -c "import sys;print(len(__import__('ast').literal_eval(sys.stdin.read())))")"
assert "$n" "4" "exactly 4 candidates (no lost record, no dup)"

echo "ALL PASS"
