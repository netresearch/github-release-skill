#!/usr/bin/env bash
# Self-test for how the gh-release guard splits a command into invocations — no network.
#
# The sibling tag guard learned this the hard way (issue #105): a Bash call
# carries SEVERAL commands, and the guard reads the whole call. Two ways to get
# that wrong, both measured on this guard on 2026-09-11:
#   - a newline is a command separator exactly as ";" is, but the command was
#     flattened with `" ".join(command.split())` and the separator set held only
#     [;&|], so anything on its own line was never seen;
#   - an invocation may carry a prefix (sudo, env VAR=x, a loop keyword), and the
#     pattern demanded that "gh" sit directly after the separator.
# Both let "gh release create" through, which burns a tag name permanently under
# immutable releases. Every case below therefore carries a full command,
# newlines included, which is why the payload goes through the environment.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_GUARD="${1:-$HERE/../guard-gh-release.py}"

fail=0

check() { # <expected-rc> <description> <command>
  local want="$1" desc="$2" command="$3" payload got
  payload=$(CMD="$command" python3 -c \
    'import json,os;print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}))')
  printf '%s' "$payload" | python3 "$GH_GUARD" >/dev/null 2>&1
  got=$?
  if [[ "$got" == "$want" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       expected rc: %s\n       actual rc:   %s\n' "$desc" "$want" "$got"
    fail=1
  fi
}

# --- the operations this guard exists to stop ------------------------------
check 2 'create, alone' 'gh release create v1.2.3'
check 2 'delete, alone' 'gh release delete v1.2.3'
check 2 'edit with --title' 'gh release edit v1.2.3 --title "x"'
check 2 'unknown subcommand' 'gh release upload v1.2.3 file.zip'

# --- a newline separates commands, exactly as ";" does ----------------------
# Regression: newlines were collapsed into spaces and a space was not a
# separator, so anything on its own line was invisible.
check 2 'create on its own line' \
  'echo preparing
gh release create v1.2.3'
check 2 'delete on its own line' \
  'cd /tmp
gh release delete v1.2.3
echo done'
check 2 'create on its own line after a pipeline' \
  'git log --oneline | head -3
gh release create v1.2.3'

# --- an invocation may carry a prefix --------------------------------------
# Regression: "gh" had to sit directly after the separator, so any prefix hid it.
check 2 'prefixed with sudo' 'sudo gh release create v1.2.3'
check 2 'prefixed with an env assignment' 'GH_TOKEN=x gh release delete v1.2.3'
# shellcheck disable=SC2016  # the guard must see "$v" literally, unexpanded
check 2 'inside a loop body' 'for v in v1.2.3; do gh release create "$v"; done'
check 2 'inside a subshell' '(gh release delete v1.2.3)'

# --- read-only and notes-only stay allowed ---------------------------------
check 0 'view' 'gh release view v1.2.3'
check 0 'list' 'gh release list'
check 0 'download' 'gh release download v1.2.3'
check 0 'edit --notes' 'gh release edit v1.2.3 --notes "text"'
check 0 'edit --notes-file' 'gh release edit v1.2.3 --notes-file notes.md'
check 0 'view on its own line' \
  'echo checking
gh release view v1.2.3'
check 0 'list after a prefix' 'GH_PAGER=cat gh release list'
check 0 'a non-release gh command' 'gh pr list'
check 0 'gh run, on its own line' \
  'echo hi
gh run watch 123'

# --- the words are not the command -----------------------------------------
check 0 'the phrase inside an echo argument' \
  'echo "never run gh release create v1.2.3"'
check 0 'the phrase inside a heredoc body' \
  "cat > note.md <<'EOF'
never run: gh release create v1.2.3
EOF"
check 0 'the phrase inside a heredoc, after a separator' \
  "cat > note.md <<'EOF'
step one; gh release delete v1.2.3 is forbidden
EOF"
check 2 'a real create AFTER a heredoc terminator' \
  "cat > note.md <<'EOF'
harmless
EOF
gh release create v1.2.3"

# --- gh api to a release endpoint ------------------------------------------
check 2 'api POST to releases' 'gh api repos/o/r/releases -X POST -f tag_name=v1.2.3'
check 2 'api DELETE on its own line' \
  'echo hi
gh api repos/o/r/releases/1 -X DELETE'
check 0 'api GET on releases' 'gh api repos/o/r/releases'

if [[ "$fail" == 0 ]]; then
  printf '\nAll gh-release invocation tests passed\n'
else
  printf '\nFAILED\n'
fi
exit "$fail"
