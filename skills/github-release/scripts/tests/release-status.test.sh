#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
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

# ---------------------------------------------------------------------------
# A herdr plugin declares its version only in herdr-plugin.toml
# ---------------------------------------------------------------------------
# netresearch/herdr-bg-activity, released as v0.1.0, got "prepare-release — no
# version file found" (issue #121).

herdr=$(mktemp -d)
trap 'rm -rf "$work" "$addon" "$herdr"' EXIT
mkdir -p "$herdr/bin" "$herdr/repo"
ln -sf "$jq_path" "$herdr/bin/jq"
printf '%s\n' 'id = "netresearch.bg-activity"' 'name = "Background Activity"' \
  'version = "0.1.0"' 'min_herdr_version = "0.9.0"' 'platforms = ["linux", "macos"]' \
  '' '[[startup]]' 'command = ["python3", "herdr_bg_activity.py"]' \
  >"$herdr/repo/herdr-plugin.toml"

herdr_out=$(cd "$herdr/repo" && env -i PATH="$herdr/bin:/usr/bin:/bin" HOME="$herdr" \
            bash --noprofile --norc "$SCRIPT" 2>&1)
check "reads the version from herdr-plugin.toml" "declared    : 0.1.0" "$herdr_out"
refute "does not report the herdr plugin as versionless" "no version file found" "$herdr_out"

# A version under a table is not the plugin's; with none at the top level the
# verdict stays versionless, and the hint names the manifest it looked for.
printf '%s\n' 'id = "x"' '[[startup]]' 'version = "9.9.9"' >"$herdr/repo/herdr-plugin.toml"
table_out=$(cd "$herdr/repo" && env -i PATH="$herdr/bin:/usr/bin:/bin" HOME="$herdr" \
            bash --noprofile --norc "$SCRIPT" 2>&1)
refute "ignores a version inside a table" "9.9.9" "$table_out"
check "the hint lists herdr-plugin.toml" "herdr-plugin.toml" "$table_out"

# ---------------------------------------------------------------------------
# A repository that states its version NOWHERE, with a release published
# ---------------------------------------------------------------------------
# netresearch/timetracker is deployed from a tag and has no manifest to bump.
# Every phase of the verdict keys off $declared, so "no version file found"
# short-circuited all of them and the one actionable thing -- the state of the
# published release -- was never reported. The released tag is that version.
#
# This case needs a forge, so `gh` is stubbed: each call the script makes is
# answered from the fixture, and anything unexpected exits non-zero rather than
# silently returning the empty string.

tagonly=$(mktemp -d)
trap 'rm -rf "$work" "$addon" "$herdr" "$tagonly"' EXIT
mkdir -p "$tagonly/bin" "$tagonly/repo"
ln -sf "$jq_path" "$tagonly/bin/jq"
cat >"$tagonly/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh for release-status.sh: a repo with one annotated tag v6.4.0,
# released, and no version file anywhere.
case "$1 $2" in
  "auth status")  exit 0 ;;
  "repo view")    echo "acme/tagonly"; exit 0 ;;
  "pr list")      echo "null"; exit 0 ;;
  "run list")     echo "none"; exit 0 ;;
  "release view") exit 0 ;;
