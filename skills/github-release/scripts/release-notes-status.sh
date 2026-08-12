#!/usr/bin/env bash
# release-notes-status.sh - Is a PUBLISHED release's body actually finished?
#
# The pre-release scripts stop at "CI checks passing" and the guards only block
# bad commands. Phase 5 -- rewriting the auto-generated body into a narrative
# with inline contributor credit -- is the one step with no mechanical check,
# and it is the one that gets skipped: it happens minutes after the tag, when
# the release already looks done.
#
# This is the release-side counterpart to git-workflow's pr-status.sh: two API
# calls, a verdict, and a computed NEXT.
#
#   ./release-notes-status.sh -R owner/repo v1.2.3
#   ./release-notes-status.sh -R owner/repo --last 5     # sweep recent releases
#   ./release-notes-status.sh -R owner/repo v1.2.3 --json
#
# Exit: 0 = ok, 1 = needs work, 2 = usage/lookup error.
set -euo pipefail

# --- pure helpers (sourced by scripts/tests/release-notes-status.test.sh) -----

# The previous release ON THE SAME LINE, not simply the previous published one.
#
# GitHub returns releases newest-first across every branch, so on a repository
# that maintains several majors in parallel the neighbour of v12.0.12 is a v13
# release. Harvesting v13.9.0..v12.0.12 then reports everyone who worked on v13
# in between as an uncredited contributor to a v12 patch — and the operator,
# following the verdict, @mentions people who had nothing to do with it.
# Attributing someone else's work to a release they did not touch is worse than
# the missing credit this check exists to find.
#
# No same-major predecessor (the first release of a new major) yields nothing,
# and the caller then skips the credit check rather than reaching across lines.
previous_release_on_line() { # <tag> <newline-separated tags, newest first>
  local tag="$1" list="$2" major
  major=$(printf '%s\n' "$tag" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\).*/\1/p')
  [ -n "$major" ] || return 0
  awk -v t="$tag" -v m="$major" '
    seen { v = $0; sub(/^v/, "", v); split(v, p, "."); if (p[1] == m) { print; exit } ; next }
    $0 == t { seen = 1 }' <<<"$list"
}

# Does <text> match? Never `printf '%s' "$text" | grep -q PATTERN`.
#
# That pipeline is a race under `set -o pipefail`, and it fails in the
# direction that hides defects: grep exits at the first match, printf then
# dies on the closed pipe with 141, and pipefail turns the *successful* match
# into a failed command. Measured against this script's own sibling blob
# (52,989 bytes, first match at byte 2,474): 25 of 40 runs returned 141. So
# netresearch/t3x-rte_ckeditor_image v13.10.0, whose body really had lost the
# SBOM block, reported `ok — narrative, credits and CI blocks all present` in
# roughly seven runs out of eight — the check answered "nothing missing"
# BECAUSE it had found something. The same race sits under the credit test,
# where it invents missing contributors, and under the auto-generated-body
# test, where it passes an untouched CI body.
#
# A herestring is not a pipeline: grep may stop reading whenever it likes.
body_has() { # <text> <grep-flag>... <pattern>
  local text="$1"; shift
  grep -q "$@" <<<"$text"
}

# Sourced by the test to exercise the helpers above; everything below needs gh.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then return 0; fi

REPO=""; TAG=""; JSON=0; LAST=0
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo) REPO="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    --last) LAST="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) TAG="$1"; shift ;;
  esac
done

