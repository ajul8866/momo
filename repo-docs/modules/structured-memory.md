# Structured memory and the convergence loop

## Why mining turns into re-guessing without memory

A naive LLM fuzzer reads the source, guesses an input, runs it, and then — next iteration — reads the source again and guesses again. Nothing is saved between attempts, so the model re-explores the same code and re-proposes the same dead input. The bug never gets closer.

`vuln-mine` breaks that loop by writing every observation into seven memory files that the next attempt reads before it acts. You saw this scaffold get seeded in [the first walkthrough step](../walkthroughs/one-real-run.md#step-1-a-manifest-becomes-seven-memory-files). This page explains why those seven categories exist and why the loop converges rather than wandering.

## The seven categories and what each one carries

Each category is one object of the mining process — not a pipeline stage. A run keeps seven of them as YAML files in the run directory, and every write bumps a `rev` counter so concurrent writers cannot silently lose an update. In plain terms they hold: the **goal** (the fixed target contract everything is checked against), the **code path** (where suspicious functions live, so the Synthesizer can aim at one), the **input format** (grammar and boundary values, so a PoC is valid enough to reach the parser), the **candidates** (inputs tried and the crashes verified), the **negatives** (what already failed, so it is not retried), the **verification log** (per-run results the loop learns from), and the **next constraint** (what the following attempt must satisfy, plus the convergence counter). The numbered filenames and exact fields are lookup material in the table below.

| Role | Holds | Why the loop needs it |
| --- | --- | --- |
| Goal (`01`) | The target contract: binary, harness command, sanitizer, success condition, budget. | Fixed for the whole run; everything else is checked against this. |
| Code path (`02`) | The parsing chain, suspicious functions, data flows the Reader found. | The Synthesizer aims a PoC at a specific site named here. |
| Input format (`03`) | Grammar facts and field boundary values. | A PoC must be syntactically valid to reach the parser at all. |
| Candidates (`04`) | Candidate inputs and the deduped verified-crashes list. | The win condition — what REPORT reads out. |
| Negatives (`05`) | Non-triggering inputs, unreachable paths, mined areas. | Stops the loop re-trying what already failed. |
| Verification (`06`) | Per-run execution results history. | The evidence base stagnation and REPORT are computed from. |
| Next constraint (`07`) | What the next PoC must satisfy, open hypotheses, the stagnation counter. | The steering wheel of convergence. |

The shapes are templated in [`memory-schemas/`](../../.claude/skills/vuln-mine/memory-schemas/) and seeded by [`init-memory.sh`](../../.claude/skills/vuln-mine/helpers/init-memory.sh). The category that does the most work is `07`: it is the one the loop reads to decide what to do next.

## How a Reader→Synthesizer→Analyst batch uses the memory

The loop runs in batches of three, each iteration an independent pipeline through three roles. The key design choice is what each role reads and writes, not the LLM prompting:

```
Reader ──writes──▶ 02-code-path, 03-input-format
   │
Synthesizer ──reads──▶ 02,03,04,05,07  ──writes──▶ 04-candidate-poc, pocs/*.bin
   │
Analyst ──runs PoC──▶ 06-verification  ──writes──▶ 04 (if crash), 05 (if benign), 07
```

The Synthesizer reads five memory files before it crafts a PoC, and its output schema forces a `targets_branch` — a concrete `file:line` — so a vague "try something near the parser" is rejected at the schema layer. The Analyst never decides whether something is a crash; it runs the harness and hands the exit code and stderr to a deterministic classifier (see [how a crash verdict is decided](deterministic-classification.md)), then writes the verdict back. That separation is what keeps the LLM from grading its own homework.

The orchestration lives in [`explore-loop.js`](../../.claude/skills/vuln-mine/workflow/explore-loop.js). Concurrency is handled in [`write-back.sh`](../../.claude/skills/vuln-mine/helpers/write-back.sh): one `flock` per category, atomic file replace, and dedup on `verified_crashes` and `mined_areas` so parallel Analysts cannot double-count or clobber each other.

## Why it converges instead of looping forever

Convergence comes from two mechanisms turning negative evidence into constraints:

1. **Stagnation forces a vector switch.** [`recompute-stagnation.sh`](../../.claude/skills/vuln-mine/helpers/recompute-stagnation.sh) recomputes `07.stagnation_counter` from the last run in `06`: a crash resets it to 0, a non-crash bumps it. At 3, the next Synthesizer is told to switch vector and target a different branch than prior candidates. The counter is read back from disk each batch so it is not double-bumped within a batch.
2. **Mined areas accumulate.** Every non-triggering attempt and unreachable path is appended to `05-negative.yaml::mined_areas`, and the Synthesizer is told to avoid them. The set only grows, so the search space shrinks.

The loop does not stop at the first crash — it keeps mining down to a 10% budget floor reserved for REPORT, so it can collect several deduplicated PoCs across distinct branches.

A caveat worth holding: this is an exploration harness, not a coverage-guided fuzzer. It reads source and aims at hypothesized bug sites; it does not maximize code coverage the way libFuzzer or AFL do. The README frames it as a complement to classic fuzzers, not a replacement.

To see one batch's worth of finished output, read [`04-candidate-poc.yaml`](../../runs/smoke-example/04-candidate-poc.yaml) and [`07-next-constraint.yaml`](../../runs/smoke-example/07-next-constraint.yaml). For the exact crash-verdict logic the Analyst relies on, continue to [how a crash verdict is decided](deterministic-classification.md).

Evidence status: Confirmed unless noted.