esac
if [ "$1" = api ]; then
  case "$2" in
    */releases/latest)  echo "v6.4.0"; exit 0 ;;
    */git/ref/tags/v6.4.0) echo "tag"; exit 0 ;;
    */git/ref/tags/*)   exit 1 ;;
    */contents/*)       exit 1 ;;
  esac
fi
exit 1
STUB
chmod +x "$tagonly/bin/gh"

tagonly_out=$(cd "$tagonly/repo" && env -i PATH="$tagonly/bin:/usr/bin:/bin" HOME="$tagonly" \
              bash --noprofile --norc "$SCRIPT" -R acme/tagonly 2>&1)
check  "takes the version from the release when no file states it" "declared    : 6.4.0" "$tagonly_out"
check  "says where that version came from"   "no version file in the tree" "$tagonly_out"
refute "does not demand a version-file bump" "NEXT: prepare-release" "$tagonly_out"
check  "reports the tag it found"            "tag         : annotated" "$tagonly_out"

# Without a release there is nothing to fall back on, and the original verdict
# -- with its list of the manifests that were looked for -- must survive.
cat >"$tagonly/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view")   echo "acme/tagonly"; exit 0 ;;
  "pr list")     echo "null"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$tagonly/bin/gh"
norelease_out=$(cd "$tagonly/repo" && env -i PATH="$tagonly/bin:/usr/bin:/bin" HOME="$tagonly" \
                bash --noprofile --norc "$SCRIPT" -R acme/tagonly 2>&1)
check "versionless with no release still says so" "no version file found" "$norelease_out"
check "and still names the manifests"             "herdr-plugin.toml" "$norelease_out"

# ---------------------------------------------------------------------------
# The tag's workflow run, behind a dozen newer runs of other workflows
# ---------------------------------------------------------------------------
# netresearch/raybeam v1.2.0 reported "workflow : none" on 2026-09-22 although
# its Release run 32944806553 had succeeded: the script filtered the 12 newest
# runs of every workflow, and Renovate, the merge queue and CI had long pushed
# the tag's run out of that window. This stub behaves like gh: `run list` honours
# --branch and applies the --jq filter with real jq, so a lookup that does not
# ask for the tag gets the twelve foreign runs and nothing else.

runs=$(mktemp -d)
trap 'rm -rf "$work" "$addon" "$herdr" "$tagonly" "$runs"' EXIT
mkdir -p "$runs/bin" "$runs/repo"
ln -sf "$jq_path" "$runs/bin/jq"
cat >"$runs/bin/gh" <<'STUB'
#!/usr/bin/env bash
# A repo released as v6.4.0 whose tag push started CI and Release. Twelve CI
# runs on main came after it. RUNS_MODE selects the state of the tag's runs.
case "$1 $2" in
  "auth status")  exit 0 ;;
  "repo view")    echo "acme/runs"; exit 0 ;;
  "pr list")      echo "null"; exit 0 ;;
  "release view") exit 1 ;;
  "run list")
    [ "${RUNS_MODE:-}" = fail ] && exit 1
    branch=""; filter="."; shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --branch) branch="$2"; shift 2 ;;
        --jq)     filter="$2"; shift 2 ;;
        *)        shift ;;
      esac
    done
    if [ "$branch" = "v6.4.0" ]; then
      n=0; [ -f "$RUNS_COUNTER" ] && n=$(cat "$RUNS_COUNTER"); echo $((n + 1)) >"$RUNS_COUNTER"
      rel='{"name":"Release","status":"completed","conclusion":"success","headBranch":"v6.4.0"}'
      if [ "${RUNS_MODE:-}" = watch ] && [ "$n" -lt 2 ]; then
        rel='{"name":"Release","status":"in_progress","conclusion":"","headBranch":"v6.4.0"}'
      fi
      # CI on the same tag is newer and still running; it is not the publisher.
      data="[{\"name\":\"CI\",\"status\":\"in_progress\",\"conclusion\":\"\",\"headBranch\":\"v6.4.0\"},$rel]"
    elif [ -z "$branch" ]; then
      # Cancelled, so a foreign run can never pass for the tag's successful one.
      data=$(jq -nc '[range(12) | {name:"Release",status:"completed",conclusion:"cancelled",headBranch:"main"}]')
    else
      data='[]'
    fi
    printf '%s' "$data" | jq -r "$filter"
    exit 0 ;;
esac
if [ "$1" = api ]; then
  case "$2" in
    */releases/latest)     echo "v6.4.0"; exit 0 ;;
    */git/ref/tags/v6.4.0) echo "tag"; exit 0 ;;
    */git/ref/tags/*)      exit 1 ;;
    */contents/*)          exit 1 ;;
  esac
fi
exit 1
STUB
chmod +x "$runs/bin/gh"

runs_env() { env -i PATH="$runs/bin:/usr/bin:/bin" HOME="$runs" RUNS_COUNTER="$runs/count" "$@"; }

rm -f "$runs/count"
runs_out=$(cd "$runs/repo" && runs_env bash --noprofile --norc "$SCRIPT" -R acme/runs 2>&1)
check  "finds the tag's run behind twelve newer ones" "workflow    : completed/success" "$runs_out"
refute "does not report the run as missing"          "workflow    : none" "$runs_out"

# The failed lookup must not read as "there is no run".
rm -f "$runs/count"
fail_out=$(cd "$runs/repo" && runs_env RUNS_MODE=fail bash --noprofile --norc "$SCRIPT" -R acme/runs 2>&1)
check "a failed lookup says unknown" "workflow    : unknown" "$fail_out"

# --watch: the Release run is in progress for the first two lookups, then done.
# The timeout is short so that a broken watch fails this test in seconds rather
# than holding it for the default 45 minutes.
rm -f "$runs/count"
watch_out=$(cd "$runs/repo" && runs_env RUNS_MODE=watch RELEASE_STATUS_WATCH_INTERVAL=0 \
            RELEASE_STATUS_WATCH_TIMEOUT=3 bash --noprofile --norc "$SCRIPT" -R acme/runs --watch 2>&1)
check  "watch reports the state it waited through" "watch: v6.4.0 workflow in_progress/-" "$watch_out"
check  "watch ends on the completed run"           "workflow    : completed/success" "$watch_out"
refute "watch did not run into its timeout"        "watch timed out" "$watch_out"
check  "watch polled exactly until the state changed" "lookups=3;" "lookups=$(cat "$runs/count");"

# ---------------------------------------------------------------------------
# package.json / composer.json versions, and tags without a `v`
# ---------------------------------------------------------------------------
# netresearch/assetpicker states its version only in package.json and tags its
# releases bare: 2.0.0, 2.0.1. The script read no version file, took 2.0.1 from
# the release, asked for the tag `v2.0.1`, got a 404, and answered
# "tag: absent" / "NEXT: prepare-release" for a finished release.
#
# The stub serves the releases/latest tag from STUB_LATEST and treats every name
# in STUB_TAGS as an annotated tag with a successful Release run. Anything it is
# not told about is a 404, so a lookup under the wrong spelling finds nothing.

manif=$(mktemp -d)
trap 'rm -rf "$work" "$addon" "$herdr" "$tagonly" "$runs" "$manif"' EXIT
mkdir -p "$manif/bin" "$manif/repo"
ln -sf "$jq_path" "$manif/bin/jq"
cat >"$manif/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status")  exit 0 ;;
  "repo view")    echo "acme/manif"; exit 0 ;;
  "pr list")      echo "null"; exit 0 ;;
  "release view")
    # STUB_PUBLISHED: every tag in STUB_TAGS has a published release whose
    # body is already a narrative, so release-notes-status.sh answers ok.
    [ -n "${STUB_PUBLISHED:-}" ] || exit 1
    found=""; for t in ${STUB_TAGS:-}; do [ "$t" = "$3" ] && found=1; done
    [ -n "$found" ] || exit 1
    case "$*" in
      *isDraft*) echo "false" ;;
      *body*)    echo "Pictures can be picked from the new media browser." ;;
    esac
    exit 0 ;;
  "run list")
    branch=""; shift 2
    while [ $# -gt 0 ]; do
      case "$1" in --branch) branch="$2"; shift 2 ;; *) shift ;; esac
    done
    for t in ${STUB_TAGS:-}; do
      [ "$t" = "$branch" ] && { echo "completed/success"; exit 0; }
    done
    echo "none"; exit 0 ;;
esac
if [ "$1" = api ]; then
  case "$2" in
    */releases/latest)
      [ -n "${STUB_LATEST:-}" ] && { echo "$STUB_LATEST"; exit 0; }
      exit 1 ;;
    */releases\?*)  exit 0 ;;
    */git/ref/tags/*)
      for t in ${STUB_TAGS:-}; do
        [ "$t" = "${2##*/git/ref/tags/}" ] && { echo "tag"; exit 0; }
      done
      exit 1 ;;
  esac
