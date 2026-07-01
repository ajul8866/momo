#!/usr/bin/env bash
# write-back.sh — flock + rev + append-merge for one memory category
# Usage: write-back.sh <run-dir> <category> <record.json>
#   <category> = basename without .yaml (e.g. "candidate-poc" -> 04-candidate-poc.yaml)
# Prints the new rev. Exit 0/1.
set -euo pipefail

run_dir="$1"
category="$2"
record_file="$3"

# resolve the numbered category file (e.g. 04-candidate-poc.yaml)
yfile="$(ls "$run_dir"/[0-9][0-9]-"$category".yaml 2>/dev/null | head -1 || true)"
if [ -z "${yfile:-}" ] || [ ! -f "$yfile" ]; then
  echo "write-back: no [0-9][0-9]-$category.yaml in $run_dir" >&2
  exit 1
fi

mkdir -p "$run_dir/.locks"
lockf="$run_dir/.locks/$category.lock"
exec 9>"$lockf"
flock 9   # serialize writers for this category; held until process exits

python3 - "$yfile" "$record_file" <<'PY'
import sys, json, yaml, os
yfile, record_file = sys.argv[1], sys.argv[2]
with open(yfile) as f:
    data = yaml.safe_load(f) or {}
with open(record_file) as f:
    rec = json.load(f)

data['rev'] = int(data.get('rev', 0)) + 1

for key, new_val in rec.items():
    if isinstance(new_val, list):
        cur = data.get(key)
        if not isinstance(cur, list):
            cur = [] if cur is None else [cur]
        if key == 'verified_crashes':
            ids = {it.get('poc_id') for it in cur if isinstance(it, dict)}
            for it in new_val:
                if isinstance(it, dict) and it.get('poc_id') not in ids:
                    cur.append(it); ids.add(it.get('poc_id'))
        elif key == 'mined_areas':
            seen = set(cur)
            for it in new_val:
                if it not in seen:
                    cur.append(it); seen.add(it)
        else:
            cur.extend(new_val)
        data[key] = cur
    else:
        data[key] = new_val   # scalar -> overwrite

tmp = yfile + '.tmp'
with open(tmp, 'w') as f:
    yaml.safe_dump(data, f, sort_keys=False, default_flow_style=False)
os.replace(tmp, yfile)        # atomic
print(data['rev'])
PY
