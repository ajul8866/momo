# Vulnerability-Oriented Memory for LLM-Driven Fuzzing — Design

**Date:** 2026-07-01
**Status:** Approved (brainstorming)
**Runtime:** Claude Code (agents = sub-agents + Workflow tool; memory = files on disk)

## 1. Purpose & Core Idea

A structured **memory method** for vulnerability mining of native (C/C++) targets.
Instead of re-reading context and re-guessing each iteration, the system maintains
continuously-updated **task memory** organized around the objects of the mining process
(goal, code-path, input-format, candidate PoC, negative evidence, verification, next-constraint).
Every code read, execution result, and failed attempt is converted into **reusable constraints**
for the next PoC, turning mining into an evidence-based convergence process rather than
"read the context again and guess again."

## 2. Decisions (from brainstorming)

| # | Aspect | Decision |
|---|--------|----------|
| 1 | Runtime | Di atas Claude Code (agents = sub-agents + Workflow; memory = repo files) |
| 2 | Target | Generic — target supplied as input per-invocation (binary + harness + input-format spec) |
| 3 | Memory store | Directory + one YAML/JSON file per category |
| 4 | Stop/budget | Keep mining to collect **multiple** PoCs; stop when budget exhausted (dedup variants) |
| 5 | Agent roles | Three separate roles: Reader → Synthesizer → Analyst |
| 6 | Architecture | One monolithic skill `vuln-mine` (recommended option A) |

## 3. High-Level Architecture

One skill `vuln-mine` containing the entire mining protocol. Memory = run directory +
7 YAML files. Loop = a Reader→Synthesizer→Analyst pipeline driven by the Workflow tool.
Crash verification = `Bash` (run harness, capture sanitizer).

```
invocation: /vuln-mine <target>
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│  INIT (phase 1)                                          │
│  create runs/<run-id>/ , seed 7 YAML files from manifest │
│  (binary, harness, input-format, success condition)      │
└──────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│  EXPLORE LOOP  (Workflow, parallel per-hypothesis)       │
│   ┌──────────┐   ┌──────────────┐   ┌──────────┐         │
│   │ Reader   │──▶│ Synthesizer  │──▶│ Analyst  │        │
│   │ read src │   │ 1 PoC+reason │   │ run      │        │
│   │ upd code-│   │ upd candidate│   │ harness  │        │
│   │ path/fmt │   │ -poc         │   │ upd verif│        │
│   └──────────┘   └──────────────┘   └──────────┘         │
│         │              │                │                 │
│         └──── write-back to 7 YAML files (concurrent) ───│
│   loop: while budget.remaining() > floor AND not stopped │
└──────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│  REPORT                                                  │
│  summarize verified PoCs, mined areas, dead ends         │
└──────────────────────────────────────────────────────────┘
```

- **`runs/<run-id>/`** = per-invocation memory instance. Multiple runs do not interfere.
- **`vuln-memory/`** = cross-run memory promoted from a run (generic code-path findings
  reusable for the same target in future runs). v1: optional/empty (upgrade path).
- **The skill is pure protocol**, not application code. Deterministic logic (sanitizer
  parsing, variant dedup, memory compaction) = small Bash/`jq` helper scripts invoked by
  agents, not a library.

## 4. The Seven Memory Categories

`runs/<run-id>/` holds 7 YAML files, one per category. Every file carries a `rev` that
increments on each write-back — used to detect stale reads during parallel agent operation.

### 4.1 `01-goal.yaml`
```yaml
rev: 3
target:
  binary: ./targets/pngparse/pngfuzz        # harness binary
  harness_cmd: "./pngfuzz {{input}}"        # {{input}} = path to PoC
  sanitizer: asan                           # asan|msan|ubsan|none
  build_ok: true                            # result of INIT build-check
success_condition:
  kind: crash                               # crash|hang|oom|leak|sanitizer_flag
  must_reach: null                          # optional symbol/file:line (definitive)
  acceptable_signals: [SIGSEGV, SIGABRT]    # empty = any crash
constraints:                               # most important constraints for this task
  - "input must pass PNG magic-number check at minimum"
budget:
  max_iterations: 40
  stop_when: budget_exhausted              # decision #4
```
**Read-only after INIT** — no agent writes the goal during the loop, eliminating one
whole class of conflicts.

