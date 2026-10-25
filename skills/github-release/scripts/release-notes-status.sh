#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
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
# a TYPO3 extension's v13.10.0 release, whose body really had lost the
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

# Is <@login> credited in a release body? Only a bare `@login` is a mention
# there (references/release-process.md, "Crediting contributors"):
# `[@login](https://github.com/login)` renders as a plain link, which notifies
# nobody, so a body crediting that way is uncredited. A substring test passed
# it, and also took `@alicebob` or `mail@alice.dev` as credit for `@alice`.
# Inline links `[label](url)` are therefore removed first, label included, and
# the mention may not follow `[` or a word character, nor run on into a longer
# login. Code spans are not excluded, and the match stays case-sensitive.
# `<@login>` comes from `grep -oE '@[A-Za-z0-9-]+'`, so it is safe in a regex.
#
# Lines GitHub generated are removed too: `* <title> by @login in <pull URL>`
# and `* @login made their first contribution in <pull URL>` name the PR
# author whether or not anyone rewrote the body, so counting them as credit
# reports an untouched list as credited.
credit_mentioned() { # <body> <@login>
  local unlinked
  unlinked=$(grep -vE "$GENERATED_BULLET_RE|$FIRST_CONTRIBUTION_RE" <<<"$1" || true)
  unlinked=$(sed -E 's/\[[^]]*\]\([^)]*\)//g' <<<"$unlinked")
  body_has "$unlinked" -E "(^|[^[A-Za-z0-9_])$2([^A-Za-z0-9-]|\$)"
}

# GitHub's generated release notes ("Generate release notes", or a workflow's
# `generate_release_notes: true`) list each PR as
#   * <title> by @<login> in https://github.com/<owner>/<repo>/pull/<n>
# with `* @<login> made their first contribution in <pull URL>` under
# `## New Contributors`. Nobody writes that line by hand.
GENERATED_BULLET_RE='^\* .+ by @[A-Za-z0-9-]+(\[bot\])? in https://github\.com/[^ ]+/pull/[0-9]+$'
FIRST_CONTRIBUTION_RE='^\* @[A-Za-z0-9-]+(\[bot\])? made their first contribution in https://github\.com/[^ ]+/pull/[0-9]+$'

# Is the body still the auto-generated PR list? Prints 1 or 0.
#
# Two shapes sit under `## Changes` / `## What's Changed`: the netresearch
# orchestrators' `- <title> (#123)` lines, and GitHub's own generated bullets
# above. The first needs two lines, so a narrative citing one PR does not trip
# it. The second needs one, because it is unambiguous; matching only the first
# shape passed netresearch/git-workflow-skill v1.36.0, a raw 14-bullet GitHub
# list, as `ok — narrative, credits and CI blocks all present`.
autogenerated_body() { # <body>
  local section dash generated
  body_has "$1" -E '^## (Changes|What'"'"'s Changed)$' || { echo 0; return 0; }
  section=$(sed -n '/^## \(Changes\|What'"'"'s Changed\)$/,/^## /p' <<<"$1")
  dash=$(grep -cE '^- .*\(#[0-9]+\)$' <<<"$section" || true)
  generated=$(grep -cE "$GENERATED_BULLET_RE" <<<"$section" || true)
  if [ "${dash:-0}" -ge 2 ] || [ "${generated:-0}" -ge 1 ]; then echo 1; else echo 0; fi
}

# The sections the netresearch orchestrators append after `## Changes`, one per
# line. It is a function rather than a literal inside the loop so the test reads
# the same list the check reads, instead of a retyped copy that agrees with
# whatever the check happens to do.
#
# `release-go-app.yml` emits `## Container image` (the three rolling tags) when
# the run builds one, and `## Verify your download` always; the library and
# source-archive orchestrators emit `## Installation` and
# `## Software Bill of Materials`. Anything this list omits is destroyed by an
# overhaul in silence — `## Container image` was omitted here and a measured
# v1.7.0 release lost it while this script reported `ok`.
ci_block_sections() {
  printf '%s\n' Installation "Container image" "Verify your download" \
                "Software Bill of Materials"
}

# Does <text> carry `## <section>` as a heading? Only a whole heading line
# counts. A substring test took prose such as "the `## Installation` block" in
# one sibling as proof that the line emits that block, and then reported every
# other release on the line as CI-APPENDED BLOCKS LOST. Trailing whitespace is
# allowed because bodies edited in the web UI end their lines with `\r`.
# <section> comes from ci_block_sections and holds no regex metacharacters.
has_heading() { # <text> <section>
  body_has "$1" -E "^## $2[[:space:]]*\$"
}

# The CI blocks a sibling on the line carries as a heading and <body> does not,
# each as ` "<section>"`.
lost_ci_sections() { # <body> <sibling bodies>
  local s lost=""
  while IFS= read -r s; do
    if has_heading "$2" "$s" && ! has_heading "$1" "$s"; then
      lost="$lost \"$s\""
    fi
  done <<< "$(ci_block_sections)"
  printf '%s' "$lost"
}

