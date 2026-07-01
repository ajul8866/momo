#!/usr/bin/env bash
# test-init-memory.sh — integration test for init-memory.sh
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILL_DIR="$(cd "$HELPERS_DIR/.." && pwd)"

assert() { # assert <description> <command...>
  local desc="$1"; shift
  if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; exit 1; fi
}

manifest="$SKILL_DIR/manifests/example/manifest.yaml"
run_dir="$(mktemp -d)"
trap 'rm -rf "$run_dir"' EXIT

# Precondition: example binary built in Task 8.
if [ ! -x "$SKILL_DIR/manifests/example/naiveparse" ]; then
  echo "FAIL: precondition naiveparse binary missing; run Task 8 build.sh first"
  exit 1
fi

# Run init-memory.
bash "$HELPERS_DIR/init-memory.sh" "$manifest" "$run_dir"

# 1. all 7 files exist
for f in 01-goal 02-code-path 03-input-format 04-candidate-poc 05-negative 06-verification 07-next-constraint; do
  assert "file $f.yaml exists" test -f "$run_dir/$f.yaml"
done

# 2. 01-goal.target.binary matches manifest (resolved absolute, manifest-dir-relative)
expected_bin="$(cd "$SKILL_DIR/manifests/example" && realpath naiveparse)"
got_bin=$(python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['target']['binary'])" "$run_dir/01-goal.yaml")
assert "01-goal.target.binary == $expected_bin" [ "$got_bin" = "$expected_bin" ]

# 3. 07-next-constraint.next_iteration_must is non-empty
nim=$(python3 -c "import yaml,sys;print(len(yaml.safe_load(open(sys.argv[1]))['next_iteration_must']))" "$run_dir/07-next-constraint.yaml")
assert "07 next_iteration_must non-empty" [ "$nim" -gt 0 ]

# 4. 03-input-format.format == manifest spec (NPv1)
fmt=$(python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['format'])" "$run_dir/03-input-format.yaml")
assert "03 format == NPv1" [ "$fmt" = "NPv1" ]

# 5. scaffold dirs created
assert "pocs/ exists"  test -d "$run_dir/pocs"
assert ".locks/ exists" test -d "$run_dir/.locks"

# 6. all 7 files parse as valid YAML (non-empty mappings)
for f in 01-goal 02-code-path 03-input-format 04-candidate-poc 05-negative 06-verification 07-next-constraint; do
  assert "$f.yaml parses as YAML mapping" python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert isinstance(d, dict) and d, sys.argv[1]
' "$run_dir/$f.yaml"
done

echo "ALL PASS: init-memory"
