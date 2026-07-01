# momo Repo Docs

`momo` is a research harness that finds memory-safety bugs in C/C++ code by reading the source, hypothesizing where a bug lives, and crafting inputs aimed at that spot — instead of mutating blindly the way classic fuzzers do. Two Claude Code skills do this end to end: `vuln-target-prep` turns a GitHub repo into a ready fuzz target, and `vuln-mine` runs a structured Reader→Synthesizer→Analyst loop over it until it produces a verified PoC that actually crashes the target under AddressSanitizer.

The core idea is on the repo's [main README](../README.md): keep mining memory between iterations so the search converges rather than re-guessing. This guide explains how one real run does that, then points at the exact code and contracts.

This guide documents the **mining loop** — how `/vuln-mine` turns a manifest into verified PoCs. The upstream `vuln-target-prep` path (GitHub URL → manifest) is summarized in [the manifest-contract reference](references/manifest-contract.md) but its live-network clone is fixture-tested only.

## Reader Routes

| Reader goal | Start here | What this page gives you |
| --- | --- | --- |
| Understand the main behavior | [Follow one real run](walkthroughs/one-real-run.md) | How `/vuln-mine example` becomes a verified PoC, end to end |
| Why the loop converges | [Structured memory](modules/structured-memory.md) | The 7 memory categories and the Reader→Synthesizer→Analyst pipeline |
| How a crash is judged | [Deterministic classification](modules/deterministic-classification.md) | The signal→verdict table and the ASan carry-forward |
| Look up the contract | [Manifest contract](references/manifest-contract.md) | Required fields, path resolution, and the injection gate |
| Audit the evidence | [Source evidence](references/source-evidence.md) | Traversal log, claim/evidence table, falsifying checks |
| Audit guide quality | [Quality review](references/quality-review.md) | Reader simulation and residual risk |
| Decode repeated terms | [Glossary](glossary.md) | Project-specific meanings in one place |

New here? [Follow the full run from manifest to verified PoC](walkthroughs/one-real-run.md). Know fuzzing already? Jump to [the manifest contract](references/manifest-contract.md) and [how a crash verdict is decided](modules/deterministic-classification.md).

## Scope and caveats

- **Mining loop is the focus.** `vuln-target-prep`'s real-GitHub-clone path is described but not walked; it is fixture-tested (`test-smoke-prep.sh`) and a real clone is the documented first end-to-end test.
- **ASan only, in practice.** The carry-forward that makes ASan crashes observable covers `asan`; MSan/UBSan exist in the vocabulary but a parallel sanitizer sweep is a v1 limitation.
- **Exploration, not coverage fuzzing.** This complements libFuzzer/AFL; it does not replace them.

Evidence status: Confirmed unless noted.
