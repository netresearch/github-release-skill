#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Self-test for suggest-version.sh against throwaway git repositories. The
# script runs git-cliff through uvx, so the first run downloads git-cliff.
#
# Pins the 0.x rule: on 0.y with y >= 1 the caret stops at the middle number
# (`^0.54` admits 0.54.* only), so a middle bump is a new major for every
# consumer. suggest-version.sh used to map `feat:` to the middle number on 0.x
# too; netresearch/t3x-nr-llm raised the middle number eleven times from 0.45.0
# to 0.55.0 without a breaking entry, and each such release requires the
# dependent extensions to widen their constraint and release. On 0.x a feature
# is now a patch bump; only a breaking commit raises the middle number. From
# 1.0.0 on, feat is a minor bump.
#
# `check` cases must hold. `known` cases are inputs git-cliff answers
# differently from what the rule wants; they are documented, not patched
# around (references/release-process.md), and print the current answer
# without failing. A `known` case that starts to match says so.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../suggest-version.sh"

fail=0
check() { # check <name> <expected> <actual>
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$name"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$name" "$expected" "$actual"
    fail=1
  fi
}

known() { # known <name> <wanted> <actual>
  local name="$1" wanted="$2" actual="$3"
  if [[ "$wanted" == "$actual" ]]; then
    printf 'ok   - %s (known limit no longer reproduces; move it to check)\n' "$name"
  else
    printf 'known- %s\n       wanted:   [%s]\n       git-cliff: [%s]\n' "$name" "$wanted" "$actual"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run_in <tag> <commit message>... -> the script's whole output, from a fresh
# repository whose last tag is <tag> followed by the commits. A message may span
# several lines (subject, blank line, body with footers).
run_in() {
  local tag="$1"; shift
  local repo="$TMP/repo-$RANDOM$RANDOM"
  mkdir -p "$repo"
  # env -u: a hook or a linked worktree exports GIT_DIR, which would override -C.
  # The -c flags keep a signing or hook setup of the machine out of the probe.
  local g=(env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C "$repo" -c user.email=t@example.org -c user.name=T -c commit.gpgsign=false -c tag.gpgsign=false -c tag.forceSignAnnotated=false -c core.hooksPath=/dev/null)
  if ! { "${g[@]}" init -q && "${g[@]}" commit -q --allow-empty -m "chore: initial" && "${g[@]}" tag -a "$tag" -m "$tag"; }; then
    echo "SETUP FAILED - could not create the repository with tag $tag" >&2
    exit 2
  fi
  local s
  for s in "$@"; do
    if ! "${g[@]}" commit -q --allow-empty -m "$s"; then
      echo "SETUP FAILED - could not commit: $s" >&2
      exit 2
    fi
  done
  (cd "$repo" && env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE bash "$SCRIPT")
}

# suggest <tag> <commit subject>... -> the "suggested:" and "bump:" lines only.
suggest() {
  run_in "$@" | grep -E '^(suggested|bump):' | tr '\n' ' '
}

# Repeated expectations and messages, named once.
MIDDLE_BUMP='suggested:0.55.0 bump:minor '
PATCH_BUMP='suggested:0.54.3 bump:patch '
FEAT='feat: add a thing'

check "0.x: feat is a patch bump" \
  "$PATCH_BUMP" "$(suggest v0.54.2 "$FEAT" 'fix: repair a thing')"
check "0.x: fix is a patch bump" \
  "$PATCH_BUMP" "$(suggest v0.54.2 'fix: repair a thing')"
check "0.x: a breaking commit raises the middle number" \
  "$MIDDLE_BUMP" "$(suggest v0.54.2 "$FEAT" 'feat(api)!: remove Foo::bar()')"
check "0.x: ! on a fix commit raises the middle number" \
  "$MIDDLE_BUMP" "$(suggest v0.54.2 'fix!: reject the old option')"
check "0.x: a BREAKING CHANGE footer on a feat commit raises the middle number" \
  "$MIDDLE_BUMP" "$(suggest v0.54.2 "$FEAT"$'\n\nBREAKING CHANGE: Foo::bar() is gone.')"
check "0.x: a BREAKING-CHANGE footer counts as well" \
  "$MIDDLE_BUMP" "$(suggest v0.54.2 $'fix: repair a thing\n\nBREAKING-CHANGE: the option is renamed.')"
check "0.x: BREAKING CHANGE: none is a breaking footer, as the specification reads it" \
  "$MIDDLE_BUMP" "$(suggest v0.54.2 "$FEAT"$'\n\nBREAKING CHANGE: none')"
check "0.x: a name!: string line in a body is no breaking commit" \
  "$PATCH_BUMP" "$(suggest v0.54.2 "$FEAT"$'\n\nname!: string')"
check "0.x: a subject that only mentions a breaking change is no breaking commit" \
  "$PATCH_BUMP" "$(suggest v0.54.2 'fix: explain why this is no breaking change')"
check "0.x: a body that only mentions breaking changes is no footer" \
  "$PATCH_BUMP" "$(suggest v0.54.2 "$FEAT"$'\n\nNo breaking change here.')"
check "0.x: no commits since the tag is no bump" \
  "suggested:0.54.2 bump:none " "$(suggest v0.54.2)"
check "0.0.z: git-cliff raises the last number, also for a breaking commit" \
  "suggested:0.0.4 bump:patch " "$(suggest v0.0.3 'feat!: remove a thing')"
check "1.x: feat is a minor bump" \
  "suggested:1.3.0 bump:minor " "$(suggest v1.2.3 "$FEAT")"
check "1.x: a breaking commit is a major bump" \
  "suggested:2.0.0 bump:major " "$(suggest v1.2.3 'feat!: remove a thing')"
check "1.x: build metadata is no pre-release" \
  "suggested:1.3.0 bump:minor " "$(suggest v1.2.3+build.7 "$FEAT")"
check "1.x: a leading zero is not a version number" \
  "suggested:unknown bump:unknown " "$(suggest v1.02.3 "$FEAT")"

known "0.x: a subject that opens with BREAKING CHANGE: raises the middle number" \
  "$MIDDLE_BUMP" "$(suggest v0.54.2 'BREAKING CHANGE: drop the old option')"
known "0.x: a squash body listing a ! commit raises the middle number" \
  "$MIDDLE_BUMP" "$(suggest v0.54.2 "$FEAT (#12)"$'\n\n* feat: add the part\n* feat(api)!: drop Foo::bar()')"
known "0.x: a squash body with - bullets counts as well" \
  "$MIDDLE_BUMP" "$(suggest v0.54.2 "$FEAT (#12)"$'\n\n- fix!: reject the old option')"
known "0.x: after a pre-release tag the release of that version is next" \
  "suggested:0.54.2 bump:release " "$(suggest v0.54.2-rc.1 "$FEAT")"
known "1.x: after a pre-release tag the release of that version is next" \
  "suggested:1.3.0 bump:release " "$(suggest v1.3.0-beta.2 'fix: repair a thing')"
known "1.x: a breaking commit after a minor pre-release raises the major" \
  "suggested:2.0.0 bump:major " "$(suggest v1.3.0-rc.1 'feat!: remove a thing')"
known "0.x: a breaking commit after a patch pre-release raises the middle number" \
  "$MIDDLE_BUMP" "$(suggest v0.54.2-rc.1 'fix!: reject the old option')"
check "a continued pre-release is reported as unknown, never as a release" \
  "suggested:0.54.2-rc.2 bump:unknown " "$(suggest v0.54.2-rc.1 "$FEAT")"

reason=$(run_in v0.3.0 "$FEAT" | grep '^reason:')
case "$reason" in
  *"changelog"*) printf 'ok   - %s\n' "0.x: the reason sends the reader to the changelog" ;;
  *) printf 'FAIL - %s\n       actual: [%s]\n' "0.x: the reason sends the reader to the changelog" "$reason"; fail=1 ;;
esac

# Without uvx and git-cliff the script says so instead of guessing. The PATH
# holds git and dirname only; env -i and --noprofile keep a login profile from
# adding ~/.local/bin back.
bin="$TMP/bin"
mkdir -p "$bin"
ln -s "$(command -v git)" "$bin/git"
ln -s "$(command -v dirname)" "$bin/dirname"
repo="$TMP/no-tool"
git init -q "$repo"
git -C "$repo" -c user.email=t@example.org -c user.name=T -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "chore: initial"
git -C "$repo" -c user.email=t@example.org -c user.name=T -c tag.gpgsign=false -c tag.forceSignAnnotated=false tag -a v0.54.2 -m v0.54.2
git -C "$repo" -c user.email=t@example.org -c user.name=T -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "$FEAT"
no_tool=$(cd "$repo" && env -i HOME="$TMP" PATH="$bin" "$(command -v bash)" --noprofile --norc "$SCRIPT" | grep -E '^(bump|reason):' | tr '\n' ' ')
case "$no_tool" in
  "bump:unknown reason:neither uvx nor git-cliff is installed"*) printf 'ok   - %s\n' "without uvx and git-cliff the bump is unknown" ;;
  *) printf 'FAIL - %s\n       actual: [%s]\n' "without uvx and git-cliff the bump is unknown" "$no_tool"; fail=1 ;;
esac

exit "$fail"