### 4.2 `02-code-path.yaml`
```yaml
rev: 5
entry_points:
  - {fn: LLVMFuzzerTestOneInput, file: harness.c:24, confirmed: true}
parsing_chain:
  - {fn: png_read_sig,       file: pngread.c:101, role: "magic-number gate"}
  - {fn: png_read_chunk_hdr, file: pngread.c:188, role: "per-chunk loop"}
suspicious:
  - {fn: png_inflate_IDAT, file: pngread.c:412, why: "len from chunk, no clear bound-check"}
data_flows:
  - "chunk.length → malloc → memcpy(len)"   # manual taint flow
```

### 4.3 `03-input-format.yaml`
```yaml
rev: 2
format: PNG
grammar:                                     # pseudo-grammar / structure
  - magic: "\x89PNG\r\n\x1a\n"
  - chunk*: {len:u32, type:u4, data:len, crc:u32}
field_constraints:
  - {field: "chunk.length", type: u32, max: 0x7fffffff, boundary_values: [0, 0xffffffff]}
known_valid_patterns: ["<minimal 1x1 IHDR+IDAT+IEND>"]
known_invalid_patterns: ["<IDAT without IHDR → rejected early, not a vector>"]
```

### 4.4 `04-candidate-poc.yaml`
```yaml
rev: 9
candidates:
  - id: poc-007
    file: runs/r-2026-07-01/pocs/poc-007.bin
    rationale: "chunk.length = 0xffffffff in IDAT → malloc overflow"
    targets_branch: "pngread.c:412 len unchecked"
    hypothesis_status: unverified          # unverified|verified_crash|verified_benign
    derived_from: [poc-003]                # mutation chain
verified_crashes:                          # moved here when Analyst confirms
  - {poc_id: poc-005, signal: SIGSEGV, sanitizer: "heap-buffer-overflow", at: "pngread.c:419"}
```

### 4.5 `05-negative.yaml`
```yaml
rev: 6
non_triggering:
  - {poc_id: poc-002, reason: "rejected at magic-number gate, never reached parser"}
unreachable:
  - {branch: "png_handle_APNG", reason: "feature compiled out (#ifdef PNG_NO_APNG)"}
build_failures: []
format_errors:
  - {pattern: "chunk.type not 4 ASCII", reason: "harness rejects before parser"}
mined_areas:                               # for decision #4 (variant dedup)
  - "chunk.length overflow in IDAT — already mined (poc-003..007)"
```

### 4.6 `06-verification.yaml`
```yaml
rev: 4
last_run:
  poc_id: poc-007
  harness_exit: 1
  stdout_tail: "..."                       # last 2-3 lines
  sanitizer_output: "ERROR: AddressSanitizer: heap-buffer-overflow..."
  crash: true
  crash_location: "pngread.c:419"
  why_no_crash: null                       # filled if crash=false
verdict: needs_more                        # needs_more|converging|stuck
```

### 4.7 `07-next-constraint.yaml`
```yaml
rev: 4
next_iteration_must:
  - "reach branch pngread.c:412 (png_inflate_IDAT) — untouched by any PoC yet"
  - "chunk.length must be > buffer_size (0x10000) to trigger overflow"
  - "AVOID corrupting magic number (already negative, see 05)"
open_hypotheses:
  - "if type=tEXt with large len → different path, worth trying"
stagnation_counter: 1                      # consecutive iterations with no new evidence
```

### 4.8 Key properties (deliberate)
1. **`07-next-constraint.yaml` is "the conclusion"**, not abstract — it translates all prior
   memory into *concrete constraints* the next PoC must satisfy. This is what makes the loop
   converge rather than "guess again."
