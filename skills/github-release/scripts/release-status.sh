#!/usr/bin/env bash
# release-status.sh - Where is this repo in the release lifecycle, and what is
# the next valid action?
#
# The release-side counterpart to git-workflow's pr-status.sh. The existing
# /release-status command lists commands for a human to interpret; this
# computes a verdict and ends in a NEXT the caller can act on -- which is what
# stops a phase being skipped because the release already *looks* finished.
#
# Phases, in the order release-process.md defines them:
#
#   prepare-release        version files still on the released version
#   merge-release-pr       a release/vX.Y.Z PR is open
#   signed-tag             merged, but no tag -- or a lightweight/unsigned one
#   await-release-workflow tag pushed, the publishing workflow has not finished
#   rewrite-release-notes  published, but the body is still CI output
#   verify-publication     notes done, registries not serving the version yet
#   ok
#
#   ./release-status.sh [-R owner/repo]
#   ./release-status.sh -R owner/repo --json
#
# Exit: 0 = ok, 1 = action needed, 2 = usage/lookup error.
set -euo pipefail

REPO=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo) REPO="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

# `gh` is not a precondition, it is a capability. Six of six recorded agent
# trials in a sandbox without it got `exit 2` and one unusable fact, when the
# local half of this verdict -- which version the files declare, whether they
# agree, what to prepare next -- needed no forge at all. Half a verdict, clearly
# labelled, beats an error that says only "not here".
HAVE_GH=0
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then HAVE_GH=1; fi

if [ "$HAVE_GH" = 1 ] && [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
fi
if [ -z "$REPO" ]; then
  # A remote is enough to name the repository; being logged in is not needed
  # for that, and neither is being inside the checkout when -R was passed.
  origin=$(git config --get remote.origin.url 2>/dev/null || true)
  case "$origin" in
    *github.com[:/]*) REPO=$(printf '%s' "$origin" | sed -E 's#.*github\.com[:/]##; s#/+$##; s#\.git$##') ;;
  esac
fi
LOCAL_ONLY=0
if [ "$HAVE_GH" = 0 ]; then
  LOCAL_ONLY=1
  add_note_pending="no gh (or not authenticated): local phase only, nothing about tags, workflow, release body or registries"
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

note=""; next=""; cmd=""
add_note() { note="${note}${note:+; }$1"; }
if [ -n "${add_note_pending:-}" ]; then add_note "$add_note_pending"; fi

# --- what is released, and what does the tree claim -------------------------
# `gh api --jq` prints the ERROR body when the call fails, so a 404 lands a
# blob of JSON in $latest and every comparison below then reads as a version
# mismatch. Take the value only when the call succeeded, and only when it looks
# like a tag.
latest=""
if [ "$LOCAL_ONLY" = 0 ]; then
  if latest_raw=$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null); then
    case "$latest_raw" in
      *[!A-Za-z0-9._-]* | "" | null) latest="" ;;
      *) latest="$latest_raw" ;;
    esac
  fi
fi

# Version the working tree declares: TYPO3 ext_emconf, else composer extra,
# else a skill repo's plugin.json (the whole skill fleet declares it there and
# nowhere else — without this the verdict is "prepare-release" for every one of
# them, however cleanly they are released), else a WoW addon's .toc manifest,
# which is the only place such an addon states its version.
declared=""
if [ -f ext_emconf.php ]; then
  declared=$(grep -oE "'version'[[:space:]]*=>[[:space:]]*'[^']+'" ext_emconf.php 2>/dev/null \
             | grep -oE "'[0-9][^']*'$" | tr -d "'" || true)
fi
[ -n "$declared" ] || declared=$(jq -r '.extra["typo3/cms"].version // empty' composer.json 2>/dev/null || true)
[ -n "$declared" ] || declared=$(jq -r '.version // empty' .claude-plugin/plugin.json 2>/dev/null || true)

