#!/usr/bin/env bash
# test-validate-manifest.sh — pure bash asserts, no framework.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VALIDATE="$HERE/../../helpers/validate-manifest.sh"
FIX="$HERE/fixtures/validate"
mkdir -p "$FIX"

pass=0; fail=0
assert_exit() { # name  expected_exit  manifest_path
  local name="$1" want="$2" man="$3" got
  if "$VALIDATE" "$man" >/dev/null 2>&1; then got=0; else got=$?; fi
  if [ "$got" = "$want" ]; then echo "PASS: $name"; pass=$((pass+1));
  else echo "FAIL: $name -- expected exit $want, got $got"; fail=$((fail+1)); fi
}
finish() { [ "$fail" -eq 0 ] && echo "ok ($pass passed)" || { echo "NOT OK ($fail failed)"; exit 1; }; }
trap finish EXIT

# shared, valid input_format spec
cat > "$FIX/spec.yaml" <<'YAML'
format: raw-argv
YAML

# 1) GOOD manifest -> exit 0
cat > "$FIX/good.yaml" <<YAML
name: echo-target
binary: /bin/echo
harness_cmd: "{{binary}} {{input}}"
sanitizer: none
input_format:
  spec_file: $FIX/spec.yaml
success_condition:
  kind: crash
budget:
  max_iterations: 10
YAML
assert_exit "good manifest passes" 0 "$FIX/good.yaml"

# 2) MISSING binary path -> exit 1
cat > "$FIX/missing-binary.yaml" <<YAML
name: echo-target
binary: /no/such/binary
harness_cmd: "{{binary}} {{input}}"
sanitizer: none
input_format:
  spec_file: $FIX/spec.yaml
success_condition:
  kind: crash
budget:
  max_iterations: 10
YAML
assert_exit "missing binary fails" 1 "$FIX/missing-binary.yaml"

# 3) INJECTION in harness_cmd -> exit 1
cat > "$FIX/injection.yaml" <<YAML
name: echo-target
binary: /bin/echo
harness_cmd: "a; rm -rf /"
sanitizer: none
input_format:
  spec_file: $FIX/spec.yaml
success_condition:
  kind: crash
budget:
  max_iterations: 10
YAML
assert_exit "injection harness_cmd fails" 1 "$FIX/injection.yaml"

# 4) BAD sanitizer -> exit 1
cat > "$FIX/bad-san.yaml" <<YAML
name: echo-target
binary: /bin/echo
harness_cmd: "{{binary}} {{input}}"
sanitizer: heap-sanitizer-v2
input_format:
  spec_file: $FIX/spec.yaml
success_condition:
  kind: crash
budget:
  max_iterations: 10
YAML
assert_exit "bad sanitizer fails" 1 "$FIX/bad-san.yaml"

# 5) MISSING required key (no budget) -> exit 1
cat > "$FIX/missing-key.yaml" <<YAML
name: echo-target
binary: /bin/echo
harness_cmd: "{{binary}} {{input}}"
sanitizer: none
input_format:
  spec_file: $FIX/spec.yaml
success_condition:
  kind: crash
YAML
assert_exit "missing required key fails" 1 "$FIX/missing-key.yaml"

# 6) NEWLINE in harness_cmd -> exit 1 (newline is a shell command separator)
python3 - "$FIX/newline.yaml" <<'PY'
import sys, yaml
m = {
    "name": "echo-target",
    "binary": "/bin/echo",
    "harness_cmd": "{{binary}} {{input}}\nrm -rf /",
    "sanitizer": "none",
    "input_format": {"spec_file": sys.argv[1].rsplit("/", 1)[0] + "/spec.yaml"},
    "success_condition": {"kind": "crash"},
    "budget": {"max_iterations": 10},
}
with open(sys.argv[1], "w") as f:
    yaml.safe_dump(m, f)
PY
assert_exit "newline harness_cmd fails" 1 "$FIX/newline.yaml"

# 7) NON-STRING binary -> exit 1 (int bypasses exists/executable checks)
cat > "$FIX/nonstring-binary.yaml" <<YAML
name: echo-target
binary: 123
harness_cmd: "{{binary}} {{input}}"
sanitizer: none
input_format:
  spec_file: $FIX/spec.yaml
success_condition:
  kind: crash
budget:
  max_iterations: 10
YAML
assert_exit "non-string binary fails" 1 "$FIX/nonstring-binary.yaml"
