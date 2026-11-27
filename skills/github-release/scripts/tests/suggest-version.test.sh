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
pass() { # pass <name>
  local name="$1"
  printf 'ok   - %s\n' "$name"
}

check() { # check <name> <expected> <actual>
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$name"
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

# A setup step that fails aborts the whole test with exit 2. Most setups run
# inside a command substitution, where `exit` would end only that subshell, so
# the subshell signals the test's own process as well.
TEST_PID=$$
trap 'exit 2' USR1
setup_failed() {
  echo "SETUP FAILED - $1" >&2
  kill -s USR1 "$TEST_PID"
  exit 2
}

# A hook or a linked worktree exports GIT_DIR, which would override -C and send
# every write below into the caller's repository. Record its state, so the end
# of the test can prove nothing landed there.
caller_state() {
  if [[ -n "${GIT_DIR:-}" ]]; then
    git rev-parse --verify -q HEAD 2>/dev/null; git tag -l 2>/dev/null
  fi
}
CALLER_BEFORE="$(caller_state)"

# git_in <repo> <git args>... : git on a test repository only. env -u keeps a
# caller's GIT_DIR out; the -c flags keep a signing or hook setup of the
# machine out of the probe.
git_in() {
  local repo="$1"; shift
  env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C "$repo" \
    -c user.email=t@example.org -c user.name=T -c commit.gpgsign=false \
    -c tag.gpgsign=false -c tag.forceSignAnnotated=false -c core.hooksPath=/dev/null "$@"
}

# make_repo <tag> <commit message>... -> the path of a fresh repository whose
# last tag is <tag> followed by the commits. A message may span several lines
# (subject, blank line, body with footers).
make_repo() {
  local tag="$1"; shift
  local repo="$TMP/repo-$RANDOM$RANDOM"
  mkdir -p "$repo"
  { git_in "$repo" init -q && git_in "$repo" commit -q --allow-empty -m "chore: initial" \
    && git_in "$repo" tag -a "$tag" -m "$tag"; } || setup_failed "could not create the repository with tag $tag"
  local s
  for s in "$@"; do
    git_in "$repo" commit -q --allow-empty -m "$s" || setup_failed "could not commit: $s"
  done
  echo "$repo"
}

# run_script <repo> [script] -> the script's whole output, run in <repo>.
run_script() {
  local repo="$1" script="${2:-$SCRIPT}"
  (cd "$repo" && env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE bash "$script")
}

# run_in <tag> <commit message>... -> the script's whole output.
run_in() {
  local repo
  repo="$(make_repo "$@")" || exit 2
  run_script "$repo"
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
  *"changelog"*) pass "0.x: the reason sends the reader to the changelog" ;;
  *) printf 'FAIL - %s\n       actual: [%s]\n' "0.x: the reason sends the reader to the changelog" "$reason"; fail=1 ;;
esac

# fields <output> -> the "suggested:" and "bump:" lines of a run.
fields() {
  local output="$1"
  grep -E '^(suggested|bump):' <<< "$output" | tr '\n' ' '
}

# Tags git-cliff would otherwise take for the last version: an unprefixed
# version tag, and a lightweight marker tag on HEAD.
repo="$(make_repo v0.54.2 "$FEAT")"
git_in "$repo" tag -a 0.60.0 -m 0.60.0 || setup_failed "tag 0.60.0"
check "an unprefixed version tag is not the last version" \
  "$PATCH_BUMP" "$(fields "$(run_script "$repo")")"
repo="$(make_repo v0.54.2 "$FEAT")"
git_in "$repo" tag ci-marker || setup_failed "tag ci-marker"
check "a lightweight marker tag is not the last version" \
  "$PATCH_BUMP" "$(fields "$(run_script "$repo")")"

# Commits that change nothing a release carries give no confident bump.
for subject in 'chore: bump a tool' 'docs: fix a typo' 'ci: cache the build' 'test: cover a case' 'a commit without a type'; do
  check "a range of only '$subject' is no confident bump" \
    "suggested:unknown bump:unknown " "$(suggest v0.54.2 "$subject")"