# WoW addon: the version lives in a .toc manifest and nowhere else. Not every
# .toc is one — the extension also belongs to LaTeX tables of contents — but the
# `## Version:` line is itself the evidence, so a file without one is skipped and
# the search continues rather than stopping on it. A multi-flavour addon ships a
# manifest per game flavour beside the primary one; `sort` reaches the
# flavourless name first, and keeping the set in step is
# validate-pre-release.sh's job.
if [ -z "$declared" ]; then
  while IFS= read -r toc; do
    # The trailing [[:space:]]*$ takes a CRLF manifest's carriage return off the
    # value; [:space:] includes \r.
    declared=$(sed -n 's/^##[[:space:]]*Version:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' \
               "$toc" 2>/dev/null | head -1 || true)
    [ -n "$declared" ] && break
  done < <(find . -maxdepth 2 -name '*.toc' -type f 2>/dev/null | sort)
fi

pkg=$(jq -r '.name // empty' composer.json 2>/dev/null || true)
extkey=$(jq -r '.extra["typo3/cms"]["extension-key"] // empty' composer.json 2>/dev/null || true)

# --- phase 2: an open release PR --------------------------------------------
relpr="null"
if [ "$LOCAL_ONLY" = 0 ]; then
  relpr=$(gh pr list --repo "$REPO" --state open --json number,headRefName \
          --jq '[.[] | select(.headRefName|test("^release/"))] | .[0].number' 2>/dev/null || echo "null")
fi

# --- phase 3: tag exists, and is annotated + signed --------------------------
tag_state=""
if [ -n "$declared" ] && [ "$LOCAL_ONLY" = 0 ]; then
  want="v$declared"
  if gh api "repos/$REPO/git/ref/tags/$want" >/dev/null 2>&1; then
    obj=$(gh api "repos/$REPO/git/ref/tags/$want" --jq .object.type 2>/dev/null || echo "")
    if [ "$obj" = "tag" ]; then tag_state="annotated"; else tag_state="lightweight"; fi
  else
    tag_state="absent"
  fi
fi

# --- phase 4: the publishing workflow ---------------------------------------
wf_state=""
if [ "$tag_state" = "annotated" ]; then
  wf_state=$(gh run list --repo "$REPO" --limit 12 \
    --json headBranch,status,conclusion,name \
    --jq "[.[] | select(.headBranch==\"v$declared\")] | .[0] | if .==null then \"none\" else \"\(.status)/\(.conclusion // \"-\")\" end" 2>/dev/null || echo "none")
fi

# --- phase 5: is the published body finished? --------------------------------
notes_next=""
if [ -n "$declared" ] && gh release view "v$declared" --repo "$REPO" >/dev/null 2>&1; then
  if [ -x "$HERE/release-notes-status.sh" ]; then
    notes_next=$("$HERE/release-notes-status.sh" -R "$REPO" "v$declared" --json 2>/dev/null | jq -r .next 2>/dev/null || echo "")
  fi
fi

# --- phase 6: do the registries actually serve it? ---------------------------
reg_missing=""
if [ -n "$declared" ] && [ "$notes_next" = "ok" ]; then
  # "Packagist does not know this package" is not the same as "this version has
  # not landed yet": a skill repo (composer type ai-agent-skill) is never
  # published there, and asserting it would fail every such repo forever.
  if [ -n "$pkg" ]; then
    pk=$(curl -sS -w '\n%{http_code}' "https://repo.packagist.org/p2/${pkg}.json" 2>/dev/null || true)
    if [ "$(printf '%s' "$pk" | tail -1)" = "200" ]; then
      printf '%s' "$pk" | sed '$d' \
        | jq -e --arg v "v$declared" '.packages[][]? | select(.version==$v)' >/dev/null 2>&1 \
        || reg_missing="$reg_missing packagist"
    fi
  fi
  # Only assert TER when the release workflow actually publishes there --
  # an extension key in composer.json alone is not a claim that it does.
  ter_declared=$(gh api "repos/$REPO/contents/.github/workflows/release.yml" --jq .content 2>/dev/null \
    | base64 -d 2>/dev/null | grep -c 'TYPO3_TER_ACCESS_TOKEN' || true)
  if [ -n "$extkey" ] && [ "${ter_declared:-0}" -gt 0 ]; then
    curl -sS "https://extensions.typo3.org/api/v1/extension/${extkey}/versions" 2>/dev/null \
      | jq -e --arg v "$declared" '.[0][]? | select(.number==$v)' >/dev/null 2>&1 \
      || reg_missing="$reg_missing TER"
  fi
fi