fi
exit 1
STUB
chmod +x "$manif/bin/gh"
# Packagist as it answers for netresearch/assetpicker: the versions are the tag
# names as tagged, so a bare tag is listed as "2.0.1", not "v2.0.1".
cat >"$manif/bin/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *repo.packagist.org/p2/netresearch/assetpicker.json*)
    printf '%s\n200' '{"packages":{"netresearch/assetpicker":[{"version":"2.0.1"},{"version":"2.0.0"}]}}' ;;
  *) exit 7 ;;
esac
STUB
chmod +x "$manif/bin/curl"

# manif_run <STUB_LATEST> <STUB_TAGS> [script args...] — gh on PATH, forge stubbed
manif_run() {
  local latest="$1" tags="$2"; shift 2
  (cd "$manif/repo" && env -i PATH="$manif/bin:/usr/bin:/bin" HOME="$manif" \
     STUB_LATEST="$latest" STUB_TAGS="$tags" STUB_PUBLISHED="${STUB_PUBLISHED:-}" \
     bash --noprofile --norc "$SCRIPT" "$@" 2>&1)
}
# local_run — no gh on PATH, only the version files are read
local_run() {
  (cd "$manif/repo" && env -i PATH="$work/bin:/usr/bin:/bin" HOME="$manif" \
     bash --noprofile --norc "$SCRIPT" 2>&1)
}

# The real case: assetpicker's package.json and composer.json (the latter has
# no version), its latest release 2.0.1, and its bare tags.
printf '%s\n' '{"name": "assetpicker", "version": "2.0.1", "type": "module"}' >"$manif/repo/package.json"
printf '%s\n' '{"name": "netresearch/assetpicker", "type": "library"}' >"$manif/repo/composer.json"
ap_out=$(manif_run 2.0.1 "2.0.0 2.0.1" -R netresearch/assetpicker)
# The line must end after the version: the release fallback prints the same
# number followed by "(from the latest release ...)".
check  "assetpicker: reads the version from package.json"  "declared    : 2.0.1"$'\n' "$ap_out"
refute "assetpicker: does not fall back to the release"    "no version file in the tree" "$ap_out"
check  "assetpicker: finds the bare tag 2.0.1"             "tag         : annotated" "$ap_out"
refute "assetpicker: does not report the tag as absent"    "tag         : absent" "$ap_out"
check  "assetpicker: looks up the run under the bare tag"  "workflow    : completed/success" "$ap_out"
refute "assetpicker: is not sent back to prepare-release"  "NEXT: prepare-release" "$ap_out"

# With the release published and its notes finished, the verdict reaches the
# registry check, and Packagist lists the version under the bare tag name.
ap_pub=$(STUB_PUBLISHED=1 manif_run 2.0.1 "2.0.0 2.0.1" -R netresearch/assetpicker)
check  "assetpicker: the finished release is ok"        "NEXT: ok" "$ap_pub"
refute "assetpicker: Packagist is not reported missing" "registries  : missing" "$ap_pub"

# The `v` spelling is still found, also when the latest release is bare.
vtag_out=$(manif_run 2.0.0 "v2.0.1" -R acme/manif)
check  "a v-tag is found when the latest release is bare"  "tag         : annotated" "$vtag_out"
refute "and is not reported absent"                        "tag         : absent" "$vtag_out"

# A missing tag is suggested in the spelling the repository already uses.
printf '%s\n' '{"name": "assetpicker", "version": "2.0.2"}' >"$manif/repo/package.json"
bare_next=$(manif_run 2.0.1 "2.0.0 2.0.1" -R acme/manif)
check  "suggests a bare tag after bare releases"  "git tag -s 2.0.2 -m 2.0.2" "$bare_next"
refute "does not suggest a v-tag there"           "git tag -s v2.0.2" "$bare_next"
printf '%s\n' '{"name": "assetpicker", "version": "6.5.0"}' >"$manif/repo/package.json"
v_next=$(manif_run v6.4.0 "v6.4.0" -R acme/manif)
check  "suggests a v-tag after v-releases"        "git tag -s v6.5.0 -m v6.5.0" "$v_next"

