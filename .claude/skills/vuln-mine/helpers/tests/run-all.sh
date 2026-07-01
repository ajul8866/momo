#!/usr/bin/env bash
# Run every *.test.sh under helpers/tests/; exit nonzero on first failure.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failures=0
shopt -s nullglob
# ponytail: brief specifies *.test.sh, but Tasks 2-7 created test-*.sh.
# Match both conventions so all existing tests are discovered.
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
