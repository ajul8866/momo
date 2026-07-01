#!/usr/bin/env bash
# recompute-stagnation.sh — recompute 07.stagnation_counter from 06.runs[] and PERSIST it.
# Usage: recompute-stagnation.sh <07-next-constraint.yaml> <06-verification.yaml>
# Writes the new counter into 07.stagnation_counter atomically (under the same
# flock used for next-constraint write-back) AND prints the new value to stdout.
#   crash == true  -> progress -> reset to 0
#   crash == false -> no new evidence -> current + 1
set -euo pipefail

nc="$1"
ver="$2"

run_dir="$(cd "$(dirname "$(readlink -f "$nc")")" && pwd)"
mkdir -p "$run_dir/.locks"
lockf="$run_dir/.locks/next-constraint.lock"

# Hold the next-constraint lock for the whole read-modify-write so a concurrent
# write-back.sh on the same category cannot interleave.
(
  flock 9
  python3 - "$nc" "$ver" <<'PY'
import sys, yaml, os
nc_f, ver_f = sys.argv[1], sys.argv[2]
nc_data  = yaml.safe_load(open(nc_f))  or {}
ver_data = yaml.safe_load(open(ver_f)) or {}
cur  = int(nc_data.get('stagnation_counter', 0))
runs = ver_data.get('runs') or []
last = runs[-1] if runs else {}
crash = bool(last.get('crash', False))
new_counter = 0 if crash else cur + 1

nc_data['stagnation_counter'] = new_counter
nc_data['rev'] = int(nc_data.get('rev', 0)) + 1
tmp = nc_f + '.tmp'
with open(tmp, 'w') as f:
    yaml.safe_dump(nc_data, f, sort_keys=False, default_flow_style=False)
os.replace(tmp, nc_f)
print(new_counter)
PY
) 9>"$lockf"
