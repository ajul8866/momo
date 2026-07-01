#!/usr/bin/env bash
# test-lib-yaml.sh — pure bash asserts, no framework.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../helpers/lib-yaml.sh"

pass=0; fail=0
assert() { # name condition
  local name="$1"; shift
  if eval "$@"; then
    echo "PASS: $name"; pass=$((pass+1))
  else
    echo "FAIL: $name -- condition failed: $*"; fail=$((fail+1))
  fi
}
finish() { [ "$fail" -eq 0 ] && echo "ok ($pass passed)" || { echo "NOT OK ($fail failed)"; exit 1; }; }
trap finish EXIT

# fixture: known values we read back
FIX="$(mktemp -d)/goal.yaml"
cat > "$FIX" <<'YAML'
rev: 3
target:
  binary: /bin/true
  harness_cmd: "{{binary}} {{input}}"
  sanitizer: asan
  build_ok: false
YAML

# yaml_get reads nested known value
v="$(yaml_get "$FIX" target.binary)"
assert "yaml_get nested path returns /bin/true" "[ '$v' = '/bin/true' ]"

# yaml_get reads a top-level scalar
r="$(yaml_get "$FIX" rev)"
assert "yaml_get top-level scalar returns 3" "[ '$r' = '3' ]"

# yaml_set_kv writes a top-level scalar and round-trips
yaml_set_kv "$FIX" rev 7
r2="$(yaml_get "$FIX" rev)"
assert "yaml_set_kv updates scalar to 7" "[ '$r2' = '7' ]"

# yaml_new_run_id matches the documented format
id="$(yaml_new_run_id)"
assert "yaml_new_run_id matches r-YYYYMMDD-HHMMSS" \
       "[[ \"\$id\" =~ ^r-[0-9]{8}-[0-9]{6}\$ ]]"