# A private package.json is local tooling: its version is not the release's.
rm -f "$manif/repo/composer.json"
printf '%s\n' '{"name": "tooling", "private": true, "version": "9.9.9"}' >"$manif/repo/package.json"
priv_out=$(local_run)
refute "a private package.json is not read"   "9.9.9" "$priv_out"
check  "and the tree counts as versionless"   "declared    : <none>" "$priv_out"
printf '%s\n' '{"name": "tooling", "private": false, "version": "9.9.9"}' >"$manif/repo/package.json"
check  "a package.json with private: false is read" "declared    : 9.9.9" "$(local_run)"
rm -f "$manif/repo/package.json"

# composer.json's top-level "version" (the PHP/Composer row of
# ecosystem-detection.md), and nothing when the field is absent.
printf '%s\n' '{"name": "acme/lib", "version": "3.2.1"}' >"$manif/repo/composer.json"
check  "reads the top-level composer.json version" "declared    : 3.2.1" "$(local_run)"
printf '%s\n' '{"name": "acme/lib"}' >"$manif/repo/composer.json"
check  "a composer.json without version is not a version file" "declared    : <none>" "$(local_run)"
# composer.json allows a leading v; the tag lookup must not become vv2.0.1.
printf '%s\n' '{"name": "acme/lib", "version": "v2.0.1"}' >"$manif/repo/composer.json"
cv_out=$(manif_run 2.0.1 "2.0.0 2.0.1" -R acme/manif)
check  "a v-prefixed composer version is read without the v" "declared    : 2.0.1"$'\n' "$cv_out"
check  "and its bare tag is found"                          "tag         : annotated" "$cv_out"
refute "and no vv-tag is looked for or suggested"           "vv2.0.1" "$cv_out"
refute "and the tag is not reported absent"                 "tag         : absent" "$cv_out"
rm -f "$manif/repo/composer.json"

# ---------------------------------------------------------------------------
# -R names a repository the current directory is not a checkout of
# ---------------------------------------------------------------------------
# netresearch/t3x-nr-llm, 2026-09-24: `release-status.sh -R … --watch` was run
# from a parent directory right after the v0.37.1 tag push. No version file
# there, so the script fell back to the latest release, v0.37.0, watched that
# release's finished run and reported ok. The stub serves acme/remote: its
# default branch declares 3.1.0 in ext_emconf.php, its latest release is
# v3.0.0. A raw contents request for any other file is a 404.

remote=$(mktemp -d)
trap 'rm -rf "$work" "$addon" "$herdr" "$tagonly" "$runs" "$manif" "$remote"' EXIT
mkdir -p "$remote/bin" "$remote/plain" "$remote/other" "$remote/same" "$remote/alias"
ln -sf "$jq_path" "$remote/bin/jq"
cat >"$remote/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status")  exit 0 ;;
  "pr list")      echo "null"; exit 0 ;;
  "run list")     echo "none"; exit 0 ;;
  "release view") exit 1 ;;
