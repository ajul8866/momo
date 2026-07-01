#!/usr/bin/env bash
# validate-manifest.sh — trust-boundary gate for operator-authored manifests.
# Usage: validate-manifest.sh <manifest.yaml>
# Exit 0 = valid; 1 = invalid (reasons on stderr).
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <manifest.yaml>" >&2
  exit 1
fi

man="$1"
if [ ! -f "$man" ]; then
  echo "ERROR: manifest file does not exist: $man" >&2
  exit 1
fi

exec python3 - "$man" <<'PYEOF'
import os
import re
import sys
import yaml

man = sys.argv[1]
errs = []

# 1) parse
try:
    with open(man) as f:
        raw = yaml.safe_load(f)
except Exception as e:
    print(f"ERROR: manifest not parseable YAML: {e}", file=sys.stderr)
    sys.exit(1)
if not isinstance(raw, dict):
    print("ERROR: manifest top-level must be a mapping", file=sys.stderr)
    sys.exit(1)

# 2) top-level keys present and non-empty
required = ["name", "binary", "harness_cmd", "sanitizer",
            "input_format", "success_condition", "budget"]
for k in required:
    if k not in raw or raw[k] in (None, ""):
        errs.append(f"missing or empty required key: {k}")

# 3) binary exists and is executable
b = raw.get("binary")
if isinstance(b, str) and b:
    if not os.path.exists(b):
        errs.append(f"binary does not exist: {b}")
    elif not os.access(b, os.X_OK):
        errs.append(f"binary not executable: {b}")

# 4) sanitizer vocabulary
san = raw.get("sanitizer")
if san not in ("asan", "msan", "ubsan", "none"):
    errs.append(f"sanitizer must be one of asan|msan|ubsan|none, got: {san!r}")

# 5) input_format.spec_file exists and parses
ifo = raw.get("input_format")
if isinstance(ifo, dict):
    spec = ifo.get("spec_file")
    if spec in (None, ""):
        errs.append("missing input_format.spec_file")
    elif not isinstance(spec, str):
        errs.append("input_format.spec_file must be a string path")
    elif not os.path.exists(spec):
        errs.append(f"input_format.spec_file does not exist: {spec}")
    else:
        try:
            with open(spec) as f:
                yaml.safe_load(f)
        except Exception as e:
            errs.append(f"input_format.spec_file not parseable YAML: {e}")
else:
    errs.append("input_format must be a mapping with spec_file")

# 6) harness_cmd: reject shell metacharacters OUTSIDE {{binary}}/{{input}} placeholders
hc = raw.get("harness_cmd")
if isinstance(hc, str) and hc:
    # mask the two allowed placeholders, then scan the remainder
    masked = hc.replace("{{binary}}", "").replace("{{input}}", "")
    bad = sorted(set(c for c in ";|&$`<>" if c in masked))
    # also reject $(...) and backticks explicitly (backtick caught above)
    if re.search(r"\$\(", masked):
        bad.append("$()")
    if bad:
        errs.append(
            "harness_cmd contains forbidden shell metacharacters outside "
            f"{{{{binary}}}}/{{{{input}}}} placeholders: {bad}"
        )

if errs:
    for e in errs:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF
