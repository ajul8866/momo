# vuln-target-prep — Auto-Prepare Fuzz Targets from a GitHub Repo — Design

**Date:** 2026-07-01
**Status:** Approved (brainstorming)
**Runtime:** Claude Code (agents = sub-agents + Workflow tool; helpers = bash scripts)

## 1. Purpose & Core Idea

A skill that turns a **bare GitHub URL** into a ready-to-mine target for the
existing `vuln-mine` skill. The user supplies only a repo link; the skill clones,
reads the source, picks a parser function, builds the target with AddressSanitizer,
writes a harness + manifest + input-format spec, and verifies the result. The
output is a `manifests/<name>/` directory that satisfies `vuln-mine`'s
`validate-manifest.sh` contract — so the user can then run `/vuln-mine <name>`.

This closes the gap that "repo publik sembarang" almost never ships a fuzzer
harness: the skill **writes the harness itself**.

## 2. Decisions (from brainstorming)

| # | Aspect | Decision |
|---|--------|----------|
| 1 | Target source | Arbitrary public GitHub repo (link) |
| 2 | Harness | AI writes a new C harness that calls a target parser function |
| 3 | Harness↔target link | Build target into a `.a` static lib via its native build system, link harness to it |
| 4 | On failure | Auto-retry a chain of build strategies before giving up with a diagnosis |
| 5 | Architecture | One monolithic pipeline skill `vuln-target-prep` (recommended option A) |
| 6 | Chaining | Skill prepares only; user runs `vuln-mine` separately (no auto-chain in v1) |

## 3. High-Level Architecture

One skill `vuln-target-prep`. Input: a GitHub URL (+ optional name). Output:
`manifests/<name>/` that passes `validate-manifest.sh`, ready for `vuln-mine`.

```
/vuln-target-prep <github-url> [<name>]
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│ 1. CLONE & INDEX                                         │
│    git clone --depth 1 → targets/<name>/src/             │
│    fingerprint: language, build system, deps, size       │
└──────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│ 2. ANALYZE (AI sub-agent via Workflow)                   │
│    read source → pick 1 parser function + signature +    │
│    input format (magic/grammar/boundary)                 │
└──────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│ 3. BUILD (fallback-chain, auto-retry)                    │
│    A: build .a via native build system + ASan            │
│    B: compile-gabung (single cc command)                 │
│    C: use target's own file-reading CLI as harness       │
│    stop only if all three fail (with diagnosis)          │
└──────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│ 4. HARNESS (AI writes)                                   │
│    harness.c: read input file → call target parser       │
│    compile + link to .a (or use CLI) → ASan binary       │
└──────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│ 5. VERIFY + EMIT                                         │
│    a. run binary on minimal valid input → EXIT=0         │
│    b. run on synthetic hostile input → crash (proof of   │
│       triggerability)                                    │
│    c. write manifest.yaml + format.grammar.yaml          │
│    d. validate-manifest.sh → MUST exit 0 (final gate)    │
└──────────────────────────────────────────────────────────┘
        │
        ▼
  output: manifests/<name>/  →  user runs /vuln-mine <name>
```

**Separation of responsibilities:**
- **AI sub-agents (Workflow)** = judgment work (read source, pick function, write harness, infer grammar).
- **Bash helpers** = deterministic work (clone, build, fingerprint, verify crash) — must not "guess".
- **`vuln-mine`'s `validate-manifest.sh`** = the final gate proving the output is consumable (single source of truth for the cross-skill contract).

## 4. Phase Details