done
check "chore beside feat still gives the feat bump" \
  "$PATCH_BUMP" "$(suggest v0.54.2 'chore: bump a tool' "$FEAT")"
check "a breaking chore commit still raises the middle number" \
  "$MIDDLE_BUMP" "$(suggest v0.54.2 'chore!: drop the old option')"
check "a chore commit with a BREAKING CHANGE footer still raises the middle number" \
  "$MIDDLE_BUMP" "$(suggest v0.54.2 $'chore: drop the old option\n\nBREAKING CHANGE: the option is gone.')"

# The script finds its configuration beside its real file, also through a
# symlink, and refuses to guess without it.
lonely="$TMP/lonely"
mkdir -p "$lonely"
cp "$SCRIPT" "$lonely/suggest-version.sh"
repo="$(make_repo v0.54.2 "$FEAT")"
missing=$(run_script "$repo" "$lonely/suggest-version.sh")
case "$(fields "$missing")$(grep '^reason:' <<< "$missing")" in
  "suggested:unknown bump:unknown reason:"*"suggest-version.cliff.toml"*) pass "without its configuration the bump is unknown" ;;
  *) printf 'FAIL - %s\n       actual: [%s]\n' "without its configuration the bump is unknown" "$missing"; fail=1 ;;
esac
ln -s "$SCRIPT" "$lonely/linked.sh"
check "a symlinked script still finds its configuration" \
  "$PATCH_BUMP" "$(fields "$(run_script "$repo" "$lonely/linked.sh")")"

# Without uvx and git-cliff the script says so instead of guessing. The PATH
# holds git, dirname and readlink only; env -i and --noprofile keep a login
# profile from adding ~/.local/bin back.
bin="$TMP/bin"
mkdir -p "$bin"
for tool in git dirname readlink; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
run_bare() { # run_bare <bin dir> <repo> -> the script's output with only <bin dir> on PATH
  local path="$1" repo="$2"
  (cd "$repo" && env -i HOME="$TMP" PATH="$path" "$(command -v bash)" --noprofile --norc "$SCRIPT")
}
repo="$(make_repo v0.54.2 "$FEAT")"
no_tool=$(run_bare "$bin" "$repo" | grep -E '^(bump|reason):' | tr '\n' ' ')
case "$no_tool" in
  "bump:unknown reason:neither uvx nor git-cliff is installed"*) pass "without uvx and git-cliff the bump is unknown" ;;
  *) printf 'FAIL - %s\n       actual: [%s]\n' "without uvx and git-cliff the bump is unknown" "$no_tool"; fail=1 ;;
esac

# An empty range is no bump, whatever tool is present and whatever the tag.
check "no commits and no tool is no bump" \
  "suggested:0.54.2 bump:none " "$(fields "$(run_bare "$bin" "$(make_repo v0.54.2)")")"
check "no commits after a pre-release tag is no bump" \
  "suggested:0.54.2-rc.1 bump:none " "$(suggest v0.54.2-rc.1)"

# A uvx that fails falls back to a git-cliff binary on PATH.
fallback="$TMP/fallback-bin"
mkdir -p "$fallback"
for tool in git dirname readlink; do ln -s "$(command -v "$tool")" "$fallback/$tool"; done
printf '#!/bin/sh\nexit 1\n' > "$fallback/uvx"
printf '#!/bin/sh\necho v0.54.3\n' > "$fallback/git-cliff"
chmod +x "$fallback/uvx" "$fallback/git-cliff"
check "a failing uvx falls back to git-cliff on PATH" \
  "$PATCH_BUMP" "$(fields "$(run_bare "$fallback" "$(make_repo v0.54.2 "$FEAT")")")"

# Nothing of the above wrote into a caller's repository.
if [[ "$(caller_state)" == "$CALLER_BEFORE" ]]; then
  pass "the caller's repository is unchanged"
else
  printf 'FAIL - %s\n' "the caller's repository is unchanged (GIT_DIR=${GIT_DIR:-})"; fail=1
fi

exit "$fail"
