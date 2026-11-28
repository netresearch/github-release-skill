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
#     unknown: git-cliff is missing or failed, the configuration is missing,
#              the commits carry nothing to bump (only chore, docs, ci, test,
#              style, build or untyped commits), a .cliffignore sits at the
#              repository root, .git-blame-ignore-revs hides a commit of the
#              range from git-cliff, or git-cliff suggested another pre-release
#   reason:<explanation>
#
# git-cliff runs as `uvx git-cliff@latest`, which resolves the newest release
# on each run (a bare `uvx git-cliff` reuses a cached or installed copy), as
# dev tooling here runs its newest release. A `git-cliff` binary on PATH is
# used when uv is missing or that run fails.
#
# On 0.y (y >= 1) the suggestion maps feat and fix to the last number and a
# breaking commit to the middle number; on 0.0.z git-cliff raises the last
# number for every commit. It reads commit messages only; on 0.x the
# package's changelog BREAKING entries and its API diff stay authoritative
# (references/release-process.md).
set -euo pipefail

# The configuration sits beside the real file, also when this script is
# called through a symlink.
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG="$HERE/suggest-version.cliff.toml"

# Find the last version tag: vMAJOR.MINOR.PATCH, a pre-release suffix allowed.
# An interface tag such as v1 or a two-part v0.60 is no release.
last_tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)

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

if [[ -z "$(git log "${last_tag}..HEAD" --format=%H 2>/dev/null)" ]]; then
    echo "suggested:${current}"
    echo "bump:none"
    echo "reason:no commits since ${last_tag}"
    exit 0
fi

# Without its configuration git-cliff would fall back to its own defaults
# (feat bumps the middle number on 0.x) and answer as if nothing were wrong.
[[ -r "$CONFIG" ]] || unknown "the git-cliff configuration ${CONFIG} is missing; reinstall the skill or choose the next version by hand"

# git-cliff drops every commit listed in a .cliffignore at the repository root
# and has no option to read another file; a branch could hide a breaking
# commit there.
root=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$root" ]] || unknown "not inside a git work tree; run the script from the root of the repository being released"
if [[ -n "$root" ]] && [[ -e "$root/.cliffignore" || -L "$root/.cliffignore" ]]; then
    unknown "git-cliff would skip the commits listed in ${root}/.cliffignore; choose the next version by hand, or run git-cliff in a temporary clone without that file"
fi

# git-cliff also drops every commit listed in .git-blame-ignore-revs at the
# repository root (abbreviated hashes included), and, once the file lists any
# commit, every commit that changes only that file. Refuse only when that hits
# a commit of the range that git-cliff would count: the file is common and
# usually lists old reformats, and a hidden commit the configuration skips
# anyway (an untyped one, or chore, docs, ci, test, style or build that is not
# breaking) changes nothing.
counts() { # counts <sha> -> true when git-cliff would count the commit
    local message subject
    message=$(git log -1 --format=%B "$1")
    subject="${message%%$'\n'*}"
    if [[ "$subject" =~ ^[A-Za-z]+(\([^\)]*\))?!: ]] || grep -q -E '^BREAKING[ -]CHANGE:' <<< "$message"; then
        return 0
    fi
    [[ "$subject" =~ ^[A-Za-z]+(\([^\)]*\))?: ]] \
        && ! [[ "$subject" =~ ^(chore|docs|ci|test|style|build)(\([^\)]*\))?: ]]
}
blame_file="$root/.git-blame-ignore-revs"
if [[ -n "$root" && -r "$blame_file" ]]; then
    listed=$(grep -v -E '^[[:space:]]*(#|$)' "$blame_file" | tr -d '[:blank:]\r' || true)
    if [[ -n "$listed" ]]; then
        while read -r sha; do
            hidden=false
            while read -r id; do
                if [[ -n "$id" && "$sha" == "$id"* ]]; then
                    hidden=true
                fi
            done <<< "$listed"
            if ! $hidden && [[ "$(git diff-tree --no-commit-id --name-only -r --root -m "$sha" | sort -u)" == ".git-blame-ignore-revs" ]]; then
                hidden=true
            fi
            if $hidden && counts "$sha"; then
                unknown "git-cliff would skip commit ${sha:0:12} because of ${blame_file}; review the commits since ${last_tag} and choose the next version by hand"
            fi
        done < <(git rev-list "${last_tag}..HEAD")
    fi
fi

# cliff_next <command>... -> git-cliff's answer, or a non-zero status. The
# caller's GIT_CLIFF_* variables would set options (GIT_CLIFF_SKIP_COMMIT) and
# GIT_CLIFF__* ones would override the configuration (GIT_CLIFF__GIT__SPLIT_COMMITS),
# so the run gets neither.
cliff_next() (
    for name in $(compgen -e); do
        if [[ "$name" == GIT_CLIFF* ]]; then
            unset "$name"
        fi
    done
    # Run from a subdirectory, git-cliff would count only the commits that
    # touch it; --repository makes it read the whole repository.
    "$@" --repository "$root" --config "$CONFIG" --bumped-version 2>/dev/null
)

have_uvx=false; have_cliff=false
command -v uvx >/dev/null 2>&1 && have_uvx=true
command -v git-cliff >/dev/null 2>&1 && have_cliff=true
if ! $have_uvx && ! $have_cliff; then
    unknown "neither uvx nor git-cliff is installed; install uv (or git-cliff) or choose the next version by hand"
fi
if ! { $have_uvx && next=$(cliff_next uvx git-cliff@latest); } \
    && ! { $have_cliff && next=$(cliff_next git-cliff); }; then
    unknown "git-cliff could not compute a version from ${last_tag}; choose the next version by hand"
fi
next="${next##*$'\n'}"
next="${next#v}"
next="${next%%+*}"

core="${current%%+*}"
if [[ "$next" == "$core" ]]; then
    unknown "git-cliff counted nothing to bump in the commits since ${last_tag} (only chore, docs, ci, test, style, build or untyped commits); review them and choose the next version by hand"
fi
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

# git-cliff answers with the last version when it counted nothing to bump; an
# answer below the last tag means it read another tag than `git describe`.
if ((new_major < major || (new_major == major && new_minor < minor) \
    || (new_major == major && new_minor == minor && new_patch <= patch))); then
    unknown "git-cliff counted nothing to bump in the commits since ${last_tag} (only chore, docs, ci, test, style, build or untyped commits); review them and choose the next version by hand"
fi

if ((new_major != major)); then
    bump="major"
elif ((new_minor != minor)); then
    bump="minor"
elif ((new_patch != patch)); then
    bump="patch"
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
