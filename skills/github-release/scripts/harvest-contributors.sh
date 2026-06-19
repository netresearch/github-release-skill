#!/usr/bin/env bash
# harvest-contributors.sh — emit a Markdown "Contributors" section for a release,
# crediting BOTH code authors (merged-PR authors) and issue reporters (authors of
# the issues those PRs closed). Bots are filtered out — humans only, matching the
# no-bot-credit-in-release-notes policy. Reporters count as contributors: the
# auto-generated GitHub notes derive from commit subjects and never list them.
#
# Usage:
#   harvest-contributors.sh --from <tag> --to <tag> [--repo owner/repo]
#
# --from/--to are git refs that exist on the remote (e.g. v0.25.1 / v0.26.0).
# --repo defaults to `gh repo view` (run inside the checkout, or pass it). PR
# discovery uses the GitHub compare API, so the script is cwd-independent. The
# GitHub compare API returns at most 250 commits; for a wider range, split it
# and run twice. Requires: gh (authenticated) and jq.
#
# Output is Markdown on stdout — review it, then splice it into the release notes
# before applying with `gh release edit vX.Y.Z --notes-file notes.md`.
set -euo pipefail

REPO=""; FROM=""; TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    -h | --help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "gh (authenticated) required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
[ -n "$FROM" ] && [ -n "$TO" ] || { echo "both --from and --to are required (e.g. --from v0.25.1 --to v0.26.0)" >&2; exit 2; }

owner="${REPO%/*}"; name="${REPO#*/}"

# PR numbers from the compare range, taken ONLY from the SUBJECT (first line) of
# each commit and ONLY from the place GitHub stamps the PR number: a squash-merge
# "… (#N)" suffix or a "Merge pull request #N" subject. Sourced from the API so
# this works from any directory.
# Run gh api directly (not inside the process substitution) so a failure — auth,
# rate limit, bad range — trips `set -e` instead of silently yielding an empty
# list and a misleading "No PRs found".
#
# Do NOT grep the full multi-line message for "#N": commit BODIES cross-reference
# unrelated issues/PRs ("follow-up to #114"), and dependency-bump commits
# (Renovate/Dependabot) embed upstream changelogs full of foreign "#123" refs and
# "&#8203;" HTML entities — all of which would be looked up against THIS repo's
# numbering and falsely credit whoever happens to own that number.
subjects="$(gh api --paginate "repos/${REPO}/compare/${FROM}...${TO}" --jq '.commits[].commit.message | split("\n")[0]')"
mapfile -t PRS < <(grep -oE '\(#[0-9]+\)$|^Merge pull request #[0-9]+' <<<"$subjects" | grep -oE '[0-9]+' | sort -un || true)
[ "${#PRS[@]}" -gt 0 ] || { echo "No PRs found in ${REPO} ${FROM}...${TO}." >&2; exit 0; }

# GitHub bot logins end in "[bot]"; also drop known automation by bare name.
is_bot() {
  case "$1" in
    *'[bot]') return 0 ;;
    dependabot | renovate | github-actions | gemini-code-assist | copilot*) return 0 ;;
    *) return 1 ;;
  esac
}

declare -A CODE      # login -> 1 (merged-PR authors)
declare -A REPORTERS # login -> "12 34" (space-separated issue numbers, deduped at emit)
for pr in "${PRS[@]}"; do
  # shellcheck disable=SC2016 # $o/$n/$pr are GraphQL variables, expanded server-side
  json="$(gh api graphql -f query='
    query($o:String!,$n:String!,$pr:Int!){
      repository(owner:$o,name:$n){
        pullRequest(number:$pr){
          author{login}
          closingIssuesReferences(first:30){nodes{number author{login}}}
        }
      }
    }' -F o="$owner" -F n="$name" -F pr="$pr" 2>/dev/null)" || continue
  # A number that is an issue (not a PR) returns pullRequest: null. jq tolerates
  # indexing null (yields null -> // empty), and .nodes[]? guards the iteration,
  # so the null case is handled without erroring under set -e.
  a="$(jq -r '.data.repository.pullRequest.author.login // empty' <<<"$json")"
  if [ -n "$a" ] && ! is_bot "$a"; then CODE["$a"]=1; fi

  while IFS=$'\t' read -r inum ilogin; do
    if [ -n "$ilogin" ] && ! is_bot "$ilogin"; then
      REPORTERS["$ilogin"]="${REPORTERS["$ilogin"]:+${REPORTERS["$ilogin"]} }${inum}"
    fi
  done < <(jq -r '.data.repository.pullRequest.closingIssuesReferences.nodes[]?
                  | "\(.number)\t\(.author.login // "")"' <<<"$json")
done

echo "## 👥 Contributors"
echo
echo "Thanks to everyone who made this release — code and reports alike:"
echo
if [ "${#CODE[@]}" -gt 0 ]; then
  joined=""
  for k in $(printf '%s\n' "${!CODE[@]}" | sort -f); do joined="${joined}@${k}, "; done
  echo "- **Code:** ${joined%, }"
fi
# "Reported" credits humans who reported a fixed issue but are NOT already in
# Code — so each person is credited once and this line highlights the reporters
# (typically community members) who didn't also author a PR. This also drops a
# maintainer's self-reported issues, since maintainers appear under Code.
line="- **Reported issues fixed here:** "; any=0
for k in $(printf '%s\n' "${!REPORTERS[@]}" | sort -f); do
  [ -n "${CODE["$k"]:-}" ] && continue
  # paste -d takes the delimiter chars cyclically, so -d', ' would alternate
  # "," and " " between fields — join with a single "," then expand to ", ".
  refs="$(printf '%s\n' "${REPORTERS["$k"]}" | tr ' ' '\n' | grep . | sort -un | sed 's/^/#/' | paste -sd, - | sed 's/,/, /g')"
  line="${line}@${k} (${refs}), "; any=1
done
[ "$any" -eq 1 ] && echo "${line%, }"
