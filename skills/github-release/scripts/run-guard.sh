#!/bin/sh
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# Starts one guard hook (hooks/hooks.json) and keeps the machine usable when
# the guard's dependencies cannot be installed.
#
# Usage: run-guard.sh <guard-script-name>   (the hook payload arrives on stdin)
#
# The guards declare tree-sitter and tree-sitter-bash as inline dependencies,
# which uv installs on first use. Both hooks match EVERY Bash call and block on
# any failure, so with no network and an empty uv cache a plain `uv run` exits
# non-zero and every Bash call is blocked, `ls` included. An unreachable index
# is worse: uv waits about 49 s, past the hook timeout. Its exit codes cannot
# tell such failures from the guard's own verdict either, because uv exits 2
# on a network error and 2 is the guard's "block".
#
# So the decision happens before the guard runs:
#   1. `uv sync --script --offline` reports whether the environment can be
#      built from the cache alone (about 10 ms when it can).
#   2. If not, one bounded online install is tried (3 s HTTP timeout, no
#      retries), at most once per 5 minutes per user.
#   3. If the environment is ready, the guard runs offline and its exit code
#      is passed through unchanged.
#   4. Otherwise a fallback without dependencies decides: it blocks every call
#      that names `gh` or `git` and lets every other call through.
#
# Requires uv 0.5.31 or later (`uv sync --script`). With an older uv the
# fallback decides every call.
set -u

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
name=${1:?usage: run-guard.sh <guard-script-name>}
guard="$here/$name"
[ -f "$guard" ] || {
  echo "run-guard.sh: no guard script at $guard" >&2
  exit 1
}

# The payload is read once and handed to whichever path decides.
payload=$(cat)

env_ready() {
  uv sync --script "$guard" --offline >/dev/null 2>&1
}

if ! env_ready; then
  stamp="${TMPDIR:-/tmp}/github-release-guard-install-$(id -u).stamp"
  if [ -z "$(find "$stamp" -mmin -5 2>/dev/null)" ]; then
    touch "$stamp" 2>/dev/null
    UV_HTTP_TIMEOUT=3 UV_HTTP_RETRIES=0 uv sync --script "$guard" >/dev/null 2>&1
  fi
fi

if env_ready; then
  printf '%s' "$payload" | uv run --offline "$guard"
  exit $?
fi

# --- fallback: the guard cannot run -----------------------------------------
# Read the command out of the payload when a Python is at hand; otherwise scan
# the whole payload, which can only block more, never less.
command=$(printf '%s' "$payload" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
ti = d.get("tool_input") if isinstance(d.get("tool_input"), dict) else {}
c = ti.get("command", d.get("command", ""))
if not isinstance(c, str):
    sys.exit(1)
sys.stdout.write(c)
' 2>/dev/null) || command=$payload

# The guards recognise `\gh`, `"git"`, `g""h` and `/usr/bin/gh`: drop quotes
# and backslashes, then look for gh or git as a word of its own.
if printf '%s\n' "$command" | tr -d "\\\\\"'" |
  grep -Eq '(^|[^A-Za-z0-9_-])(gh|git)([^A-Za-z0-9_-]|$)'; then
  cat >&2 <<EOF
github-release: $name cannot run, because its dependencies (tree-sitter,
tree-sitter-bash) are not in the uv cache and could not be installed.
Until they are, every Bash call that names gh or git is blocked; this says
nothing about the command itself. With network access, run once:
  uv sync --script "$guard"
EOF
  exit 2
fi
exit 0
