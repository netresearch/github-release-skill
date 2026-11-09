#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Self-test for run-guard.sh, the launcher both guard hooks start through.
#
# The guards need tree-sitter and tree-sitter-bash, which uv installs on first
# use. Started as a plain `uv run` from hooks/hooks.json, a machine without
# network and with an empty uv cache blocked EVERY Bash call, `ls` included,
# because both hooks match all Bash calls and block on any failure. These cases
# run the command strings from hooks/hooks.json, so a hook that bypasses the
# launcher fails here.
#
# "Offline" below is UV_OFFLINE=1 with an empty UV_CACHE_DIR; the unreachable
# index case points uv at a blackholed address. Neither needs network. The
# warm cases need the two packages once, like the other guard tests.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
LAUNCHER="$HERE/../run-guard.sh"
HOOKS="$ROOT/hooks/hooks.json"

fail=0
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# The hooks.json command for a guard, exactly as Claude Code runs it.
hook_cmd() { # <guard-script-name>
  local guard="$1"
  jq -r --arg g "$guard" '.hooks.PreToolUse[].hooks[].command | select(contains($g))' "$HOOKS"
}
REL_CMD=$(hook_cmd guard-gh-release.py)
TAG_CMD=$(hook_cmd guard-lightweight-tag.py)
for c in "$REL_CMD" "$TAG_CMD"; do
  if [[ "$c" != *run-guard.sh* ]]; then
    printf 'FAIL - hooks.json starts a guard without run-guard.sh: %s\n' "$c"
    fail=1
  fi
done

# The warm cases need the dependencies installed, not left to whichever suite
# happened to run first, and a stamp of their own: a fresh stamp in the real
# TMPDIR from a failed install would send them to the fallback.
for g in guard-gh-release.py guard-lightweight-tag.py; do
  if ! uv sync --script "$HERE/../$g" >/dev/null 2>&1; then
    printf 'FAIL - cannot install the dependencies of %s for the warm cases\n' "$g"
    fail=1
  fi
done
WARM_TMP=$(mktemp -d "$SCRATCH/warm.XXXX")

payload_for() { # <command>
  CMD="$1" python3 -c \
    'import json,os;print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}))'
}

# <mode> <expected-rc> <hook-cmd> <description> <command> [expected stderr text]
# mode: warm = the developer's own uv cache; offline = empty cache, no network.
check() {
  local mode="$1" want="$2" hook="$3" desc="$4" command="$5" text="${6:-}"
  local payload got stderr
  payload=$(payload_for "$command")
  if [[ "$mode" == offline ]]; then
    local d
    d=$(mktemp -d "$SCRATCH/offline.XXXX")
    stderr=$(printf '%s' "$payload" |
      CLAUDE_PLUGIN_ROOT="$ROOT" UV_OFFLINE=1 UV_CACHE_DIR="$d/cache" TMPDIR="$d" \
        sh -c "$hook" 2>&1 >/dev/null)
    got=$?
  else
    stderr=$(printf '%s' "$payload" | CLAUDE_PLUGIN_ROOT="$ROOT" TMPDIR="$WARM_TMP" sh -c "$hook" 2>&1 >/dev/null)
    got=$?
  fi
  if [[ "$got" == "$want" && "$stderr" == *"$text"* ]]; then
    printf 'ok   - [%s] %s\n' "$mode" "$desc"
  else
    printf 'FAIL - [%s] %s\n       expected rc: %s, stderr containing: %s\n       actual rc:   %s\n       actual stderr: %s\n' \
      "$mode" "$desc" "$want" "$text" "$got" "$stderr"
    fail=1
  fi
}

# --- warm cache: the guard decides, and the payload reaches it ---------------
# A launcher that dropped stdin would hand the guard an empty command, which
# the guard allows, so the blocking cases are what pins the forwarding.
check warm 2 "$REL_CMD" 'release guard blocks delete' 'gh release delete v1.2.3'
check warm 2 "$REL_CMD" 'release guard blocks create on its own line' $'cd /tmp\ngh release create v1.2.3'
check warm 0 "$REL_CMD" 'release guard allows view' 'gh release view v1.2.3'
check warm 0 "$REL_CMD" 'release guard allows ls' 'ls -la'
check warm 2 "$TAG_CMD" 'tag guard blocks lightweight tag' 'git tag v1.2.3'
check warm 0 "$TAG_CMD" 'tag guard allows signed tag' 'git tag -s v1.2.3 -m release'
check warm 0 "$TAG_CMD" 'tag guard allows git status' 'git status'

# --- offline, empty cache: the fallback decides -----------------------------
# Regression: every one of these calls exited 1 under `uv run` and was blocked.
check offline 0 "$REL_CMD" 'release guard lets ls through' 'ls -la'
check offline 0 "$TAG_CMD" 'tag guard lets ls through' 'ls -la'
check offline 0 "$REL_CMD" 'words that merely contain gh or git pass' 'echo highlight digit github-cli legit'
check offline 2 "$REL_CMD" 'release guard blocks gh release delete' 'gh release delete v1.2.3' 'uv sync --script'
check offline 2 "$TAG_CMD" 'tag guard blocks git tag' 'git tag v1.2.3' 'uv sync --script'
check offline 2 "$REL_CMD" 'any gh call is blocked' 'gh pr list'
check offline 2 "$TAG_CMD" 'any git call is blocked' 'git status'
check offline 2 "$REL_CMD" 'gh with a directory' '/usr/bin/gh release create v1.2.3'
check offline 2 "$REL_CMD" 'gh escaped' '\gh release create v1.2.3'
check offline 2 "$REL_CMD" 'gh split by empty quotes' 'g""h release create v1.2.3'
check offline 2 "$TAG_CMD" 'git quoted' "'git' tag v1.2.3"
check offline 2 "$TAG_CMD" 'git on a later line' $'echo start\nsudo git tag v1.2.3'

