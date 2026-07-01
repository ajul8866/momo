---
name: vuln-mine
description: Mine native C/C++ targets for memory-safety bugs via a 7-category memory-driven Reader→Synthesizer→Analyst loop. Supply a target name with a manifest; the skill bootstraps memory, runs the explore loop, and reports verified PoCs.
---

# vuln-mine

Protocol: INIT → EXPLORE → REPORT. Memory = 7 YAML files in `runs/<run-id>/`.
Deterministic logic lives in `helpers/*.sh`; LLM prompts + parallel control live in
`workflow/explore-loop.js`. Do not improvise outside this protocol.

## 0. Conventions

- Repo root is `/root/momo`. Run every Bash command from there so the relative
  helper paths below resolve.
- Skill root: `.claude/skills/vuln-mine` (referred to as `$SKILL` below).
- All paths printed to the user MUST be absolute.

## 1. INIT

1. Resolve the target name to a manifest:
   `$SKILL/manifests/<NAME>/manifest.yaml`. Fail fast (abort the skill) if absent.
2. If the target's binary is not built or is older than its source, build it now:
   `bash $SKILL/manifests/<NAME>/src/build.sh`.
3. Generate a run-id and create the run directory. Use the helper
   `yaml_new_run_id` (from `helpers/lib-yaml.sh`) for an ISO timestamp id; if not
   sourced, fall back to `date -u +%Y%m%dT%H%M%SZ`:
   ```
   RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
   RUN_DIR=/root/momo/runs/vuln-mine-$RUN_ID
   mkdir -p "$RUN_DIR"
   ```
4. Bootstrap memory:
   ```
   bash $SKILL/helpers/init-memory.sh $SKILL/manifests/<NAME>/manifest.yaml "$RUN_DIR"
   ```
   This validates the manifest, build-checks the binary, seeds all 7 category
   files, and records a non-budgeted baseline run into `06-verification.yaml`.
   If it exits nonzero, STOP — do not enter the loop.
5. `cd /root/momo` so every helper path in EXPLORE resolves.

## 2. EXPLORE

Invoke the Claude Code **Workflow** tool:

- `scriptPath`: `.claude/skills/vuln-mine/workflow/explore-loop.js`
- `parameters`:
  ```
  { run_dir: "$RUN_DIR", budget_total: <manifest.budget.max_iterations>, budget_used: 0 }
  ```

The loop runs Reader→Synthesizer→Analyst batches until `budget_remaining <= FLOOR`
(10% held back for REPORT). Stagnation ≥ 3 forces a vector switch in the next
Synthesizer. Crashes are recorded but the loop does NOT stop on the first crash.

### ASan carry-forward (IMPORTANT)

The example target (and any `asan` target) is compiled with
`-fsanitize=address`. By default ASan reports the bug and **exits 1** — it does
NOT raise SIGABRT, so a `success_condition.acceptable_signals: [SIGABRT]` match
would never fire. To make ASan crashes observable as signal 134 / SIGABRT,
`helpers/run-harness.sh` exports `ASAN_OPTIONS=abort_on_error=1` whenever the
goal's `target.sanitizer == asan` (and leaves any caller-provided `ASAN_OPTIONS`
in place otherwise). No manifest or build change is required. Chosen option:
**harness sets `ASAN_OPTIONS=abort_on_error=1` for asan builds** (simplest,
single point of truth, no matcher ambiguity).

## 3. REPORT

Read the final memory state and print a markdown summary (no improvisation —
data comes from the files):

1. Verified PoCs ← `cat "$RUN_DIR/04-candidate-poc.yaml"` → list each
   `verified_crashes` entry with its absolute PoC path
   (`$RUN_DIR/pocs/<id>.bin`), signal, sanitizer, location.
2. Mined areas ← `cat "$RUN_DIR/05-negative.yaml"` (`.mined_areas`).
3. Dead ends ← `05-negative.yaml` (`.unreachable`, `.build_failures`,
   `.format_errors`, `.non_triggering`).
4. Open hypotheses ← `cat "$RUN_DIR/07-next-constraint.yaml"`
   (`.open_hypotheses`).
5. Stats: iterations run = `budget_used`; crashes found =
   `len(04.verified_crashes)`.
6. Print every PoC absolute path so the user can replay it.

Always end the report with the absolute `$RUN_DIR` so the run can be inspected.

## 4. End-to-end smoke test

Run from `/root/momo`. The example OOB is trivially triggerable, so a tiny budget
must yield ≥ 1 entry in `04-candidate-poc.yaml::verified_crashes`.

1. Build the example target:
   `bash $SKILL/manifests/example/src/build.sh` → expect `built .../naiveparse`.
2. Ensure a baseline exists:
   `printf 'NPv1\x01\x00A' > $SKILL/manifests/example/baseline.bin`.
3. Create the run directory and bootstrap memory:
   ```
   RUN_DIR=/root/momo/runs/smoke-example
   mkdir -p "$RUN_DIR"
   bash $SKILL/helpers/init-memory.sh $SKILL/manifests/example/manifest.yaml "$RUN_DIR"
   ```
   Expect last line: `init-memory: seeded $RUN_DIR (binary=.../naiveparse)`.
4. Invoke the Workflow tool with `scriptPath`
   `.claude/skills/vuln-mine/workflow/explore-loop.js` and `parameters`
   `{ run_dir: "$RUN_DIR", budget_total: 6, budget_used: 0 }`.
   If the Workflow tool cannot be invoked headlessly (e.g. from a subagent),
   run a REDUCED manual simulation: directly invoke `run-harness.sh` +
   `parse-sanitizer.sh` + `write-back.sh` on a crafted OOB PoC
   (`NPv1` + `len=128` little-endian + 128 `A`s) to prove a crash lands in
   `04-candidate-poc.yaml::verified_crashes`. State which path was taken.
5. After the loop returns, assert at least one verified crash:
   ```
   n=$(python3 -c "import yaml,sys;d=yaml.safe_load(open(sys.argv[1]));print(len(d.get('verified_crashes',[])))" "$RUN_DIR/04-candidate-poc.yaml")
   [ "$n" -ge 1 ] && echo "SMOKE OK: $n verified crash(es)" || { echo "SMOKE FAIL"; exit 1; }
   ```
   Expect: `SMOKE OK: 1 verified crash(es)` (or more).
6. Print the REPORT per §3; include the absolute path of the crashing PoC
   (`$RUN_DIR/pocs/poc-*.bin`) and `$RUN_DIR`.
7. Re-run the PoC directly to prove it reproduces:
   `$SKILL/manifests/example/naiveparse "$RUN_DIR"/pocs/poc-*.bin; echo "EXIT=$?"`
   Expect an ASan `ERROR: AddressSanitizer` line (e.g. `unknown-crash`) and `EXIT=134`
   (SIGABRT, thanks to the `abort_on_error=1` baked into the harness).
