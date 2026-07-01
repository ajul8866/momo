#!/usr/bin/env bash
# fingerprint.sh <src-dir> — print JSON {lang,compiler,build_system,deps[],missing_deps[],file_count,loc}
# spec §4.1, §7.1 — see task-2-brief.md
set -euo pipefail

if [ "$#" -lt 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <src-dir>" >&2
  exit 2
fi

SRC_DIR="$1"

python3 - "$SRC_DIR" <<'PYEOF'
import json, os, re, subprocess, sys

root = sys.argv[1]

C_EXTS   = (".c",)
CPP_EXTS = (".cpp", ".cc", ".cxx")
HDR_EXTS = (".h", ".hpp", ".hh", ".hxx")
SRC_EXTS = C_EXTS + CPP_EXTS + HDR_EXTS

# Curated set of standard / host-provided headers. Any top-level stem
# NOT in this set is treated as an external dependency candidate.
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

INC_RE = re.compile(r'^\s*#\s*include\s*[<"]([^>"]+)[>"]')


def walk_files(root):
    out = []
    for base, dirs, files in os.walk(root):
        # prune noisy / vendored / build dirs
        dirs[:] = [d for d in dirs
                   if not d.startswith(".")
                   and d not in ("build", "out", "target", "Builds",
                                 "node_modules", "third_party", ".git")]
        for f in files:
            out.append(os.path.join(base, f))
    return out


all_files = walk_files(root)

c_files, cpp_files, hdr_files, py_files = [], [], [], []
for f in all_files:
    if f.endswith(C_EXTS):
        c_files.append(f)
    elif f.endswith(CPP_EXTS):
        cpp_files.append(f)
    elif f.endswith(HDR_EXTS):
        hdr_files.append(f)
    elif f.endswith(".py"):
        py_files.append(f)

src_all = c_files + cpp_files + hdr_files
file_count = len(src_all)

# language / compiler — whichever side has more files wins
if len(c_files) >= len(cpp_files) and file_count > 0:
    lang, compiler = "c", "cc"
elif cpp_files:
    lang, compiler = "c++", "c++"
elif py_files:
    lang, compiler = "python", ""
else:
    lang, compiler = "", ""

# build system detection
lower_names = [os.path.basename(f).lower() for f in all_files]
basenames = set(os.path.basename(f) for f in all_files)
has_cmake     = "cmakelists.txt" in lower_names
has_makefile  = any(n == "makefile" or n.endswith(".mk") for n in lower_names)
has_configure = "configure" in basenames
has_meson     = "meson.build" in lower_names

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

# dependency scan over #include directives
dep_set, seen = [], set()
for f in src_all:
    try:
        with open(f, "r", errors="replace") as fh:
            for line in fh:
                m = INC_RE.match(line)
                if not m:
                    continue
                inc = m.group(1)
                stem = inc.split("/")[0]            # "openssl/ssl.h" -> "openssl"
                root_stem = stem.rsplit(".", 1)[0]  # "zlib.h"        -> "zlib"
                if root_stem in STD_HEADERS:
                    continue
                if root_stem in seen:
                    continue
                seen.add(root_stem)
                dep_set.append(root_stem)
    except OSError:
        pass

# dep present / missing
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
        if (os.path.isdir(os.path.join(d, stem))
                or os.path.exists(os.path.join(d, stem + ".h"))):
            return True
    return False


deps, missing = [], []
for d in dep_set:
    if pkgconfig_has(d) or header_in_std_path(d):
        deps.append(d)
    else:
        missing.append(d)

# loc — wc -l over all C/C++/header source files
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
PYEOF