### 4.1 CLONE & INDEX (deterministic, bash helper)
```
targets/<name>/src/  ←  git clone --depth 1 <url>
```
**Fingerprint** (`fingerprint.sh`, JSON to stdout):
- **Language**: count `.c`/`.h` (C) vs `.cpp`/`.cc`/`.cxx` (C++); choose compiler `cc` vs `c++`.
- **Build system**: `CMakeLists.txt` → cmake; `Makefile`/`*.mk` → make; `configure`/autotools; `meson.build`; none → "raw".
- **Dependencies**: scan non-standard `#include` across all `.c/.h`; check `pkg-config`/`find_package` in build files → list external libs (zlib, libpng, openssl…). Flag those **not installed** (early warning for the build phase).
- **Size**: file count + total LOC. If over threshold (e.g. 200 files / 50k LOC), flag "large — vuln-mine Reader may need focus".

### 4.2 ANALYZE (AI sub-agent via Workflow)
One (or two parallel) sub-agent reads source and emits, into `analysis.yaml`:
- **`target_function`**: name + full signature (return type, params, file:line). Selection criteria: takes a buffer/length or stream, processes untrusted data, has loops/memory ops (memcpy/malloc/array index) where memory bugs live.
- **`input_format`**: inferred grammar (magic bytes, field structure, types, boundary values) → becomes `format.grammar.yaml`.
- **`link_info`**: what to `#include`/link so the harness can call it; whether the function is `static`/internal (needs `--whole-archive` or to be exposed).

Output `analysis.yaml` is a work file, not the final output. BUILD and HARNESS read it.

### 4.3 BUILD (deterministic fallback-chain, bash helper)
See §5 for the full chain. Produces `<name>.a` (or `.o`/binary) + `build.log`. Exits 0 on success, 1 with diagnosis on total failure.

### 4.4 HARNESS (AI writes harness.c)
Sub-agent writes `harness.c`:
```c
#include <stdio.h>
#include <stdlib.h>
#include "<target header>"

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(n);
    fread(buf, 1, n, f);
    fclose(f);
    <target_function>(buf, n);   /* call the target parser */
    free(buf);
    return 0;
}
```
Compile + link to `.a` (strategy A) or gabung (strategy B). Final binary: `<manifest_dir>/<name>_fuzz`.

