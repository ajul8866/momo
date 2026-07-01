#!/usr/bin/env bash
# recompute-stagnation.sh — recompute 07.stagnation_counter from 06.last_run
# Usage: recompute-stagnation.sh <07-next-constraint.yaml> <06-verification.yaml>
# Prints the new counter int (does NOT write either file).
#   crash == true  -> progress -> reset to 0
#   crash == false -> no new evidence -> current + 1
set -euo pipefail

nc="$1"
ver="$2"

python3 - "$nc" "$ver" <<'PY'
import sys, yaml
nc_f, ver_f = sys.argv[1], sys.argv[2]
nc_data  = yaml.safe_load(open(nc_f))  or {}
ver_data = yaml.safe_load(open(ver_f)) or {}
cur  = int(nc_data.get('stagnation_counter', 0))
last = (ver_data.get('last_run') or {})
crash = bool(last.get('crash', False))
print(0 if crash else cur + 1)
PY
