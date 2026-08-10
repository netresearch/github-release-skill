#!/usr/bin/env bash
# Self-test for the two PreToolUse guards — no network.
#
# Pins the regression fixed alongside it: Claude Code delivers the command as
# `tool_input.command`, while both guards only read a top-level `command`. Every
# real invocation therefore fell through to exit 0 and the guards blocked
# nothing at all in the harness they exist for. Both payload shapes are asserted
# here so the flat shape (direct invocation, other harnesses) keeps working too.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG_GUARD="$HERE/../guard-lightweight-tag.py"
REL_GUARD="$HERE/../guard-gh-release.py"

fail=0
check() { # check <name> <expected-rc> <guard> <payload>
  local rc
  printf '%s' "$4" | python3 "$3" >/dev/null 2>&1
  rc=$?
  if [ "$rc" = "$2" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected rc: %s\n       actual rc:   %s\n' "$1" "$2" "$rc"
    fail=1
  fi
}

nested() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
flat()   { printf '{"command":"%s"}' "$1"; }

# --- guard-lightweight-tag: blocks a lightweight version tag ----------------
check "tag guard blocks lightweight tag (nested payload)" 2 "$TAG_GUARD" "$(nested 'git tag v0.28.0')"
check "tag guard blocks lightweight tag (flat payload)"   2 "$TAG_GUARD" "$(flat   'git tag v0.28.0')"
check "tag guard allows signed tag (nested payload)"      0 "$TAG_GUARD" "$(nested 'git tag -s v0.28.0 -m release')"
check "tag guard allows annotated tag (nested payload)"   0 "$TAG_GUARD" "$(nested 'git tag -a v0.28.0 -m release')"
check "tag guard ignores non-git command"                 0 "$TAG_GUARD" "$(nested 'gh release view v0.28.0')"

# --- guard-gh-release: blocks mutating release operations ------------------
check "release guard blocks create (nested payload)"      2 "$REL_GUARD" "$(nested 'gh release create v0.28.0')"
check "release guard blocks create (flat payload)"        2 "$REL_GUARD" "$(flat   'gh release create v0.28.0')"
check "release guard allows notes-file edit"              0 "$REL_GUARD" "$(nested 'gh release edit v0.28.0 --notes-file notes.md')"
check "release guard allows read-only view"               0 "$REL_GUARD" "$(nested 'gh release view v0.28.0')"
check "release guard ignores non-release command"         0 "$REL_GUARD" "$(nested 'git tag -s v0.28.0 -m release')"

# --- malformed input must never block --------------------------------------
check "tag guard allows on empty stdin"                   0 "$TAG_GUARD" ""
check "release guard allows on empty stdin"               0 "$REL_GUARD" ""
check "tag guard allows on non-JSON stdin"                0 "$TAG_GUARD" "not json at all"

exit "$fail"
