#!/usr/bin/env bash
# lib-yaml.sh — minimal YAML read/write used by vuln-mine helpers.
# Requires: python3 with PyYAML. No new dependencies.
#
# Sourced by other helpers. Functions exported via being declared in the
# sourcing shell. Paths/keys are passed through argv to avoid injection.

set -uo pipefail

# yaml_get <file> <dotted.path>  -> prints value to stdout, exit 1 if missing.
# Scalars print as their string form; mappings/sequences print as one-line YAML.
yaml_get() {
  local file="$1" path="${2-}"
  [ -n "$file" ] || { echo "yaml_get: missing file" >&2; return 2; }
  [ -n "$path" ] || { echo "yaml_get: missing path" >&2; return 2; }
  python3 -c '
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
cur = data
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        sys.exit(1)
    cur = cur[part]
if isinstance(cur, (dict, list)):
    print(yaml.dump(cur, default_flow_style=True).strip())
elif cur is None:
    sys.exit(1)
else:
    print(cur)
' "$file" "$path"
}

# yaml_set_kv <file> <key> <value>  -> writes a TOP-LEVEL scalar key.
# Creates the file empty if missing. Non-scalar values are not supported
# (write-back.sh handles list appends separately).
yaml_set_kv() {
  local file="$1" key="$2" val="$3"
  [ -n "$file" ] && [ -n "$key" ] || { echo "yaml_set_kv: bad args" >&2; return 2; }
  python3 -c '
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
except FileNotFoundError:
    data = None
data = data if isinstance(data, dict) else {}
data[sys.argv[2]] = sys.argv[3]
with open(sys.argv[1], "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
' "$file" "$key" "$val"
}

# yaml_new_run_id  -> prints r-YYYYMMDD-HHMMSS (bash date, UTC-independent).
yaml_new_run_id() {
  printf 'r-%s\n' "$(date +%Y%m%d-%H%M%S)"
}
