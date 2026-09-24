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
rm -f "$manif/repo/composer.json"

# The guard is a case pattern over the value gh returned; a JSON error body
# contains characters a tag cannot.
tagshaped() { case "$1" in *[!A-Za-z0-9._-]* | "" | null) echo no ;; *) echo yes ;; esac; }
check "a tag is accepted"        "yes" "$(tagshaped 'v2.4.1')"
check "an error body is not"     "no"  "$(tagshaped '{ "message": "Not Found" }')"
check "a literal null is not"    "no"  "$(tagshaped 'null')"

exit "$fail"
