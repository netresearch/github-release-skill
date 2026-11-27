#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# suggest-version.sh - Analyze git log since last version tag and suggest next semver version.
#
# Output format:
#   current:<version>
#   suggested:<version>
#   bump:<major|minor|patch|unknown>
#   reason:<explanation>
#
set -euo pipefail

# Find the last version tag matching v*
last_tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)

if [[ -z "$last_tag" ]]; then
    echo "current:none"
    echo "suggested:0.1.0"
    echo "bump:minor"
    echo "reason:no version tags found, suggesting initial 0.1.0"
    exit 0
fi

# Strip leading 'v' to get semver
current="${last_tag#v}"
echo "current:${current}"

# Parse semver components. Build metadata (+...) carries no meaning for the
# order; a pre-release (-...) is finished by releasing its own version.
core="${current%%+*}"
prerelease=""
if [[ "$core" == *-* ]]; then
    prerelease="${core#*-}"
    core="${core%%-*}"
fi
IFS='.' read -r major minor patch <<< "$core"
major=${major:-0}
minor=${minor:-0}
patch=${patch:-0}
if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]]; then
    echo "suggested:unknown"
    echo "bump:unknown"
    echo "reason:${last_tag} is not a MAJOR.MINOR.PATCH version; choose the next version by hand"
    exit 0
fi

if [[ -n "$prerelease" ]]; then
    echo "suggested:${major}.${minor}.${patch}"
    echo "bump:release"
    echo "reason:${last_tag} is a pre-release (${prerelease}); its release ${major}.${minor}.${patch} is next — choose another version by hand if the commits since change what that release is"
    exit 0
fi

# Get commits since last tag: whole messages, separated by an ASCII record
# separator, because a BREAKING CHANGE footer sits in the body.
commits=$(git log "${last_tag}..HEAD" --format='%B%x1e' 2>/dev/null)

if [[ -z "${commits//[$'\x1e\n']/}" ]]; then
    echo "suggested:${current}"
    echo "bump:none"
    echo "reason:no commits since ${last_tag}"
    exit 0
fi

# Count conventional commit types
breaking=0
feat=0
fix=0
other=0

while IFS= read -r -d $'\x1e' message; do
    message="${message#$'\n'}"
    [[ -z "$message" ]] && continue
    subject="${message%%$'\n'*}"
    # Breaking: `!` before the colon, BREAKING CHANGE in the subject, or a
    # `BREAKING CHANGE:` / `BREAKING-CHANGE:` footer line in the body.
    if grep -qE '^[a-z]+(\([^)]*\))?!:' <<< "$subject" || grep -qi 'BREAKING CHANGE' <<< "$subject" \
        || grep -qE '^BREAKING[ -]CHANGE: ' <<< "$message"; then
        ((breaking++)) || true
    elif echo "$subject" | grep -qE '^feat(\([^)]*\))?:'; then
        ((feat++)) || true
    elif echo "$subject" | grep -qE '^(fix|perf|refactor)(\([^)]*\))?:'; then
        ((fix++)) || true
    else
        ((other++)) || true
    fi
done <<< "$commits"

# Determine bump level
if ((breaking > 0)); then
    if ((major == 0)); then
        # Pre-1.0.0: breaking changes bump the middle number
        bump="minor"
        new_major=$major
        new_minor=$((minor + 1))
        new_patch=0
        reason="${breaking} breaking change(s) (pre-1.0.0: bumps minor)"
    else
        bump="major"
        new_major=$((major + 1))
        new_minor=0
        new_patch=0
        reason="${breaking} breaking change(s)"
    fi
elif ((feat > 0)) && ((major == 0)); then
    # On 0.y with y >= 1 the caret stops at the middle number (^0.54 admits
    # only 0.54.*), so raising it is a new major for every consumer. Features
    # go into the last number; only a breaking change raises the middle one.
    # On 0.0.z the caret admits only that exact version, so every release
    # needs a widened constraint; the suggestion stays a patch there too.
    bump="patch"
    new_major=$major
    new_minor=$minor
    new_patch=$((patch + 1))
    reason="${feat} feat commit(s) (pre-1.0.0: features bump patch; read the changelog and the API diff for a breaking change the commit subjects do not mark)"
elif ((feat > 0)); then
    bump="minor"
    new_major=$major
    new_minor=$((minor + 1))
    new_patch=0
    reason="${feat} feat commit(s)"
elif ((fix > 0)); then
    bump="patch"
    new_major=$major
    new_minor=$minor
    new_patch=$((patch + 1))
    reason="${fix} fix/perf/refactor commit(s)"
else
    # No conventional commits recognized
    if ((other > 0)); then
        bump="unknown"
        new_major=$major
        new_minor=$minor
        new_patch=$((patch + 1))
        reason="${other} commit(s) without conventional commit prefixes; manual review recommended"
    else
        bump="unknown"
        new_major=$major
        new_minor=$minor
        new_patch=$patch
        reason="unable to determine bump from commit messages"
    fi
fi

suggested="${new_major}.${new_minor}.${new_patch}"

echo "suggested:${suggested}"
echo "bump:${bump}"
echo "reason:${reason}"