esac
[ "$1" = api ] || exit 1
path=""; for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
case "$path" in
  repos/acme/remote/contents/ext_emconf.php)
    printf '%s\n' '<?php' "\$EM_CONF['x'] = ['version' => '3.1.0'];"; exit 0 ;;
  repos/acme/remote/contents/composer.json)
    printf '%s\n' '{"name": "acme/remote", "extra": {"typo3/cms": {"extension-key": "remote_ext"}}}'; exit 0 ;;
  repos/acme/remote/contents/*) echo '{"message":"Not Found"}'; exit 1 ;;
  repos/acme/remote)             echo "main"; exit 0 ;;
  repos/acme/remote/git/trees/*) exit 0 ;;
  repos/acme/remote/releases/latest) echo "v3.0.0"; exit 0 ;;
  repos/acme/remote/git/ref/tags/*)  exit 1 ;;
  # acme/lib states no version anywhere: a composer library.
  repos/acme/lib/contents/composer.json) printf '%s\n' '{"name": "acme/lib"}'; exit 0 ;;
  repos/acme/lib/contents/*) echo '{"message":"Not Found"}'; exit 1 ;;
  repos/acme/lib)                echo "main"; exit 0 ;;
  repos/acme/lib/git/trees/*)    exit 0 ;;
  repos/acme/lib/releases/latest) echo "v1.0.0"; exit 0 ;;
  repos/acme/lib/git/ref/tags/*) exit 1 ;;
  # acme/old: its default branch lags the latest release.
  repos/acme/old/contents/ext_emconf.php)
    printf '%s\n' '<?php' "\$EM_CONF['x'] = ['version' => '1.0.0'];"; exit 0 ;;
  repos/acme/old/contents/*)     echo '{"message":"Not Found"}'; exit 1 ;;
  repos/acme/old)                echo "main"; exit 0 ;;
  repos/acme/old/git/trees/*)    exit 0 ;;
  repos/acme/old/releases/latest) echo "v2.0.0"; exit 0 ;;
  repos/acme/old/git/ref/tags/*) exit 1 ;;
  # acme/tree: the tree listing fails; the root manifest must still count.
  repos/acme/tree/contents/ext_emconf.php)
    printf '%s\n' '<?php' "\$EM_CONF['x'] = ['version' => '1.2.0'];"; exit 0 ;;
  repos/acme/tree/contents/*)    echo '{"message":"Not Found"}'; exit 1 ;;
  repos/acme/tree)               echo "main"; exit 0 ;;
  repos/acme/tree/git/trees/*)   echo '{"message":"Server Error"}'; exit 1 ;;
  repos/acme/tree/releases/latest) echo "v1.1.0"; exit 0 ;;
  repos/acme/tree/git/ref/tags/*) exit 1 ;;
esac
exit 1
STUB
chmod +x "$remote/bin/gh"
remote_run() { # remote_run <dir> [extra args]
  (cd "$1" && env -i PATH="$remote/bin:/usr/bin:/bin" HOME="$remote" \
     bash --noprofile --norc "$SCRIPT" -R acme/remote "${@:2}" 2>&1)
}

# (a) not a checkout at all, and no version file here: the default branch is read.
plain_out=$(remote_run "$remote/plain")
check  "-R outside a checkout reads the default branch"   "declared    : 3.1.0" "$plain_out"
check  "and says where the version came from"             "from the default branch of acme/remote" "$plain_out"
refute "and does not fall back to the previous release"   "declared    : 3.0.0" "$plain_out"

# (b) a checkout of ANOTHER repository with its own version file: not read.
git -C "$remote/other" init -q
git -C "$remote/other" remote add origin https://github.com/acme/other.git
printf '%s\n' '<?php' "\$EM_CONF['x'] = ['version' => '9.9.9'];" >"$remote/other/ext_emconf.php"
other_out=$(remote_run "$remote/other")
refute "a foreign checkout's version file is not read"    "9.9.9" "$other_out"
check  "the named repository's version is read instead"   "declared    : 3.1.0" "$other_out"
check  "and the foreign checkout is named in the verdict" "checkout of another repository" "$other_out"

# (c) the matching checkout (SSH remote, different case): local files as before.
git -C "$remote/same" init -q
git -C "$remote/same" remote add origin git@github.com:Acme/Remote.git
printf '%s\n' '<?php' "\$EM_CONF['x'] = ['version' => '3.2.0'];" >"$remote/same/ext_emconf.php"
same_out=$(remote_run "$remote/same")
check  "the matching checkout's files are read"           "declared    : 3.2.0"$'\n' "$same_out"
refute "without a remote read"                            "from the default branch" "$same_out"
refute "and without calling it foreign"                   "checkout of another repository" "$same_out"

# (d) the matching checkout behind an SSH host alias: the URL names no
# github.com, so it cannot be ruled foreign -- local files as before.
git -C "$remote/alias" init -q
git -C "$remote/alias" remote add origin git@github.com-work:acme/remote.git
printf '%s\n' '<?php' "\$EM_CONF['x'] = ['version' => '3.2.0'];" >"$remote/alias/ext_emconf.php"
alias_out=$(remote_run "$remote/alias")
check  "an SSH host alias remote keeps the local files"   "declared    : 3.2.0"$'\n' "$alias_out"
refute "and is not called foreign"                        "checkout of another repository" "$alias_out"

# (e) the package the registries are asked about belongs to the named
# repository: never the foreign checkout's composer.json, and the fetched one
# when there is none here.
printf '%s\n' '{"name": "acme/other", "extra": {"typo3/cms": {"extension-key": "other_ext"}}}' >"$remote/other/composer.json"
other_json=$(remote_run "$remote/other" --json)
check  "a foreign checkout's package is not used"        '"package":"acme/remote"' "$other_json"
check  "nor its extension key"                           '"extension_key":"remote_ext"' "$other_json"
check  "outside a checkout the fetched package is used"  '"package":"acme/remote"' "$(remote_run "$remote/plain" --json)"
# The same when the named repository states no version at all, so the version
# comes from its release and the fetched files only supply the package.
lib_run() { # lib_run <dir>
  (cd "$1" && env -i PATH="$remote/bin:/usr/bin:/bin" HOME="$remote" \
     bash --noprofile --norc "$SCRIPT" -R acme/lib --json 2>&1)
}
check  "a versionless repository: not the foreign package" '"package":"acme/lib"' "$(lib_run "$remote/other")"
check  "a versionless repository: the fetched package outside a checkout" '"package":"acme/lib"' "$(lib_run "$remote/plain")"

named_run() { # named_run <repo> <dir>
  (cd "$2" && env -i PATH="$remote/bin:/usr/bin:/bin" HOME="$remote" \
     bash --noprofile --norc "$SCRIPT" -R "$1" 2>&1)
}
# (f) a default branch that lags the latest release is not a stale worktree:
# the switch advice would act on the current directory, not on the named repo.
old_out=$(named_run acme/old "$remote/plain")
check  "a lagging default branch is named as such"       "default branch of acme/old declares v1.0.0" "$old_out"
refute "and gets no worktree switch"                     "switch --detach" "$old_out"

# (g) the .toc tree listing fails: the root manifest fetched before it counts.
tree_out=$(named_run acme/tree "$remote/plain")
check  "a failed tree listing keeps the root manifest"   "declared    : 1.2.0" "$tree_out"

# ---------------------------------------------------------------------------
# A maintenance branch is compared with its own line, not the newest release
# ---------------------------------------------------------------------------
# netresearch/t3x-nr-textdb (issue #173): v3.0.5 was prepared on the
# maintenance branch TYPO3_13 after v4.0.0 had been released from main. The
# script compared 3.0.5 with the latest release 4.0.0, called the tree stale
# and advised `git switch --detach origin/main`. The fixture is a real git
# repository: main and TYPO3_13 diverge after 3.0.0, v3.0.4 is tagged on
# TYPO3_13, v4.0.0 on main. The stub serves releases/latest from STUB_LATEST,
# the release list from STUB_RELEASES (through the --jq filter the script
# passes), and treats every name in STUB_TAGS as an annotated tag with a
# successful Release run and a finished release body.

maint=$(mktemp -d)
trap 'rm -rf "$work" "$addon" "$herdr" "$tagonly" "$runs" "$manif" "$remote" "$maint"' EXIT
mkdir -p "$maint/bin" "$maint/repo" "$maint/notags"
ln -sf "$jq_path" "$maint/bin/jq"
cat >"$maint/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status")  exit 0 ;;
  "pr list")      echo "null"; exit 0 ;;
  "release view")
    found=""; for t in ${STUB_TAGS:-}; do [ "$t" = "$3" ] && found=1; done
    [ -n "$found" ] || exit 1
    case "$*" in
      *isDraft*) echo "false" ;;
      *body*)    echo "Translations are imported in batches." ;;
    esac
    exit 0 ;;
  "run list")
    branch=""; shift 2
    while [ $# -gt 0 ]; do
      case "$1" in --branch) branch="$2"; shift 2 ;; *) shift ;; esac
    done
    for t in ${STUB_TAGS:-}; do
      [ "$t" = "$branch" ] && { echo "completed/success"; exit 0; }
    done
    echo "none"; exit 0 ;;
esac
[ "$1" = api ] || exit 1
path=""; filter="."; prev=""
for a in "$@"; do
  case "$a" in repos/*) path="$a" ;; esac
  [ "$prev" = "--jq" ] && filter="$a"
  prev="$a"
done
case "$path" in
  */releases/latest)
    [ -n "${STUB_LATEST:-}" ] && { echo "$STUB_LATEST"; exit 0; }
    echo '{"message":"Not Found"}'; exit 1 ;;
  */releases\?*)
    [ -n "${STUB_RELEASES_FAIL:-}" ] && { echo '{"message":"Server Error"}'; exit 1; }
    printf '%s\n' ${STUB_RELEASES:-} \
      | jq -R '{tag_name: ., draft: false, prerelease: false}' | jq -s . | jq -r "$filter"
    exit 0 ;;
  */git/ref/tags/*)
    for t in ${STUB_TAGS:-}; do
      [ "$t" = "${path##*/git/ref/tags/}" ] && { echo "tag"; exit 0; }
    done
    exit 1 ;;
