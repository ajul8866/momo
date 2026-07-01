# Deterministic crash classification

## Why the LLM must not judge its own results

When an LLM both crafts a PoC and decides whether it crashed, it tends to rationalize — a near-miss becomes "almost there," a benign exit gets a generous reading, and the convergence signal in [structured memory](structured-memory.md) goes noisy. `vuln-mine` removes that by classifying every run with pure logic over the harness exit code and the sanitizer output. The LLM only writes the resulting verdict back into memory; it never produces it.

You saw this step run inside the Analyst in [the walkthrough](../walkthroughs/one-real-run.md#step-2-the-loop-reads-code-crafts-a-poc-runs-it). This page explains the mapping the classifier applies, so you can predict the verdict from an exit code without running it.

## The signal → verdict mapping

[`classify-result.sh`](../../.claude/skills/vuln-mine/helpers/classify-result.sh) normalizes the raw exit code into a signal name, then matches it against the manifest's `success_condition`. The normalization handles the three ways a process can terminate:

| Exit code | Meaning | Signal name |
| --- | --- | --- |
| `0` | clean exit | (none) → benign |
| `1..127` | ordinary nonzero | (none) → benign |
| `124` | killed by `timeout` | `TIMEOUT` → `needs_more` |
| `≥ 128` | killed by a signal | `exit - 128`, mapped: 6→SIGABRT, 11→SIGSEGV, 9→SIGKILL, 8→SIGFPE, 7→SIGBUS, 4→SIGILL, … |

The verdict then falls out of three booleans: is it a crash (exit 124, exit ≥ 128, or a sanitizer line present), is it a hang (124), and does it satisfy `success_condition`. With `kind: crash` and `acceptable_signals: [SIGABRT, SIGSEGV]`, a SIGABRT run that is not a timeout becomes `verified_crash`. A crash whose signal is not in the acceptable list becomes `not_verified_crash`. A clean exit becomes `benign`. A timeout becomes `needs_more`, because a hang is evidence the input reached deep code but did not prove a memory bug.

The sanitizer kind and crash location come from regex over stderr — the same `ERROR: AddressSanitizer: <kind>` and `#0 ... in <fn> <file:line>` patterns that [`parse-sanitizer.sh`](../../.claude/skills/vuln-mine/helpers/parse-sanitizer.sh) extracts. They are evidence, not the verdict trigger; the exit code is.

## The ASan carry-forward

There is one wrinkle that would silently break the whole table. AddressSanitizer reports a bug and exits 1 by default — it does not raise SIGABRT. So a manifest with `acceptable_signals: [SIGABRT]` would never match an ASan crash; every real bug would classify as benign and the loop would never converge.

[`run-harness.sh`](../../.claude/skills/vuln-mine/helpers/run-harness.sh) closes that gap at the single point where the harness runs: when the goal's `target.sanitizer` is `asan`, it exports `ASAN_OPTIONS=abort_on_error=1` (unless the caller already set `ASAN_OPTIONS`). That makes ASan abort on the bug, so it surfaces as SIGABRT / exit 134 and matches the acceptable list. The same option is baked into [`verify-crash.sh`](../../.claude/skills/vuln-target-prep/helpers/verify-crash.sh) on the prep side, so the two skills agree on what an ASan crash looks like.

For the example run this is exactly why the crash at `parse_np naiveparse.c:22` lands as `signal: SIGABRT, sanitizer: AddressSanitizer` in [`runs/smoke-example/04-candidate-poc.yaml`](../../runs/smoke-example/04-candidate-poc.yaml) rather than vanishing as a benign exit 1.

A caveat: this only covers `asan`. MSan/UBSan paths exist in the sanitizer vocabulary but gcc lacks MSan, and a parallel sanitizer sweep is a documented v1 limitation. The deterministic table itself is sanitizer-agnostic; only the carry-forward option is ASan-specific.

To verify the mapping by hand, replay the example PoC and read the exit code:

```bash
.claude/skills/vuln-mine/manifests/example/naiveparse runs/smoke-example/pocs/poc-1.bin; echo "EXIT=$?"
# EXIT=134  →  134-128=6  →  SIGABRT  →  verified_crash
```

For the exact manifest fields that define `success_condition` and `acceptable_signals`, read [the manifest contract](../references/manifest-contract.md).

Evidence status: Confirmed unless noted.
