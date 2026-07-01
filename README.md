# momo — LLM-driven memory-safety fuzzing for C/C++

Two Claude Code skills that work together: point them at a C/C++ codebase and
they hunt for memory-safety bugs (out-of-bounds, use-after-free, stack overflow),
producing **verified PoC inputs** that actually crash the target under
AddressSanitizer.

```
GitHub repo ──/vuln-target-prep──▶ ready fuzz target ──/vuln-mine──▶ verified PoC(s)
```

This is a research/exploration harness, not a coverage-guided fuzzer replacement.
It complements libFuzzer/AFL: where classic fuzzers mutate inputs blindly, this
system **reads the source**, forms hypotheses about where a bug lives, and crafts
inputs aimed at that spot — using a structured memory that converges instead of
re-guessing.

## Requirements

All confirmed present on the dev host (Ubuntu + apt):

| Tool | Why |
|---|---|
| `cc`/`gcc` 15, `clang` 21 | Build targets with `-fsanitize=address\|memory\|undefined` |
| `cmake` 4.2, `make`, `patch`, `pkg-config` | Native target build systems |
| `python3` + PyYAML | Helper logic + YAML read/emit |
| `node` v22 | Workflow scripts (run by Claude Code) |
| `jq`, `flock`, `timeout`, `grep` | Bash helpers (validation, locking, execution) |
| `git` | Clone targets |

Optional: `clang` enables MSan (gcc lacks it); `cmake` only if a target uses it.

## Install

Clone and open in Claude Code — the skills live under `.claude/skills/` and are
auto-discovered:

```bash
git clone <this-repo> momo && cd momo
claude   # opens Claude Code; both skills are available
```

No build step, no dependencies to install. Verify the helpers work:

```bash
bash .claude/skills/vuln-target-prep/helpers/tests/run-all.sh   # prep suite
bash .claude/skills/vuln-mine/helpers/tests/run-all.sh          # mine suite
```

## Usage

### 1. Prepare a target (`vuln-target-prep`)

Give it a public GitHub repo. It clones, fingerprints the build system, has an
AI agent read the source to pick a parser function and infer the input format,
builds with ASan, writes a harness, and emits a manifest.

```
/vuln-target-prep https://github.com/<owner>/<repo> [<name>]
```

Output lands in `.claude/skills/vuln-mine/manifests/<name>/` (manifest, format
grammar, ASan binary, harness source). The skill's final gate runs
`vuln-mine`'s `validate-manifest.sh` — if it doesn't pass, the skill stops and
tells you why.

**If a target needs external libraries**, the skill stops with an `apt install`
suggestion (it will not `apt install` unprompted). Install the lib, re-run.

### 2. Mine it (`vuln-mine`)

```
/vuln-mine <name>
```

It bootstraps a 7-category structured memory, then runs a
Reader→Synthesizer→Analyst loop that reads the code, crafts candidate PoC inputs,
runs them under the harness, and records what happened — converging toward a
crash. Output: verified PoCs as binary files plus a markdown report.

## How it works

### `vuln-target-prep` — 5 phases

1. **Clone & fingerprint** — `git clone --depth 1`; detect language, build system,
   dependencies, size.
2. **Analyze** (AI) — read source, pick one parser function + signature, infer
   the input format (magic/grammar/boundary values).
3. **Build** — fallback chain with auto-retry: (A) native build system → `.a`,
   (B) compile-gabung single `cc`, (C) target's own file-reading CLI as harness.
   Stops at the first that works; on total failure, emits a structured
   diagnosis (missing deps + `apt` suggestion).
4. **Harness** (AI) — writes `harness.c` that reads an input file and calls the
   target parser; compiled + linked to the `.a` with ASan.
5. **Verify & emit** — confirms a valid input doesn't crash and a hostile one
   does, then writes the manifest and passes `validate-manifest.sh`.

### `vuln-mine` — 7-category memory + 3-role loop

The core contribution is structured task memory (7 YAML files per run, under
`runs/<run-id>/`):

