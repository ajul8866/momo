#!/usr/bin/env bash
# build-target.sh — deterministic build fallback-chain A->B->C.
# Usage: build-target.sh <src-dir> <out-dir> <fingerprint.json>
# Tries strategies in order, stops first that yields a working artifact,
# logs each attempt to <out-dir>/build.log. Exit 0 on success, 1 on total failure
# (structured diagnosis on stderr AND build.log: strategies tried, each failure's
# last 5 stderr lines, missing deps, concrete apt install suggestion).
set -uo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <src-dir> <out-dir> <fingerprint.json>" >&2
    exit 1
fi

src_dir="$1"; out_dir="$2"; fp="$3"
if [ ! -d "$src_dir" ]; then echo "ERROR: src-dir not a directory: $src_dir" >&2; exit 1; fi
if [ ! -f "$fp" ]; then echo "ERROR: fingerprint.json not found: $fp" >&2; exit 1; fi
mkdir -p "$out_dir" || { echo "ERROR: cannot create out-dir: $out_dir" >&2; exit 1; }

name="$(basename "$(cd "$src_dir" && pwd)")"
log="$out_dir/build.log"
: > "$log"

ASAN_FLAGS="-fsanitize=address -g"
err_capture="$out_dir/.stderr_capture"

# --- field readers for fingerprint.json (jq-free, one-line grep+sed) ---
fp_field() { # <key>  -> value (empty if absent)
    grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$fp" \
        | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/'
}

build_system="$(fp_field build_system)"
missing_raw="$(grep -oE '"missing_deps"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$fp" \
    | head -1 | sed -E 's/.*\[(.*)\].*/\1/' | sed -E 's/[",]//g')"

# --- append one strategy attempt block to build.log ---
log_attempt() { # <letter> <desc> <cmd> <rc> <errfile>
    local letter="$1" desc="$2" cmd="$3" rc="$4" errfile="$5"
    {
        echo "STRATEGY $letter: $desc"
        echo " command: $cmd"
        echo " exit: $rc"
        if [ "$rc" -ne 0 ] && [ -s "$errfile" ]; then
            echo " last stderr (up to 5 lines):"
            tail -5 "$errfile" | sed 's/^/   /'
        fi
        echo
    } >> "$log"
}

# ============================================================================
# Strategy A: native build system -> locate/collect .a
# ============================================================================
strategy_a() {
    if printf '%s' "$missing_raw" | grep -q '[a-zA-Z0-9_]'; then
        { echo "STRATEGY A: native build system"
          echo "  skipped: missing deps:"
          printf '%s\n' "$missing_raw" | sed 's/^/   /'
          echo
        } >> "$log"
        return 1
    fi
    local subdir="$out_dir/build_a"
    rm -rf "$subdir"; mkdir -p "$subdir"
    : > "$err_capture"
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
            ( cd "$src_dir" && make CFLAGS="$ASAN_FLAGS" CXXFLAGS="$ASAN_FLAGS" \
                CC="${CC:-cc}" CXX="${CXX:-c++}" >"$err_capture" 2>&1 )
            local rc=$?
            log_attempt A "make native build" "make CFLAGS=-asan CC=cc" "$rc" "$err_capture"
            [ $rc -eq 0 ] || return 1
            ;;
        autotools)
            ( cd "$src_dir" && ./configure CC="${CC:-cc}" CFLAGS="$ASAN_FLAGS" >"$err_capture" 2>&1 \
                && make >>"$err_capture" 2>&1 )
            local rc=$?
            log_attempt A "autotools native build" "./configure CC=cc && make" "$rc" "$err_capture"
            [ $rc -eq 0 ] || return 1
            ;;
        *)
            { echo "STRATEGY A: native build system"
              echo "  skipped: build_system='$build_system' not cmake/make/autotools"
              echo
            } >> "$log"
            return 1
            ;;
    esac

    # locate resulting .a (native build may have placed it under src_dir or subdir)
    local found_a
    found_a="$(find "$src_dir" "$subdir" -type f -name '*.a' 2>/dev/null | head -1)"
    if [ -n "$found_a" ]; then
        cp -f "$found_a" "$out_dir/$name.a"
        { echo "STRATEGY A: RESULT success (copied $found_a -> $name.a)"
          echo
        } >> "$log"
        return 0
    fi
    # collect .o into a fresh .a
    local objs
    objs="$(find "$src_dir" "$subdir" -type f \( -name '*.o' -o -name '*.obj' \) 2>/dev/null)"
    if [ -n "$objs" ]; then
        # shellcheck disable=SC2086
        ar rcs "$out_dir/$name.a" $objs
        if [ -f "$out_dir/$name.a" ]; then
            { echo "STRATEGY A: RESULT success (ar rcs collected .o -> $name.a)"
              echo
            } >> "$log"
            return 0
        fi
    fi
    { echo "STRATEGY A: RESULT no .a/.o artifact produced after native build"
      echo
    } >> "$log"
    return 1
}

