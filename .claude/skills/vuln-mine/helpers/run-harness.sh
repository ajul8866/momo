#!/usr/bin/env bash
# run-harness.sh — render harness_cmd, run under timeout, capture streams, print EXIT=<n>
# Usage: run-harness.sh <goal-or-manifest.yaml> <poc.bin> <timeout_sec>
# Env:   RUN_DIR (default: directory containing the goal file)
# Returns: harness exit code (124 on timeout). Prints exactly one line: EXIT=<n>.
set -euo pipefail

goal_yaml="$1"
poc="$2"
timeout_sec="${3:-30}"

goal_dir="$(cd "$(dirname "$(readlink -f "$goal_yaml")")" && pwd)"
run_dir="${RUN_DIR:-$goal_dir}"
runs_dir="$run_dir/.runs"
mkdir -p "$runs_dir"

# read a dotted-path scalar from a YAML file (contract: python3 helper allowed)
read_yaml_scalar() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
f, path = sys.argv[1], sys.argv[2]
with open(f) as fh:
    data = yaml.safe_load(fh) or {}
cur = data
for part in path.split('.'):
    cur = cur[part]
print('' if cur is None else cur)
PY
}

binary="$(read_yaml_scalar "$goal_yaml" target.binary)"
harness_cmd="$(read_yaml_scalar "$goal_yaml" target.harness_cmd)"

# substitute {{binary}} and {{input}} (manifest is trust-boundary validated: only these placeholders)
cmd="${harness_cmd//\{\{binary\}\}/$binary}"
cmd="${cmd//\{\{input\}\}/$poc}"

poc_stem="$(basename "$poc")"; poc_stem="${poc_stem%.*}"
out_file="$runs_dir/$poc_stem.out"
err_file="$runs_dir/$poc_stem.err"

set +e
timeout "$timeout_sec" bash -c "$cmd" >"$out_file" 2>"$err_file"
code=$?
set -e

echo "EXIT=$code"
exit "$code"