esac
exit 1
STUB
chmod +x "$maint/bin/gh"

mg() { git -C "$1" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false \
         -c tag.gpgsign=false "${@:2}" >/dev/null 2>&1; }
mver() { printf '%s\n' '<?php' "\$EM_CONF['textdb'] = ['version' => '$2'];" >"$1/ext_emconf.php"; }
mg "$maint/repo" init -q -b main
mver "$maint/repo" 3.0.0; mg "$maint/repo" add -A; mg "$maint/repo" commit -qm 3.0.0
mg "$maint/repo" tag -a v3.0.0 -m v3.0.0
mg "$maint/repo" branch TYPO3_13
mver "$maint/repo" 4.0.0; mg "$maint/repo" commit -qam 4.0.0
mg "$maint/repo" tag -a v4.0.0 -m v4.0.0
mg "$maint/repo" switch -q TYPO3_13
mver "$maint/repo" 3.0.4; mg "$maint/repo" commit -qam 3.0.4
mg "$maint/repo" tag -a v3.0.4 -m v3.0.4
mver "$maint/repo" 3.0.5; mg "$maint/repo" commit -qam 3.0.5

# maint_run <dir> <STUB_LATEST> <STUB_TAGS> <STUB_RELEASES> [VAR=value...]
maint_run() {
  local dir="$1" latest="$2" tags="$3" rels="$4"; shift 4
  (cd "$dir" && env -i PATH="$maint/bin:/usr/bin:/bin" HOME="$maint" \
     STUB_LATEST="$latest" STUB_TAGS="$tags" STUB_RELEASES="$rels" "$@" \
     bash --noprofile --norc "$SCRIPT" -R acme/textdb 2>&1)
}

# (a) the issue's case: 3.0.5 prepared on TYPO3_13, v4.0.0 is the latest release.
m_prep=$(maint_run "$maint/repo" v4.0.0 "v3.0.0 v3.0.4 v4.0.0" "v4.0.0 v3.0.4 v3.0.0")
check  "maintenance: compared with the newest release of its line" "latest rel  : v3.0.4" "$m_prep"
check  "maintenance: the prepared version is to be tagged"         "NEXT: signed-tag" "$m_prep"
check  "maintenance: the tag is suggested for the branch tip"      "verify HEAD==origin/TYPO3_13 first" "$m_prep"
check  "maintenance: the verdict names the line"                   "maintenance line 3.x" "$m_prep"
refute "maintenance: not called a stale worktree"                  "already released -- fetch" "$m_prep"
refute "maintenance: no advice to switch to main"                  "origin/main" "$m_prep"

