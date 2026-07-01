#!/usr/bin/env bash
# test-run-harness.sh — assert run-harness exit reporting + stream capture
set -euo pipefail

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helpers_dir="$(dirname "$__dir")"

# tiny assert: prints PASS/FAIL, exits 1 on failure
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

# --- fixture: goal.yaml using /bin/cat as the harness binary ---
cat > "$tmp/goal.yaml" <<'YAML'
rev: 1
target:
  binary: /bin/cat
  harness_cmd: "{{binary}} {{input}}"
  sanitizer: none
  build_ok: true
YAML
printf 'hello\n' > "$tmp/poc.txt"

# 1) cat-based harness, valid poc -> EXIT=0
# (`|| true` because the harness exits with the run code; set -e would abort.)
out="$(bash "$helpers_dir/run-harness.sh" "$tmp/goal.yaml" "$tmp/poc.txt" 5)" || true
assert "$out" "EXIT=0" "cat harness returns EXIT=0"

# stdout captured to .runs/<stem>.out
stem="$(basename "$tmp/poc.txt")"; stem="${stem%.*}"
assert "$(cat "$tmp/.runs/$stem.out")" "hello" "stdout captured to .runs/<stem>.out"

# 2) /bin/false harness -> EXIT=1
cat > "$tmp/goal-false.yaml" <<'YAML'
rev: 1
target:
  binary: /bin/false
  harness_cmd: "{{binary}}"
  sanitizer: none
  build_ok: true
YAML
out="$(bash "$helpers_dir/run-harness.sh" "$tmp/goal-false.yaml" "$tmp/poc.txt" 5)" || true
assert "$out" "EXIT=1" "/bin/false returns EXIT=1"

# 3) hanging command (sleep 5) with timeout 1 -> EXIT=124
cat > "$tmp/goal-hang.yaml" <<'YAML'
rev: 1
target:
  binary: /bin/sleep
  harness_cmd: "{{binary}} 5"
  sanitizer: none
  build_ok: true
YAML
out="$(bash "$helpers_dir/run-harness.sh" "$tmp/goal-hang.yaml" "$tmp/poc.txt" 1)" || true
assert "$out" "EXIT=124" "timeout kill returns EXIT=124"

echo "ALL PASS"
