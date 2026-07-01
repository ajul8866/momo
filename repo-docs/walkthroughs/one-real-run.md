# How a verified PoC comes out of one mining run

You have a C/C++ target compiled with AddressSanitizer and a manifest that describes it. You want a proof-of-concept input that actually crashes the target — not a guess, but a binary file you can replay and watch die under ASan. The `vuln-mine` skill turns that into a structured search that converges instead of re-guessing.

We follow one concrete run: `/vuln-mine example` against the built-in `naiveparse` target. The target is a toy `NPv1` parser whose bug is an unbounded `memcpy` of an attacker-controlled length into a 64-byte stack buffer. A finished copy of this exact run is checked in at [`runs/smoke-example/`](../../runs/smoke-example/), so every artifact below is real and inspectable.

The hard part is not running the harness — that is one command. The hard part is keeping the search from re-reading the same source and re-guessing the same input every iteration. `vuln-mine` handles that by writing every code read, every execution result, and every failed attempt back into seven structured memory files, so the next attempt starts from accumulated constraints rather than a blank slate. A second pressure sits underneath: crashes must be classified deterministically, because an LLM that judges its own results will rationalize. Both pressures shape every step below.

The three phases are INIT (set up memory), EXPLORE (the Reader→Synthesizer→Analyst loop), and REPORT (read memory back). Details of why the memory layout converges live in [structured memory](../modules/structured-memory.md); the exact crash-classification logic lives in [how a crash verdict is decided](../modules/deterministic-classification.md).

## Step 1: a manifest becomes seven memory files

Before anything runs, the skill needs a contract describing the target: where the binary is, how to invoke it, what sanitizer it was built with, what counts as success, and the input format. That contract is the manifest — for the example, the [`manifest.yaml`](../../.claude/skills/vuln-mine/manifests/example/manifest.yaml) under the example target. It names the binary `naiveparse`, sets `sanitizer: asan`, declares `acceptable_signals: [SIGABRT, SIGSEGV]`, and points at a grammar file.

The skill first validates that manifest against a trust-boundary gate. [`validate-manifest.sh`](../../.claude/skills/vuln-mine/helpers/validate-manifest.sh) checks that required keys exist, the binary is executable, the sanitizer is in vocabulary, and — critically — that `harness_cmd` carries no shell metacharacters outside its two allowed placeholders `{{binary}}` and `{{input}}`. A manifest with `harness_cmd: "a; rm -rf /"` is rejected here, before it ever reaches execution. This matters because the harness command is later interpolated and run under `bash -c`.

Once the manifest passes, [`init-memory.sh`](../../.claude/skills/vuln-mine/helpers/init-memory.sh) creates a run directory under `runs/` and seeds seven YAML files: `01-goal`, `02-code-path`, `03-input-format`, `04-candidate-poc`, `05-negative`, `06-verification`, `07-next-constraint`. The first six are the memory categories the loop will read and write; the seventh carries the convergence control. Each file starts at `rev: 0`. init-memory also build-probes the binary on a baseline input and records the result into `06-verification.yaml` — but that baseline run does not consume a budget iteration. If the probe is signal-killed (exit ≥ 128) or times out (124), INIT stops, because a binary that crashes on valid input means something is already broken.

After INIT, the run directory holds the scaffold the loop will mutate. You can see the seeded state in [`runs/smoke-example/01-goal.yaml`](../../runs/smoke-example/01-goal.yaml).

## Step 2: the loop reads code, crafts a PoC, runs it

The EXPLORE phase is a pipeline driven by the Claude Code Workflow tool via [`explore-loop.js`](../../.claude/skills/vuln-mine/workflow/explore-loop.js). It runs in batches of three independent iterations, each passing through three stages:

- **Reader** reads the target source and updates `02-code-path.yaml` (where the parsing chain and suspicious functions live) and `03-input-format.yaml` (grammar facts and boundary values).
- **Synthesizer** reads those plus the candidate, negative, and next-constraint memory, then crafts exactly one PoC binary aimed at a specific branch — for the example, a `len=128` payload that overflows the 64-byte buffer. It writes the bytes to `pocs/poc-<i>.bin` and registers the candidate in `04-candidate-poc.yaml`. The synthesizer's output schema requires a `targets_branch` (a concrete file:line); a PoC without it is rejected, so every attempt is anchored to a hypothesis.
- **Analyst** runs the PoC through the harness, classifies the result deterministically, and writes the outcome back into `06-verification.yaml`, `05-negative.yaml` (if benign), `04-candidate-poc.yaml` (if a verified crash), and `07-next-constraint.yaml` (what the next attempt must satisfy).

