# Glossary

| Term | Plain meaning | Further reading |
| --- | --- | --- |
| vuln-mine | The skill that mines a prepared target for memory-safety bugs via the Reader→Synthesizer→Analyst loop, producing verified PoCs. Invoked as `/vuln-mine <name>`. | [structured-memory](modules/structured-memory.md) |
| vuln-target-prep | The upstream skill that turns a GitHub C/C++ repo into a ready-to-mine target: clone, fingerprint, analyze, build, harness, emit manifest. Invoked as `/vuln-target-prep <url>`. | [manifest-contract](references/manifest-contract.md) |
| manifest | The operator-authored YAML contract that describes one target: binary, harness command, sanitizer, success condition, input format. It is the trust boundary INIT consumes. | [manifest-contract](references/manifest-contract.md) |
| memory category | One of the seven YAML files (01–07) the loop reads and writes per run. Each holds one object of the mining process. | [structured-memory](modules/structured-memory.md) |
| Reader / Synthesizer / Analyst | The three roles in one explore iteration. Reader reads source; Synthesizer crafts one PoC aimed at a named branch; Analyst runs it and writes back the deterministic verdict. | [structured-memory](modules/structured-memory.md) |
| stagnation | A counter of consecutive non-crashing runs. At 3 it forces the next Synthesizer to switch vector. | [structured-memory](modules/structured-memory.md) |
| verified_crash | A PoC whose run matched `success_condition` — its signal is in `acceptable_signals` and its location satisfies `must_reach`. The loop's win condition; never LLM-judged. | [deterministic-classification](modules/deterministic-classification.md) |
| ASan carry-forward | The harness exports `ASAN_OPTIONS=abort_on_error=1` for `asan` targets so a bug surfaces as SIGABRT/134 and matches `acceptable_signals`. | [deterministic-classification](modules/deterministic-classification.md) |
| harness_cmd | The command template run per PoC. Only `{{binary}}` and `{{input}}` are interpolated; all other shell metacharacters are rejected by the validator. | [manifest-contract](references/manifest-contract.md) |
| rev | A per-file counter that every write-back bumps, so concurrent writers do not silently lose updates. | — |
| SUT | System under test — the target binary the harness runs. The example SUT is `naiveparse`, a deliberate bug. | — |
| init-memory.sh | INIT helper that validates the manifest, build-probes the binary, and seeds the seven memory files for a run. | — |
| run-harness.sh | Renders `harness_cmd`, forces ASan `abort_on_error=1` for asan targets, runs under `timeout`, and prints `EXIT=<n>`. | deterministic-classification |
| recompute-stagnation.sh | Recomputes and persists `stagnation_counter` from the last run: a crash resets it, a non-crash bumps it. | structured-memory |
| acceptable_signals | The signal list in `success_condition` a crash must match to count as verified. | manifest-contract |
| acceptable_signals: [SIGABRT, SIGSEGV] | The concrete value the example ASan target uses. SIGABRT appears because the carry-forward forces ASan to abort on a bug. | deterministic-classification |
| parse_np naiveparse.c:22 | The crash site in the example SUT: the unbounded `memcpy` in `parse_np`, line 22 of `naiveparse.c`. Used as the worked crash throughout the guide. | deterministic-classification |
| target.sanitizer | The manifest field naming the target's instrumentation (`asan`/`msan`/`ubsan`/`none`). Drives the ASan carry-forward. | deterministic-classification |
| write-back.sh | Appends one record to a memory category under `flock`, bumps `rev`, and replaces the file atomically so parallel writers never clobber. | structured-memory |
| crash location | The `fn file.c:line` the sanitizer's first stack frame points at. Recorded per run; checked against `must_reach` when set. | deterministic-classification |
