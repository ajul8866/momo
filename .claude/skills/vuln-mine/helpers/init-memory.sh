#!/usr/bin/env bash
# init-memory.sh <manifest.yaml> <run-dir>
# Bootstrap the 7 vuln-mine memory category files for one run from a target manifest.
# Uses python3 + PyYAML (present) and jq (present) for robust manifest/grammar parsing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -ne 2 ]; then
  echo "usage: init-memory.sh <manifest.yaml> <run-dir>" >&2
  exit 64
fi

manifest="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
run_dir="$2"
man_dir="$(dirname "$manifest")"

# 1. VALIDATE MANIFEST (trust boundary) — fail fast.
#    Run from the manifest's own dir so its manifest-dir-relative paths
#    (binary, spec_file) resolve exactly as the contract documents.
if ! (cd "$man_dir" && "$SCRIPT_DIR/validate-manifest.sh" "$manifest"); then
  echo "init-memory: manifest validation failed: $manifest" >&2
  exit 1
fi

# 2. Extract manifest fields to JSON.
fields_json=$(python3 - "$manifest" <<'PY'
import sys, yaml, json
m = yaml.safe_load(open(sys.argv[1]))
def g(*ks, f=None):
    cur = m
    for k in ks:
        cur = cur.get(k, {}) if isinstance(cur, dict) else None
    return cur if cur is not None else f
json.dump({
  "name":         g("name"),
  "binary":       g("binary"),
  "harness_cmd":  g("harness_cmd"),
  "sanitizer":    g("sanitizer"),
  "timeout_sec":  g("timeout_sec", f=10),
  "spec_file":    g("input_format", "spec_file"),
  "kind":         g("success_condition", "kind", f="crash"),
  "must_reach":   g("success_condition", "must_reach", f=""),
  "signals":      g("success_condition", "acceptable_signals", f=[]),
  "max_iter":     g("budget", "max_iterations", f=20),
  "stop_when":    g("budget", "stop_when", f="budget_exhausted"),
  "constraints":  g("constraints", f=[]),
  "source_root":  g("source_root", f=""),
}, sys.stdout)
PY
)

binary_rel=$(jq -r '.binary'      <<<"$fields_json")
timeout_sec=$(jq -r '.timeout_sec' <<<"$fields_json")

# binary is resolved relative to the manifest's own directory (documented contract).
if [ -x "$man_dir/$binary_rel" ]; then
  binary_abs="$(cd "$man_dir" && realpath -- "$binary_rel")"
elif [ -x "$binary_rel" ]; then
  binary_abs="$(realpath -- "$binary_rel")"   # fallback: CWD-relative
else
  echo "init-memory: binary not found: $binary_rel (looked in $man_dir)" >&2
  exit 1
fi

# 3. BUILD-CHECK — prefer a valid baseline; fall back to /dev/null. Fail only on
#    signal-killed (>=128) or timeout (124): a strict parser may legitimately exit
#    nonzero on empty input.
baseline="$man_dir/baseline.bin"
probe="$baseline"; [ -f "$probe" ] || probe="/dev/null"
set +e
timeout "$timeout_sec" "$binary_abs" "$probe" >/dev/null 2>&1
probe_rc=$?
set -e
if [ "$probe_rc" -eq 124 ] || [ "$probe_rc" -ge 128 ]; then
  echo "init-memory: build-check failed (rc=$probe_rc) for $binary_abs" >&2
  exit 1
fi

# 4. Create run-dir scaffold.
mkdir -p "$run_dir/pocs" "$run_dir/.locks" "$run_dir/.runs"

# 5. Seed the 7 category files (rev=0; first write-back bumps to 1).
python3 - "$fields_json" "$man_dir" "$run_dir" "$binary_abs" <<'PY'
import sys, json, yaml, os
fields, man_dir, run_dir, binary_abs = sys.argv[1:5]
F = json.loads(fields)

spec_path = F["spec_file"]
if spec_path and not os.path.isabs(spec_path):
    spec_path = os.path.join(man_dir, spec_path)
fmt, grammar, field_constraints = F["name"], [], []
if spec_path and os.path.isfile(spec_path):
    gd = yaml.safe_load(open(spec_path)) or {}
    fmt = gd.get("format", F["name"])
    grammar = gd.get("grammar", []) or []
    field_constraints = gd.get("field_constraints", []) or []

files = {
"01-goal.yaml": {
    "rev": 0,
    "target": {
        "binary": binary_abs,
        "harness_cmd": F["harness_cmd"],
        "sanitizer": F["sanitizer"],
        "build_ok": True,
    },
    "success_condition": {
        "kind": F["kind"],
        "must_reach": F["must_reach"] or None,
        "acceptable_signals": F["signals"] or [],
    },
    "constraints": F["constraints"] or ["input must match the documented format"],
    "budget": {"max_iterations": F["max_iter"], "stop_when": F["stop_when"]},
},
"02-code-path.yaml": {
    "rev": 0,
    "entry_points": [{"fn": "main", "file": "", "confirmed": False}],
    "parsing_chain": [],
    "suspicious": [],
    "data_flows": [],
},
"03-input-format.yaml": {
    "rev": 0,
    "format": fmt,
    "grammar": grammar,
    "field_constraints": field_constraints,
    "known_valid_patterns": [],
    "known_invalid_patterns": [],
},
"04-candidate-poc.yaml": {"rev": 0, "candidates": [], "verified_crashes": []},
"05-negative.yaml": {
    "rev": 0, "non_triggering": [], "unreachable": [],
    "build_failures": [], "format_errors": [], "mined_areas": [],
},
"06-verification.yaml": {"rev": 0, "runs": []},
"07-next-constraint.yaml": {
    "rev": 0,
    "next_iteration_must": [
        "reach the parser's memcpy site and identify the length field that controls it"
    ],
    "open_hypotheses": [],
    "stagnation_counter": 0,
},
}
for name, obj in files.items():
    with open(os.path.join(run_dir, name), "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, default_flow_style=False)
PY

# 6. OPTIONAL baseline run — record into 06.runs[] (NOT budget-counted).
if [ -f "$baseline" ]; then
  set +e
  timeout "$timeout_sec" "$binary_abs" "$baseline" \
    >"$run_dir/.runs/baseline.out" 2>"$run_dir/.runs/baseline.err"
  brc=$?
  set -e
  python3 - "$run_dir" "$brc" <<'PY'
import sys, yaml
run_dir, rc = sys.argv[1], int(sys.argv[2])
p = f"{run_dir}/06-verification.yaml"
d = yaml.safe_load(open(p)) or {}
def tail(path, n=3):
    try:
        return b"\n".join(open(path,"rb").read().splitlines()[-n:]).decode("utf-8","replace")
    except FileNotFoundError:
        return ""
entry = {
    "poc_id": "baseline",
    "harness_exit": rc,
    "stdout_tail": tail(f"{run_dir}/.runs/baseline.out"),
    "sanitizer_output": tail(f"{run_dir}/.runs/baseline.err"),
    "crash": rc >= 128,
    "crash_location": None,
    "why_no_crash": None if rc >= 128 else "baseline valid input; no crash expected",
    "verdict": "stuck" if rc >= 128 else "fresh",
}
d.setdefault("runs", []).append(entry)
d["rev"] = int(d.get("rev", 0)) + 1
yaml.safe_dump(d, open(p, "w"), sort_keys=False, default_flow_style=False)
PY
fi

echo "init-memory: seeded $run_dir (binary=$binary_abs)"
