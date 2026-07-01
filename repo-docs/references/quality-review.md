# Quality Review For the vuln-mine Guide

This is an audit note for the guide. It checks whether the guide transfers a usable reader model and whether the main claims are evidence-backed.

## Reader Simulation

| Reader question | Answer from the guide |
| --- | --- |
| What real path is followed? | `/vuln-mine example` against the built-in `naiveparse` ASan target, whose finished state is checked in at `runs/smoke-example/`. |
| What is hard or non-trivial? | Keeping the search from re-reading source and re-guessing every iteration, and classifying crashes without LLM self-judgment. |
| What changes at each phase? | INIT seeds 7 memory files; EXPLORE runs Reader→Synthesizer→Analyst batches that mutate them; REPORT reads them back unchanged. |
| Where do assumptions stop? | The ASan `abort_on_error` carry-forward only covers `asan`; the live-network prep path is fixture-tested, not real-clone-proven; MSan/UBSan sweep is a v1 limitation. |
| What would prove this explanation wrong? | `test-validate-manifest.sh` (injection gate), `test-write-back.sh` (concurrency), and an empty `verified_crashes` in the smoke run (ASan carry-forward). |
| What would a careful newcomer ask next? | "How does a target get from a GitHub URL to this manifest?" — answered in [manifest-contract](manifest-contract.md) and labeled as fixture-tested. |
| How can I verify it? | Rebuild, re-seed, re-run the loop, replay the PoC — the verify block at the end of [one-real-run.md](../walkthroughs/one-real-run.md). |

| Review question | Result | Evidence | Follow-up |
| --- | --- | --- | --- |
| Can a reader state the hard part in one sentence? | Yes. | [one-real-run.md opening](../walkthroughs/one-real-run.md) | None. |
| Does the evidence map prove at least two modeling passes? | Yes. | [Evidence Traversal Log](source-evidence.md#evidence-traversal-log) | None. |
| Does the guide answer the strongest likely follow-up? | Yes. | [manifest-contract.md](manifest-contract.md) prep section | Add a real-clone walkthrough when a v2 network path lands. |
| What remains out of scope or partially verified? | `vuln-target-prep` live clone; MSan/UBSan. | [source-evidence coverage note](source-evidence.md) | Document when those paths stabilize. |

Residual risk: the guide describes the Workflow-tool-driven loop from `explore-loop.js` and the checked-in `smoke-example` state. A reader who cannot invoke the Workflow tool (e.g. from a subagent) hits SKILL.md §4's reduced manual simulation; the guide mentions this but does not walk it.

Evidence status: Confirmed unless noted.
