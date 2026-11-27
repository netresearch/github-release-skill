#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# suggest-version.sh - Suggest the next semver version from the commits since
# the last version tag, computed by git-cliff (`--bumped-version`) with the
# configuration beside this script (suggest-version.cliff.toml).
#
# Output format:
#   current:<version>
#   suggested:<version>
#   bump:<major|minor|patch|release|none|unknown>
#     release: kept in the contract; git-cliff continues a pre-release
#              (rc.1 -> rc.2) instead, which is reported as unknown
#     none:    no commits since the last tag
#     unknown: git-cliff is missing, failed, or suggested another pre-release
#   reason:<explanation>
#
# git-cliff runs as `uvx git-cliff` (no version pinned: dev tooling runs its
# newest release), or as a `git-cliff` binary on PATH when uv is missing.
#
# On 0.y (y >= 1) the suggestion maps feat and fix to the last number and a
# breaking commit to the middle number; on 0.0.z git-cliff raises the last
# number for every commit. It reads commit messages only; on 0.x the
# package's changelog BREAKING entries and its API diff stay authoritative
# (references/release-process.md).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/suggest-version.cliff.toml"

# Find the last version tag matching v*
last_tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)

if [[ -z "$last_tag" ]]; then
    echo "current:none"
    echo "suggested:0.1.0"
    echo "bump:minor"
    echo "reason:no version tags found, suggesting initial 0.1.0"
    exit 0
fi

current="${last_tag#v}"
echo "current:${current}"

unknown() {
    echo "suggested:unknown"
    echo "bump:unknown"
    echo "reason:$1"
    exit 0
}

if command -v uvx >/dev/null 2>&1; then
    cliff=(uvx git-cliff)
elif command -v git-cliff >/dev/null 2>&1; then
    cliff=(git-cliff)
else
    unknown "neither uvx nor git-cliff is installed; install uv (or git-cliff) or choose the next version by hand"
fi

if ! next=$("${cliff[@]}" --config "$CONFIG" --bumped-version 2>/dev/null); then
    unknown "git-cliff could not compute a version from ${last_tag}; choose the next version by hand"
fi
next="${next##*$'\n'}"
next="${next#v}"
next="${next%%+*}"

core="${current%%+*}"
if [[ "$next" == *-* ]]; then
    echo "suggested:${next}"
    echo "bump:unknown"
    echo "reason:${last_tag} is a pre-release; git-cliff suggests the next pre-release ${next}. To release, choose ${core%%-*} or, if a commit since demands more, a higher version by hand"
    exit 0
fi

number='^(0|[1-9][0-9]*)$'
IFS='.' read -r major minor patch <<< "${core%%-*}"
IFS='.' read -r new_major new_minor new_patch <<< "$next"
for part in "$major" "$minor" "$patch" "$new_major" "$new_minor" "$new_patch"; do
    [[ "$part" =~ $number ]] || unknown "git-cliff answered ${next} for ${last_tag}, which is not MAJOR.MINOR.PATCH; choose the next version by hand"
done

if [[ -z "$(git log "${last_tag}..HEAD" --format=%H 2>/dev/null)" ]]; then
    echo "suggested:${current}"
    echo "bump:none"
    echo "reason:no commits since ${last_tag}"
    exit 0
fi

if ((new_major != major)); then
    bump="major"
elif ((new_minor != minor)); then
    bump="minor"
elif ((new_patch != patch)); then
    bump="patch"
else
    unknown "git-cliff found nothing to bump in the commits since ${last_tag}; choose the next version by hand"
fi

reason="git-cliff: ${bump} bump from ${last_tag}"
if ((major == 0 && minor == 0)); then
    reason="${reason} (0.0.z: git-cliff bumps the last number for every commit, breaking ones included; the changelog BREAKING entries and the API diff decide, read them before choosing)"
elif ((major == 0)); then
    reason="${reason} (0.x: feat and fix bump the last number, a breaking commit the middle one; the changelog BREAKING entries and the API diff decide, read them before choosing)"
fi

echo "suggested:${next}"
echo "bump:${bump}"
echo "reason:${reason}"