| File | Holds |
|---|---|
| `01-goal.yaml` | target, harness, sanitizer, success condition, budget |
| `02-code-path.yaml` | entry points, parsing chain, suspicious functions, data flows |
| `03-input-format.yaml` | grammar, field constraints, boundary values |
| `04-candidate-poc.yaml` | candidate inputs + rationale; verified crashes |
| `05-negative.yaml` | non-triggering attempts, unreachable paths, mined areas |
| `06-verification.yaml` | per-run execution results history |
| `07-next-constraint.yaml` | concrete constraints the next PoC must satisfy |

Each iteration: **Reader** (reads source, updates code-path/format) →
**Synthesizer** (crafts one PoC aimed at a specific branch) → **Analyst** (runs
it, classifies crash deterministically, updates verification/negative/constraints).
The loop continues to collect multiple PoCs; on stagnation it forces a vector
switch. Crash classification is deterministic (exit code + sanitizer regex), not
LLM judgment.

## Project layout

```
.claude/skills/
├── vuln-target-prep/        # GitHub URL → ready target
│   ├── SKILL.md
│   ├── helpers/{fingerprint,build-target,verify-crash}.sh + tests/
│   └── workflow/analyze-and-harness.js
└── vuln-mine/               # target → verified PoC
    ├── SKILL.md
    ├── helpers/{validate-manifest,run-harness,parse-sanitizer,
    │            write-back,recompute-stagnation,init-memory,
    │            classify-result,lib-yaml}.sh + tests/
    ├── workflow/explore-loop.js
    ├── memory-schemas/      # the 7 category shape templates
    └── manifests/
        └── example/         # built-in ASan target (naiveparse) for smoke tests

docs/superpowers/
├── specs/                   # design docs (brainstorming output)
└── plans/                   # TDD implementation plans

runs/                        # per-invocation memory (gitignored)
```

## Built-in example

The `example` target (`naiveparse`) is a tiny C parser with a deliberate
out-of-bounds bug, used by the test suites. Build and trigger it manually:

```bash
bash .claude/skills/vuln-mine/manifests/example/src/build.sh
# valid input — no crash:
printf 'NPv1\x01\x00A' > /tmp/valid.bin
.claude/skills/vuln-mine/manifests/example/naiveparse /tmp/valid.bin; echo "EXIT=$?"
# hostile input — ASan reports the overflow (default exit 1; the harness
# helper sets ASAN_OPTIONS=abort_on_error=1 to surface it as SIGABRT/134):
printf 'NPv1\x80\x00%0128d' 0 > /tmp/oob.bin
.claude/skills/vuln-mine/manifests/example/naiveparse /tmp/oob.bin; echo "EXIT=$?"  # nonzero
```

## Testing

Pure-bash, assert-based, no framework:

```bash
bash .claude/skills/vuln-target-prep/helpers/tests/run-all.sh
bash .claude/skills/vuln-mine/helpers/tests/run-all.sh
```

The prep smoke test exercises the full cross-skill contract end-to-end on a local
fixture (no network): fingerprint → build → harness → verify → manifest →
`validate-manifest.sh` exit 0.

## Limitations (v1)

- **Live-Workflow path is tested by fixture, not by a real network clone.** The
  first real GitHub target is the true end-to-end test; `validate-manifest.sh`
  is the backstop that prevents a broken manifest from reaching `vuln-mine`.
- **No auto dependency install** — missing libs halt with a suggestion.
- **Single-config ASan build** (no parallel MSan/UBSan sweep).
- **Shallow clone only** (no specific tag/commit, no private repos).
- Targets must be **C/C++**; the skill stops cleanly on other languages.
- Compiling and running untrusted C is inherent to the tool's purpose — run it
  on targets you trust or in a sandbox. Sandbox isolation is deferred to v2.

## Design & plans

- `docs/superpowers/specs/2026-07-01-vuln-mine-design.md`
- `docs/superpowers/specs/2026-07-01-vuln-target-prep-design.md`
- `docs/superpowers/plans/2026-07-01-vuln-mine.md`
- `docs/superpowers/plans/2026-07-01-vuln-target-prep.md`