# Is the body empty apart from GitHub's `**Full Changelog**: <compare URL>`
# line? Prints 1 or 0. That is what a release created without notes shows, and
# it passed every other test here, so it reported `ok` for a release nobody
# had written anything for.
empty_body() { # <body>
  local rest
  rest=$(grep -vE '^[[:space:]]*(\*\*Full Changelog\*\*:.*)?[[:space:]]*$' <<<"$1" || true)
  if [ -z "$rest" ]; then echo 1; else echo 0; fi
}

# Does <composer.json> declare a skill package? Prints 1 or 0.
#
# A netresearch skill repository releases with GitHub's generated body and
# keeps it: netresearch/skill-repo-skill#257 settled that the generated list,
# its `by @login` credits included, is the release notes there, and
# skill-repo-skill's release-discipline.md says not to rewrite it. Every skill
# repository has a composer.json with `"type": "ai-agent-skill"`. Unreadable
# or absent input is no skill package, so the normal checks apply.
skill_package() { # <composer.json text>
  if jq -e '.type == "ai-agent-skill"' >/dev/null 2>&1 <<<"$1"; then echo 1; else echo 0; fi
}

# gh's message for a failed call, last line only. A rate limit or an auth
# failure is not a missing release: reporting it as `not found` sends the
# operator looking for a release that exists.
gh_error() { # <stderr file>
  local msg
  msg=$(grep . "$1" 2>/dev/null | tail -n 1 || true)
  printf '%s' "${msg:-gh exited non-zero without a message}"
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

ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT

# Every lookup below is checked. Each one used to end in `2>/dev/null || true`
# or carried no check at all, so a rate-limited run read a release that exists
# as `not found`, compared against no siblings, and harvested no one — and a
# `--last` sweep exited 0 having checked nothing. A failed lookup returns 2.
lookup_failed() { # <what>
  echo "lookup failed: $1 in $REPO — $(gh_error "$ERR")" >&2
  return 2
}

check_one() {
  local tag="$1" rc=0
  local body draft prev
  if ! body=$(gh release view "$tag" --repo "$REPO" --json body --jq '.body // ""' 2>"$ERR"); then
    if grep -qiE 'release not found|HTTP 404' "$ERR"; then
      echo "release $tag not found in $REPO" >&2; return 2
    fi
    lookup_failed "release $tag"; return 2
  fi
  draft=$(gh release view "$tag" --repo "$REPO" --json isDraft --jq .isDraft 2>"$ERR") || {
    lookup_failed "draft state of $tag"; return 2; }

  # 1. Auto-generated shape still in place. The CI body is a "## Changes" (or
  #    "## What's Changed") list of PR titles; a narrative replaces it.
  local raw; raw=$(autogenerated_body "$body")

  # 1a. In a skill repository the generated list is the accepted body (see
  #     skill_package). A 404 for composer.json means no skill package; any
  #     other failure is a failed lookup, not a verdict.
  local kept=0 composer
  if [ "$raw" = 1 ]; then
    if composer=$(gh api "repos/$REPO/contents/composer.json?ref=$tag" \
                    --jq '.content' 2>"$ERR"); then
      if [ "$(skill_package "$(base64 -d <<<"$composer" 2>/dev/null || true)")" = 1 ]; then
        kept=1; raw=0
      fi
    elif ! grep -qF 'HTTP 404' "$ERR"; then
      lookup_failed "composer.json at $tag"; return 2
    fi
  fi

  # 2. A CI stub body ("see CHANGELOG.md for details") counts as not-overhauled,
  #    and so does a body with nothing in it but the Full Changelog link.
  local stub=0 empty
  body_has "$body" -iE 'see CHANGELOG\.md for details' && stub=1
  empty=$(empty_body "$body")

  # 3. Contributors named in the range but never @mentioned in the body.
  #
  # The harvest's exit status is read, not swallowed. It used to run under
  # `2>/dev/null || true`, so a harvest that crashed — or never reached the
  # API — left an empty list, and the verdict read the same as for a range with
  # no contributors in it.
  #
  # A kept generated body credits PR authors in its own by-lines, and #257
  # accepts that as the credit, so the harvest does not run for it at all: a
  # failed release list or harvest must not turn an accepted body into an error.
  local missing="" harvest_failed=""
  if [ -x "$HARVEST" ] && [ "$kept" != 1 ]; then
    local tags
    tags=$(gh api "repos/$REPO/releases?per_page=100" --paginate \
             --jq '.[] | select(.draft==false) | .tag_name' 2>"$ERR") || {
      lookup_failed "release list"; return 2; }
    prev=$(previous_release_on_line "$tag" "$tags")
    if [ -n "$prev" ] && [ "$prev" != "null" ]; then
      local harvested people
      if harvested=$("$HARVEST" --repo "$REPO" --from "$prev" --to "$tag" 2>"$ERR"); then
        people=$(grep -v '^#' <<<"$harvested" | grep -oE '@[A-Za-z0-9-]+' | sort -u || true)
        local p
        for p in $people; do
          credit_mentioned "$body" "$p" || missing="$missing $p"
        done
      else
        harvest_failed="harvest-contributors.sh $prev..$tag failed: $(gh_error "$ERR")"
      fi
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
  # whose CI never emitted them — one measured repository reported
  # exactly that for v12.0.12, where the entire v12 line has zero release assets
  # and no Installation or SBOM section anywhere. Writing those blocks would have
  # described signed artifacts and an SBOM that do not exist.
  local lost sibling major_of_tag
  major_of_tag=$(printf '%s\n' "$tag" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\).*/\1/p')
  sibling=$(gh api "repos/$REPO/releases?per_page=100" --paginate --jq \
    "[.[] | select(.draft==false) | select(.tag_name!=\"$tag\") | {t: .tag_name, b: .body}]
     | map(select(.t | ltrimstr(\"v\") | split(\".\")[0] == \"$major_of_tag\"))
     | map(.b // \"\") | join(\"\n\")" 2>"$ERR") || {
    lookup_failed "sibling releases of $tag"; return 2; }
  lost=$(lost_ci_sections "$body" "$sibling")

  local next="ok"
  [ "$raw" = 1 ] || [ "$stub" = 1 ] || [ "$empty" = 1 ] && next="overhaul-notes"
  [ "$next" = "ok" ] && [ -n "$harvest_failed" ] && next="credit-check-failed"
  [ "$next" = "ok" ] && [ -n "$missing" ] && next="add-credits"
  [ "$next" = "ok" ] && [ "$section" = 1 ] && next="inline-the-credits"
  [ "$next" = "ok" ] && [ -n "$lost" ] && next="restore-ci-sections"
  [ "$next" = "ok" ] || rc=1

  if [ "$JSON" = 1 ]; then
    jq -nc --arg tag "$tag" --arg next "$next" --arg missing "${missing# }" \
       --arg lost "${lost# }" --argjson raw "$raw" --argjson stub "$stub" \
       --argjson empty "$empty" --arg harvest_failed "$harvest_failed" \
       --argjson section "$section" --arg draft "$draft" \
       --argjson kept "$kept" \
       '{tag:$tag, next:$next, autogenerated:($raw==1), stub:($stub==1),
         generated_body_kept:($kept==1),
         empty:($empty==1),
         missing_credits:($missing|split(" ")|map(select(length>0))),
         credit_check_failed:(if $harvest_failed == "" then null else $harvest_failed end),
         lost_ci_sections:$lost, handwritten_contributors_section:($section==1),
         draft:($draft=="true")}'
  else
    printf '%-14s ' "$tag"
    case "$next" in
      ok)
        if [ "$kept" = 1 ]; then
          printf 'ok — generated body kept (skill repository, skill-repo-skill#257)\n'
        else
          printf 'ok — narrative, credits and CI blocks all present\n'
        fi ;;
      overhaul-notes)
        if [ "$stub" = 1 ]; then
          printf 'NOT OVERHAULED — body is still the CI stub\n'
        elif [ "$raw" = 1 ]; then
          printf 'NOT OVERHAULED — body is still the auto-generated PR-title list\n'
        else
          printf 'NOT OVERHAULED — body is empty apart from the Full Changelog link\n'
        fi ;;
      credit-check-failed) printf 'CREDIT CHECK FAILED — %s\n' "$harvest_failed" ;;
      add-credits) printf 'MISSING CREDITS —%s never @mentioned in the body\n' "$missing" ;;
      inline-the-credits) printf 'hand-written Contributors section — credit inline instead\n' ;;
      restore-ci-sections) printf 'CI-APPENDED BLOCKS LOST —%s\n' "$lost" ;;
    esac
    [ "$draft" = "true" ] && printf '%-14s note: still a draft\n' ""
  fi
  return $rc
}

# A lookup error (2) outranks needs-work (1): a sweep in which any release could
# not be read has not answered the question for that release.
overall=0
record() { # <check_one status>
  if [ "$1" = 2 ]; then overall=2; elif [ "$1" != 0 ] && [ "$overall" = 0 ]; then overall=1; fi
}
if [ "$LAST" != 0 ]; then
  recent=$(gh api "repos/$REPO/releases?per_page=$LAST" --jq '.[].tag_name' 2>"$ERR") \
    || { lookup_failed "recent releases"; exit 2; }
  for t in $recent; do
    rc=0; check_one "$t" || rc=$?
    record "$rc"
  done
else
  if [ -z "$TAG" ]; then
    TAG=$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>"$ERR") || {
      if grep -qF 'HTTP 404' "$ERR"; then echo "no release found in $REPO" >&2; exit 2; fi
      lookup_failed "latest release"; exit 2; }
  fi
  rc=0; check_one "$TAG" || rc=$?
  record "$rc"
fi
exit $overall
