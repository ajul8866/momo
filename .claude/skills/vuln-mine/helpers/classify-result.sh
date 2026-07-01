#!/usr/bin/env bash
# classify-result.sh — deterministic crash/benign/hang classification (spec §7.1)
# Implements the signal×sanitizer→verdict table WITHOUT LLM judgment, and the
# signal normalization (128+sig mapping, 124→TIMEOUT) required by I3.
#
# Usage: classify-result.sh <goal.yaml> <harness_exit> <stderr.log>
# Prints exactly one line:
#   crash=true|signal=SIGABRT|sanitizer=heap-buffer-overflow|at=file.c:42|verdict=verified_crash
#   crash=false|signal=|sanitizer=|at=|verdict=benign
#   crash=true|signal=TIMEOUT|sanitizer=|at=|verdict=needs_more
set -euo pipefail

goal_yaml="$1"
exit_code="$2"
stderr_log="${3:-/dev/null}"
[ -f "$stderr_log" ] || stderr_log=/dev/stdin

python3 - "$goal_yaml" "$exit_code" "$stderr_log" <<'PY'
import sys, re, yaml

goal_f, exit_s, stderr_f = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    exit_code = int(exit_s)
except ValueError:
    exit_code = 0

try:
    goal = yaml.safe_load(open(goal_f)) or {}
except FileNotFoundError:
    goal = {}

# --- read stderr once ---
try:
    with open(stderr_f) as f:
        stderr = f.read()
except (FileNotFoundError, OSError):
    stderr = ""

# --- signal normalization (I3): 124 timeout; >=128 subtract 128; classic sig codes ---
def signal_from_exit(code):
    if code == 124:
        return "TIMEOUT"
    if code >= 128:
        sig = code - 128
        table = {9:"SIGKILL", 11:"SIGSEGV", 6:"SIGABRT", 8:"SIGFPE",
                 7:"SIGBUS", 4:"SIGILL", 15:"SIGTERM", 1:"SIGHUP", 3:"SIGQUIT", 10:"SIGUSR1", 12:"SIGUSR2"}
        return table.get(sig, f"SIG{sig}")
    return ""

# --- sanitizer extraction (reuses parse-sanitizer regex logic) ---
kind = ""
loc  = ""
m = re.search(r'ERROR: (AddressSanitizer|MemorySanitizer|UndefinedBehaviorSanitizer):\s*([A-Za-z0-9_-]+)', stderr)
if m:
    kind = m.group(2)
m2 = re.search(r'#0 .* in (\S+)\s+(\S+:\d+)', stderr)
if m2:
    loc = f"{m2.group(1)} {m2.group(2)}"
else:
    m3 = re.search(r'#0 .* in (\S+:\d+)', stderr)
    if m3:
        loc = m3.group(1)

# --- deterministic classification (spec §7.1 table) ---
signal = signal_from_exit(exit_code)
is_crash = (exit_code == 124) or (exit_code >= 128) or (kind != "")
is_hang   = (exit_code == 124)

# --- verdict: match against success_condition ---
sc = goal.get('success_condition') or {}
kind_cond = sc.get('kind')
must_reach = sc.get('must_reach')
acceptable = sc.get('acceptable_signals') or []

verdict = "needs_more"
if is_crash and not is_hang:
    # crash: check success_condition (kind==crash + acceptable_signals + must_reach)
    if kind_cond == "crash":
        sig_ok = (len(acceptable) == 0) or (signal in acceptable)
        reach_ok = (must_reach in (None, "", "null")) or (loc == must_reach) or (must_reach in loc)
        verdict = "verified_crash" if (sig_ok and reach_ok) else "not_verified_crash"
    else:
        verdict = "not_verified_crash"
elif is_hang:
    verdict = "needs_more"
else:
    # benign / exit 0
    verdict = "benign"

crash_str = "true" if is_crash else "false"
print(f"crash={crash_str}|signal={signal}|sanitizer={kind}|at={loc}|verdict={verdict}")
PY
