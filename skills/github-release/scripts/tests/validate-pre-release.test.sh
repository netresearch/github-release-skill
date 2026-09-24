#!/usr/bin/env bash
# Self-test for the "CI checks passing" item of validate-pre-release.sh.
#
# The check used to ask `gh run list --limit 1` for the newest run of any
# workflow on any branch, so a green run on a feature branch passed the gate
# for a `main` whose own CI was red. It must grade the runs of the commit that
# is about to be tagged (HEAD) on the branch the script runs on, and all of
# them, not only the newest.
#
# `gh` is stubbed. Like gh, `run list` honours --branch, --commit and --limit
# and applies the --jq filter with real jq, so a lookup that does not pin the
# branch and commit sees the foreign runs, newest first.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../validate-pre-release.sh"
fail=0

check() { # check <name> <expected-substring> <actual>
  case "$3" in
    *"$2"*) printf 'ok   - %s\n' "$1" ;;
    *) printf 'FAIL - %s\n       expected to contain: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fail=1 ;;
  esac
}

jq_path=$(command -v jq 2>/dev/null) || { echo "SKIP - jq not installed"; exit 0; }
git_path=$(command -v git 2>/dev/null) || { echo "SKIP - git not installed"; exit 0; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/repo"
ln -sf "$jq_path" "$work/bin/jq"
ln -sf "$git_path" "$work/bin/git"

git -C "$work/repo" init -q -b main
git -C "$work/repo" -c user.name=t -c user.email=t@example.invalid \
  commit -q --allow-empty -m init
head_sha=$(git -C "$work/repo" rev-parse HEAD)

cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# STUB_RUNS: JSON array of runs, newest first. STUB_FAIL=1: the lookup fails.
[ "$1 $2" = "run list" ] || exit 1
[ -n "${STUB_FAIL:-}" ] && { echo "HTTP 502" >&2; exit 1; }
branch=""; commit=""; limit=20; filter="."; shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    -b|--branch) branch="$2"; shift 2 ;;
    -c|--commit) commit="$2"; shift 2 ;;
    -L|--limit)  limit="$2"; shift 2 ;;
    -q|--jq)     filter="$2"; shift 2 ;;
    *)           shift ;;
  esac
done
printf '%s' "$STUB_RUNS" | jq -c --arg b "$branch" --arg c "$commit" --argjson n "$limit" \
  '[.[] | select(($b == "" or .headBranch == $b) and ($c == "" or .headSha == $c))][:$n]' \
  | jq -r "$filter"
STUB
chmod +x "$work/bin/gh"

# run_ci <runs-json> [STUB_FAIL] — prints the script's CI line
run_ci() {
  (cd "$work/repo" && env -i PATH="$work/bin:/usr/bin:/bin" HOME="$work" \
     STUB_RUNS="$1" STUB_FAIL="${2:-}" bash --noprofile --norc "$SCRIPT" 2>&1) \
    | grep 'CI checks passing'
}

run() { # run <branch> <sha> <workflow> <status> <conclusion>
  printf '{"headBranch":"%s","headSha":"%s","workflowName":"%s","status":"%s","conclusion":"%s"}' "$@"
}

# The real shape: a feature branch finished green after main's CI went red.
feature=$(run feature/x 1111111111111111111111111111111111111111 CI completed success)
main_red=$(run main "$head_sha" CI completed failure)
main_ok=$(run main "$head_sha" Lint completed success)
check "a green run on another branch does not pass a red main" \
  "FAIL  CI checks passing" "$(run_ci "[$feature,$main_ok,$main_red]")"

# Every run of the commit counts, not only the newest: Lint is newer and green.
check "a red workflow behind a newer green one still fails" \
  "CI=failure" "$(run_ci "[$main_ok,$main_red]")"

# An older commit on main does not stand in for HEAD.
old_ok=$(run main 2222222222222222222222222222222222222222 CI completed success)
check "a green older commit does not pass HEAD" \
  "WARN  CI checks passing" "$(run_ci "[$old_ok]")"

check "all runs of HEAD green passes" \
  "PASS  CI checks passing" "$(run_ci "[$feature,$main_ok,$(run main "$head_sha" CI completed success)]")"

check "a run still in progress is not a pass" \
  "WARN  CI checks passing" "$(run_ci "[$main_ok,$(run main "$head_sha" CI in_progress '')]")"

# A list that fills the query limit may hide a red run beyond it.
many=$(run main "$head_sha" CI completed success)
for _ in $(seq 2 500); do many="$many,$(run main "$head_sha" CI completed success)"; done
check "a run list cut at the limit is not a pass" \
  "may be truncated" "$(run_ci "[$many,$main_red]")"

# A failed lookup must not read as "there are no runs".
check "a failed lookup says so" \
  "run lookup failed" "$(run_ci "[$main_ok]" 1)"

exit "$fail"
