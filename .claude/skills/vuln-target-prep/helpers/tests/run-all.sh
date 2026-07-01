#!/usr/bin/env bash
# run-all.sh — run every test under helpers/tests/, exit nonzero on first failure.
# Discovers BOTH conventions: test-*.sh AND *.test.sh
# (vuln-mine learned the literal *.test.sh glob matches zero files when
# nullglob is off, so we use both patterns and dedup.)
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failures=0
shopt -s nullglob
# Match both conventions so test-*.sh (Tasks 2-7) and *.test.sh (future) are found.
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