### 4.5 VERIFY + EMIT
- **a. Minimal valid input** (AI materializes from `known_valid_patterns`): run → must be `EXIT=0` with no sanitizer. (Proves harness isn't broken.)
- **b. Synthetic hostile input** (grammar boundary values: oversize len, extreme fields): run → must crash (`EXIT!=0` + ASan line). (Proves triggerability — if it never crashes, warn the target function may be a wrong pick.)
- **c. Write** `manifest.yaml` (from fingerprint + analysis + success_condition) and `format.grammar.yaml` (from analysis).
- **d. Final gate**: `bash vuln-mine/helpers/validate-manifest.sh manifests/<name>/manifest.yaml` → **MUST exit 0**. If it fails, fix inline (binary path, spec_file, etc.) until it passes. On exit 0 → `manifests/<name>/` is ready.

## 5. Build Fallback-Chain & Error Handling

### 5.1 Build strategies (tried in order until one succeeds)
```
build-target.sh tries:

A) NATIVE BUILD SYSTEM → .a
   - cmake:  mkdir build && cd build &&
             cmake .. -DCMAKE_C_FLAGS="-fsanitize=address -g" \
                      -DCMAKE_BUILD_TYPE=Debug &&
             make <target-lib>
   - make:   make CFLAGS="-fsanitize=address -g" CC=cc
   - autotools: ./configure CC=cc CFLAGS="-fsanitize=address -g" && make
   - detect output: find *.a or collect final *.o
   - if deps missing (zlib etc) → FAIL A, record "missing: zlib"

B) COMPILE-GABUNG (single command)
   - gather all core .c (skip target's main, skip test/example)
   - cc -fsanitize=address -g -O1 -I<include> *.c harness.c -o binary
   - if unresolved symbols (external lib) → try -l<dep>;
     if dep absent → FAIL B

C) TARGET CLI AS HARNESS (skip .a entirely)
   - if target has a main() CLI that reads a file (argv[1]) → build that CLI
     binary as the harness, DO NOT write harness.c
   - vuln-mine harness_cmd = invoke the CLI directly
```

### 5.2 Auto-retry rules
- Each strategy's outcome is logged in `build.log` (command + exit + last 5 stderr lines).
- Stop at the first strategy that yields a working ASan binary.
- If all three fail → **clean stop** with structured diagnosis: which strategies were tried, why each failed, what deps are missing, concrete suggestion ("install zlib1g-dev then re-run"). **No unbounded guessing.**

### 5.3 Failure modes & response
| Failure | Response |
|---|---|
| Clone fails (bad URL / private) | Stop: "repo cannot be cloned, check URL/access" |
| Not C/C++ (e.g. pure Python/Go) | Stop: "vuln-mine only mines native C/C++ targets" |
| External dep not installed | Try strategies that don't need it; if all need it → stop + `apt install` suggestion |
| ANALYZE finds no clear parser function | Stop: "no clear parser function identified; user must point to one" |
| Harness link fails (unresolved symbols) | Auto-retry B/C; if still failing → stop + list missing symbols |
| VERIFY: valid input crashes (pre-existing bug) | **Not a failure** — that's a finding! Record as bonus, continue to emit manifest |
| VERIFY: hostile input never crashes | Warning (not stop): "target may be hard to trigger / wrong function", but manifest still emitted |
| validate-manifest fails at gate | Auto-fix inline (binary path, spec_file relative-CWD) until exit 0; if impossible → stop |

### 5.4 Deliberate simplifications
- `ponytail:` **Shallow clone `--depth 1`** — no git history analysis. Ceiling: bugs that only appear at a specific version. Upgrade path: `--ref` option to checkout a tag/commit.
- `ponytail:` **Single-config build** (ASan only, not multi-sanitizer parallel). Ceiling: bugs that are MSan/UBSan-sensitive only. Upgrade path: per-sanitizer build loop.
- `ponytail:` **No auto dependency install** (`apt install` needs sudo/confirmation — skill won't run it unprompted). Ceiling: repo needs a rare lib. Upgrade path: skill *suggests* the install command, user runs it, re-run prep.

## 6. Skill Structure & Helpers

One monolithic skill (consistent with `vuln-mine`). Bash helpers for deterministic
work, a Workflow for judgment work.
```
.claude/skills/vuln-target-prep/
├── SKILL.md                  # protocol: 5 sequential phases
├── helpers/
│   ├── fingerprint.sh        # detect lang/build-system/dep/size → JSON
│   ├── build-target.sh       # fallback-chain .a / compile-gabung (auto-retry)
│   ├── verify-crash.sh       # run binary on input → classify crash/benign
│   └── tests/                # assert-based, one per helper
│       ├── run-all.sh
│       ├── test-fingerprint.sh
│       ├── test-build-target.sh
│       └── test-verify-crash.sh
├── workflow/
│   └── analyze-and-harness.js # AI sub-agents: ANALYZE (read source) + HARNESS (write harness.c)
└── targets/                  # clone results (contents gitignored except final manifest)
    └── <name>/               # src/ (cloned), analysis.yaml, harness.c, build artifacts
```

**Final output** (consumed by vuln-mine) is written into vuln-mine's contract dir:
`.claude/skills/vuln-mine/manifests/<name>/` (`manifest.yaml`, `format.grammar.yaml`,
binary, `harness.c`). So `vuln-target-prep` *writes into another skill* via the
existing contract path.

### Helper responsibilities
| Helper | Input | Output | Deterministic? |
|---|---|---|---|
| `fingerprint.sh <src-dir>` | cloned source dir | JSON `{lang, compiler, build_system, deps[], missing_deps[], file_count, loc}` | yes (file scan + grep) |
| `build-target.sh <src-dir> <out-dir> <fingerprint.json>` | source + fingerprint | `<out-dir>/<name>.a` (or `.o`/binary) + `build.log`; exit 0/1 | yes (tries A→B, records winning strategy) |
| `verify-crash.sh <binary> <input> <timeout>` | binary + input file | `EXIT=<n>\|SIGNAL=...\|ASAN=bool` (reuses vuln-mine's classify logic) | yes |

### Workflow `analyze-and-harness.js`
Two-stage pipeline:
- **ANALYZE** `agent()` reads source via Bash (grep/Glob), emits `analysis.yaml` (target_function signature, input_format, link_info). Structured schema.
- **HARNESS** `agent()` reads `analysis.yaml`, writes `harness.c` via the Write tool, documents how to compile it.

Not parallel across the two stages (HARNESS needs ANALYZE output); internal parallelism possible (e.g. multiple agents reading source concurrently).

## 7. Testing, Scope, Cross-Skill Interface

### 7.1 Testing
Approach matches `vuln-mine`: deterministic helpers = assert-based bash unit tests; pipeline = end-to-end smoke test on a sample repo.
- **`test-fingerprint.sh`** — mini fixtures: dir with `CMakeLists.txt` + `.c` → `{lang:c, compiler:cc, build_system:cmake}`; dir with no build file → `build_system:raw`; pure `.py` dir → flagged non-C.
- **`test-build-target.sh`** — small C repo with Makefile → strategy A yields `.a`; repo with no build file → fallback B (compile-gabung) succeeds; repo with missing dep → all three fail + diagnosis.
- **`test-verify-crash.sh`** — binary + valid input → `EXIT=0\|ASAN=false`; OOB input → `EXIT=134\|ASAN=true`.
- **End-to-end smoke** — clone one small real public C repo (or use vuln-mine's own `example` target as a known-path fixture), run `/vuln-target-prep <url>`, then assert: (a) `manifests/<name>/manifest.yaml` exists, (b) `validate-manifest.sh` exits 0, (c) binary exists & executable, (d) valid input does not crash.

### 7.2 Cross-skill interface (contract)
```
vuln-target-prep  ──writes──►  .claude/skills/vuln-mine/manifests/<name>/
                                  ├── manifest.yaml       (passes validate-manifest.sh)
                                  ├── format.grammar.yaml (input_format.spec_file)
                                  ├── <name>_fuzz          (ASan binary, executable)
                                  └── harness.c            (harness source, for repro)

user  ──runs──►  /vuln-mine <name>   (reads manifests/<name>/manifest.yaml)
```
**Binding contract:**
- Prep output **MUST** pass vuln-mine's `validate-manifest.sh` (phase-5 final gate). That is the single truth — if the manifest validates, vuln-mine can consume it.
- `manifest.yaml.binary` = path **relative to the manifest dir** (matches `init-memory.sh`, which cds to the manifest dir). Prep must write a relative path, not absolute, for portability.
- Prep does NOT invoke `vuln-mine` (decision #6). Prep only prepares + prints the final instruction "run `/vuln-mine <name>`".

### 7.3 v1 / v2 scope
- **v1 (this spec):** public GitHub repo `--depth 1`; build chain A→B→C single-config ASan; dep detection + manual install suggestion; 1 target function, argv-file harness; 1 ANALYZE sub-agent; user runs vuln-mine manually.
- **v2 (upgrade path, explicitly deferred):**
  - Specific tag/commit, private repos (auth), tarball archives.
  - Multi-sanitizer parallel build (ASan+UBSan+MSan).
  - Auto-install deps (with sudo confirmation).
  - Multi-entry / native libFuzzer `LLVMFuzzerTestOneInput` harness.
  - Multi-agent parallel ANALYZE per-component.
  - Auto-chain prep → vuln-mine.

## 8. Open Items (none blocking v1)
- Choice of a small, real public C repo for the end-to-end smoke test (must be cloneable and have a clear parser). Candidates to confirm during implementation.
- Exact LOC/file-count threshold for the "large target" fingerprint flag.