# (b) the same branch after v3.0.5 is released and its notes are finished.
m_done=$(maint_run "$maint/repo" v4.0.0 "v3.0.0 v3.0.4 v3.0.5 v4.0.0" "v4.0.0 v3.0.5 v3.0.4 v3.0.0")
check  "maintenance: a finished maintenance release is ok" "NEXT: ok" "$m_done"
check  "maintenance: against v3.0.5, not v4.0.0"           "latest rel  : v3.0.5" "$m_done"

# (c) a maintenance worktree behind its own line is stale on that line, and the
# advice points at the branch it is on, not at main.
mg "$maint/repo" switch -q -c t13-old v3.0.4
m_stale=$(maint_run "$maint/repo" v4.0.0 "v3.0.0 v3.0.4 v3.0.5 v4.0.0" "v4.0.0 v3.0.5 v3.0.4 v3.0.0")
check  "maintenance: behind its own line is stale"  "declares v3.0.4 but v3.0.5 is already released" "$m_stale"
refute "maintenance: stale, still no switch to main" "origin/main" "$m_stale"

# (d) detached HEAD at the maintenance tip: the line is found from the commit
# graph, the branch name is not needed.
mg "$maint/repo" switch -q --detach TYPO3_13
m_det=$(maint_run "$maint/repo" v4.0.0 "v3.0.0 v3.0.4 v4.0.0" "v4.0.0 v3.0.4 v3.0.0")
check  "maintenance, detached: compared with its line" "latest rel  : v3.0.4" "$m_det"
check  "maintenance, detached: to be tagged"           "NEXT: signed-tag" "$m_det"
refute "maintenance, detached: no advice to switch to main" "origin/main" "$m_det"

# (d2) a local branch with another name that tracks origin/TYPO3_13: the advice
# names the upstream, where the tag belongs.
mg "$maint/repo" remote add origin "file://$maint/nowhere"
mg "$maint/repo" update-ref refs/remotes/origin/TYPO3_13 TYPO3_13
mg "$maint/repo" switch -q -c work TYPO3_13
mg "$maint/repo" config branch.work.remote origin
mg "$maint/repo" config branch.work.merge refs/heads/TYPO3_13
m_up=$(maint_run "$maint/repo" v4.0.0 "v3.0.0 v3.0.4 v4.0.0" "v4.0.0 v3.0.4 v3.0.0")
check  "maintenance, tracking branch: the upstream is named" "verify HEAD==origin/TYPO3_13 first" "$m_up"
refute "maintenance, tracking branch: not the local name"   "origin/work" "$m_up"

# (e) the release list cannot be read: the newest tag of the line reachable from
# HEAD stands in for it.
mg "$maint/repo" switch -q TYPO3_13
m_local=$(maint_run "$maint/repo" v4.0.0 "v3.0.0 v3.0.4 v4.0.0" "" STUB_RELEASES_FAIL=1)
check  "maintenance, no release list: the reachable tag is used" "latest rel  : v3.0.4" "$m_local"
check  "maintenance, no release list: to be tagged"             "NEXT: signed-tag" "$m_local"

# (f) main at the newest line is unaffected.
mg "$maint/repo" switch -q main
m_main=$(maint_run "$maint/repo" v4.0.0 "v3.0.0 v3.0.4 v4.0.0" "v4.0.0 v3.0.4 v3.0.0")
check  "main at the newest line: ok"                "NEXT: ok" "$m_main"
check  "main at the newest line: the latest release" "latest rel  : v4.0.0" "$m_main"
refute "main at the newest line: no maintenance note" "maintenance line" "$m_main"

# (g) a checkout of main from before the release is still a stale worktree:
# its HEAD is an ancestor of v4.0.0, so it is not a maintenance branch.
mg "$maint/repo" switch -q --detach v3.0.0
m_old=$(maint_run "$maint/repo" v4.0.0 "v3.0.0 v3.0.4 v4.0.0" "v4.0.0 v3.0.4 v3.0.0")
check  "stale main: still stale"              "declares v3.0.0 but v4.0.0 is already released" "$m_old"
check  "stale main: still told to switch"     "git switch --detach origin/main" "$m_old"
refute "stale main: not a maintenance branch" "maintenance line" "$m_old"

# (h) a repository without any tag or release: the prepared version is tagged.
mg "$maint/notags" init -q -b main
mver "$maint/notags" 1.0.0; mg "$maint/notags" add -A; mg "$maint/notags" commit -qm 1.0.0
m_none=$(maint_run "$maint/notags" "" "" "")
check  "no tags: the first version is to be tagged" "NEXT: signed-tag" "$m_none"
check  "no tags: under a v-name"                    "git tag -s v1.0.0 -m v1.0.0" "$m_none"
refute "no tags: not a maintenance branch"          "maintenance line" "$m_none"

# (i) the latest release's tag is not in the local repository: the commit graph
# cannot answer, and the verdict says how to make it answer.
m_notag=$(maint_run "$maint/notags" v4.0.0 "v4.0.0" "v4.0.0")
check  "latest tag not local: asks for the tags" "git fetch --tags" "$m_notag"
# (j) outside a git checkout there is no commit graph, and no fetch advice.
mkdir -p "$maint/plain"; mver "$maint/plain" 3.0.5
m_plain=$(maint_run "$maint/plain" v4.0.0 "v4.0.0" "v4.0.0")
refute "not a checkout: no fetch advice"         "git fetch --tags" "$m_plain"