# A payload whose tool_input.command is empty is read through to the top-level
# command, as the guards' parse_command does.
d=$(mktemp -d "$SCRATCH/shape.XXXX")
printf '%s' '{"tool_input":{"command":""},"command":"gh release delete v1"}' |
  CLAUDE_PLUGIN_ROOT="$ROOT" UV_OFFLINE=1 UV_CACHE_DIR="$d/cache" TMPDIR="$d" \
    sh -c "$REL_CMD" >/dev/null 2>&1
got=$?
if [[ "$got" == 2 ]]; then
  printf 'ok   - [offline] empty tool_input.command falls through to command\n'
else
  printf 'FAIL - [offline] empty tool_input.command falls through to command: rc %s\n' "$got"
  fail=1
fi

# --- no uv on PATH: the fallback decides and names the real cause -----------
uv_dir=$(dirname "$(command -v uv)")
if [[ -x "$uv_dir/sh" || -x "$uv_dir/python3" ]]; then
  printf 'skip - [no-uv] uv shares %s with sh or python3\n' "$uv_dir"
else
  NOUV_PATH=$(tr ':' '\n' <<<"$PATH" | grep -vxF "$uv_dir" | paste -sd: -)
  for c in 'ls -la|0|' 'gh pr list|2|uv is not on PATH'; do
    IFS='|' read -r command want text <<<"$c"
    d=$(mktemp -d "$SCRATCH/nouv.XXXX")
    stderr=$(printf '%s' "$(payload_for "$command")" |
      PATH="$NOUV_PATH" CLAUDE_PLUGIN_ROOT="$ROOT" TMPDIR="$d" sh -c "$REL_CMD" 2>&1 >/dev/null)
    got=$?
    if [[ "$got" == "$want" && "$stderr" == *"$text"* ]]; then
      printf 'ok   - [no-uv] %s\n' "$command"
    else
      printf 'FAIL - [no-uv] %s: rc %s (want %s), stderr: %s\n' "$command" "$got" "$want" "$stderr"
      fail=1
    fi
  done
fi

# --- unreachable index: the call is decided inside the hook timeout ---------
# uv waits about 49 s for a blackholed index on its own; hooks.json allows 10.
d=$(mktemp -d "$SCRATCH/blackhole.XXXX")
for round in first second; do
  start=$(date +%s)
  printf '%s' "$(payload_for 'ls -la')" |
    CLAUDE_PLUGIN_ROOT="$ROOT" UV_CACHE_DIR="$d/cache" TMPDIR="$d" \
      UV_DEFAULT_INDEX=http://10.255.255.1/simple sh -c "$REL_CMD" >/dev/null 2>&1
  got=$?
  secs=$(($(date +%s) - start))
  limit=8
  [[ "$round" == second ]] && limit=2 # the install is not retried for 5 minutes
  if [[ "$got" == 0 && "$secs" -le "$limit" ]]; then
    printf 'ok   - [blackhole] %s call allowed in %ss (limit %ss)\n' "$round" "$secs" "$limit"
  else
    printf 'FAIL - [blackhole] %s call: rc %s after %ss (want 0 within %ss)\n' "$round" "$got" "$secs" "$limit"
    fail=1
  fi
done

# --- every blocking case of the guards' own suites, through the launcher ----
# warm: the full suites, verdicts unchanged. offline: the fallback must block
# every case the guards block (it may block more, so allowed cases are skipped).
run_suite() { # <mode> <suite>
  local mode="$1" suite="$2" out rc d
  if [[ "$mode" == offline ]]; then
    d=$(mktemp -d "$SCRATCH/suite.XXXX")
    out=$(GUARD_LAUNCHER="$LAUNCHER" BLOCK_ONLY=1 UV_OFFLINE=1 UV_CACHE_DIR="$d/cache" TMPDIR="$d" \
      bash "$HERE/$suite" 2>&1)
  else
    out=$(GUARD_LAUNCHER="$LAUNCHER" bash "$HERE/$suite" 2>&1)
  fi
  rc=$?
  local oks
  oks=$(grep -c '^ok ' <<<"$out")
  if [[ "$rc" == 0 && "$oks" -gt 0 ]]; then
    printf 'ok   - [%s] %s through the launcher (%s cases)\n' "$mode" "$suite" "$oks"
  else
    printf 'FAIL - [%s] %s through the launcher (rc %s, %s ok)\n' "$mode" "$suite" "$rc" "$oks"
    grep '^FAIL' <<<"$out" | head -20
    fail=1
  fi
}
for suite in guard-gh-release-invocations.test.sh guard-tag-invocations.test.sh; do
  run_suite warm "$suite"
  run_suite offline "$suite"
done

exit "$fail"