# --- verdict -----------------------------------------------------------------
# A stale worktree declares an older version than the latest release, which
# would otherwise read as "ok" for a version released long ago. Fetch first.
stale=0
if [ -n "$declared" ] && [ -n "$latest" ] && [ "$declared" != "${latest#v}" ]; then
  if printf '%s\n%s\n' "$declared" "${latest#v}" | sort -V | head -1 | grep -qx "$declared"; then
    stale=1
    add_note "working tree declares v$declared but $latest is already released -- fetch before trusting this"
  fi
fi

if [ "$LOCAL_ONLY" = 1 ] && [ -n "$declared" ]; then
  next="prepare-release"
  add_note "version files declare v$declared; whether that is released cannot be checked without gh"
  cmd="release-status.sh -R ${REPO:-owner/repo}   # re-run once gh is available"
elif [ -z "$declared" ]; then
  next="prepare-release"; add_note "no version file found (ext_emconf.php / composer extra.typo3/cms.version / .claude-plugin/plugin.json)"
elif [ "$relpr" != "null" ] && [ -n "$relpr" ]; then
  next="merge-release-pr"; cmd="pr-status.sh -R $REPO $relpr   # then pr-merge.sh"
  add_note "release PR #$relpr is open for v$declared"
elif [ "$declared" = "${latest#v}" ] && [ "$tag_state" = "annotated" ] && [ "$notes_next" = "ok" ] && [ -z "$reg_missing" ]; then
  next="ok"; add_note "v$declared released, notes rewritten, registries serving it"
elif [ "$stale" = 1 ]; then
  next="prepare-release"; cmd="git fetch origin && git switch --detach origin/main   # then re-run"
elif [ "$tag_state" = "absent" ]; then
  if [ "$declared" = "${latest#v}" ]; then
    next="prepare-release"; add_note "version files already on the released v$declared"
  else
    next="signed-tag"
    cmd="git tag -s v$declared -m v$declared && git push origin v$declared   # verify HEAD==origin/main first"
    add_note "v$declared prepared but not tagged"
  fi
elif [ "$tag_state" = "lightweight" ]; then
  next="signed-tag"; add_note "v$declared is a LIGHTWEIGHT tag -- unsigned, and the name is spent once a release uses it"
elif [ -n "$wf_state" ] && [ "${wf_state%%/*}" != "completed" ] && [ "$wf_state" != "none" ]; then
  next="await-release-workflow"; add_note "publishing workflow is $wf_state"
elif [ -n "$wf_state" ] && [ "$wf_state" = "completed/failure" ]; then
  next="await-release-workflow"; add_note "publishing workflow FAILED -- read its annotations before re-running"
elif [ -n "$notes_next" ] && [ "$notes_next" != "ok" ]; then
  next="rewrite-release-notes"
  cmd="release-notes-status.sh -R $REPO v$declared   # then gh release edit --notes-file"
  add_note "release body: $notes_next"
elif [ -n "$reg_missing" ]; then
  next="verify-publication"; add_note "not served yet by:$reg_missing"
else
  next="ok"
fi

if [ "$JSON" = 1 ]; then
  jq -nc --arg repo "$REPO" --arg declared "$declared" --arg latest "$latest" \
     --arg tag "$tag_state" --arg wf "$wf_state" --arg notes "$notes_next" \
     --arg reg "${reg_missing# }" --arg next "$next" --arg note "$note" --arg cmd "$cmd" \
     '{repo:$repo, declared_version:$declared, latest_release:$latest, tag:$tag,
       workflow:$wf, notes:$notes, registries_missing:$reg, next:$next,
       note:$note, cmd:$cmd}'
else
  echo "${REPO:-<repository not identified>}"
  printf '  declared    : %s\n' "${declared:-<none>}"
  printf '  latest rel  : %s\n' "${latest:-<none>}"
  printf '  tag         : %s\n' "${tag_state:-n/a}"
  [ -n "$wf_state" ] && printf '  workflow    : %s\n' "$wf_state"
  [ -n "$notes_next" ] && printf '  notes       : %s\n' "$notes_next"
  [ -n "$reg_missing" ] && printf '  registries  : missing on%s\n' "$reg_missing"
  echo
  printf 'NEXT: %s%s\n' "$next" "$([ -n "$note" ] && echo " — $note")"
  [ -n "$cmd" ] && printf '  cmd   : %s\n' "$cmd"
fi

[ "$next" = "ok" ] && exit 0 || exit 1
