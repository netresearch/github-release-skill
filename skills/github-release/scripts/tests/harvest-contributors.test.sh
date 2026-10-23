#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Self-test for harvest-contributors.sh pure helpers — no network.
#
# Pins the regression fixed alongside it: PR numbers must come ONLY from the
# squash-merge "(#N)" subject suffix or a "Merge pull request #N" subject — never
# from body cross-references, dependency-bump changelog excerpts, or the
# "&#8203;" HTML entity (which used to be grepped as PR "#8203").
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The path is computed at runtime, so shellcheck cannot follow it without -x,
# and the pre-commit hook does not pass it.
# shellcheck source=../harvest-contributors.sh disable=SC1091
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
check "trailing space after (#N)"     "843" "$(ex 'feat: y (#843) ')"
check "trailing tab after (#N)"       "844" "$(printf 'feat: z (#844)\t' | extract_pr_numbers | paste -sd, -)"

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

# --- argument parsing ---
# `-R` is what release-status.sh takes, and reaching for it here used to exit 2
# with `unknown arg: -R`. Both spellings must reach the same variable.
#
# --from/--to are deliberately omitted: an accepted repo flag then stops at the
# "both --from and --to are required" check, which sits before the first gh
# call, so the case stays offline. Supplying them would run the harvest against
# a repository that does not exist — passing for the wrong reason, over the
# network. A rejected flag names itself and never gets that far.
argerr() { bash "$HERE/../harvest-contributors.sh" "$@" 2>&1 >/dev/null | head -1; }
check "-R is accepted"                    "" "$(argerr -R o/r | grep -o 'unknown arg: -R')"
check "--repo still accepted"             "" "$(argerr --repo o/r | grep -o 'unknown arg')"
check "an unknown flag is still rejected" "unknown arg: --nope" "$(argerr --nope x)"

# --- a range with no human author -------------------------------------------
# `local -A CODE` without `=()` is unbound under `set -u` in bash 4.4 to 5.3,
# so `${#CODE[@]}` aborted the run whenever every PR in the range was a bot's.
# gh is stubbed: the compare call yields one PR, and the GraphQL answer comes
# from $STUB_AUTHOR.
stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT
mkdir -p "$stub/bin"
ln -sf "$(command -v jq)" "$stub/bin/jq"
cat >"$stub/bin/gh" <<'STUB'
#!/usr/bin/env bash
jqexpr="."; args=()
while [ $# -gt 0 ]; do
  case "$1" in --jq) jqexpr="$2"; shift 2 ;; --paginate) shift ;; *) args+=("$1"); shift ;; esac
done
set -- "${args[@]}"
case "$1 $2" in
  "api repos/o/r/compare/v1...v2")
    jq -nr '{commits:[{commit:{message:"chore(deps): bump x (#5)"}}]}' | jq -r "$jqexpr"; exit ;;
  "api graphql")
    jq -n --arg a "$STUB_AUTHOR" \
      '{data:{repository:{pullRequest:{author:{login:$a},closingIssuesReferences:{nodes:[]}}}}}'; exit ;;
esac
echo "gh stub: unexpected call: $*" >&2; exit 1
STUB
chmod +x "$stub/bin/gh"
harvest() { # <author> — output plus a final `EXIT: <status>` line
  env -i PATH="$stub/bin:/usr/bin:/bin" HOME="$stub" STUB_AUTHOR="$1" \
    bash --noprofile --norc "$HERE/../harvest-contributors.sh" -R o/r --from v1 --to v2 2>&1
  echo "EXIT: $?"
}
bot_out=$(harvest 'renovate[bot]')
check "a bot-only range does not crash" "" "$(grep -o 'unbound variable' <<<"$bot_out")"
check "a bot-only range exits 0"        "EXIT: 0" "$(tail -n 1 <<<"$bot_out")"
check "a bot-only range credits no one" "" "$(grep '^code authors' <<<"$bot_out")"
human_out=$(harvest alice)
check "a human author is still listed"  "code authors: @alice" "$(grep '^code authors' <<<"$human_out")"

if [ "$fail" -eq 0 ]; then
  echo "All harvest-contributors self-tests passed."
else
  echo "Some harvest-contributors self-tests FAILED." >&2
fi
exit "$fail"
