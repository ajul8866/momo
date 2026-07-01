#!/usr/bin/env bash
# Build the example naiveparse target with AddressSanitizer.
# Output binary lands at manifests/example/naiveparse (parent of src/).
set -euo pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$(cd "$SRC_DIR/.." && pwd)"
cc -fsanitize=address -g -O1 "$SRC_DIR/naiveparse.c" -o "$OUT_DIR/naiveparse"
echo "built $OUT_DIR/naiveparse"
