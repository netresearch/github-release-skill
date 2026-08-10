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

# Cases, one per line: <expected-rc>|<guard>|<shape>|<command>|<description>
# shape: nested = Claude Code's tool_input envelope, flat = bare {"command": …},
#        raw   = the payload is the 4th field verbatim (malformed-input cases).
CASES=$(
  cat <<'EOF'
2|tag|nested|git tag v0.28.0|tag guard blocks lightweight tag (nested payload)
2|tag|flat|git tag v0.28.0|tag guard blocks lightweight tag (flat payload)
0|tag|nested|git tag -s v0.28.0 -m release|tag guard allows signed tag
0|tag|nested|git tag -a v0.28.0 -m release|tag guard allows annotated tag
0|tag|nested|gh release view v0.28.0|tag guard ignores non-git command
2|rel|nested|gh release create v0.28.0|release guard blocks create (nested payload)
2|rel|flat|gh release create v0.28.0|release guard blocks create (flat payload)
0|rel|nested|gh release edit v0.28.0 --notes-file notes.md|release guard allows notes-file edit
0|rel|nested|gh release view v0.28.0|release guard allows read-only view
0|rel|nested|git tag -s v0.28.0 -m release|release guard ignores non-release command
0|tag|raw||tag guard allows on empty stdin
0|rel|raw||release guard allows on empty stdin
0|tag|raw|not json at all|tag guard allows on non-JSON stdin
EOF
)

while IFS='|' read -r want guard shape command desc; do
  [[ -z "$want" ]] && continue

  local_guard="$TAG_GUARD"
  [[ "$guard" == "rel" ]] && local_guard="$REL_GUARD"

  case "$shape" in
    nested) payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$command") ;;
    flat)   payload=$(printf '{"command":"%s"}' "$command") ;;
    *)      payload="$command" ;;
  esac

  printf '%s' "$payload" | python3 "$local_guard" >/dev/null 2>&1
  got=$?

  if [[ "$got" == "$want" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       expected rc: %s\n       actual rc:   %s\n' "$desc" "$want" "$got"
    fail=1
  fi
done <<<"$CASES"

exit "$fail"
