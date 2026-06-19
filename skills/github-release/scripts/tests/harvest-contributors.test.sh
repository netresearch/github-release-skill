#!/usr/bin/env bash
# Self-test for harvest-contributors.sh pure helpers — no network.
#
# Pins the regression fixed alongside it: PR numbers must come ONLY from the
# squash-merge "(#N)" subject suffix or a "Merge pull request #N" subject — never
# from body cross-references, dependency-bump changelog excerpts, or the
# "&#8203;" HTML entity (which used to be grepped as PR "#8203").
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../harvest-contributors.sh
source "$HERE/../harvest-contributors.sh"
set +e # drive assertions ourselves; sourcing turned on `set -e`

fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

ex() { printf '%s\n' "$@" | extract_pr_numbers | paste -sd, -; }

# --- extract_pr_numbers ---
check "squash suffix"                 "842" "$(ex 'docs(readme): restructure (#842)')"
check "two refs -> trailing PR only"  "847" "$(ex 'fix: aspect ratio (#846) (#847)')"
check "merge-commit subject"          "853" "$(ex 'Merge pull request #853 from netresearch/x')"

# Regression: body / changelog-excerpt / entity lines must yield NOTHING.
check "changelog '&#8203;' + foreign #refs -> none" "" \
  "$(ex 'to v4]  -  by [@hi-ogawa] in &#8203; #10450' '[#&#8203;2439](https://github.com/actions/checkout/pull/2439)')"
check "body cross-ref -> none"        "" "$(ex 'follow-up to #114, see #837')"
check "plain subject -> none"         "" "$(ex 'docs: update readme')"

# Realistic mixed set: only the real PR stamps survive, sorted-unique.
check "mixed set -> 842,847,853,855" "842,847,853,855" \
  "$(ex 'docs(readme): restructure (#842)' \
        'chore(deps): bump undici 7.25.0 to 7.28.0 &#8203; #10450 (#855)' \
        'fix: aspect ratio (#846) (#847)' \
        'Merge pull request #853 from x' \
        'follow-up to #114')"

# --- is_bot ---
for b in 'dependabot[bot]' 'renovate' 'github-actions' 'copilot-pull-request-reviewer' 'gemini-code-assist'; do
  is_bot "$b"; check "is_bot: $b" "0" "$?"
done
for h in 'marekskopal' 'CybotTM' 'dkochc'; do
  is_bot "$h"; check "human: $h" "1" "$?"
done

if [ "$fail" -eq 0 ]; then
  echo "All harvest-contributors self-tests passed."
else
  echo "Some harvest-contributors self-tests FAILED." >&2
fi
exit "$fail"