The pressure here is concurrency and memory discipline. Three batches run in parallel, and several Analysts can write to the same memory file at once. [`write-back.sh`](../../.claude/skills/vuln-mine/helpers/write-back.sh) solves this with a `flock` per category and an atomic `os.replace` — every writer bumps `rev`, appends to the right list, and the `verified_crashes` and `mined_areas` lists dedup by content. The test suite proves four candidates survive concurrent writes with no lost increment.

A subtle but load-bearing detail sits inside the Analyst's run step. AddressSanitizer, by default, reports a bug and exits 1 — it does not raise SIGABRT. That means a `success_condition.acceptable_signals: [SIGABRT]` match would never fire for an ASan target. [`run-harness.sh`](../../.claude/skills/vuln-mine/helpers/run-harness.sh) exports `ASAN_OPTIONS=abort_on_error=1` whenever the goal's `target.sanitizer` is `asan`, so the bug surfaces as SIGABRT / exit 134 and the classifier can match it. This is the single point of truth — no manifest or build change is required to make ASan crashes observable. For the example run, that is exactly how the crash at `parse_np naiveparse.c:22` reaches `04-candidate-poc.yaml` with `signal: SIGABRT`.

The loop does not stop on the first crash. It keeps mining until the budget hits a floor (10% held back for REPORT), so it can collect multiple deduplicated PoCs across different branches.

## Step 3: stagnation forces a direction change

A loop that keeps crafting the same kind of PoC after a string of non-crashes is wasting budget. [`recompute-stagnation.sh`](../../.claude/skills/vuln-mine/helpers/recompute-stagnation.sh) recomputes `07-next-constraint.yaml::stagnation_counter` from the last run in `06-verification.yaml`: a crash resets it to 0, a non-crash increments it. When the counter reaches 3, the next Synthesizer is told to switch vector — pick an untried open hypothesis and target a different branch than prior candidates. The counter is read back from disk rather than kept in memory, so a batch that runs three Synthesizers does not double-count stagnation within the same batch.

This is the convergence mechanism in miniature: negative evidence (a PoC that did not crash) is not discarded, it becomes a constraint that pushes the next attempt somewhere new.

## Step 4: the report reads memory back, no improvisation

When the budget floor is reached, the REPORT phase assembles a markdown summary straight from the memory files — it does not invent anything. It lists verified PoCs from `04-candidate-poc.yaml` with their absolute paths and crash locations, mined and dead-end areas from `05-negative.yaml`, open hypotheses from `07-next-constraint.yaml`, and the run statistics, and ends with the absolute run directory so the run can be inspected.

For the example run, the report names the crashing PoC at `runs/smoke-example/pocs/poc-1.bin`, the SIGABRT signal, the `AddressSanitizer` sanitizer, and the location `parse_np naiveparse.c:22` — all from [`runs/smoke-example/04-candidate-poc.yaml`](../../runs/smoke-example/04-candidate-poc.yaml).

Verify the whole path end to end:

```bash
# from repo root: rebuild the SUT, re-seed memory, re-run, re-replay
bash .claude/skills/vuln-mine/manifests/example/src/build.sh
RUN_DIR=/root/momo/runs/smoke-example
bash .claude/skills/vuln-mine/helpers/init-memory.sh \
  .claude/skills/vuln-mine/manifests/example/manifest.yaml "$RUN_DIR"
# then invoke the Workflow tool with explore-loop.js (parameters run_dir, budget_total=6)
# and assert at least one verified crash:
python3 -c "import yaml;d=yaml.safe_load(open('$RUN_DIR/04-candidate-poc.yaml'));print(len(d['verified_crashes']))"
.claude/skills/vuln-mine/manifests/example/naiveparse "$RUN_DIR"/pocs/poc-*.bin; echo "EXIT=$?"
# expect an ASan ERROR line and EXIT=134
```

If you want the deterministic mechanics behind "why exit 134 means a verified crash," read [how a crash verdict is decided](../modules/deterministic-classification.md). If you want the exact manifest fields and validator rules that gate this whole path, read [the manifest contract](../references/manifest-contract.md).

Evidence status: Confirmed unless noted.
