#!/usr/bin/env bash
# Self-test for check-changelog-links.py against THIS repository's CHANGELOG.
#
# The script existed and nothing ran it, so the file it validates drifted: a
# release section had no footer link and the [Unreleased] range pointed at the
# version before the newest one. Both are invisible until a reader clicks a
# link that does not resolve. This test runs the checker where the drift
# happens, on every push, so the next missing link fails a job instead of
# shipping.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../check-changelog-links.py"
CHANGELOG="$HERE/../../../../CHANGELOG.md"

out="$("$CHECK" "$CHANGELOG" 2>&1)"
rc=$?

if [ $rc -eq 0 ]; then
  printf 'ok   - CHANGELOG.md link references resolve\n'
  exit 0
fi

printf 'FAIL - CHANGELOG.md link references\n%s\n' "$out"
exit 1
