# vuln-target-prep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `vuln-target-prep` Claude Code skill that turns a bare GitHub URL into a ready-to-mine target (validated manifest + ASan binary + harness) consumable by the existing `vuln-mine` skill.

**Architecture:** One monolithic skill with a 5-phase pipeline (CLONE & INDEX → ANALYZE → BUILD → HARNESS → VERIFY + EMIT). Deterministic logic (fingerprint, fallback-chain build, crash verification) lives in bash helpers; judgment work (read source, pick parser function, write harness, infer input format) lives in a Workflow script (`analyze-and-harness.js`). The final gate is `vuln-mine`'s `validate-manifest.sh` — prep's output MUST pass it.

**Tech Stack:** Bash helpers + asserts (`jq`, `flock`, `timeout`, `grep`, `ar`), Python 3 + PyYAML (JSON/YAML emit), Node v22 (Workflow scripts), `cc`/`gcc`/`clang` with `-fsanitize=address`, `cmake`/`make`/`autotools` (native target builds), Claude Code skills + Workflow tool. Existing `vuln-mine` skill is the consumer (its `validate-manifest.sh` is the cross-skill gate).

## Global Constraints

Copied verbatim from `docs/superpowers/specs/2026-07-01-vuln-target-prep-design.md`:

- **Runtime:** Claude Code (agents = sub-agents + Workflow tool; helpers = repo files). No standalone app/server.
- **Input:** a public GitHub URL (+ optional name); clone via `git clone --depth 1`.
- **Output:** `.claude/skills/vuln-mine/manifests/<name>/` (`manifest.yaml`, `format.grammar.yaml`, `<name>_fuzz` ASan binary, `harness.c`) that PASSES `bash .claude/skills/vuln-mine/helpers/validate-manifest.sh <manifest.yaml>` (exit 0).
- **Manifest path rule:** `manifest.yaml.binary` must be RELATIVE to the manifest dir (vuln-mine's `init-memory.sh` cds to the manifest dir); `harness_cmd` uses only `{{binary}} {{input}}` placeholders.
- **Build:** fallback-chain A (native build system → `.a`) → B (compile-gabung) → C (target CLI as harness); auto-retry, stop at first success; on total failure, emit a structured diagnosis (missing deps + `apt` suggestion) and STOP — no unbounded guessing.
- **Cross-skill:** prep does NOT invoke `vuln-mine`; it only prepares and prints "run `/vuln-mine <name>`".
- **Deliberate simplifications (ponytail):** shallow clone only (ceiling: version-specific bugs); single-config ASan build (ceiling: MSan/UBSan-only bugs); no auto `apt install` (ceiling: rare-lib repos — suggest the command, user runs it).

## File Structure

```
.claude/skills/vuln-target-prep/
├── SKILL.md                       # 5-phase protocol (Task 6)
├── helpers/
│   ├── fingerprint.sh             # <src-dir> -> JSON {lang,compiler,build_system,deps,missing_deps,file_count,loc} (Task 2)
│   ├── build-target.sh            # fallback-chain .a / compile-gabung / CLI (auto-retry) (Task 4)
│   ├── verify-crash.sh            # <binary> <input> <timeout> -> EXIT|SIGNAL|ASAN (Task 3)
│   └── tests/
│       ├── run-all.sh             # globs test-*.sh + *.test.sh, exits nonzero on first failure (Task 7)
│       ├── test-fingerprint.sh
│       ├── test-build-target.sh
│       ├── test-verify-crash.sh
│       ├── test-smoke-prep.sh     # end-to-end on a local fixture repo (Task 7)
│       └── fixtures/
├── workflow/
│   └── analyze-and-harness.js     # AI: ANALYZE (source -> analysis.yaml) + HARNESS (write harness.c) (Task 5)
└── targets/                       # clone results (contents gitignored)
    └── <name>/src/

# Final output (written by prep, consumed by vuln-mine):
.claude/skills/vuln-mine/manifests/<name>/
    ├── manifest.yaml              # passes validate-manifest.sh
    ├── format.grammar.yaml        # input_format.spec_file
    ├── <name>_fuzz                # ASan binary, executable
    └── harness.c                  # harness source (for repro)
```

**Responsibility boundaries (locked here):**
- `helpers/*.sh` = pure deterministic logic; each independently unit-testable; no LLM calls.
- `workflow/analyze-and-harness.js` = the only place LLM prompts live (ANALYZE reads source; HARNESS writes harness.c).
- `SKILL.md` = orchestration glue: when to call which helper / Workflow, and the final validate-manifest gate.
- Cross-skill contract = vuln-mine's `validate-manifest.sh` (single source of truth).

---

I have all the context I need: the spec, the exact manifest/grammar shapes, the classify-result logic, the test conventions (assert_contains, mktemp+trap, "ALL PASS"), and the gitignore/branch state. Writing the three tasks now.

### Task 1: Scaffold vuln-target-prep skill tree + gitignore

This is scaffolding only (not TDD). We create the locked directory tree, seed empty dirs with `.gitkeep`, and extend `.gitignore` so cloned repos under `targets/` are ignored while the skill source itself stays tracked.

The locked structure to materialize:
```
.claude/skills/vuln-target-prep/
├── helpers/
│   └── tests/
├── workflow/
└── targets/
```
`SKILL.md`, `helpers/*.sh`, and `workflow/*.js` are created in later tasks — so the three leaf dirs are empty now and need `.gitkeep`.

- [ ] **Step 1: Confirm starting branch and clean tree**

Run:
```bash
cd /root/momo
git branch --show-current
git status --porcelain
```
Expected output (exactly):
```
feat/vuln-target-prep
```
(clean tree → the `git status --porcelain` line prints nothing).

- [ ] **Step 2: Create the directory tree**

Run:
```bash
cd /root/momo
mkdir -p .claude/skills/vuln-target-prep/helpers/tests
mkdir -p .claude/skills/vuln-target-prep/workflow
mkdir -p .claude/skills/vuln-target-prep/targets
```
These three `mkdir -p` chains are idempotent; re-running is safe.

- [ ] **Step 3: Seed empty leaf dirs with `.gitkeep`**

Git does not track empty directories. Each of `helpers/tests/`, `workflow/`, and `targets/` would be empty until later tasks, so we drop a `.gitkeep` (zero-byte placeholder) in each.

Run:
```bash
cd /root/momo
: > .claude/skills/vuln-target-prep/helpers/tests/.gitkeep
: > .claude/skills/vuln-target-prep/workflow/.gitkeep
: > .claude/skills/vuln-target-prep/targets/.gitkeep
```
(`: > file` truncates/creates a zero-byte file without invoking `echo`/`touch`.)

- [ ] **Step 4: Extend `.gitignore` — ignore cloned target contents, keep skill source**

We must ignore the *contents* of `targets/<name>/` (cloned repos + build artifacts) but keep `targets/.gitkeep` and all other skill source files tracked. The pattern `.claude/skills/vuln-target-prep/targets/*/` matches directories one level under `targets/` (the cloned repos) but does **not** match `targets/.gitkeep` (a file, not a directory — the trailing `/` requires a directory).

Append these two lines to the existing `/root/momo/.gitignore`:
```
# vuln-target-prep: ignore cloned target repo contents, keep skill source
.claude/skills/vuln-target-prep/targets/*/
```

Run (appends the two lines verbatim):
```bash
cd /root/momo
printf '%s\n' \
  '# vuln-target-prep: ignore cloned target repo contents, keep skill source' \
  '.claude/skills/vuln-target-prep/targets/*/' >> .gitignore
```

- [ ] **Step 5: Verify the tree with `find`**

Run:
```bash
cd /root/momo
find .claude/skills/vuln-target-prep -maxdepth 3 | sort
```
Expected output (exactly these 6 lines):
```
.claude/skills/vuln-target-prep
.claude/skills/vuln-target-prep/helpers
.claude/skills/vuln-target-prep/helpers/tests
.claude/skills/vuln-target-prep/helpers/tests/.gitkeep
.claude/skills/vuln-target-prep/targets
.claude/skills/vuln-target-prep/targets/.gitkeep
.claude/skills/vuln-target-prep/workflow
.claude/skills/vuln-target-prep/workflow/.gitkeep
```
(That is 8 entries: the root + 3 subdirs + 3 `.gitkeep` files + the `helpers` dir = 8 lines. Count: root, helpers, helpers/tests, helpers/tests/.gitkeep, targets, targets/.gitkeep, workflow, workflow/.gitkeep = 8.)

- [ ] **Step 6: Verify the gitignore rule behaves — `.gitkeep` tracked, a fake clone ignored**

Run:
```bash
cd /root/momo
mkdir -p .claude/skills/vuln-target-prep/targets/fakeclone
: > .claude/skills/vuln-target-prep/targets/fakeclone/secret.txt
git check-ignore .claude/skills/vuln-target-prep/targets/fakeclone/secret.txt && echo "CLONE_IGNORED_OK"
git check-ignore .claude/skills/vuln-target-prep/targets/.gitkeep && echo "GITKEEP_BADLY_IGNORED" || echo "GITKEEP_TRACKED_OK"
```
Expected output (exactly):
```
.claude/skills/vuln-target-prep/targets/fakeclone/secret.txt
CLONE_IGNORED_OK
GITKEEP_TRACKED_OK
```
(The first `check-ignore` prints the ignored path and exits 0 → `&&` fires `CLONE_IGNORED_OK`. The second exits 1 for the `.gitkeep` file → `||` fires `GITKEEP_TRACKED_OK`.)

Now remove the fake clone so it does not pollute the commit:
```bash
cd /root/momo
rm -rf .claude/skills/vuln-target-prep/targets/fakeclone
```

- [ ] **Step 7: Stage and inspect**

Run:
```bash
cd /root/momo
git add .gitignore .claude/skills/vuln-target-prep
git status --porcelain
```
Expected output (exactly):
```
 M .gitignore
A  .claude/skills/vuln-target-prep/helpers/tests/.gitkeep
A  .claude/skills/vuln-target-prep/targets/.gitkeep
A  .claude/skills/vuln-target-prep/workflow/.gitkeep
```

- [ ] **Step 8: Commit**

Run:
```bash
cd /root/momo
git commit -m "chore: scaffold vuln-target-prep skill tree"
```
Expected: one commit created, working tree clean (`git status --porcelain` empty afterwards).

---

### Task 2: fingerprint.sh — TDD

`fingerprint.sh <src-dir>` prints one JSON object to stdout:
`{lang, compiler, build_system, deps[], missing_deps[], file_count, loc}`.

Detection rules (spec §4.1):
- **Language/compiler**: count `.c`/`.h` → `lang=c`, `compiler=cc`; count `.cpp`/`.cc`/`.cxx` → `lang=c++`, `compiler=c++`. Whichever side has more files wins. Neither C nor C++ but `.py` present → `lang=python`, `compiler=""`.
- **Build system**: `CMakeLists.txt` anywhere → `cmake`; else `Makefile`/`*.mk` → `make`; else `configure` script → `autotools`; else `meson.build` → `meson`; else `raw`.
- **deps/missing_deps**: scan `#include <X>` / `#include "X"` across all `.c/.cpp/.h/.hpp/.hh/.hxx`; filter out a curated set of standard headers; each remaining top-level stem is a candidate dep. A dep is "present" if `pkg-config --exists <stem>` succeeds OR its header is found under a standard include path; otherwise it lands in `missing_deps[]`.
- **file_count/loc**: number of C/C++/header source files and total `wc -l` over them.

We write the failing test first with four inline fixtures, see it fail, then write the minimal helper.

- [ ] **Step 1: Write the failing test `test-fingerprint.sh`**

Create `/root/momo/.claude/skills/vuln-target-prep/helpers/tests/test-fingerprint.sh` with this full content:

```bash
#!/usr/bin/env bash
# test-fingerprint.sh — assert fingerprint.sh detects lang/compiler/build_system (spec §4.1, §7.1)
set -euo pipefail

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helpers_dir="$(dirname "$__dir")"

assert_contains() {
  if printf '%s' "$1" | grep -q -- "$2"; then echo "PASS: $3";
  else echo "FAIL: $3 ('$1' missing '$2')"; exit 1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# (a) tiny C project: CMakeLists.txt + 2 .c files -> cmake
proj_a="$tmp/proj_cmake"
mkdir -p "$proj_a"
cat > "$proj_a/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.10)
project(tiny C)
CMAKE
cat > "$proj_a/a.c" <<'C'
#include <stdio.h>
int a_fn(void) { return 1; }
C
cat > "$proj_a/b.c" <<'C'
#include <stdio.h>
int b_fn(void) { return 2; }
C
out="$(bash "$helpers_dir/fingerprint.sh" "$proj_a")"
assert_contains "$out" '"lang": "c"'           "(a) lang=c"
assert_contains "$out" '"compiler": "cc"'      "(a) compiler=cc"
assert_contains "$out" '"build_system": "cmake"' "(a) build_system=cmake"

# (b) Makefile + .c -> make
proj_b="$tmp/proj_make"
mkdir -p "$proj_b"
cat > "$proj_b/Makefile" <<'MAKE'
all: prog
prog: m.c
	cc -o prog m.c
MAKE
cat > "$proj_b/m.c" <<'C'
#include <stdio.h>
int main(void){ return 0; }
C
out="$(bash "$helpers_dir/fingerprint.sh" "$proj_b")"
assert_contains "$out" '"build_system": "make"' "(b) build_system=make"

# (c) no build file + .c -> raw
proj_c="$tmp/proj_raw"
mkdir -p "$proj_c"
cat > "$proj_c/lonely.c" <<'C'
#include <stdlib.h>
int lonely(void){ return 42; }
C
out="$(bash "$helpers_dir/fingerprint.sh" "$proj_c")"
assert_contains "$out" '"build_system": "raw"' "(c) build_system=raw"

# (d) pure python -> lang=python (NOT c/c++)
proj_d="$tmp/proj_py"
mkdir -p "$proj_d"
cat > "$proj_d/app.py" <<'PY'
print("hi")
PY
out="$(bash "$helpers_dir/fingerprint.sh" "$proj_d")"
assert_contains "$out" '"lang": "python"' "(d) lang=python"

echo "ALL PASS"
```

- [ ] **Step 2: Run the test — it must FAIL with a named reason**

Run:
```bash
cd /root/momo
bash .claude/skills/vuln-target-prep/helpers/tests/test-fingerprint.sh
```
Expected: failure. Since `fingerprint.sh` does not exist yet, the first `bash "$helpers_dir/fingerprint.sh" ...` call fails with:
```
bash: .../fingerprint.sh: No such file or directory
```
and `set -e` aborts the test (exit non-zero) before any `PASS:` line prints. The named reason is "fingerprint.sh: No such file or directory".

- [ ] **Step 3: Write the minimal implementation `fingerprint.sh`**

Create `/root/momo/.claude/skills/vuln-target-prep/helpers/fingerprint.sh` with this full content:

```bash
#!/usr/bin/env bash
# fingerprint.sh — detect lang/build-system/dep/size of a source tree (spec §4.1)
# Usage: fingerprint.sh <src-dir>
# Prints one JSON object to stdout:
#   {lang, compiler, build_system, deps[], missing_deps[], file_count, loc}
set -euo pipefail

src_dir="${1:?usage: fingerprint.sh <src-dir>}"
if [ ! -d "$src_dir" ]; then
  echo "fingerprint: src-dir not found: $src_dir" >&2
  exit 1
fi

python3 - "$src_dir" <<'PY'
import sys, os, json, subprocess

src = os.path.abspath(sys.argv[1])

C_EXTS    = (".c",)
CPP_EXTS  = (".cpp", ".cc", ".cxx")
HDR_EXTS  = (".h", ".hpp", ".hh", ".hxx")
SRC_EXTS  = C_EXTS + CPP_EXTS + HDR_EXTS

# Curated set of standard / host-provided headers. Anything whose top-level
# stem is NOT in this set is treated as an external dependency candidate.
STD_HEADERS = {
    "assert", "ctype", "errno", "fenv", "float", "inttypes", "iso646",
    "limits", "locale", "math", "setjmp", "signal", "stdalign", "stdarg",
    "stdatomic", "stdbool", "stddef", "stdint", "stdio", "stdlib", "string",
    "tgmath", "threads", "time", "uchar", "wchar", "wctype",
    "sys_types", "sys_stat", "sys_socket", "sys_wait", "sys_time", "sys_mman",
    "sys_ioctl", "sys_select", "sys_resource", "sys_uio", "sys_un",
    "arpa_inet", "netdb", "netinet_in", "netinet_tcp", "netinet_ip",
    "unistd", "fcntl", "pthread", "dlfcn", "semaphore", "mqueue",
    "aio", "spawn", "cpio", "tar", "fts", "ftw", "glob", "grp", "pwd",
    "dirent", "termios", "poll", "regex", "search", "strings",
}

INC_RE = __import__("re").compile(r'^\s*#\s*include\s*[<"]([^>"]+)[>"]')

def walk_files(root):
    out = []
    for base, dirs, files in os.walk(root):
        # prune noisy/vendored/build dirs
        dirs[:] = [d for d in dirs
                   if not d.startswith(".")
                   and d not in ("build", "out", "target", "Builds",
                                 "node_modules", "third_party", ".git")]
        for f in files:
            out.append(os.path.join(base, f))
    return out

files = walk_files(src)
basenames = [os.path.basename(f) for f in files]

c_files   = [f for f in files if f.endswith(C_EXTS)]
cpp_files = [f for f in files if f.endswith(CPP_EXTS)]
h_files   = [f for f in files if f.endswith(HDR_EXTS)]
py_files  = [f for f in files if f.endswith(".py")]
src_all   = c_files + cpp_files + h_files

# --- language / compiler ---
n_c, n_cpp = len(c_files), len(cpp_files)
if n_c == 0 and n_cpp == 0:
    lang = "python" if py_files else "unknown"
    compiler = ""
else:
    lang = "c++" if n_cpp > n_c else "c"
    compiler = "c++" if lang == "c++" else "cc"

# --- build system (priority order) ---
lower_names = {b.lower() for b in basenames}
has_makefile    = any(b == "Makefile" or b.lower() == "makefile" for b in basenames) \
                  or any(b.lower().endswith(".mk") for b in basenames)
has_configure   = any(b == "configure" for b in basenames)
has_meson       = "meson.build" in lower_names
has_cmake       = "cmakelists.txt" in lower_names

if has_cmake:
    build_system = "cmake"
elif has_makefile:
    build_system = "make"
elif has_configure:
    build_system = "autotools"
elif has_meson:
    build_system = "meson"
else:
    build_system = "raw"

# --- dependency scan across source files ---
dep_set = []
seen = set()
for f in src_all:
    try:
        with open(f, "r", errors="replace") as fh:
            for line in fh:
                m = INC_RE.match(line)
                if not m:
                    continue
                inc = m.group(1)
                stem = inc.split("/")[0]        # "openssl/ssl.h" -> "openssl"
                root_stem = stem.rsplit(".", 1)[0]  # "zlib.h" -> "zlib"
                if root_stem in STD_HEADERS:
                    continue
                if root_stem in seen:
                    continue
                seen.add(root_stem)
                dep_set.append(root_stem)

# --- classify each dep as present / missing ---
STD_INC_DIRS = ["/usr/include", "/usr/local/include"]

def pkgconfig_has(lib):
    try:
        r = subprocess.run(["pkg-config", "--exists", lib],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return r.returncode == 0
    except FileNotFoundError:
        return False

def header_in_std_path(stem):
    for d in STD_INC_DIRS:
        if os.path.isdir(os.path.join(d, stem)) or \
           os.path.exists(os.path.join(d, stem + ".h")):
            return True
    return False

deps, missing = [], []
for d in dep_set:
    (missing if (not pkgconfig_has(d) and not header_in_std_path(d)) else deps).append(d)

# --- size ---
file_count = len(src_all)
loc = 0
for f in src_all:
    try:
        with open(f, "rb") as fh:
            loc += sum(1 for _ in fh)
    except OSError:
        pass

print(json.dumps({
    "lang": lang,
    "compiler": compiler,
    "build_system": build_system,
    "deps": deps,
    "missing_deps": missing,
    "file_count": file_count,
    "loc": loc,
}))
PY
```

Mark it executable:
```bash
cd /root/momo
chmod +x .claude/skills/vuln-target-prep/helpers/fingerprint.sh
```

- [ ] **Step 4: Run the test — it must PASS**

Run:
```bash
cd /root/momo
bash .claude/skills/vuln-target-prep/helpers/tests/test-fingerprint.sh
```
Expected output (exactly, in order):
```
PASS: (a) lang=c
PASS: (a) compiler=cc
PASS: (a) build_system=cmake
PASS: (b) build_system=make
PASS: (c) build_system=raw
PASS: (d) lang=python
ALL PASS
```

Quick sanity on real JSON shape (optional, confirms no syntax noise):
```bash
cd /root/momo
bash .claude/skills/vuln-target-prep/helpers/fingerprint.sh .claude/skills/vuln-mine/manifests/example/src | jq .
```
Expected: a single JSON object with the seven keys; `jq .` parses it without error.

- [ ] **Step 5: Commit**

Run:
```bash
cd /root/momo
git add .claude/skills/vuln-target-prep/helpers/fingerprint.sh \
        .claude/skills/vuln-target-prep/helpers/tests/test-fingerprint.sh
git commit -m "feat: add fingerprint helper"
```
Expected: one commit; `git status --porcelain` clean afterwards. `targets/.gitkeep` is not touched by this task.

---

### Task 3: verify-crash.sh — TDD

`verify-crash.sh <binary> <input> <timeout_sec>` runs `timeout <t> <binary> <input>`, captures stderr, and prints exactly one line:
```
EXIT=<n>|SIGNAL=<name>|ASAN=<bool>
```
- `SIGNAL`: `124` → `TIMEOUT`; exit `>= 128` → subtract 128, map via `{9:SIGKILL, 11:SIGSEGV, 6:SIGABRT, 8:SIGFPE, 7:SIGBUS, 4:SIGILL, 15:SIGTERM, 1:SIGHUP, 3:SIGQUIT, 10:SIGUSR1, 12:SIGUSR2}` (else `SIG<n>`); otherwise `NONE`.
- `ASAN=true` iff stderr matches `ERROR: AddressSanitizer|MemorySanitizer|UndefinedBehaviorSanitizer`.
- Mirrors `vuln-mine`'s `run-harness.sh`: when `sanitizer==asan` the harness forces `ASAN_OPTIONS=abort_on_error=1` so an ASan bug surfaces as `SIGABRT`/exit `134`. We replicate that here unconditionally-if-unset so any ASan binary we probe reports `EXIT=134|SIGNAL=SIGABRT|ASAN=true` deterministically.

- [ ] **Step 1: Write the failing test `test-verify-crash.sh`**

Create `/root/momo/.claude/skills/vuln-target-prep/helpers/tests/test-verify-crash.sh` with this full content:

```bash
#!/usr/bin/env bash
# test-verify-crash.sh — assert verify-crash.sh classifies exit/signal/sanitizer (spec §7.1)
set -euo pipefail

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helpers_dir="$(dirname "$__dir")"

assert_eq() {  # assert_eq <actual> <expected> <label>
  if [ "$1" = "$2" ]; then echo "PASS: $3";
  else echo "FAIL: $3 (got '$1' want '$2')"; exit 1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1) /bin/true on /dev/null -> EXIT=0 | SIGNAL=NONE | ASAN=false
line="$(bash "$helpers_dir/verify-crash.sh" /bin/true /dev/null 5)"
assert_eq "$line" "EXIT=0|SIGNAL=NONE|ASAN=false" "true -> clean exit"

# 2) /bin/false on /dev/null -> EXIT=1 | SIGNAL=NONE | ASAN=false
line="$(bash "$helpers_dir/verify-crash.sh" /bin/false /dev/null 5)"
assert_eq "$line" "EXIT=1|SIGNAL=NONE|ASAN=false" "false -> benign nonzero"

# 3) a slow script killed by timeout -> EXIT=124 | SIGNAL=TIMEOUT | ASAN=false
cat > "$tmp/slow.sh" <<'SH'
#!/bin/sh
sleep 30
SH
chmod +x "$tmp/slow.sh"
line="$(bash "$helpers_dir/verify-crash.sh" "$tmp/slow.sh" /dev/null 1)"
assert_eq "$line" "EXIT=124|SIGNAL=TIMEOUT|ASAN=false" "timeout -> 124/TIMEOUT"

# 4) a tiny out-of-bounds heap write compiled with -fsanitize=address
#    -> ASan aborts -> EXIT=134 | SIGNAL=SIGABRT | ASAN=true
cat > "$tmp/oob.c" <<'C'
#include <stdlib.h>
int main(int argc, char **argv) {
    char *p = (char *)malloc(4);
    p[64] = 'x';          /* heap-buffer-overflow, reliably caught by ASan */
    return (int)p[0];
}
C
cc -fsanitize=address -g -O0 -o "$tmp/oob" "$tmp/oob.c"
: > "$tmp/in.bin"        # input file (program ignores argv[1])
line="$(bash "$helpers_dir/verify-crash.sh" "$tmp/oob" "$tmp/in.bin" 10)"
assert_eq "$line" "EXIT=134|SIGNAL=SIGABRT|ASAN=true" "ASan OOB -> 134/SIGABRT"

echo "ALL PASS"
```

- [ ] **Step 2: Run the test — it must FAIL with a named reason**

Run:
```bash
cd /root/momo
bash .claude/skills/vuln-target-prep/helpers/tests/test-verify-crash.sh
```
Expected: failure. `verify-crash.sh` does not exist yet, so the first probe fails:
```
bash: .../verify-crash.sh: No such file or directory
```
and `set -e` aborts before any `PASS:` line. Named reason: "verify-crash.sh: No such file or directory".

- [ ] **Step 3: Write the minimal implementation `verify-crash.sh`**

Create `/root/momo/.claude/skills/vuln-target-prep/helpers/verify-crash.sh` with this full content:

```bash
#!/usr/bin/env bash
# verify-crash.sh — run a binary on an input, classify exit/signal/sanitizer (spec §7.1)
# Usage: verify-crash.sh <binary> <input> <timeout_sec>
# Prints exactly one line: EXIT=<n>|SIGNAL=<name>|ASAN=<bool>
#
# Mirrors vuln-mine run-harness.sh + classify-result.sh signal normalization:
#   - timeout -> 124 -> SIGNAL=TIMEOUT
#   - exit >= 128 -> signal = exit-128 -> mapped name
#   - ASan/MSan/UBSan line in stderr -> ASAN=true
# ASan abort_on_error is forced (when caller hasn't set ASAN_OPTIONS) so an
# instrumented bug surfaces as SIGABRT/134, matching vuln-mine's contract.
set -euo pipefail

binary="${1:?usage: verify-crash.sh <binary> <input> <timeout_sec>}"
input="${2:?usage: verify-crash.sh <binary> <input> <timeout_sec>}"
timeout_sec="${3:?usage: verify-crash.sh <binary> <input> <timeout_sec>}"

[ -x "$binary" ] || { echo "verify-crash: binary not executable: $binary" >&2; exit 2; }
[ -f "$input" ]  || { echo "verify-crash: input not found: $input" >&2; exit 2; }

# Force ASan to abort (->SIGABRT/134) when caller hasn't configured it,
# exactly like vuln-mine/helpers/run-harness.sh does for sanitizer==asan.
if [ -z "${ASAN_OPTIONS:-}" ]; then
  export ASAN_OPTIONS="abort_on_error=1"
fi

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

set +e
timeout "$timeout_sec" "$binary" "$input" >/dev/null 2>"$err_file"
code=$?
set -e

# --- signal normalization (classify-result.sh I3 logic) ---
sig="NONE"
if [ "$code" -eq 124 ]; then
  sig="TIMEOUT"
elif [ "$code" -ge 128 ]; then
  s=$((code - 128))
  case "$s" in
    9)  sig="SIGKILL";;
    11) sig="SIGSEGV";;
    6)  sig="SIGABRT";;
    8)  sig="SIGFPE";;
    7)  sig="SIGBUS";;
    4)  sig="SIGILL";;
    15) sig="SIGTERM";;
    1)  sig="SIGHUP";;
    3)  sig="SIGQUIT";;
    10) sig="SIGUSR1";;
    12) sig="SIGUSR2";;
    *)  sig="SIG$s";;
  esac
fi

# --- sanitizer detection ---
asan=false
if grep -Eq 'ERROR: (AddressSanitizer|MemorySanitizer|UndefinedBehaviorSanitizer)' "$err_file"; then
  asan=true
fi

printf 'EXIT=%s|SIGNAL=%s|ASAN=%s\n' "$code" "$sig" "$asan"
```

Mark it executable:
```bash
cd /root/momo
chmod +x .claude/skills/vuln-target-prep/helpers/verify-crash.sh
```

- [ ] **Step 4: Run the test — it must PASS**

Run:
```bash
cd /root/momo
bash .claude/skills/vuln-target-prep/helpers/tests/test-verify-crash.sh
```
Expected output (exactly, in order):
```
PASS: true -> clean exit
PASS: false -> benign nonzero
PASS: timeout -> 124/TIMEOUT
PASS: ASan OOB -> 134/SIGABRT
ALL PASS
```

If the ASan case fails with `EXIT=1|SIGNAL=NONE|ASAN=true`, the compile step lost the sanitizer flag — re-run the `cc -fsanitize=address ...` line in the test and confirm `cc --version` is present (the contract guarantees cc/clang with ASan).

- [ ] **Step 5: Commit**

Run:
```bash
cd /root/momo
git add .claude/skills/vuln-target-prep/helpers/verify-crash.sh \
        .claude/skills/vuln-target-prep/helpers/tests/test-verify-crash.sh
git commit -m "feat: add verify-crash helper"
```
Expected: one commit; `git status --porcelain` clean afterwards.

---

---

I have enough context. The task list is for the broader plan-writing effort; my job is to produce markdown for two tasks. I won't touch the task list. Writing the markdown now.

### Task 4: build-target.sh (fallback-chain A->B->C with auto-retry) — TDD

**Goal:** a deterministic build helper at `.claude/skills/vuln-target-prep/helpers/build-target.sh` that takes `<src-dir> <out-dir> <fingerprint.json>`, tries strategies A→B→C in order, stops at the first one that yields a working artifact, logs every attempt (command + exit + last 5 stderr lines) to `<out-dir>/build.log`, and on total failure emits a structured diagnosis (which strategies were tried, each failure's last 5 stderr lines, missing deps, and a concrete `apt install` suggestion).

Contract reminders the impl must obey:
- `<name>` is derived from the basename of `<src-dir>` (so fixtures are reproducible).
- The winning artifact is `<out-dir>/<name>.a` (strategies A and B) or `<out-dir>/<name>_cli` (strategy C).
- ASan flags are fixed: `-fsanitize=address -g` (CMake sets them via `-DCMAKE_C_FLAGS`/`-DCMAKE_CXX_FLAGS`; make/autotools/cc set them via `CFLAGS`/`CXXFLAGS`).
- `build.log` records, per strategy: a `STRATEGY A/B/C:` header, the command run, the exit code, and (on failure) the last 5 lines of stderr.
- Exit 0 on success, 1 on total failure with diagnosis on stderr AND in `build.log`.

- [ ] **Step 1: write the failing test (`test-build-target.sh`) with three fixtures**

Create `.claude/skills/vuln-target-prep/helpers/tests/test-build-target.sh`. Three cases:
1. **Fixture `tinylib`** — a C library with a `Makefile` that builds `libtinylib.a`. Strategy A (native build system → `.a`) must succeed; `build.log` must mention `STRATEGY A` and the produced `<name>.a` must exist and be an archive (`ar t` lists a member).
2. **Fixture `rawlib`** — two `.c` files, NO build file. Strategy B (compile-gabung) must succeed; the produced `<name>.a` must exist and `ar t` must list at least one member named after one of the source files.
3. **Fixture `badlib`** — a single `.c` that `#include <nonexistentlib.h>` (not installed). All strategies must fail; the script exits 1 AND `build.log` mentions both the missing header AND an `apt install` suggestion.

The test creates the fixture sources verbatim in a `mktemp -d` directory, writes a minimal `fingerprint.json` for each, runs the helper, and asserts. Full file:

```bash
#!/usr/bin/env bash
# test-build-target.sh — build-target.sh fallback-chain A->B->C (deterministic)
set -euo pipefail

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helpers_dir="$(dirname "$__dir")"
build_target="$helpers_dir/build-target.sh"

assert() { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (got '$1' want '$2')"; exit 1; fi; }
assert_contains() { if printf '%s' "$1" | grep -q -- "$2"; then echo "PASS: $3"; else echo "FAIL: $3 ('$1' missing '$2')"; exit 1; fi; }
assert_file() { if [ -f "$1" ]; then echo "PASS: $2"; else echo "FAIL: $2 (missing $1)"; exit 1; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------
# Fixture 1: tinylib — Makefile builds libtinylib.a  =>  Strategy A wins
# ---------------------------------------------------------------------------
src1="$tmp/tinylib"; mkdir -p "$src1"
cat > "$src1/parser.c" <<'C'
#include <string.h>
int tinylib_parse(const char *buf, long n) {
    if (n < 4) return -1;
    return buf[0] == 'N' && buf[1] == 'P' ? 0 : -1;
}
C
cat > "$src1/parser.h" <<'C'
#ifndef TINYLIB_PARSER_H
#define TINYLIB_PARSER_H
int tinylib_parse(const char *buf, long n);
#endif
C
cat > "$src1/Makefile" <<'MK'
CC?=cc
CFLAGS?=-g
libtinylib.a: parser.o
	ar rcs $@ $^
parser.o: parser.c
	$(CC) $(CFLAGS) -c parser.c -o parser.o
MK
cat > "$src1/fingerprint.json" <<'JSON'
{"lang":"c","compiler":"cc","build_system":"make","deps":[],"missing_deps":[],"file_count":2,"loc":6}
JSON
out1="$tmp/out1"; mkdir -p "$out1"
set +e
bash "$build_target" "$src1" "$out1" "$src1/fingerprint.json" >"$out1/run.stdout" 2>"$out1/run.stderr"
rc1=$?
set -e
assert "$rc1" "0" "tinylib: build-target exits 0 (Strategy A)"
assert_file "$out1/tinylib.a" "tinylib: <name>.a produced"
assert_contains "$(cat "$out1/build.log")" "STRATEGY A" "tinylib: build.log notes Strategy A"
# archive must contain at least one object
members1="$(ar t "$out1/tinylib.a" 2>/dev/null | tr '\n' ' ')"
assert_contains "$members1" "parser" "tinylib: archive contains parser object"

# ---------------------------------------------------------------------------
# Fixture 2: rawlib — two .c, no build file  =>  Strategy B wins
# ---------------------------------------------------------------------------
src2="$tmp/rawlib"; mkdir -p "$src2/include"
cat > "$src2/include/rawlib.h" <<'C'
#ifndef RAWLIB_H
#define RAWLIB_H
long rawlib_sum(const long *p, long n);
#endif
C
cat > "$src2/sum.c" <<'C'
#include "rawlib.h"
long rawlib_sum(const long *p, long n) {
    long s = 0; for (long i = 0; i < n; i++) s += p[i]; return s;
}
C
cat > "$src2/util.c" <<'C'
#include "rawlib.h"
long rawlib_double(long v) { return v * 2; }
C
cat > "$src2/fingerprint.json" <<'JSON'
{"lang":"c","compiler":"cc","build_system":"none","deps":[],"missing_deps":[],"file_count":2,"loc":8}
JSON
out2="$tmp/out2"; mkdir -p "$out2"
set +e
bash "$build_target" "$src2" "$out2" "$src2/fingerprint.json" >"$out2/run.stdout" 2>"$out2/run.stderr"
rc2=$?
set -e
assert "$rc2" "0" "rawlib: build-target exits 0 (Strategy B)"
assert_file "$out2/rawlib.a" "rawlib: <name>.a produced"
assert_contains "$(cat "$out2/build.log")" "STRATEGY B" "rawlib: build.log notes Strategy B"
members2="$(ar t "$out2/rawlib.a" 2>/dev/null | tr '\n' ' ')"
assert_contains "$members2" "sum" "rawlib: archive contains sum object"

# ---------------------------------------------------------------------------
# Fixture 3: badlib — #include <nonexistentlib.h>  =>  all strategies fail
# ---------------------------------------------------------------------------
src3="$tmp/badlib"; mkdir -p "$src3"
cat > "$src3/bad.c" <<'C'
#include <nonexistentlib.h>
int badlib_run(const char *b, long n) { return nonexistent_func(b, n); }
C
cat > "$src3/fingerprint.json" <<'JSON'
{"lang":"c","compiler":"cc","build_system":"none","deps":[],"missing_deps":[],"file_count":1,"loc":3}
JSON
out3="$tmp/out3"; mkdir -p "$out3"
set +e
bash "$build_target" "$src3" "$out3" "$src3/fingerprint.json" >"$out3/run.stdout" 2>"$out3/run.stderr"
rc3=$?
set -e
assert "$rc3" "1" "badlib: build-target exits 1 (all strategies fail)"
assert_file "$out3/build.log" "badlib: build.log written on failure"
log3="$(cat "$out3/build.log")"
assert_contains "$log3" "nonexistentlib.h" "badlib: build.log mentions missing header"
assert_contains "$log3" "apt install" "badlib: build.log suggests apt install"

echo "ALL PASS"
```

- [ ] **Step 2: run the test, see it FAIL**

The helper does not exist yet, so every case fails (the script cannot be found, or an empty/stub file produces no artifact). Run:

```bash
bash /root/momo/.claude/skills/vuln-target-prep/helpers/tests/test-build-target.sh
```

Expected output (failure, non-zero exit):

```
FAIL: tinylib: build-target exits 0 (Strategy A) (got '<something>' want '0')
```
(or a "No such file" error from invoking a missing `build-target.sh`.) This confirms the test runs and fails for the right reason: no working fallback chain exists yet.

- [ ] **Step 3: write the minimal `build-target.sh` implementation**

Create `.claude/skills/vuln-target-prep/helpers/build-target.sh`. Full file:

```bash
#!/usr/bin/env bash
# build-target.sh — deterministic build fallback-chain A->B->C.
# Usage: build-target.sh <src-dir> <out-dir> <fingerprint.json>
# Tries strategies in order, stops at the first that yields a working artifact,
# logs every attempt to <out-dir>/build.log. Exit 0 on success, 1 on total failure
# (structured diagnosis on stderr AND build.log: strategies tried, each failure's
# last 5 stderr lines, missing deps, concrete apt install suggestion).
set -uo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <src-dir> <out-dir> <fingerprint.json>" >&2
  exit 1
fi

src_dir="$1"; out_dir="$2"; fp="$3"
if [ ! -d "$src_dir" ]; then echo "ERROR: src-dir not a directory: $src_dir" >&2; exit 1; fi
if [ ! -f "$fp" ];        then echo "ERROR: fingerprint.json not found: $fp" >&2; exit 1; fi
mkdir -p "$out_dir" || { echo "ERROR: cannot create out-dir: $out_dir" >&2; exit 1; }

name="$(basename "$(cd "$src_dir" && pwd)")"
log="$out_dir/build.log"
: > "$log"

ASAN_FLAGS="-fsanitize=address -g"

# --- field readers for fingerprint.json (jq-free, one-line grep+sed) ---
fp_field() { # <key> -> value or "" if absent
  grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$fp" \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/'
}
build_system="$(fp_field build_system)"
missing_raw="$(grep -oE '\"missing_deps\"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$fp" | head -1)"

# log_attempt <strategy-letter> <label> <command> <exit> <stderr-file>
log_attempt() {
  {
    echo "STRATEGY $1: $2"
    echo "  cmd: $3"
    echo "  exit: $4"
    if [ "$4" != "0" ] && [ -s "$5" ]; then
      echo "  stderr (last 5):"
      tail -n 5 "$5" | sed 's/^/    /'
    fi
    echo
  } >> "$log"
}

err_capture="$out_dir/.stderr.tmp"

# ============================================================================
# Strategy A: native build system -> .a
# ============================================================================
strategy_a() {
  if [ -n "$missing_raw" ] && printf '%s' "$missing_raw" | grep -q '[a-zA-Z0-9_]'; then
    { echo "STRATEGY A: native build system"; echo "  skipped: missing deps:"; printf '%s\n' "$missing_raw" | sed 's/^/    /'; echo; } >> "$log"
    return 1
  fi
  local subdir="$out_dir/build_a"
  rm -rf "$subdir"; mkdir -p "$subdir"
  case "$build_system" in
    cmake)
      ( cd "$subdir" && cmake "$src_dir" \
            -DCMAKE_C_FLAGS="$ASAN_FLAGS" -DCMAKE_CXX_FLAGS="$ASAN_FLAGS" \
            -DCMAKE_BUILD_TYPE=Debug >"$err_capture" 2>&1 && \
        make >>"$err_capture" 2>&1 )
      local rc=$?
      log_attempt A "cmake native build" "cmake $src_dir (-asan -g) && make" "$rc" "$err_capture"
      [ $rc -eq 0 ] || return 1
      ;;
    make)
      ( cd "$src_dir" && make CFLAGS="$ASAN_FLAGS" CXXFLAGS="$ASAN_FLAGS" CC="${CC:-cc}" CXX="${CXX:-c++}" \
            >"$err_capture" 2>&1 )
      local rc=$?
      log_attempt A "make native build" "make CFLAGS=-asan CC=cc" "$rc" "$err_capture"
      [ $rc -eq 0 ] || return 1
      ;;
    autotools)
      ( cd "$src_dir" && ./configure CC="${CC:-cc}" CFLAGS="$ASAN_FLAGS" >"$err_capture" 2>&1 && make >>"$err_capture" 2>&1 )
      local rc=$?
      log_attempt A "autotools native build" "./configure CC=cc && make" "$rc" "$err_capture"
      [ $rc -eq 0 ] || return 1
      ;;
    *)
      { echo "STRATEGY A: native build system"; echo "  skipped: build_system='$build_system' not cmake/make/autotools"; echo; } >> "$log"
      return 1
      ;;
  esac
  # harvest: prefer *.a built anywhere under src_dir/out; else gather *.o into a .a.
  local found_a
  found_a="$(find "$src_dir" "$subdir" -name '*.a' -type f 2>/dev/null | head -1)"
  if [ -n "$found_a" ]; then
    cp "$found_a" "$out_dir/$name.a"
    { echo "STRATEGY A: RESULT success (harvested $(basename "$found_a"))"; echo; } >> "$log"
    return 0
  fi
  local objs
  objs="$(find "$src_dir" "$subdir" -name '*.o' -type f 2>/dev/null)"
  if [ -n "$objs" ]; then
    # shellcheck disable=SC2086
    ar rcs "$out_dir/$name.a" $objs >>"$err_capture" 2>&1
    if [ -f "$out_dir/$name.a" ]; then
      { echo "STRATEGY A: RESULT success (archived *.o -> $name.a)"; echo; } >> "$log"
      return 0
    fi
  fi
  log_attempt A "harvest" "find *.a / ar rcs from *.o" 1 "$err_capture"
  return 1
}

# gather non-main, non-test/example .c sources for compile-gabung
gather_sources() {
  find "$src_dir" -type f \( -name '*.c' -o -name '*.cpp' \) \
    ! -path '*/test/*' ! -path '*/tests/*' ! -path '*/example/*' \
    ! -path '*/examples/*' ! -path '*/build_a/*' \
    | while IFS= read -r f; do
        # skip the target's own CLI main (we want the library to link into harness.c)
        if grep -q 'int main(' "$f"; then continue; fi
        printf '%s\n' "$f"
      done
}

# ============================================================================
# Strategy B: compile-gabung (single cc) -> <name>.a
# ============================================================================
strategy_b() {
  local srcs
  srcs="$(gather_sources)"
  if [ -z "$srcs" ]; then
    { echo "STRATEGY B: compile-gabung"; echo "  skipped: no non-main .c/.cpp sources found"; echo; } >> "$log"
    return 1
  fi
  local inc=""
  [ -d "$src_dir/include" ] && inc="-I$src_dir/include"
  local objdir="$out_dir/obj_b"
  rm -rf "$objdir"; mkdir -p "$objdir"
  local rc=0
  # shellcheck disable=SC2086
  ( cd "$objdir" && for s in $srcs; do
      cc $ASAN_FLAGS -O1 $inc -c "$s" -o "$(basename "$s" | sed -E 's/\.[cp]+$//').o" \
        >>"$err_capture" 2>&1 || exit 1
    done ) || rc=$?
  if [ $rc -ne 0 ]; then
    log_attempt B "compile-gabung (per-file cc -c)" "cc $ASAN_FLAGS -O1 $inc -c <sources>" "$rc" "$err_capture"
    return 1
  fi
  # shellcheck disable=SC2086
  ar rcs "$out_dir/$name.a" "$objdir"/*.o >>"$err_capture" 2>&1
  if [ ! -f "$out_dir/$name.a" ]; then
    log_attempt B "ar rcs" "ar rcs $name.a *.o" 1 "$err_capture"
    return 1
  fi
  { echo "STRATEGY B: RESULT success ($name.a from $(echo "$srcs" | wc -l) source(s))"; echo; } >> "$log"
  return 0
}

# ============================================================================
# Strategy C: target's own CLI (file-reading main) as harness -> <name>_cli
# ============================================================================
strategy_c() {
  local main_src
  main_src="$(find "$src_dir" -type f \( -name '*.c' -o -name '*.cpp' \) \
      ! -path '*/build_a/*' \
      -exec grep -l 'int main(' {} \; | head -1)"
  if [ -z "$main_src" ]; then
    { echo "STRATEGY C: CLI as harness"; echo "  skipped: no main() found in sources"; echo; } >> "$log"
    return 1
  fi
  # require that the main reads argv[1] as a file (fopen/argv[1])
  if ! grep -Eq "argv\[1\]" "$main_src"; then
    { echo "STRATEGY C: CLI as harness"; echo "  skipped: main does not read argv[1] as a file"; echo; } >> "$log"
    return 1
  fi
  local inc=""
  [ -d "$src_dir/include" ] && inc="-I$src_dir/include"
  # compile the whole project (main + supporting sources) into the CLI binary
  local all_srcs
  all_srcs="$(find "$src_dir" -type f \( -name '*.c' -o -name '*.cpp' \) ! -path '*/build_a/*')"
  # shellcheck disable=SC2086
  ( cc $ASAN_FLAGS -O1 $inc $all_srcs -o "$out_dir/${name}_cli" >>"$err_capture" 2>&1 )
  local rc=$?
  log_attempt C "CLI as harness" "cc $ASAN_FLAGS $inc <all sources> -o ${name}_cli" "$rc" "$err_capture"
  if [ $rc -eq 0 ] && [ -x "$out_dir/${name}_cli" ]; then
    { echo "STRATEGY C: RESULT success (harness=cli, binary=${name}_cli)"; echo; } >> "$log"
    return 0
  fi
  return 1
}

# --- run chain ---
rm -f "$err_capture"
strategy_a && { echo "build-target: OK strategy A -> $out_dir/$name.a"; rm -f "$err_capture"; exit 0; }
strategy_b && { echo "build-target: OK strategy B -> $out_dir/$name.a"; rm -f "$err_capture"; exit 0; }
strategy_c && { echo "build-target: OK strategy C -> $out_dir/${name}_cli (harness=cli)"; rm -f "$err_capture"; exit 0; }

# --- total failure: structured diagnosis ---
missing_headers="$(grep -hRoE '[a-zA-Z0-9_]+\.h' "$err_capture" 2>/dev/null | sort -u | head -20)"
suggest=""
if [ -n "$missing_headers" ]; then
  suggest="apt install "
  i=0
  while IFS= read -r h; do
    # guess package name: lib<h Stem>0-dev (lowercase, strip extension)
    base="$(printf '%s' "$h" | sed -E 's/\.h$//; s/_/-/g' | tr '[:upper:]' '[:lower:]')"
    pkg="lib${base}-dev"
    [ $i -gt 0 ] && suggest="$suggest "
    suggest="$suggest$pkg"
    i=$((i+1))
  done <<<"$missing_headers"
fi
{
  echo "=== BUILD FAILED: all strategies A/B/C failed for '$name' ==="
  echo "Strategies tried (see above for each command/exit/stderr)."
  if [ -n "$missing_headers" ]; then
    echo "Missing headers detected:"
    printf '  %s\n' $missing_headers
  fi
  if [ -n "$suggest" ]; then
    echo "Suggested install (run manually, then re-run prep):"
    echo "  $suggest"
  fi
} >> "$log"

{
  echo "ERROR: build-target: all strategies failed for '$name' (see $log)" >&2
  [ -n "$suggest" ] && echo "Try: $suggest" >&2
}
rm -f "$err_capture"
exit 1
```

- [ ] **Step 4: run the test, see it PASS**

```bash
bash /root/momo/.claude/skills/vuln-target-prep/helpers/tests/test-build-target.sh
```

Expected output:

```
PASS: tinylib: build-target exits 0 (Strategy A)
PASS: tinylib: <name>.a produced
PASS: tinylib: build.log notes Strategy A
PASS: tinylib: archive contains parser object
PASS: rawlib: build-target exits 0 (Strategy B)
PASS: rawlib: <name>.a produced
PASS: rawlib: build.log notes Strategy B
PASS: rawlib: archive contains sum object
PASS: badlib: build-target exits 1 (all strategies fail)
PASS: badlib: build.log written on failure
PASS: badlib: build.log mentions missing header
PASS: badlib: build.log suggests apt install
ALL PASS
```

If any case fails, inspect the relevant `out<N>/build.log` — every strategy attempt and its last 5 stderr lines are recorded there.

- [ ] **Step 5: commit**

```bash
git add .claude/skills/vuln-target-prep/helpers/build-target.sh \
        .claude/skills/vuln-target-prep/helpers/tests/test-build-target.sh
git commit -m "feat: add build-target fallback-chain helper

build-target.sh <src-dir> <out-dir> <fingerprint.json> tries strategies
A (native build system -> .a) -> B (compile-gabung single cc -> .a) ->
C (target CLI as harness -> <name>_cli), stopping at the first that
yields a working artifact. Every attempt (command + exit + last 5 stderr
lines) is appended to <out-dir>/build.log. On total failure it emits a
structured diagnosis including missing headers and a concrete apt install
suggestion. Adds test-build-target.sh with three fixtures (tinylib/
rawlib/ badlib) covering the A-success, B-success, and all-fail paths.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

Expected:

```
[feat/vuln-target-prep XXXXXXX] feat: add build-target fallback-chain helper
 2 files changed, N insertions(+)
 create mode 100755 .claude/skills/vuln-target-prep/helpers/build-target.sh
 create mode 100644 .claude/skills/vuln-target-prep/helpers/tests/test-build-target.sh
```

---

### Task 5: workflow/analyze-and-harness.js — write + node --check

**Goal:** a Claude Code Workflow script at `.claude/skills/vuln-target-prep/workflow/analyze-and-harness.js`. It is a two-stage pipeline:
- **ANALYZE** — an `agent()` reads the cloned source via Bash (`grep`/`Glob`/`cat`) and emits `analysis.yaml` with the schema `{target_function:{name,return_type,params:[{name,type}],file,line}, input_format:{format,grammar[],field_constraints[],known_valid_patterns[],known_invalid_patterns[]}, link_info:{include_header, is_static, needs_whole_archive, extra_libs[]}}`.
- **HARNESS** — an `agent()` reads `analysis.yaml` and writes `harness.c` (the argv-file harness template from spec §4.4, calling `target_function(buf,n)`) plus `compile_hints`.

Run context (`src_dir`, `name`, `manifest_dir`, `fingerprint`) arrives via the Workflow global `args`. Critical constraints the file must satisfy:
- Plain JS (no TypeScript), begins with `export const meta = {name,description,phases}` as a **pure literal** (no `Date.now()`/`Math.random()`/`argless new Date()` — vary only by index).
- Guard `args` existence (the smoke test in the SKILL.md task runs it headlessly; missing args must not crash with a `TypeError`).
- `node --check` must exit 0.

- [ ] **Step 1: write `analyze-and-harness.js`**

Create `.claude/skills/vuln-target-prep/workflow/analyze-and-harness.js`. Full file:

```javascript
// analyze-and-harness.js — Claude Code Workflow for vuln-target-prep.
// Two stages: ANALYZE (read source -> analysis.yaml) then HARNESS
// (analysis.yaml -> harness.c + compile_hints). Run context arrives via the
// Workflow `args` global: {src_dir, name, manifest_dir, fingerprint}.
//
// Constraints honored:
//  - plain JS (no TypeScript)
//  - meta is a pure literal (no Date.now / Math.random / argless new Date;
//    any variation is by stage index only)
//  - args existence is guarded (headless node --check must not throw)

export const meta = {
  name: "analyze-and-harness",
  description:
    "vuln-target-prep: read cloned source, pick a parser function, infer " +
    "its input grammar, then write an argv-file harness.c that calls it.",
  phases: [
    { id: "analyze", name: "ANALYZE", description: "Read source -> analysis.yaml" },
    { id: "harness", name: "HARNESS", description: "analysis.yaml -> harness.c + compile_hints" },
  ],
};

// Workflow harness injects `agent`, `args`, and the Bash/Write/Glob tools as
// globals at runtime. They are absent under plain `node --check`, so guard.
const args = (typeof args !== "undefined" && args) || {};
const agent = (typeof agent !== "undefined") ? agent : null;

function die(msg) {
  throw new Error("[analyze-and-harness] " + msg);
}

function requireArg(key) {
  const v = args[key];
  if (v === undefined || v === null || v === "") {
    die("missing required arg: " + key);
  }
  return v;
}

// --- ANALYZE stage -----------------------------------------------------------
// The agent reads the cloned source with grep/Glob/cat and emits analysis.yaml
// at <manifest_dir>/analysis.yaml with the schema:
//   target_function: {name, return_type, params:[{name,type}], file, line}
//   input_format: {format, grammar[], field_constraints[],
//                  known_valid_patterns[], known_invalid_patterns[]}
//   link_info: {include_header, is_static, needs_whole_archive, extra_libs[]}
async function analyze() {
  const srcDir = requireArg("src_dir");
  const name = requireArg("name");
  const manifestDir = requireArg("manifest_dir");
  const fingerprint = args.fingerprint || {};

  if (!agent) {
    die("ANALYZE: agent() unavailable (Workflow runtime required)");
  }

  const prompt = [
    "You are the ANALYZE stage of vuln-target-prep.",
    "Read the cloned C/C++ source at: " + srcDir,
    "Target name (use for naming outputs): " + name,
    "Fingerprint (build system, deps, size): " + JSON.stringify(fingerprint),
    "",
    "Use Bash to run grep/Glob/cat over the source tree. Pick ONE parser-like",
    "target function: it must take a buffer + length (or pointer + count),",
    "process untrusted data, and contain loops or memory ops (memcpy/malloc/",
    "array index) where memory bugs live.",
    "",
    "Write the result to " + manifestDir + "/analysis.yaml with EXACTLY this schema:",
    "  target_function:",
    "    name: <symbol>",
    "    return_type: <C type>",
    "    params: [{name: ..., type: ...}, ...]",
    "    file: <path relative to src_dir>",
    "    line: <1-based line of the definition>",
    "  input_format:",
    "    format: <short name, e.g. 'chunked TLV' or 'magic-prefixed binary'>",
    "    grammar: [{<field>: <type/desc>}, ...]",
    "    field_constraints: [{field, type, min, max, boundary_values:[...]}]",
    "    known_valid_patterns: [<hex or text>]",
    "    known_invalid_patterns: [<hex or text>]",
    "  link_info:",
    "    include_header: <header to #include from harness.c>",
    "    is_static: <true|false>   # if true, harness must use --whole-archive",
    "    needs_whole_archive: <true|false>",
    "    extra_libs: [<-l flags, e.g. '-lz'>]",
    "",
    "If no clear parser function exists, still write analysis.yaml with",
    "target_function.name: null and a comment explaining why. Do not guess.",
  ].join("\n");

  await agent({
    description: "ANALYZE: read source, pick parser function, write analysis.yaml",
    prompt: prompt,
  });

  return { analysis_yaml: manifestDir + "/analysis.yaml" };
}

// --- HARNESS stage -----------------------------------------------------------
// The agent reads analysis.yaml and writes harness.c: the argv-file template
// from spec §4.4. main(argc,argv) opens argv[1], reads it into a heap buffer,
// calls target_function(buf, n), frees, returns 0. Also emits compile_hints.
async function harness(analyzeOut) {
  const manifestDir = requireArg("manifest_dir");
  const analysisYaml = analyzeOut.analysis_yaml;

  if (!agent) {
    die("HARNESS: agent() unavailable (Workflow runtime required)");
  }

  const prompt = [
    "You are the HARNESS stage of vuln-target-prep.",
    "Read the analysis at: " + analysisYaml,
    "",
    "Write " + manifestDir + "/harness.c implementing this exact template,",
    "filled in from target_function in the analysis:",
    "  #include <stdio.h>",
    "  #include <stdlib.h>",
    "  #include \"<link_info.include_header>\"",
    "  int main(int argc, char **argv) {",
    "    if (argc != 2) return 2;",
    "    FILE *f = fopen(argv[1], \"rb\");",
    "    if (!f) return 2;",
    "    fseek(f, 0, SEEK_END);",
    "    long n = ftell(f);",
    "    fseek(f, 0, SEEK_SET);",
    "    unsigned char *buf = malloc(n);",
    "    if (!buf) { fclose(f); return 2; }",
    "    fread(buf, 1, n, f);",
    "    fclose(f);",
    "    <target_function>(buf, n);   /* call target parser */",
    "    free(buf);",
    "    return 0;",
    "  }",
    "",
    "Adjust the call if the signature differs (e.g. takes (buf, n, ctx)) but",
    "keep the argv-file -> heap-buffer -> call -> free shape. If link_info.",
    "is_static or needs_whole_archive is true, also write a JSON object to",
    manifestDir + "/compile_hints with:",
    "  { whole_archive: <bool>, extra_libs: [...], include_header: \"...\" }",
    "If target_function.name is null, do NOT write harness.c; instead write",
    manifestDir + "/compile_hints with {error: \"no parser function identified\"}.",
  ].join("\n");

  await agent({
    description: "HARNESS: write harness.c + compile_hints from analysis.yaml",
    prompt: prompt,
  });

  return {
    harness_c: manifestDir + "/harness.c",
    compile_hints: manifestDir + "/compile_hints",
  };
}

// --- pipeline entry ----------------------------------------------------------
// Workflow invokes `main()` with the args global populated. The two stages are
// strictly sequential (HARNESS depends on ANALYZE's analysis.yaml), so no
// internal fan-out in v1.
async function main() {
  const a = await analyze();
  const h = await harness(a);
  return { phase: "analyze-and-harness", analyze: a, harness: h };
}

// Named exports for tooling; Workflow calls main().
export { analyze, harness, main };

// Default export is the entrypoint.
export default { meta, main };
```

- [ ] **Step 2: verify with `node --check`**

```bash
node --check /root/momo/.claude/skills/vuln-target-prep/workflow/analyze-and-harness.js && echo "node --check OK"
```

Expected output (exit 0):

```
node --check OK
```

The file uses only ES module syntax (`export const`, `export { }`, `export default`), guarded `agent`/`args` references (so the module never throws at parse/load time even though `node --check` does not execute it), and `meta` is a pure object literal with no time/random calls. If `node --check` reports a syntax error, fix the cited line and re-run until it prints `OK`.

- [ ] **Step 3: commit**

```bash
mkdir -p /root/momo/.claude/skills/vuln-target-prep/workflow
git add .claude/skills/vuln-target-prep/workflow/analyze-and-harness.js
git commit -m "feat: add analyze-and-harness workflow

Two-stage Claude Code Workflow for vuln-target-prep. ANALYZE stage reads
the cloned source via Bash (grep/Glob/cat) and emits analysis.yaml with
the schema {target_function, input_format, link_info}. HARNESS stage reads
analysis.yaml and writes harness.c (the argv-file template from spec §4.4
calling target_function(buf,n)) plus compile_hints. Run context (src_dir,
name, manifest_dir, fingerprint) arrives via the args global; agent/args
are guarded so the module loads cleanly under plain node --check. meta is
a pure literal (no Date.now/Math.random); full execution is the smoke test
in the SKILL.md task.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

Expected:

```
[feat/vuln-target-prep XXXXXXX] feat: add analyze-and-harness workflow
 1 file changed, N insertions(+)
 create mode 100644 .claude/skills/vuln-target-prep/workflow/analyze-and-harness.js
```

---

Here is the markdown for the two tasks:

### Task 6: SKILL.md (5-phase orchestration protocol) — NOT strict TDD (protocol doc, verify by structure)

`vuln-target-prep` is a pure protocol skill: deterministic work lives in the bash helpers (Tasks 2–4) and judgment work lives in the Workflow script (Task 5). `SKILL.md` is the wiring the main agent follows for `/vuln-target-prep <github-url> [<name>]`. We verify by structure (frontmatter parses, 5 phases present, final gate present), not by a TDD red→green loop.

- [ ] **Step 1: create the skill directory tree**

  The helper tasks (2–4) live under `helpers/` and the Workflow under `workflow/`; `SKILL.md` is the only top-level file the main agent reads. Create the dirs so the file write succeeds, and confirm the tree is empty (we are the first writer to touch `SKILL.md`).

  ```
  mkdir -p /root/momo/.claude/skills/vuln-target-prep/{helpers/tests,workflow,targets}
  ls /root/momo/.claude/skills/vuln-target-prep/
  ```
  Expected output: `helpers  targets  workflow` (no `SKILL.md` yet).

- [ ] **Step 2: write `SKILL.md` (full content below)**

  Path: `/root/momo/.claude/skills/vuln-target-prep/SKILL.md`

  Frontmatter carries `name` + `description` (what the skill does in one line — this is what the Claude Code skill picker surfaces). The body is the 5-phase protocol. Phase 5 ends with the **final gate**: `validate-manifest.sh` MUST exit 0 — this is the cross-skill contract from `vuln-mine`. A `§ Smoke test` section documents the no-network fixture path (Task 7 wires it).

  ```yaml
  ---
  name: vuln-target-prep
  description: Turn a bare public GitHub URL into a ready-to-mine vuln-mine target — clone, fingerprint, analyze, build with ASan, write harness + manifest, and validate against vuln-mine's manifest contract.
  ---

  # vuln-target-prep

  Protocol: CLONE → ANALYZE → BUILD → HARNESS → VERIFY. Deterministic work lives in
  `helpers/*.sh`; judgment work (read source, pick parser function, write harness,
  infer grammar) lives in `workflow/analyze-and-harness.js`. Do not improvise
  outside this protocol.

  ## 0. Conventions

  - Repo root is `/root/momo`. Run every Bash command from there so the relative
    helper paths below resolve.
  - Prep skill root: `.claude/skills/vuln-target-prep` (referred to as `$PREP` below).
  - Consumer skill root: `.claude/skills/vuln-mine` (referred to as `$MINE` below).
  - All paths printed to the user MUST be absolute.

  ## 1. CLONE & INDEX

  Inputs: `<github-url>` and optional `<name>`.

  1. Derive `<name>` from the URL if not supplied (last path segment of the URL,
     `.git` suffix stripped, lowercased, non-alphanumerics → `-`).
  2. Shallow-clone the source:
     ```
     SRC=$PREP/targets/<name>/src
     git clone --depth 1 <url> "$SRC"
     ```
     ponytail: `--depth 1` — no history analysis. Ceiling: version-specific bugs.
     Upgrade: add a `--ref <tag>` option that checks out a specific commit.
  3. Fingerprint the source:
     ```
     bash $PREP/helpers/fingerprint.sh "$SRC" > "$SRC.fingerprint.json"
     ```
     Produces `{lang, compiler, build_system, deps[], missing_deps[], file_count, loc}`.
  4. Gate: if `lang` is not `c` or `c++` → **STOP** with:
     `vuln-mine only mines native C/C++ (detected: <lang>)`.

  ## 2. ANALYZE + 4. HARNESS (write harness.c)

  Invoke the Claude Code **Workflow** tool:

  - `scriptPath`: `.claude/skills/vuln-target-prep/workflow/analyze-and-harness.js`
  - `parameters`:
    ```json
    { "src_dir": "<SRC>", "name": "<name>", "manifest_dir": "<MANIFEST_DIR>", "fingerprint": "<fingerprint.json contents>" }
    ```

  The Workflow runs two stages internally: ANALYZE (read source → `analysis.yaml`)
  then HARNESS (write `harness.c`). After it returns:

  - Read `analysis.yaml`. If `analysis.target_function` is null or unclear →
    **STOP** with: `no clear parser function; user must point to one`.
  - Otherwise record `target_function`, `input_format`, `link_info`, `sanitizer`.

  `MANIFEST_DIR` is `$MINE/manifests/<name>` — the Workflow writes `harness.c` and
  `analysis.yaml` there; Phase 5 writes the final manifest + grammar there.

  ## 3. BUILD

  Build the target into a static library (or CLI binary) the harness can link:

  ```
  OUT=$PREP/targets/<name>/build
  mkdir -p "$OUT"
  bash $PREP/helpers/build-target.sh "$SRC" "$OUT" "$SRC.fingerprint.json"
  ```

  `build-target.sh` tries strategies **A → B → C** in order and stops at the first
  that yields an ASan artifact:

  - **A** native build system (`cmake`/`make`/`autotools`) → `<name>.a`
  - **B** compile-gabung (single `cc` over all core `.c`) → `<name>.a`
  - **C** target's own file-reading CLI as the harness → CLI binary, `harness=cli`

  If exit != 0 → **STOP** and surface `build.log`:
  print missing deps and the matching `apt install` suggestion, then stop. Do not
  auto-install (ponytail: no sudo prompt; upgrade path: suggest, user re-runs).

  If strategy **C** won, set `HARNESS_MODE=cli` and **skip Phase 4 compile**
  (the CLI binary IS the harness). Note `harness=cli` so Phase 5 sets
  `binary: <name>` (the CLI) instead of `<name>_fuzz`.

  ## 4. HARNESS (compile)

  Skip this phase entirely if `HARNESS_MODE=cli` (Phase 3 produced the harness
  binary). Otherwise compile `harness.c` (written by the Workflow in Phase 2) and
  link it to the `.a` from Phase 3 with ASan:

  ```
  MANIFEST_DIR=$MINE/manifests/<name>
  mkdir -p "$MANIFEST_DIR"
  cc -fsanitize=address -g -O1 \
     -I"$SRC" $(find "$SRC" -name '*.h' -printf '-I%h\n' | sort -u) \
     "$MANIFEST_DIR/harness.c" "$OUT/<name>.a" \
     -o "$MANIFEST_DIR/<name>_fuzz"
  ```

  If linking fails with unresolved symbols, retry adding `-l<dep>` for each entry
  in `fingerprint.deps[]` that is present on the system; if a dep is in
  `missing_deps[]`, **STOP** and surface the build.log diagnosis from Phase 3.

  ## 5. VERIFY + EMIT

  ### (a) Valid input → expect EXIT=0

  Materialize the smallest entry from `analysis.input_format.known_valid_patterns`
  to `$MANIFEST_DIR/baseline.bin`, then:
  ```
  bash $PREP/helpers/verify-crash.sh "$MANIFEST_DIR/<BIN>" "$MANIFEST_DIR/baseline.bin" 10
  ```
  Expect `EXIT=0|SIGNAL=NONE|ASAN=false`. If it crashes instead, that is a
  pre-existing bug — **not a failure**: note it as a bonus finding and continue.

  ### (b) Hostile boundary input → expect crash

  Materialize a hostile input from `analysis.input_format.field_constraints[].boundary_values`
  (the largest / overflow value) to `$MANIFEST_DIR/hostile.bin`, then run
  `verify-crash.sh` again. Expect a crash (ASan flag or SIGSEGV/SIGABRT).
  If NO crash ever fires, **warn but continue**: "target may be hard to trigger or
  the wrong function was selected" — the manifest is still emitted so vuln-mine
  can mine further.

  ### (c) Write the manifest + grammar

  Write `$MANIFEST_DIR/manifest.yaml`:
  ```yaml
  name: <name>
  source_root: src
  binary: <BIN>                         # RELATIVE to manifest dir: <name>_fuzz, or <name> for cli mode
  harness_cmd: "{{binary}} {{input}}"
  sanitizer: <asan|msan|ubsan|none>     # from fingerprint/analysis
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
  (`acceptable_signals: [SIGABRT]` is correct for asan targets because
  `run-harness.sh` sets `ASAN_OPTIONS=abort_on_error=1` for asan builds.)

  Write `$MANIFEST_DIR/format.grammar.yaml` from `analysis.input_format`:
  ```yaml
  format: <name>
  grammar:
    - <field>: <type/desc>              # one entry per analysis.input_format.grammar
  field_constraints:
    - {field: "<f>", type: "<t>", min: <m>, max: <x>, boundary_values: [...]}
  known_valid_patterns:
    - "<pattern>"
  known_invalid_patterns:
    - "<pattern>"
  ```

  ### (d) FINAL GATE — validate-manifest.sh MUST exit 0

  `validate-manifest.sh` runs from the manifest's own dir, so its relative paths
  resolve. Run it:
  ```
  ( cd "$MANIFEST_DIR" && bash "$MINE/helpers/validate-manifest.sh" manifest.yaml )
  ```
  - exit 0 → target ready.
  - exit != 0 → read stderr, fix inline (binary path / spec_file relative), re-run
    until exit 0. Common fixes: `binary` must be relative to the manifest dir
    (not absolute); `spec_file: format.grammar.yaml` must exist in the same dir.
  - If it cannot be made to pass → **STOP** and print the validator's stderr.

  ## End

  Print the absolute `$MANIFEST_DIR` and:
  ```
  Target ready. Run: /vuln-mine <name>
  ```

  ## Smoke test (no network)

  The cross-skill contract is provable without `git clone` using the local fixture
  under `helpers/tests/fixtures/sample-repo/` (a tiny C parser with a Makefile
  that builds a `.a`, plus a deliberate OOB). `helpers/tests/test-smoke-prep.sh`
  runs the full chain — `fingerprint.sh` → `build-target.sh` → inline harness
  compile → `verify-crash.sh` → emit `manifest.yaml` + `format.grammar.yaml` →
  `validate-manifest.sh` — and asserts the final gate exits 0. Run it via:
  ```
  bash $PREP/helpers/tests/run-all.sh
  ```
  Expect `run-all: all test files passed`.
  ```

- [ ] **Step 3: verify SKILL.md by structure**

  No TDD red→green for a protocol doc; we assert the file exists, the frontmatter
  parses, and all 5 phases + the final gate are present.

  ```
  F=/root/momo/.claude/skills/vuln-target-prep/SKILL.md
  test -f "$F" && echo "PASS: SKILL.md exists" || { echo "FAIL: missing"; exit 1; }
  head -4 "$F" | grep -q '^name: vuln-target-prep' && echo "PASS: frontmatter name" || { echo "FAIL: name"; exit 1; }
  head -4 "$F" | grep -q '^description:' && echo "PASS: frontmatter description" || { echo "FAIL: description"; exit 1; }
  for phase in '## 1. CLONE' '## 2. ANALYZE' '## 3. BUILD' '## 4. HARNESS' '## 5. VERIFY'; do
    grep -qF "$phase" "$F" && echo "PASS: $phase" || { echo "FAIL: $phase missing"; exit 1; }
  done
  grep -qF 'FINAL GATE' "$F" && echo "PASS: final gate" || { echo "FAIL: final gate"; exit 1; }
  grep -qF 'validate-manifest.sh' "$F" && echo "PASS: validator referenced" || { echo "FAIL: validator"; exit 1; }
  ```
  Expected: 9 `PASS:` lines, exit 0.

- [ ] **Step 4: commit**

  ```
  cd /root/momo
  git add .claude/skills/vuln-target-prep/SKILL.md
  git commit -m "feat: add vuln-target-prep SKILL protocol

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```
  Expected: `1 file changed` on `feat/vuln-target-prep`.

---

### Task 7: run-all.sh test runner + end-to-end smoke test wiring

The smoke test proves the cross-skill contract end-to-end WITHOUT network: it exercises `fingerprint.sh` → `build-target.sh` → inline harness compile → `verify-crash.sh` → manifest emit → `validate-manifest.sh`. If the smoke passes, the final gate of Phase 5 is real, not aspirational. `run-all.sh` discovers both test conventions (`test-*.sh` and `*.test.sh`) — vuln-mine learned the hard way that the literal `*.test.sh` glob matches zero files if `nullglob` is off, so we use both patterns.

- [ ] **Step 1: write the failing test for `run-all.sh`**

  Create `/root/momo/.claude/skills/vuln-target-prep/helpers/tests/run-all.sh` as a stub that exits 1, plus a throwaway probe test, then run it to see the named failure.

  Stub:
  ```bash
  #!/usr/bin/env bash
  # run-all.sh — stub (will fail until implemented)
  echo "run-all: NOT IMPLEMENTED" >&2
  exit 1
  ```

  Probe test at `/root/momo/.claude/skills/vuln-target-prep/helpers/tests/test-probe.sh`:
  ```bash
  #!/usr/bin/env bash
  echo "probe ok"
  exit 0
  ```

  Run:
  ```
  chmod +x /root/momo/.claude/skills/vuln-target-prep/helpers/tests/run-all.sh
  bash /root/momo/.claude/skills/vuln-target-prep/helpers/tests/run-all.sh
  ```
  Expected: `run-all: NOT IMPLEMENTED` on stderr, exit 1 — the named failure.

- [ ] **Step 2: implement `run-all.sh` (minimal)**

  Replace the stub with the real runner. It mirrors `vuln-mine/helpers/tests/run-all.sh`
  exactly: `nullglob` on, iterate `*.test.sh` then `test-*.sh`, exit nonzero on first
  failure.

  Full content of `/root/momo/.claude/skills/vuln-target-prep/helpers/tests/run-all.sh`:
  ```bash
  #!/usr/bin/env bash
  # Run every test-*.sh and *.test.sh under this dir; exit nonzero on first failure.
  set -uo pipefail
  TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  failures=0
  shopt -s nullglob
  # ponytail: brief mentions both conventions; vuln-mine proved *.test.sh alone
  # matches zero files when nullglob is off — match both so nothing is silently skipped.
  for t in "$TEST_DIR"/*.test.sh "$TEST_DIR"/test-*.sh; do
    echo "--- RUN  $(basename "$t")"
    if bash "$t"; then
      echo "--- PASS $(basename "$t")"
    else
      echo "--- FAIL $(basename "$t")"
      failures=$((failures + 1))
    fi
  done
  shopt -u nullglob
  if [ "$failures" -ne 0 ]; then
    echo "run-all: $failures test file(s) failed" >&2
    exit 1
  fi
  echo "run-all: all test files passed"
  exit 0
  ```

  Run:
  ```
  bash /root/momo/.claude/skills/vuln-target-prep/helpers/tests/run-all.sh
  ```
  Expected: `--- RUN test-probe.sh`, `probe ok`, `--- PASS test-probe.sh`,
  `run-all: all test files passed`, exit 0.

- [ ] **Step 3: build the local fixture repo (no network)**

  The fixture is a miniature version of vuln-mine's `naiveparse`: a tiny C parser
  with a deliberate OOB and a Makefile that builds a `.a`. `test-smoke-prep.sh`
  creates it inline under `tests/fixtures/sample-repo/` so the test is self-contained.

  Create the fixture files now (verbatim below) so the smoke test in Step 4 can
  reference them. Path: `/root/momo/.claude/skills/vuln-target-prep/helpers/tests/fixtures/sample-repo/`.

  `parse_thing.c`:
  ```c
  /* parse_thing.c — tiny PTv1 format parser with a deliberate OOB.
   * Fixture for vuln-target-prep smoke test. NOT production code.
   * Format: magic "PTv1" (4) | len L (u16 LE) | payload (L bytes)
   * Bug: payload memcpy'd into a 64-byte stack buffer with no bounds check.
   */
  #include <string.h>
  #include <stdint.h>

  #define FIXED_BUF 64

  int parse_thing(const unsigned char *buf, long len) {
      if (len < 6) return 1;
      if (memcmp(buf, "PTv1", 4) != 0) return 2;
      uint16_t L = (uint16_t)(buf[4] | (buf[5] << 8));
      if (len < 6 + L) return 3;
      char dst[FIXED_BUF];
      memcpy(dst, buf + 6, L);            /* DELIBERATE OOB when L > 64 */
      volatile char sink = dst[0];
      (void)sink;
      return 0;
  }
  ```

  `parse_thing.h`:
  ```c
  #ifndef PARSE_THING_H
  #define PARSE_THING_H
  int parse_thing(const unsigned char *buf, long len);
  #endif
  ```

  `Makefile`:
  ```make
  CC ?= cc
  CFLAGS ?= -fsanitize=address -g -O1
  LIBNAME = libparse_thing.a

  $(LIBNAME): parse_thing.c parse_thing.h
	$(CC) $(CFLAGS) -c parse_thing.c -o parse_thing.o
	ar rcs $(LIBNAME) parse_thing.o

  clean:
	rm -f $(LIBNAME) parse_thing.o

  .PHONY: clean
  ```
  (Makefile recipe lines are TAB-indented — verbatim above uses a single tab.)

  Verify the fixture builds standalone:
  ```
  cd /root/momo/.claude/skills/vuln-target-prep/helpers/tests/fixtures/sample-repo
  make clean && make
  ls libparse_thing.a
  ```
  Expected: `libparse_thing.a` exists. (This also confirms the tab-indentation is correct.)

- [ ] **Step 4: write `test-smoke-prep.sh` (end-to-end, no network)**

  Path: `/root/momo/.claude/skills/vuln-target-prep/helpers/tests/test-smoke-prep.sh`

  This is the heart of Task 7. It exercises the full prep chain against the local
  fixture and ends by asserting vuln-mine's `validate-manifest.sh` exits 0 —
  proving the cross-skill contract. Pure-bash `assert()` (same style as
  `vuln-mine/helpers/tests/test-init-memory.sh`), no framework.

  Full content:
  ```bash
  #!/usr/bin/env bash
  # test-smoke-prep.sh — end-to-end prep smoke test on a local fixture (no network).
  # Proves: fingerprint -> build -> harness compile -> verify-crash -> manifest emit
  #         -> vuln-mine validate-manifest.sh EXIT 0 (the cross-skill contract).
  set -euo pipefail

  TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  HELPERS_DIR="$(cd "$TEST_DIR/.." && pwd)"
  PREP_DIR="$(cd "$HELPERS_DIR/.." && pwd)"
  REPO_ROOT="$(cd "$PREP_DIR/../../.." && pwd)"
  MINE_DIR="$REPO_ROOT/.claude/skills/vuln-mine"

  FIX="$TEST_DIR/fixtures/sample-repo"

  assert() { # assert <description> <command...>
    local desc="$1"; shift
    if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; exit 1; fi
  }

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  OUT="$work/build"
  MAN_DIR="$work/manifest"
  mkdir -p "$OUT" "$MAN_DIR"

  # 1. fingerprint the fixture source
  bash "$HELPERS_DIR/fingerprint.sh" "$FIX" > "$work/fp.json"
  lang=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['lang'])" "$work/fp.json")
  assert "fingerprint lang == c" [ "$lang" = "c" ]
  bs=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('build_system',''))" "$work/fp.json")
  echo "info: build_system=$bs"

  # 2. build the .a via the fallback chain
  bash "$HELPERS_DIR/build-target.sh" "$FIX" "$OUT" "$work/fp.json" > "$work/build.log" 2>&1 \
    || { cat "$work/build.log"; echo "FAIL: build-target.sh exit nonzero"; exit 1; }
  lib=$(find "$OUT" -name '*.a' | head -1)
  assert "build produced a .a" [ -n "$lib" -a -f "$lib" ]

  # 3. write a trivial harness inline (argv-file -> parse_thing), compile+link with ASan.
  cat > "$MAN_DIR/harness.c" <<'C'
  #include <stdio.h>
  #include <stdlib.h>
  #include "parse_thing.h"
  int main(int argc, char **argv) {
      if (argc < 2) return 2;
      FILE *f = fopen(argv[1], "rb");
      if (!f) return 2;
      fseek(f, 0, SEEK_END);
      long n = ftell(f);
      fseek(f, 0, SEEK_SET);
      unsigned char *buf = malloc(n ? n : 1);
      if (!buf) { fclose(f); return 2; }
      fread(buf, 1, n, f);
      fclose(f);
      parse_thing(buf, n);
      free(buf);
      return 0;
  }
  C
  cc -fsanitize=address -g -O1 -I"$FIX" "$MAN_DIR/harness.c" "$lib" -o "$MAN_DIR/sample_fuzz"
  assert "harness binary built" test -x "$MAN_DIR/sample_fuzz"

  # 4a. valid input -> verify-crash.sh reports EXIT=0
  #     PTv1 + len=1 (01 00) + 0x41  -> 7 bytes, fits in 64-byte buffer.
  printf 'PTv1\x01\x00A' > "$MAN_DIR/valid.bin"
  out=$(bash "$HELPERS_DIR/verify-crash.sh" "$MAN_DIR/sample_fuzz" "$MAN_DIR/valid.bin" 10)
  echo "info: valid -> $out"
  case "$out" in
    EXIT=0\|*) echo "PASS: valid input EXIT=0" ;;
    *) echo "FAIL: valid input crashed (pre-existing bug ok, but expected EXIT=0 here): $out"; exit 1 ;;
  esac

  # 4b. hostile input -> expect a crash (L=128 overflows the 64-byte buffer).
  #     PTv1 + len=128 (80 00) + 128 'A's.
  { printf 'PTv1\x80\x00'; head -c 128 /dev/zero | tr '\0' 'A'; } > "$MAN_DIR/hostile.bin"
  out2=$(bash "$HELPERS_DIR/verify-crash.sh" "$MAN_DIR/sample_fuzz" "$MAN_DIR/hostile.bin" 10 || true)
  echo "info: hostile -> $out2"
  case "$out2" in
    EXIT=134\|*SIGABRT*|*SIGSEGV*|*ASAN=true*) echo "PASS: hostile input crashes" ;;
    *) echo "WARN: hostile did not crash as expected: $out2 (continuing — manifest still emitted)" ;;
  esac

  # 5. emit manifest.yaml + format.grammar.yaml (mirror Phase 5 shapes).
  cp "$MAN_DIR/sample_fuzz" "$MAN_DIR/sample_fuzz"  # ensure present + executable
  cat > "$MAN_DIR/manifest.yaml" <<YAML
  name: sample
  source_root: src
  binary: sample_fuzz
  harness_cmd: "{{binary}} {{input}}"
  sanitizer: asan
  timeout_sec: 10
  input_format:
    spec_file: format.grammar.yaml
  success_condition:
    kind: crash
    must_reach: null
    acceptable_signals: [SIGABRT, SIGSEGV]
  constraints:
    - "input must begin with magic bytes 'PTv1'"
  budget:
    max_iterations: 20
  YAML

  cat > "$MAN_DIR/format.grammar.yaml" <<'YAML'
  format: PTv1
  grammar:
    - magic: "PTv1"
    - len: u16-le
    - payload: bytes[len]
  field_constraints:
    - {field: "len", type: u16-le, min: 0, max: 65535, boundary_values: [0, 1, 63, 64, 65, 128, 0xffff]}
  known_valid_patterns:
    - "magic 'PTv1' + len=1 (01 00) + 0x41"
  known_invalid_patterns:
    - "missing/wrong magic -> rejected at gate, never reaches parser"
    - "len declared but fewer than len payload bytes present -> truncated, returns 3 early"
  YAML

  # 6. FINAL GATE: vuln-mine validate-manifest.sh MUST exit 0.
  #    (validate-manifest.sh resolves paths relative to the manifest dir, so cd in.)
  if ( cd "$MAN_DIR" && bash "$MINE_DIR/helpers/validate-manifest.sh" manifest.yaml ); then
    echo "PASS: validate-manifest.sh exit 0 (cross-skill contract holds)"
  else
    echo "FAIL: validate-manifest.sh rejected the emitted manifest"
    exit 1
  fi

  echo "smoke-prep: end-to-end OK"
  ```

- [ ] **Step 5: run the smoke test — see it PASS**

  ```
  chmod +x /root/momo/.claude/skills/vuln-target-prep/helpers/tests/test-smoke-prep.sh
  bash /root/momo/.claude/skills/vuln-target-prep/helpers/tests/test-smoke-prep.sh
  ```
  Expected (in order): `PASS: fingerprint lang == c`, `info: build_system=...`,
  `PASS: build produced a .a`, `PASS: harness binary built`, `info: valid -> EXIT=0|...`,
  `PASS: valid input EXIT=0`, `info: hostile -> EXIT=134|SIGNAL=SIGABRT|ASAN=true`
  (or the SIGSEGV variant), `PASS: hostile input crashes`,
  `PASS: validate-manifest.sh exit 0 (cross-skill contract holds)`,
  `smoke-prep: end-to-end OK`, exit 0.

  If the hostile-input line lands in the `WARN` branch instead, the test still
  passes — the contract is the final gate, not the crash. But for this fixture
  (a deliberate `memcpy` overflow at `L=128 > 64`), the crash branch is the
  expected path under ASan.

- [ ] **Step 6: run `run-all.sh` — both tests discovered and pass**

  ```
  bash /root/momo/.claude/skills/vuln-target-prep/helpers/tests/run-all.sh
  ```
  Expected: discovers `test-probe.sh` AND `test-smoke-prep.sh`, both `--- PASS`,
  `run-all: all test files passed`, exit 0.

- [ ] **Step 7: delete the throwaway probe test**

  It only existed to drive `run-all.sh` TDD; it asserts nothing about prep. Keep
  the test suite honest.
  ```
  rm /root/momo/.claude/skills/vuln-target-prep/helpers/tests/test-probe.sh
  bash /root/momo/.claude/skills/vuln-target-prep/helpers/tests/run-all.sh
  ```
  Expected: only `test-smoke-prep.sh` runs, `run-all: all test files passed`.

- [ ] **Step 8: commit**

  ```
  cd /root/momo
  git add .claude/skills/vuln-target-prep/helpers/tests/run-all.sh \
          .claude/skills/vuln-target-prep/helpers/tests/test-smoke-prep.sh \
          .claude/skills/vuln-target-prep/helpers/tests/fixtures/
  git commit -m "feat: add run-all + end-to-end smoke test

  Co-Authored-By: Claude <noreply@anthropic.com>"
  ```
  Expected: `test-smoke-prep.sh`, `run-all.sh`, and the `fixtures/sample-repo/`
  trio staged and committed.

## Done

v1 of `vuln-target-prep` is complete: SKILL.md wires the 5-phase protocol, the
three deterministic helpers (`fingerprint.sh`, `build-target.sh`, `verify-crash.sh`)
have TDD coverage, the Workflow script handles ANALYZE + HARNESS, and the smoke
test proves the cross-skill contract (`validate-manifest.sh` exits 0 on the
emitted manifest) end-to-end without network. The user can now run
`/vuln-target-prep <github-url>` and then `/vuln-mine <name>`.

Deferred to v2 (explicitly out of scope for v1, per spec §7.3):

- private / tag- or commit-pinned repos (`git clone --ref`, auth) and tarball archives
- multi-sanitizer parallel build (ASan + UBSan + MSan in one pass)
- auto dependency install (sudo `apt install` instead of suggest-and-stop)
- native libFuzzer harness (`LLVMFuzzerTestOneInput` entry, multi-entry targets)
- multi-agent parallel ANALYZE per source component
- auto-chain prep → vuln-mine (today the user runs `/vuln-mine <name>` themselves)

---

Relevant absolute paths:

- `/root/momo/.claude/skills/vuln-target-prep/SKILL.md` (Task 6 writes)
- `/root/momo/.claude/skills/vuln-target-prep/helpers/tests/run-all.sh` (Task 7)
- `/root/momo/.claude/skills/vuln-target-prep/helpers/tests/test-smoke-prep.sh` (Task 7)
- `/root/momo/.claude/skills/vuln-target-prep/helpers/tests/fixtures/sample-repo/{parse_thing.c,parse_thing.h,Makefile}` (Task 7 fixture)
- `/root/momo/.claude/skills/vuln-mine/helpers/validate-manifest.sh` (final gate, read for contract — relative path resolution confirmed: `binary` and `input_format.spec_file` are resolved relative to the manifest dir; the smoke test `cd`s into the manifest dir before invoking it)
- `/root/momo/.claude/skills/vuln-mine/manifests/example/manifest.yaml` + `format.grammar.yaml` (reference shapes the emitted files mirror)
- `/root/momo/.claude/skills/vuln-mine/helpers/tests/run-all.sh` (style reference — both-globs pattern copied verbatim)

Load-bearing details: `validate-manifest.sh` requires `binary` to exist and be executable relative to CWD (it does NOT `cd` to the manifest dir itself — `init-memory.sh` does that before calling it), so every `validate-manifest.sh` invocation in both tasks is wrapped in `( cd "$MAN_DIR" && bash .../validate-manifest.sh manifest.yaml )`. The `harness_cmd` value `"{{binary}} {{input}}"` is the only form the validator accepts (rejects `; | & $ \` < >` and any control char outside the two placeholders).