command -v gh >/dev/null || { echo "gh (authenticated) required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
[ -n "$REPO" ] || { echo "no repo: pass -R owner/repo" >&2; exit 2; }

HARVEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harvest-contributors.sh"

check_one() {
  local tag="$1" rc=0
  local body prev
  body=$(gh release view "$tag" --repo "$REPO" --json body --jq .body 2>/dev/null) || {
    echo "release $tag not found in $REPO" >&2; return 2; }
  local draft; draft=$(gh release view "$tag" --repo "$REPO" --json isDraft --jq .isDraft)

  # 1. Auto-generated shape still in place. The CI body is a "## Changes" (or
  #    "## What's Changed") list of PR titles; a narrative replaces it.
  local raw=0
  if body_has "$body" -E '^## (Changes|What'"'"'s Changed)$'; then
    # A handful of "- ... (#123)" lines directly under it is the giveaway.
    local n; n=$(printf '%s' "$body" | sed -n '/^## \(Changes\|What'"'"'s Changed\)$/,/^## /p' \
                 | grep -cE '^- .*\(#[0-9]+\)$' || true)
    [ "${n:-0}" -ge 2 ] && raw=1
  fi

  # 2. A CI stub body ("see CHANGELOG.md for details") counts as not-overhauled.
  local stub=0
  body_has "$body" -iE 'see CHANGELOG\.md for details' && stub=1

  # 3. Contributors named in the range but never @mentioned in the body.
  local missing=""
  if [ -x "$HARVEST" ]; then
    local tags
    tags=$(gh api "repos/$REPO/releases?per_page=100" --paginate \
             --jq '.[] | select(.draft==false) | .tag_name' 2>/dev/null || true)
    prev=$(previous_release_on_line "$tag" "$tags")
    if [ -n "$prev" ] && [ "$prev" != "null" ]; then
      local people; people=$("$HARVEST" --repo "$REPO" --from "$prev" --to "$tag" 2>/dev/null \
        | grep -v '^#' | grep -oE '@[A-Za-z0-9-]+' | sort -u || true)
      local p
      for p in $people; do
        body_has "$body" -F "$p" || missing="$missing $p"
      done
    fi
  fi

  # 4. A hand-written Contributors section duplicates the avatar row GitHub
  #    builds from inline mentions -- the rule is inline credit, never a section.
  local section=0
  body_has "$body" -iE '^#+ *Contributors' && section=1

  # 5. CI-appended blocks destroyed by an overhaul that replaced the whole body.
  #
  # The comparison set is the releases on the SAME line, for the same reason the
  # credit range is. Taking the newest six of the whole repository asks a v12
  # patch from May to carry blocks that a v13 release added in August, on a line
  # whose CI never emitted them — netresearch/t3x-rte_ckeditor_image reported
  # exactly that for v12.0.12, where the entire v12 line has zero release assets
  # and no Installation or SBOM section anywhere. Writing those blocks would have
  # described signed artifacts and an SBOM that do not exist.
  local lost="" sibling s major_of_tag
  major_of_tag=$(printf '%s\n' "$tag" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\).*/\1/p')
  sibling=$(gh api "repos/$REPO/releases?per_page=100" --paginate --jq \
    "[.[] | select(.draft==false) | select(.tag_name!=\"$tag\") | {t: .tag_name, b: .body}]
     | map(select(.t | ltrimstr(\"v\") | split(\".\")[0] == \"$major_of_tag\"))
     | map(.b) | join(\"\n\")" 2>/dev/null || true)
  for s in Installation "Verify your download" "Software Bill of Materials"; do
    if body_has "$sibling" -F "## $s" && ! body_has "$body" -F "## $s"; then
      lost="$lost \"$s\""
    fi
  done

  local next="ok"
  [ "$raw" = 1 ] || [ "$stub" = 1 ] && next="overhaul-notes"
  [ "$next" = "ok" ] && [ -n "$missing" ] && next="add-credits"
  [ "$next" = "ok" ] && [ "$section" = 1 ] && next="inline-the-credits"
  [ "$next" = "ok" ] && [ -n "$lost" ] && next="restore-ci-sections"
  [ "$next" = "ok" ] || rc=1

  if [ "$JSON" = 1 ]; then
    jq -nc --arg tag "$tag" --arg next "$next" --arg missing "${missing# }" \
       --arg lost "${lost# }" --argjson raw "$raw" --argjson stub "$stub" \
       --argjson section "$section" --arg draft "$draft" \
       '{tag:$tag, next:$next, autogenerated:($raw==1), stub:($stub==1),
         missing_credits:($missing|split(" ")|map(select(length>0))),
         lost_ci_sections:$lost, handwritten_contributors_section:($section==1),
         draft:($draft=="true")}'
  else
    printf '%-14s ' "$tag"
    case "$next" in
      ok) printf 'ok — narrative, credits and CI blocks all present\n' ;;
      overhaul-notes) printf 'NOT OVERHAULED — body is still the %s\n' \
        "$([ "$stub" = 1 ] && echo 'CI stub' || echo 'auto-generated PR-title list')" ;;
      add-credits) printf 'MISSING CREDITS —%s never @mentioned in the body\n' "$missing" ;;
      inline-the-credits) printf 'hand-written Contributors section — credit inline instead\n' ;;
      restore-ci-sections) printf 'CI-APPENDED BLOCKS LOST —%s\n' "$lost" ;;
    esac
    [ "$draft" = "true" ] && printf '%-14s note: still a draft\n' ""
  fi
  return $rc
}

overall=0
if [ "$LAST" != 0 ]; then
  for t in $(gh api "repos/$REPO/releases?per_page=$LAST" --jq '.[].tag_name'); do
    check_one "$t" || overall=1
  done
else
  [ -n "$TAG" ] || TAG=$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null) \
    || { echo "no release found in $REPO" >&2; exit 2; }
  check_one "$TAG" || overall=1
fi
exit $overall