# (k) a line released under both spellings: 3.0.5 is newer than v3.0.4, although
# `sort -V` alone orders the bare name first.
mg "$maint/repo" switch -q t13-old
m_mixed=$(maint_run "$maint/repo" v4.0.0 "v3.0.0 v3.0.4 3.0.5 v4.0.0" "v4.0.0 3.0.5 v3.0.4 v3.0.0")
check  "mixed spellings: the newest of the line by number" "latest rel  : 3.0.5" "$m_mixed"
check  "mixed spellings: the older checkout is stale"      "declares v3.0.4 but 3.0.5 is already released" "$m_mixed"

# (l) a shallow clone: both tags resolve, the history between them is cut off,
# so the commit graph cannot tell a maintenance branch from a stale worktree.
git clone -q --depth 1 --branch TYPO3_13 "file://$maint/repo" "$maint/shallow" >/dev/null 2>&1
git -C "$maint/shallow" fetch -q --depth 1 origin tag v4.0.0 >/dev/null 2>&1
m_shallow=$(maint_run "$maint/shallow" v4.0.0 "v3.0.0 v3.0.4 v4.0.0" "v4.0.0 v3.0.4 v3.0.0")
check  "shallow clone: asks for the history"     "git fetch --unshallow" "$m_shallow"
refute "shallow clone: not judged a maintenance branch" "maintenance line" "$m_shallow"

# ---------------------------------------------------------------------------
# --tag: judge the tag just pushed, not the previous release
# ---------------------------------------------------------------------------
# A repository without a version file takes its version from the LATEST RELEASE.
# Right after `git push origin v1.0.1` that is still v1.0.0, so the verdict was
# about v1.0.0 (ok) and --watch returned at once. --tag names the release.

tagarg=$(mktemp -d)
trap 'rm -rf "$work" "$addon" "$herdr" "$tagonly" "$tagarg"' EXIT
mkdir -p "$tagarg/bin" "$tagarg/repo"
ln -sf "$jq_path" "$tagarg/bin/jq"
cat >"$tagarg/bin/gh" <<'STUB'
#!/usr/bin/env bash
# acme/tagarg: released v1.0.0, tag v1.0.1 pushed annotated, its run in progress.
case "$1 $2" in
  "auth status")  exit 0 ;;
  "repo view")    echo "acme/tagarg"; exit 0 ;;
  "pr list")      echo "null"; exit 0 ;;
  "release view") [ "$3" = v1.0.0 ] && exit 0; exit 1 ;;
  "run list")
    case "$*" in
      *"--branch v1.0.1"*) echo "in_progress/-" ;;
      *"--branch v1.0.0"*) echo "completed/success" ;;
      *) echo none ;;
    esac
    exit 0 ;;
esac
if [ "$1" = api ]; then
  case "$2" in
    */releases/latest)     echo "v1.0.0"; exit 0 ;;
    */git/ref/tags/v1.0.0|*/git/ref/tags/v1.0.1) echo "tag"; exit 0 ;;
    */git/ref/tags/*)      exit 1 ;;
    */contents/*)          exit 1 ;;
  esac
fi
exit 1
STUB
chmod +x "$tagarg/bin/gh"
tagarg_run() {
  (cd "$tagarg/repo" && env -i PATH="$tagarg/bin:/usr/bin:/bin" HOME="$tagarg" \
    bash --noprofile --norc "$SCRIPT" -R acme/tagarg "$@" 2>&1)
  return $?
}

no_tag_out=$(tagarg_run)
check  "without --tag the previous release is judged"  "declared    : 1.0.0" "$no_tag_out"

tag_out=$(tagarg_run --tag v1.0.1)
check  "--tag judges the tag just pushed"              "declared    : 1.0.1" "$tag_out"
check  "--tag says where the version came from"        "(from --tag v1.0.1)" "$tag_out"
check  "--tag sees the run of that tag"                "workflow    : in_progress/-" "$tag_out"
check  "--tag waits for the release workflow"          "NEXT: await-release-workflow" "$tag_out"

# An older tag than the latest release is not a stale worktree: it was asked for.
old_out=$(tagarg_run --tag v1.0.0)
refute "an older --tag is not called stale"            "fetch before trusting" "$old_out"

# Usage errors exit 2 and say why.
tagarg_run --tag >/dev/null; st=$?
check "--tag without a value exits 2" "status=2" "status=$st"
tagarg_run --tag "" >/dev/null; st=$?
check "an empty --tag exits 2" "status=2" "status=$st"
bad_out=$(tagarg_run --tag 'v1;rm'); st=$?
check "a malformed --tag exits 2" "status=2" "status=$st"
check  "a malformed --tag is named"                    "is not a tag name" "$bad_out"

# The guard is a case pattern over the value gh returned; a JSON error body
# contains characters a tag cannot.
tagshaped() { case "$1" in *[!A-Za-z0-9._-]* | "" | null) echo no ;; *) echo yes ;; esac; }
check "a tag is accepted"        "yes" "$(tagshaped 'v2.4.1')"
check "an error body is not"     "no"  "$(tagshaped '{ "message": "Not Found" }')"
check "a literal null is not"    "no"  "$(tagshaped 'null')"

exit "$fail"