2. **`mined_areas` + `derived_from`** = the variant-dedup mechanism (decision #4): once an
   area is mined, `05-negative` + `07` steer the Synthesizer to a new area.
3. **`rev` on every file** = stale-read detection when parallel agents read-modify-write the
   same file (see §7.2).

## 5. The Explore Loop & Three Roles

The loop runs inside one Workflow tool call. Each iteration = one item flowing through a
3-stage pipeline (Reader → Synthesizer → Analyst) with **no barrier between stages**. Many
iterations run concurrently until slots are full (~10 agents at once).

### 5.1 Stage 1 — `Reader` (schema: code-path + input-format)
Read source snippets around the target branch; update **only** `02-code-path.yaml` &
`03-input-format.yaml`.
- Reads: `01-goal` (target area), `02`/`03` (known landscape), `07-next-constraint` (area to explore).
- Writes: new entries to `02`/`03` only. Does **not** touch PoC, verification, or next-constraint.
- Structured output: `{parsing_chain[], suspicious[], data_flows[], format_facts[]}` → agent only
  summarizes, a `jq` helper merges into the category file.

### 5.2 Stage 2 — `Synthesizer` (schema: candidate-poc)
Produce **one** PoC + rationale; update `04-candidate-poc.yaml`.
- Reads: `02`/`03` (landscape), `04` (mutation chain `derived_from`), `05-negative` (avoid),
  `07` (constraints that **must** hold).
- Writes: one `{id, file, rationale, targets_branch, derived_from}` + writes the PoC binary to
  `runs/<run-id>/pocs/`.
- Rule: PoC **must** state `targets_branch` (the concrete branch aimed at) — schema rejects a
  PoC without a branch target. This forces concrete hypotheses, not random guessing.

### 5.3 Stage 3 — `Analyst` (schema: verification + negative + next-constraint)
Run the PoC via `Bash`, classify the result, update `06`/`05`/`07`.
- Reads: `04` (new PoC + `01-goal.harness_cmd`).
- Runs: `timeout 30 ./pngfuzz poc-XXX.bin` (or the harness command from goal); capture exit code
  + tail of stdout/stderr.
- Decides: crash? sanitizer tripped? why not (if benign)?
- Writes:
  - `06-verification.yaml` (this run's result)
  - `05-negative.yaml` (if benign / branch not reached → record + raise `mined_areas`)
  - `07-next-constraint.yaml` (constraint for the next iteration — raise `stagnation_counter`
    when no new evidence)
  - `04-candidate-poc.verified_crashes` (if crash confirmed → move here)

### 5.4 Loop control
```js
phase('Explore')
while (budget.remaining() > FLOOR) {           // decision #4
  const batch = make_iterations(N, read_state()) // N = remaining agent slots
  await pipeline(batch, Reader, Synthesizer, Analyst)
  recompute_stagnation()                        // helper: read 07, bump/reset counter
}
```
- **`stagnation_counter`** = convergence signal. When ≥ K (e.g. 3) consecutive iterations yield
  no new evidence, the next Synthesizer is instructed to **switch vector** (read
  `07.open_hypotheses`, pick an untried one) — prevents spinning in an exhausted area.
- **Budget `FLOOR`** = reserve tokens for the REPORT phase (e.g. 10% held back).
- No early-exit on crash (decision #4): crash recorded, area marked in `mined_areas`, loop
  continues seeking a different vector.

### 5.5 Why three separate roles (not monolithic) — concrete implication
- **Narrow prompt per role** → the LLM need not hold "code + format + PoC + result" at once;
  each role focuses on 2-3 category files.
- **Structured schema** → deterministic write-back, not free text to be parsed (reduces memory
  corruption).
- **Cost: ~3× agent calls per iteration vs 1×.** Trade-off is deliberate for memory quality;
  paid for by budget control (small N per batch, floor for report).

## 6. INIT Phase: Target Manifest & Memory Bootstrap

Because the target is generic input (decision #2), the system needs **one structured entry
point** carrying all target specifics: the manifest. INIT transforms the manifest into the 7
seeded YAML files.

### 6.1 Target manifest (`targets/<name>/manifest.yaml`)
One file per target that the user supplies. This is a trust-boundary input, so INIT
**validates** required fields before use.
```yaml
# targets/pngparse/manifest.yaml
name: pngparse
source_root: ./targets/pngparse/src          # for Reader (code-path memory)
binary: ./targets/pngparse/pngfuzz           # must exist & be executable
harness_cmd: "{{binary}} {{input}}"          # {{input}} = PoC path; {{binary}} substituted
sanitizer: asan                              # asan|msan|ubsan|none
timeout_sec: 30                              # per-run kill
input_format:
  spec_file: ./targets/pngparse/png.grammar.yaml   # pointer → loaded into 03-input-format
  # OR inline: magic, grammar, field_constraints, boundary_values
success_condition:
  kind: crash                                # crash|hang|oom|leak|sanitizer_flag
  must_reach: null                           # optional: file:line or symbol
  acceptable_signals: [SIGSEGV, SIGABRT]
constraints: []                              # free-form notes specific to target
budget:
  max_iterations: 40
```

### 6.2 INIT steps (single-threaded, before the loop)
```
1. VALIDATE MANIFEST
   - required fields present? (name, binary, harness_cmd, sanitizer, input_format,
     success_condition, budget)
   - binary exists & executable?      (file check — failure = INIT fails, not the loop)
   - spec_file present & parseable?
   - harness_cmd contains only {{binary}} {{input}} placeholders?
     (reject commands with shell metachars outside template — trust boundary)

2. BUILD-CHECK                              ← initial proof the harness can run
   - run: timeout <t> <binary> /dev/null    (empty / minimal-valid input)
   - result → 01-goal.build_ok
   - if build/run fails → INIT fails, do not enter loop (saves wasted budget)

3. CREATE RUN DIRECTORY
   - runs/<run-id>/    run-id = ISO timestamp via Bash `date`   (in the skill, not workflow JS)
   - runs/<run-id>/pocs/

4. SEED 7 YAML FILES
   01-goal          ← manifest (name, binary, harness, sanitizer, success, constraints, budget)
   02-code-path     ← minimal seed: entry_point = harness main (LLVMFuzzerTestOneInput/main);
                      parsing_chain/suspicious EMPTY (Reader's job to fill)
   03-input-format  ← manifest spec_file (magic, grammar, field_constraints, boundary_values)
   04-candidate-poc ← verified_crashes: [], candidates: []
   05-negative      ← mined_areas: [], all lists empty
   06-verification  ← verdict: "fresh"
   07-next-constraint ← next_iteration_must: ["reach main parser then identify the first
                       unbounded chunk-handler"];
                       open_hypotheses: []; stagnation_counter: 0

5. OPTIONAL: BASELINE POC                    ← confirm harness accepts the format
   - if manifest provides known_valid_patterns[0] → materialize to pocs/baseline.bin
   - run, record result to 06 as "baseline run" (not an iteration, not budget-counted)
   - asserts: valid input → no crash (a crash at baseline = pre-existing bug, useful info)
```

### 6.3 INIT output = loop-ready state
After INIT the 7 files are in a state where `07-next-constraint` already has **one concrete
constraint** (reach the main parser + find an unbounded handler), so iteration #1 immediately
has direction — no "searching without aim" iteration.

### 6.4 Deliberate simplifications
- `ponytail:` **No indexing/DB** — Reader uses `grep`/`Glob` directly on `source_root`.
  Ceiling: repo > ~50k LOC (needs ctags/LSP index). Upgrade path: add a `.ctags` index at INIT.
- `ponytail:` **Static manifest per target** — no auto-rediscovery of grammar. Ceiling: target
  with undocumented format. Upgrade path: Reader fills `03` incrementally, then a new target's
  INIT reuses it.

## 7. Crash Verification & Memory Concurrency

Two mechanisms that decide whether memory can be trusted: (A) how the system decides "this is a
valid crash," and (B) how many agents write to the same YAML files without overwriting each other.

### 7.1 Crash verification (Analyst via `Bash`)
```
cmd = render(harness_cmd, {binary, input: poc_path})     # from 01-goal
run:   timeout {timeout_sec} {cmd} 2>stderr.log >stdout.log; echo "EXIT=$?"
```

**Result classification** (deterministic, `jq`/bash helper — not LLM judgment):

| Signal | `crash` | Sanitizer output? | `verdict` | Writes to |
|---|---|---|---|---|
| `EXIT=0`, no `ERROR:` sanitizer | `false` | — | `needs_more` | `05-negative` (benign), bump stagnation |
| `EXIT=134` (SIGABRT) **or** line `ERROR: AddressSanitizer: ...` | `true` | yes → extract `sanitizer_kind`+`at` | `converging` | `04.verified_crashes`, reset stagnation |
| `EXIT=139` (SIGSEGV) without sanitizer | `true` | `null` | `converging` | `04.verified_crashes` |
| `EXIT=124` (timeout) | `false` (hang) | — | `needs_more` | `05-negative` (hang), record as separate hang hypothesis |
| Build/crash outside harness | — | — | `stuck` | `05.build_failures` |

**Sanitizer extraction** (regex on stderr, bash helper):
- kind: `ERROR: (AddressSanitizer|MemorySanitizer|UndefinedBehaviorSanitizer): (\w[\w-]*)` →
  `sanitizer_kind` (e.g. `heap-buffer-overflow`)
- location: `#0 .* in (\w+) (\S+:\d+)` → `crash_location`

**`why_no_crash` required when `crash=false`** — the Analyst schema rejects a benign record
without a reason (e.g. "rejected at magic gate", "OOB read but ASan off", "reached branch but
operation is safe"). This forces meaningful negative evidence, not just "failed."

**Success vs collection (decision #4):**
- A match against `success_condition` (e.g. `kind=crash` + signal in `acceptable_signals`, or
  `must_reach` matches `crash_location`) → PoC moved to `04.verified_crashes`, area tagged in
  `05.mined_areas`.
- But the loop **does not stop** — the next iteration is forced to seek a different vector
  (Synthesizer reads `mined_areas`, rejects already-mined areas).

### 7.2 Memory concurrency (parallelism over files on disk)
Within one `pipeline(...)` batch, up to ~10 agents are active simultaneously. Write conflicts
can occur when two Analyst agents (from different iterations) want to write
`07-next-constraint.yaml` at nearly the same time.

**Strategy: serialize writes per-category via lock file + optimistic `rev`.**
```
write_back(category, new_record):
    acquire  runs/<run-id>/.locks/<category>.lock   # flock; waits if busy
    read     <category>.yaml → current              # re-read latest rev INSIDE lock
    if current.rev != rev_the_agent_read:           # stale-read detected
        merge_record(new_record, current)           # re-merge atop newest state
    current.rev += 1
    append new_record
    write current
    release lock
```
- **`flock` per-category** = cheap serialization: only one writer per file at a time. Readers
  stay parallel (reads are not locked).
- **Stale-read detection via `rev`** = if an agent read `rev=4`, then at write time `rev` is
  already `6` (another agent wrote first), this agent **re-merges** its record atop the newest
  state rather than overwriting. Prevents loss of another agent's evidence.
- **Write only to your own category files**: Reader → `02`/`03`, Synthesizer → `04`, Analyst →
  `05`/`06`/`07`. Cross-role collisions only happen **within** the same role (multiple Analysts
  writing `07`), resolved by lock+rev.
- **`01-goal.yaml` read-only after INIT** — no agent writes the goal during the loop, removing
  one conflict class entirely.

### 7.3 Deliberate simplifications
- `ponytail:` **Merge strategy = simple append** (no recursive semantic-merge). Ceiling: two
  agents write mutually-contradictory records (e.g. one says branch A is safe, one says
  dangerous). Upgrade path: before append, run a small consistency check of the new record vs
  related categories.
- `ponytail:` **No full MVCC** — only `rev` + re-merge. Ceiling: very high throughput (>50
  concurrent agents). Upgrade path: per-batch snapshot + diff.

## 8. REPORT Phase, Skill Structure, Testing, Scope

### 8.1 REPORT phase
Runs after the loop (outside Workflow, in the skill directly). Reads final memory state,
produces a summary.
```
1. Verified PoCs ← read 04.verified_crashes → list (id, signal, sanitizer, at, PoC file)
2. Mined areas  ← read 05.mined_areas → what was explored
3. Dead ends    ← read 05 (unreachable, build_failures, format_errors)
4. Open hypotheses ← read 07.open_hypotheses → "directions not tried, worth continuing"
5. Statistics   ← iterations run, crashes found, useful-experiment ratio
6. Output to terminal ← markdown summary; PoCs ready to use (absolute paths)
7. OPTIONAL: promote ← generic code-path findings (not PoC-specific) → vuln-memory/<target>/
   for reuse in future runs (upgrade path, empty in v1)
```

### 8.2 Skill `vuln-mine` structure
One monolithic skill (decision #6). Since this is "on top of Claude Code," artifacts = skill
directory + protocol, not application code.
```
.claude/skills/vuln-mine/
├── SKILL.md                  ← protocol: INIT → EXPLORE → REPORT + invoke Workflow
├── memory-schemas/           ← the 7 category schemas (single source of truth)
│   ├── 01-goal.yaml … 07-next-constraint.yaml
├── manifests/                ← example manifest + format spec
│   └── example/  (manifest.yaml, format.grammar.yaml, seed baseline)
├── helpers/                  ← deterministic scripts (called by agents via Bash)
│   ├── validate-manifest.sh  ← check fields + binary + placeholder
│   ├── run-harness.sh        ← render cmd + timeout + capture EXIT/sanitizer
│   ├── parse-sanitizer.sh    ← regex extract kind+location from stderr
│   ├── write-back.sh         ← flock + rev + append per-category
│   └── recompute-stagnation.sh ← read 07, compute stagnation_counter
└── workflow/
    └── explore-loop.js       ← Workflow script: pipeline(Reader, Synthesizer, Analyst)
                                + budget/stagnation control
```

**Separation of responsibilities:**
- **SKILL.md** = high-level orchestration + when to invoke Workflow.
- **`helpers/*.sh`** = deterministic logic (must not "guess"): validation, crash classification,
  concurrency. This is where serious bugs are prevented (trust boundary `validate-manifest`,
  data safety = `write-back` flock).
- **`workflow/explore-loop.js`** = parallel control structure + per-role prompts (LLM prompts
  live here, not in shell).
- **`memory-schemas/`** = single source of truth for the shape of each category — the
  Reader/Synthesizer/Analyst schemas in Workflow reference these.

### 8.3 Testing
Approach: **helper = small assert-based bash unit test; loop = end-to-end smoke test on the
example target.** No framework.
- **`helpers/*.test.sh`** — one file per helper, simple asserts:
  - `validate-manifest`: manifest missing field → non-zero exit; missing binary → non-zero;
    foreign placeholder → non-zero.
  - `parse-sanitizer`: stderr containing `ERROR: AddressSanitizer: heap-buffer-overflow` +
    stack → extracts correct kind+loc; empty stderr → null.
  - `write-back`: 2 concurrent writes to same category → no record lost, `rev` increments
    correctly.
  - `recompute-stagnation`: 3 iterations with no new evidence → counter = 3.
- **End-to-end smoke test** — `manifests/example/` provides one mini target (e.g. a naive C
  parser <100 LOC with a deliberate OOB bug) + a valid baseline. Run `/vuln-mine example` with a
  small budget (e.g. 5 iterations) → assert: at least 1 PoC in `04.verified_crashes`, function.

### 8.4 v1 / v2 scope
- **v1 (this spec):** single skill; 7-category file memory; Reader→Synthesizer→Analyst pipeline;
  deterministic verification; flock+rev concurrency; collect-multiple-PoC loop; helper tests +
  one example smoke target.
- **v2 (upgrade path, explicitly deferred):**
  - Multi-agent fan-out at higher concurrency (>10) → full MVCC snapshot/diff.
  - Cross-run `vuln-memory/` promotion and reuse.
  - Semantic-merge consistency checker for write-back.
  - Source indexing (ctags/LSP) for large targets.
  - Auto-rediscovery of undocumented input formats.

## 9. Open Items (none blocking v1)
- Exact value of stagnation threshold K and budget FLOOR — tune during implementation on the
  example target.
- Example target choice for the smoke test — pick a small parser with a known, reproducible bug.
