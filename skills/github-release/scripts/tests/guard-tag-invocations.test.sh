#!/usr/bin/env bash
# Self-test for how the tag guard splits a command into invocations — no network.
#
# Pins issue #105 and the bypass found alongside it. The guard used to collapse
# newlines into spaces and then capture from the first "git tag" to the end of
# the whole command, so one match decided the verdict for everything:
#   - a read-only listing was blocked when a later, unrelated line held a
#     version token, with advice about signing a tag nobody asked to create;
#   - and once that first match returned early, a real creation, deletion or
#     tag force-push later in the same command was never looked at.
# Every case below therefore carries a full command, newlines included, which is
# why the payload is built through the environment rather than a delimited table.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG_GUARD="${1:-$HERE/../guard-lightweight-tag.py}"

fail=0

check() { # <expected-rc> <description> <command>
  local want="$1" desc="$2" command="$3" payload got
  payload=$(CMD="$command" python3 -c \
    'import json,os;print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}))')
  printf '%s' "$payload" | python3 "$TAG_GUARD" >/dev/null 2>&1
  got=$?
  if [[ "$got" == "$want" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       expected rc: %s\n       actual rc:   %s\n' "$desc" "$want" "$got"
    fail=1
  fi
}

check_reason() { # <expected-substring-in-reason> <description> <command>
  local want="$1" desc="$2" command="$3" payload stderr got
  payload=$(CMD="$command" python3 -c \
    'import json,os;print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}))')
  stderr=$(printf '%s' "$payload" | python3 "$TAG_GUARD" 2>&1 >/dev/null)
  got=$?
  if [[ "$got" == 2 && "$stderr" == *"$want"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       expected rc 2 and reason containing: %s\n       actual rc:   %s\n       actual stderr: %s\n' \
      "$desc" "$want" "$got" "$stderr"
    fail=1
  fi
}

# --- issue #105: read-only listings stay allowed whatever follows them -------
check 0 'listing alone' \
  'git tag --sort=-v:refname | head -5'
check 0 'listing, then an unrelated line naming a version' \
  'git tag --sort=-v:refname | head -5
git log --oneline -3 v2.11.1'
check 0 'listing, then a version named after &&' \
  'git tag --sort=-v:refname && git log v1.2.3'
check 0 'listing, then a version echoed after ;' \
  'git tag -l | head -3; echo v9.9.9'
check 0 'listing a version glob' \
  "git tag -l 'v1.*'"

# --- read-only inspection flags carrying a version argument -----------------
check 0 'inspect: -n with a version' 'git tag -n5 v1.2.3'
check 0 'inspect: --contains' 'git tag --contains v1.2.3'
check 0 'inspect: --points-at' 'git tag --points-at v1.2.3'
check 0 'inspect: --merged' 'git tag --merged v1.2.3'
check 0 'inspect: --format' 'git tag --format="%(refname)" v1.2.3'
check 0 'bare git tag' 'git tag'
check 0 'verify' 'git tag -v v1.2.3'

# --- the bypass: every invocation is judged, not just the first -------------
check 2 'lightweight tag alone' 'git tag v1.2.3'
check 2 'lightweight tag after a listing (&&)' 'git tag -l && git tag v1.2.3'
check 2 'lightweight tag after a listing (newline)' 'git tag -l
git tag v1.2.3'
check 2 'lightweight tag split across a line continuation' 'git tag \
v1.2.3'
check 2 'tag deletion after a listing' 'git tag -l && git tag -d v1.2.3'
# --delete was blocked before too, but through the creation branch, so the
# advice told the user to sign the tag they were deleting.
check_reason 'Deleting a version tag' 'tag deletion, long flag' 'git tag --delete v1.2.3'
check 2 'remote tag deletion after a listing' 'git tag -l
git push --delete origin v1.2.3'
check 2 'tag force-push after a listing' 'git tag -l
git push --force --tags'
check 2 'refspec tag deletion after a listing' 'git tag -l && git push origin :refs/tags/v1.2.3'

# --- a prefixed invocation is still an invocation (CodeRabbit, PR #111) -----
check 2 'lightweight tag in a loop body' 'for r in a b; do git tag v1.2.3; done'
check 2 'lightweight tag in a conditional body' 'if true; then git tag v1.2.3; fi'
check 2 'lightweight tag behind an env assignment' 'TZ=UTC git tag v1.2.3'
check 2 'lightweight tag behind sudo' 'sudo git tag v1.2.3'
check 2 'tag force-push behind sudo' 'sudo git push --force --tags'
# ... but the words have to be running git, not sitting inside an argument.
check 0 'the command name inside an echo' 'echo "run git tag v1.2.3 to tag it"'
check 0 'the command name inside a commit message' 'git commit -m "git tag v1.2.3"'

# --- creation forms that stay allowed ---------------------------------------
# -m and -F imply -a when -a/-s/-u are absent, so these are annotated tags.
check 0 'tag with -m only' 'git tag -m "Release v1.2.3" v1.2.3'
check 0 'tag with --message only' 'git tag --message="Release" v1.2.3'
check 0 'tag with -F only' 'git tag -F notes.txt v1.2.3'
check 0 'tag with --file only' 'git tag --file=notes.txt v1.2.3'
check 0 'signed tag' 'git tag -s v1.2.3 -m "Release v1.2.3"'
check 0 'annotated tag' 'git tag -a v1.2.3 -m "Release v1.2.3"'
check 0 'signed tag with stderr redirected' 'git tag -s v1.2.3 -m release 2>&1'
check 0 'signed tag after a listing' 'git tag -l && git tag -s v1.2.3 -m release'
check 0 'non-version tag' 'git tag nightly'
check 0 'non-version tag deletion' 'git tag -d nightly'
check 0 'ordinary branch push' 'git push origin main'

exit "$fail"
