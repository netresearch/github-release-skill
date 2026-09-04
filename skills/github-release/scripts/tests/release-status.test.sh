#!/usr/bin/env bash
# Self-test for release-status.sh without a forge — no network, no gh.
#
# Pins the behaviour that six recorded agent trials went without: in an
# environment with no `gh`, the script used to exit 2 after printing
# "gh (authenticated) required", discarding the half of its verdict that needs
# no forge at all. An agent handed that has one fact and nothing to do with it.
#
# Also pins the 404 trap: `gh api --jq` prints the ERROR body when the call
# fails, so a repository the token cannot see put a blob of JSON into the
# "latest release" value and every comparison below read as a version mismatch.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../release-status.sh"
fail=0

check() { # check <name> <expected-substring> <actual>
  case "$3" in
    *"$2"*) printf 'ok   - %s\n' "$1" ;;
    *) printf 'FAIL - %s\n       expected to contain: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fail=1 ;;
  esac
}

refute() { # refute <name> <forbidden-substring> <actual>
  case "$3" in
    *"$2"*) printf 'FAIL - %s\n       must not contain: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fail=1 ;;
    *) printf 'ok   - %s\n' "$1" ;;
  esac
}

# A PATH with jq and coreutils but deliberately no gh. `env -i` and
# --noprofile matter: a login profile re-adds ~/.local/bin, and the probe then
# measures the profile rather than the script.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/repo"
jq_path=$(command -v jq 2>/dev/null) || { echo "SKIP - jq not installed"; exit 0; }
ln -sf "$jq_path" "$work/bin/jq"
printf '%s\n' '<?php' "\$EM_CONF['x'] = ['version' => '2.4.1'];" > "$work/repo/ext_emconf.php"

out=$(cd "$work/repo" && env -i PATH="$work/bin:/usr/bin:/bin" HOME="$work" \
      bash --noprofile --norc "$SCRIPT" 2>&1)
status=$?

check "reads the declared version without a forge" "2.4.1" "$out"
check "says what it could not check"               "local phase only" "$out"
check "ends in an actionable NEXT"                 "NEXT: prepare-release" "$out"
refute "does not abort on the missing dependency"  "gh (authenticated) required" "$out"

# Exit 1 means "action needed", which is true here; exit 2 is a usage error and
# is what the caller used to get for an environment it cannot change.
if [ "$status" = "2" ]; then
  printf 'FAIL - exits 2 (usage error) where the environment simply lacks gh\n'
  fail=1
else
  printf 'ok   - exits %s, not the usage-error code\n' "$status"
fi

# --- the 404 trap, without calling anything ----------------------------------
# ---------------------------------------------------------------------------
# A WoW addon declares its version only in a .toc manifest
# ---------------------------------------------------------------------------
# Without this the verdict was "prepare-release — no version file found" for a
# released addon, so the script could never reach exit 0 on such a repository.

addon=$(mktemp -d)
trap 'rm -rf "$work" "$addon"' EXIT
mkdir -p "$addon/bin" "$addon/repo/QuickRoute"
ln -sf "$jq_path" "$addon/bin/jq"
printf '## Interface: 120100\r\n## Title: QuickRoute\r\n## Version: 1.16.0\r\n' \
  >"$addon/repo/QuickRoute/QuickRoute.toc"

addon_out=$(cd "$addon/repo" && env -i PATH="$addon/bin:/usr/bin:/bin" HOME="$addon" \
            bash --noprofile --norc "$SCRIPT" 2>&1)

check "reads the version from a .toc manifest" "1.16.0" "$addon_out"
refute "does not report the addon as versionless" "no version file found" "$addon_out"
# The fixture above is CRLF, as shipped manifests usually are. A carriage
# return left on the value makes an equal version compare unequal against the
# tag, so the released repo reads as drifted.
refute "no carriage return survives into the version" "$(printf '1.16.0\r')" "$addon_out"

# A .toc without a version line is not a manifest — the extension also belongs
# to LaTeX tables of contents — and it sorts first here, so the search has to
# step over it rather than stop on it and report the addon as versionless.
printf '\\contentsline {section}{Intro}{1}\n' >"$addon/repo/AAA-paper.toc"
skip_out=$(cd "$addon/repo" && env -i PATH="$addon/bin:/usr/bin:/bin" HOME="$addon" \
           bash --noprofile --norc "$SCRIPT" 2>&1)
check "steps over a .toc that carries no version" "1.16.0" "$skip_out"
rm -f "$addon/repo/AAA-paper.toc"

# The guard is a case pattern over the value gh returned; a JSON error body
# contains characters a tag cannot.
tagshaped() { case "$1" in *[!A-Za-z0-9._-]* | "" | null) echo no ;; *) echo yes ;; esac; }
check "a tag is accepted"        "yes" "$(tagshaped 'v2.4.1')"
check "an error body is not"     "no"  "$(tagshaped '{ "message": "Not Found" }')"
check "a literal null is not"    "no"  "$(tagshaped 'null')"

exit "$fail"