# gather non-main, non-test/example .c/.cpp sources for compile-gabung
gather_sources() {
    find "$src_dir" -type f \( -name '*.c' -o -name '*.cpp' \) \
        ! -path '*/test/*' ! -path '*/tests/*' ! -path '*/example/*' \
        ! -path '*/examples/*' ! -path '*/build_a/*' \
        | while IFS= read -r f; do
            # skip target's own CLI main (we want library link into harness.c)
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
        { echo "STRATEGY B: compile-gabung"
          echo "  skipped: no non-main .c/.cpp sources found"
          echo
        } >> "$log"
        return 1
    fi
    local inc=""
    [ -d "$src_dir/include" ] && inc="-I$src_dir/include"
    local objdir="$out_dir/obj_b"
    rm -rf "$objdir"; mkdir -p "$objdir"
    : > "$err_capture"
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
    ar rcs "$out_dir/$name.a" $objdir/*.o 2>>"$err_capture" || rc=$?
    log_attempt B "compile-gabung (ar rcs -> $name.a)" "ar rcs $name.a <*.o>" "$rc" "$err_capture"
    if [ $rc -eq 0 ] && [ -f "$out_dir/$name.a" ]; then
        { echo "STRATEGY B: RESULT success ($name.a)"; echo; } >> "$log"
        return 0
    fi
    return 1
}

# ============================================================================
# Strategy C: CLI as harness (skip .a)
# ============================================================================
strategy_c() {
    local main_src
    main_src="$(find "$src_dir" -type f \( -name '*.c' -o -name '*.cpp' \) ! -path '*/build_a/*' \
        -exec grep -l 'int main(' {} \; | head -1)"
    if [ -z "$main_src" ]; then
        { echo "STRATEGY C: CLI as harness"
          echo "  skipped: no main() found in sources"
          echo
        } >> "$log"
        return 1
    fi
    # require reads argv[1] file (fopen/argv[1])
    if ! grep -Eq "argv\[1\]" "$main_src"; then
        { echo "STRATEGY C: CLI as harness"
          echo "  skipped: main does not read argv[1] file"
          echo
        } >> "$log"
        return 1
    fi
    local inc=""
    [ -d "$src_dir/include" ] && inc="-I$src_dir/include"
    : > "$err_capture"
    # compile whole project (main + supporting sources) into CLI binary
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
strategy_c && { echo "build-target: OK strategy C -> $out_dir/${name}_cli"; rm -f "$err_capture"; exit 0; }

# --- total failure: structured diagnosis ---
# Scan only source files (.c/.cpp/.h/.hpp) so we don't re-parse our own build.log.
# A header is "missing" if find produces no output under the standard include dirs.
missing_headers="$(find "$src_dir" -type f \( -name '*.c' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) \
    -print0 2>/dev/null | xargs -0 grep -hoE '#include[[:space:]]*[<][^>]*[>]' 2>/dev/null \
    | grep -oE '[<][^>]*[>]' | tr -d '<>' | sort -u | while IFS= read -r h; do
        [ -z "$h" ] && continue
        found="$(find /usr/include /usr/local/include -name "$h" 2>/dev/null | head -1)"
        [ -z "$found" ] && printf '%s\n' "$h"
    done)"

suggest=""
[ -n "$missing_headers" ] && for h in $missing_headers; do
    case "$h" in
        libpng*)  suggest="$suggest libpng-dev";;
        libjpeg*) suggest="$suggest libjpeg-dev";;
        zlib|zlib.h) suggest="$suggest zlib1g-dev";;
        openssl/*|crypto.h|ssl.h) suggest="$suggest libssl-dev";;
        curl/*)   suggest="$suggest libcurl4-openssl-dev";;
        expat.h|expat_external.h) suggest="$suggest libexpat1-dev";;
        *) suggest="$suggest lib$(printf '%s' "$h" | sed -E 's/\.h$//' | tr '[:upper:]' '[:lower:]')-dev";;
    esac
done
suggest="$(printf '%s' "$suggest" | xargs)"  # trim/dedup whitespace

{
    echo "=== build-target: all strategies failed for '$name' ==="
    echo "Strategies tried (see above for command/exit/stderr)."
    if [ -n "$missing_headers" ]; then
        echo "Missing headers detected:"
        printf '  %s\n' $missing_headers
    fi
    if [ -n "$suggest" ]; then
        echo "Suggested install (run manually, then re-run prep):"
        echo "  apt install $suggest"
    fi
} >> "$log"

{
    echo "ERROR: build-target: all strategies failed for '$name' (see $log)" >&2
    [ -n "$suggest" ] && echo "Try: apt install $suggest" >&2
}
rm -f "$err_capture"
exit 1
