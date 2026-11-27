#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Self-test for suggest-version.sh against throwaway git repositories — no network.
#
# Pins the 0.x rule: on a 0.x version the caret stops at the middle number
# (`^0.54` admits 0.54.* only), so a middle bump is a new major for every
# consumer. suggest-version.sh used to map `feat:` to the middle number on 0.x
# too; netresearch/t3x-nr-llm released 0.44.0 to 0.55.0 as middle bumps
# without a breaking entry, and each one made the dependent extensions widen
# their constraint and release. On 0.x a feature is now a patch bump; only a
# breaking commit raises the middle number. From 1.0.0 on, feat is a minor bump.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../suggest-version.sh"

fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# run_in <tag> <commit subject>... -> the script's whole output, from a fresh
# repository whose last tag is <tag> followed by the commits.
run_in() {
  local tag="$1"; shift
  local repo="$TMP/repo-$RANDOM$RANDOM"
  mkdir -p "$repo"
  # env -u: a hook or a linked worktree exports GIT_DIR, which would override -C.
  local g=(env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C "$repo" -c user.email=t@example.org -c user.name=T -c commit.gpgsign=false -c tag.gpgsign=false)
  "${g[@]}" init -q
  "${g[@]}" commit -q --allow-empty -m "chore: initial"
  "${g[@]}" tag -a "$tag" -m "$tag"
  local s
  for s in "$@"; do
    "${g[@]}" commit -q --allow-empty -m "$s"
  done
  (cd "$repo" && env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE bash "$SCRIPT")
}

# suggest <tag> <commit subject>... -> the "suggested:" and "bump:" lines only.
suggest() {
  run_in "$@" | grep -E '^(suggested|bump):' | tr '\n' ' '
}

check "0.x: feat is a patch bump" \
  "suggested:0.54.3 bump:patch " "$(suggest v0.54.2 'feat: add a thing' 'fix: repair a thing')"
check "0.x: fix is a patch bump" \
  "suggested:0.54.3 bump:patch " "$(suggest v0.54.2 'fix: repair a thing')"
check "0.x: a breaking commit raises the middle number" \
  "suggested:0.55.0 bump:minor " "$(suggest v0.54.2 'feat: add a thing' 'feat(api)!: remove Foo::bar()')"
check "0.x: BREAKING CHANGE in the subject raises the middle number" \
  "suggested:0.55.0 bump:minor " "$(suggest v0.54.2 'refactor: BREAKING CHANGE drop the old option')"
check "1.x: feat is a minor bump" \
  "suggested:1.3.0 bump:minor " "$(suggest v1.2.3 'feat: add a thing')"
check "1.x: a breaking commit is a major bump" \
  "suggested:2.0.0 bump:major " "$(suggest v1.2.3 'feat!: remove a thing')"

reason=$(run_in v0.3.0 'feat: add a thing' | grep '^reason:')
case "$reason" in
  *"changelog"*) printf 'ok   - %s\n' "0.x: the reason sends the reader to the changelog" ;;
  *) printf 'FAIL - %s\n       actual: [%s]\n' "0.x: the reason sends the reader to the changelog" "$reason"; fail=1 ;;
esac

exit "$fail"
