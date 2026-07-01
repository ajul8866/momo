---
name: vuln-target-prep
description: Turn a public GitHub C/C++ repo into a ready-to-mine fuzz target — clone, fingerprint, analyze, build, harness, and emit a vuln-mine manifest. Use as `/vuln-target-prep <github-url> [<name>]`.
---

# vuln-target-prep

Clones a native C/C++ source tree, fingerprints it, drives the analyze+build+harness
workflow, and emits a `vuln-mine` manifest + input grammar under
`.claude/skills/vuln-mine/manifests/<name>/`. On success the target is runnable via
`/vuln-mine <name>`.

## Conventions

- `$PREP` = `.claude/skills/vuln-target-prep` (this skill root, below).
- `$MINE` = `.claude/skills/vuln-mine` (consumer skill root, below).
- `$SRC` = `$PREP/targets/<name>/src`.
- `$MANIFEST_DIR` = `$MINE/manifests/<name>`.
- All paths printed to the user MUST be absolute. Paths inside `manifest.yaml`
  MUST be relative to the manifest dir (`vuln-mine`'s `init-memory.sh` cds there).

## Invocation

`/vuln-target-prep <github-url> [<name>]`

## 1. CLONE & INDEX

Inputs: `<github-url>`, optional `<name>`.

1. Derive `<name>` if not supplied: take the last URL path segment, strip a trailing
   `.git`, lowercase, replace non-alphanumerics with `-`.
2. Shallow-clone the source:
   ```sh
   SRC=$PREP/targets/<name>/src
   mkdir -p "$SRC"
   git clone --depth 1 <url> "$SRC"
   ```
   ponytail: `--depth 1` ships no history for commit-bisection analysis.
   Ceiling: version-specific bugs. Upgrade: add a `--ref <tag>` option to pin a commit.
3. Fingerprint the source:
   ```sh
   bash $PREP/helpers/fingerprint.sh "$SRC" > "$SRC.fingerprint.json"
   ```
   Produces `{lang, compiler, build_system, deps[], missing_deps[], file_count, loc}`.
4. Gate: if `lang` is not `c` or `c++` → **STOP** with
   `vuln-mine only mines native C/C++ (detected: <lang>)`.

## 2. ANALYZE + 4. HARNESS (write harness.c)

Invoke the Claude Code **Workflow** tool:

- `scriptPath`: `.claude/skills/vuln-target-prep/workflow/analyze-and-harness.js`
- `parameters`:
  ```json
  {
    "src_dir": "<SRC>",
    "name": "<name>",
    "manifest_dir": "<MANIFEST_DIR>",
    "fingerprint": "<fingerprint.json contents>"
  }
  ```

The Workflow runs two stages internally: ANALYZE source (→ `analysis.yaml`) then
HARNESS (writes `harness.c`). After it returns:

- Read `analysis.yaml`. If `analysis.target_function` is null or unclear → **STOP**
  with `could not identify a single target function — analysis inconclusive`.
- If `analysis.input_format` is absent or has no `known_valid_patterns` → **STOP**
  with `cannot materialize baseline input without known_valid_patterns`.

## 3. BUILD

Build the target into a static library and capture a build log:

```sh
OUT=$PREP/targets/<name>/out
mkdir -p "$OUT"
bash $PREP/helpers/build-target.sh "$SRC" "$OUT" "$SRC.fingerprint.json"
```

`build-target.sh` runs a fallback chain A → B → C and prints the winning strategy:

- **A** cmake/ninja → `<name>.a`
- **B** plain `cc -c` + `ar rcs` → `<name>.a`
- **C** the target's own file-reading CLI → a CLI binary, sets `harness=cli`

If exit != 0 → **STOP** and surface `build.log`: print missing deps matched to an
`apt install` suggestion, then stop. Do not auto-install
(ponytail: avoid silent sudo prompts; upgrade path: print the suggestion and let
the user re-run).

If strategy **C** won, set `HARNESS_MODE=cli` and **skip Phase 4 compile** — the
CLI binary IS the harness. Note `harness=cli` so Phase 5 sets
`binary: <name>` (CLI binary) instead of `<name>_fuzz`.

## 4. HARNESS (compile)

Skip this phase entirely if `HARNESS_MODE=cli` (Phase 3 already produced the
harness binary). Otherwise compile `harness.c` (written by the Workflow in Phase 2)
and link it against the `.a` from Phase 3 with ASan:

```sh
MANIFEST_DIR=$MINE/manifests/<name>
mkdir -p "$MANIFEST_DIR"
cc -fsanitize=address -g -O1 \
  -I"$SRC" $(find "$SRC" -name '*.h' -printf '-I%h\n' | sort -u) \
  "$MANIFEST_DIR/harness.c" "$OUT/<name>.a" \
  -o "$MANIFEST_DIR/<name>_fuzz"
```

If linking fails with unresolved symbols, retry adding `-l<dep>` for each entry in
`fingerprint.deps[]` that is present on the system; if a missing dep is in
`missing_deps[]` → **STOP** and surface the Phase 3 `build.log` diagnosis.

## 5. VERIFY + EMIT

### (a) Valid input — expect EXIT=0

Materialize the smallest entry from `analysis.input_format.known_valid_patterns` to
`$MANIFEST_DIR/baseline.bin`, then:

```sh
bash $PREP/helpers/verify-crash.sh "$MANIFEST_DIR/<BIN>" "$MANIFEST_DIR/baseline.bin"
```

- EXIT=0 → harness accepts the baseline; continue.
- If it crashes → a pre-existing bug finding; note it (potential win) and continue.

### (b) Hostile boundary input — expect crash

Build a boundary-pushing input from `analysis.input_format` field constraints
(oversize lengths, truncation at magic offsets, OOB indices) and run it through
`verify-crash.sh`. Expect a SIGABRT (ASan) or SIGSEGV.

- If a crash is observed → note the signal; continue.
- If NO input ever crashes → warn the user that the target may be robust, but
  continue (vuln-mine will fuzz deeper).

### (c) Write manifest.yaml + format.grammar.yaml

`<BIN>` is `<name>_fuzz` in compiled-harness mode, or `<name>` in cli mode.

Write `$MANIFEST_DIR/manifest.yaml`:
```yaml
name: <name>
source_root: src
binary: <BIN>            # RELATIVE to manifest dir: <name>_fuzz, or <name> in cli mode
harness_cmd: "{{binary}} {{input}}"
sanitizer: <asan|msan|ubsan|none>   # from fingerprint/analysis
timeout_sec: 10
input_format:
  spec_file: format.grammar.yaml
success_condition:
  kind: crash
  must_reach: null
  acceptable_signals: [SIGABRT, SIGSEGV]
constraints:
  - "input must begin with: <first known_valid_pattern magic>"
budget:
  max_iterations: 20
```
(`acceptable_signals: [SIGABRT]` is correct for ASan targets — `run-harness.sh`
sets `ASAN_OPTIONS=abort_on_error=1` on ASan builds.)

Write `$MANIFEST_DIR/format.grammar.yaml` from `analysis.input_format`:
```yaml
format: <name>
grammar:
  - <field>: <type/desc>      # one entry per field in analysis.input_format.grammar
field_constraints:
  - {field: "<f>", type: "<t>", min: <m>, max: <x>, boundary_values: [...]}
known_valid_patterns:
  - "<pattern>"
known_invalid_patterns:
  - "<pattern>"
```

### (d) FINAL GATE — validate-manifest.sh MUST exit 0

`validate-manifest.sh` runs from the manifest's own dir, so relative paths must
resolve there. Run it:
```sh
( cd "$MANIFEST_DIR" && bash "$MINE/helpers/validate-manifest.sh" manifest.yaml )
```
- exit 0 → target ready.
- exit != 0 → read stderr, fix inline (binary path / spec_file relative), re-run
  until exit 0. Common fixes: `binary` must be relative to the manifest dir
  (not absolute); `spec_file: format.grammar.yaml` for a file that exists in
  the same dir.
- If it cannot be made to pass → **STOP** and surface the validator stderr.

## End

Print:
```
Target ready. Run: /vuln-mine <name>
```

## § Smoke test

Task 7 wires an automated no-network fixture. Until then, a manual smoke test:

- Clone a tiny public C parser repo (e.g. a single-file JSON or TOML parser with a
  `main` that reads from a file argument), OR
- use a local fixture under `.claude/skills/vuln-target-prep/helpers/tests/`
  containing a minimal C library with a known crash on malformed input.

Run `/vuln-target-prep <repo-url> <name>` end to end and assert:

1. `$MANIFEST_DIR/manifest.yaml` exists.
2. `( cd "$MANIFEST_DIR" && bash "$MINE/helpers/validate-manifest.sh" manifest.yaml )`
   exits 0.
3. The compiled `<name>_fuzz` (or CLI binary) accepts a baseline input with EXIT=0
   and crashes on the hostile input.

Assertion (2) is the contract gate — the final-gate line in Phase 5 (d) must hold.
