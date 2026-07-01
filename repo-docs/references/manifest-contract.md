# Manifest contract and validator rules

This is lookup material. Read [one-real-run.md](../walkthroughs/one-real-run.md) first if you do not yet understand why a manifest gates the mining loop.

The manifest is the operator-authored contract that INIT consumes to seed memory and that every harness run reads. It lives at `vuln-mine/manifests/<name>/manifest.yaml`. Because it is authored by hand and its `harness_cmd` is later run under `bash -c`, it is a trust boundary — [`validate-manifest.sh`](../../.claude/skills/vuln-mine/helpers/validate-manifest.sh) gates it before anything executes.

## Required fields

| Field | Meaning | Notes |
| --- | --- | --- |
| `name` | Target name | Used for run-dir naming and reporting. |
| `binary` | Path to the instrumented binary | Resolved relative to the manifest dir (see below). |
| `harness_cmd` | Command template run per PoC | Only `{{binary}}` and `{{input}}` are interpolated; everything else is literal. |
| `sanitizer` | Instrumentation kind | One of `asan` / `msan` / `ubsan` / `none`. |
| `input_format.spec_file` | Path to the grammar YAML | Resolved relative to the manifest dir; must exist and parse. |
| `success_condition.kind` | What counts as a win | `crash` for this skill. |
| `success_condition.acceptable_signals` | Signals that verify a crash | `[SIGABRT, SIGSEGV]` for ASan targets. |
| `success_condition.must_reach` | Required crash location, or null | Null means any location qualifies. |
| `budget.max_iterations` | Iteration budget | 10% held back for REPORT. |

See the live example at [`manifest.yaml`](../../.claude/skills/vuln-mine/manifests/example/manifest.yaml).

## Path resolution rule

`binary` and `input_format.spec_file` are **relative to the manifest's own directory**, not to the repo root or CWD. `validate-manifest.sh` and `init-memory.sh` both `cd` into the manifest dir so these resolve exactly as documented. A common failure is an absolute `binary` path or a `spec_file` that does not exist in the same dir — the validator catches both.

## harness_cmd injection gate

`harness_cmd` is the one field that can run arbitrary shell, so the validator masks the two allowed placeholders and rejects any remaining metacharacter:

| Construct | Allowed outside placeholders? |
| --- | --- |
| `{{binary}}`, `{{input}}` | Yes — the only interpolated values, both operator-chosen. |
| `;` `\|` `&` `$` `` ` `` `<` `>` | No — rejected. |
| `$(...)` | No — rejected explicitly. |
| Newline / other control chars | No — rejected. |

A manifest with `harness_cmd: "a; rm -rf /"` is rejected with a forbidden-metacharacter error. The fixture for that case is [`injection.yaml`](../../.claude/skills/vuln-mine/helpers/tests/fixtures/validate/injection.yaml), and `test-validate-manifest.sh` asserts it fails. This is the boundary that lets the loop safely interpolate and execute the command in [`run-harness.sh`](../../.claude/skills/vuln-mine/helpers/run-harness.sh).

## How prep produces a manifest

`vuln-target-prep` is the upstream skill that emits this manifest from a GitHub URL: it clones, fingerprints, analyzes the source, builds via a fallback chain (cmake → compile-gabung → target CLI), writes a `harness.c`, verifies valid-vs-hostile input, and writes `manifest.yaml` + `format.grammar.yaml`. Its own final gate runs the same `validate-manifest.sh`, so a target cannot reach `vuln-mine` with a broken manifest. The live-network clone path is fixture-tested (`test-smoke-prep.sh`) but a real GitHub clone is the documented first end-to-end test.

Evidence status: Confirmed unless a row says otherwise.
