#!/usr/bin/env bash
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

# Parse semver components
IFS='.' read -r major minor patch <<< "$current"
major=${major:-0}
minor=${minor:-0}
patch=${patch:-0}

# Get commits since last tag
commits=$(git log "${last_tag}..HEAD" --format='%s' 2>/dev/null)

if [[ -z "$commits" ]]; then
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

while IFS= read -r subject; do
    # Check for breaking changes
    if echo "$subject" | grep -qP '^[a-z]+(\([^)]*\))?!:' || echo "$subject" | grep -qi 'BREAKING CHANGE'; then
        ((breaking++)) || true
    elif echo "$subject" | grep -qP '^feat(\([^)]*\))?:'; then
        ((feat++)) || true
    elif echo "$subject" | grep -qP '^(fix|perf|refactor)(\([^)]*\))?:'; then
        ((fix++)) || true
    else
        ((other++)) || true
    fi
done <<< "$commits"

total=$((breaking + feat + fix + other))

# Determine bump level
if ((breaking > 0)); then
    if ((major == 0)); then
        # Pre-1.0.0: breaking changes bump minor
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
