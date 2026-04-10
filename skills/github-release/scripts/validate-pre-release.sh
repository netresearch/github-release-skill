#!/usr/bin/env bash
#
# validate-pre-release.sh - Pre-release validation checklist.
#
# Output: checklist with PASS/FAIL per item and overall status.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass_count=0
fail_count=0
warn_count=0

check() {
    local status="$1" label="$2" detail="${3:-}"
    if [[ "$status" == "PASS" ]]; then
        ((pass_count++)) || true
        printf "  PASS  %s" "$label"
    elif [[ "$status" == "WARN" ]]; then
        ((warn_count++)) || true
        printf "  WARN  %s" "$label"
    else
        ((fail_count++)) || true
        printf "  FAIL  %s" "$label"
    fi
    if [[ -n "$detail" ]]; then
        printf " (%s)" "$detail"
    fi
    printf "\n"
}

echo "Pre-release validation"
echo "======================"
echo ""

# ---------------------------------------------------------------------------
# 1. Version files in sync
# ---------------------------------------------------------------------------
echo "Version consistency:"
versions=()
version_files=()

if [[ -x "${SCRIPT_DIR}/detect-ecosystem.sh" ]]; then
    while IFS= read -r line; do
        case "$line" in
            version-file:*)
                file="${line#version-file:}"
                path="${file%%:*}"
                ver="${file#*:}"
                if [[ -n "$ver" ]]; then
                    versions+=("$ver")
                    version_files+=("${path}=${ver}")
                fi
                ;;
        esac
    done < <("${SCRIPT_DIR}/detect-ecosystem.sh" 2>/dev/null)
fi

if ((${#versions[@]} == 0)); then
    check "WARN" "Version files detected" "no version files found"
else
    # Check all versions are the same
    unique_versions=$(printf '%s\n' "${versions[@]}" | sort -u | wc -l)
    if ((unique_versions == 1)); then
        check "PASS" "Version files in sync" "${versions[0]} across ${#versions[@]} file(s)"
    else
        detail=$(printf '%s, ' "${version_files[@]}")
        check "FAIL" "Version files in sync" "mismatch: ${detail%, }"
    fi
fi

# ---------------------------------------------------------------------------
# 2. CHANGELOG.md has [Unreleased] section with content
# ---------------------------------------------------------------------------
echo ""
echo "Changelog:"
if [[ -f CHANGELOG.md ]]; then
    if grep -qiP '^\#+ *\[?Unreleased\]?' CHANGELOG.md; then
        # Check if there is content between [Unreleased] and the next heading
        unreleased_content=$(sed -n '/^\#\+ *\[*Unreleased\]*/,/^\#\+ *\[*[0-9]/{ /^\#/d; /^$/d; p; }' CHANGELOG.md 2>/dev/null)
        if [[ -n "$unreleased_content" ]]; then
            lines=$(echo "$unreleased_content" | wc -l)
            check "PASS" "CHANGELOG.md [Unreleased] has content" "${lines} line(s)"
        else
            check "FAIL" "CHANGELOG.md [Unreleased] has content" "section is empty"
        fi
    else
        check "FAIL" "CHANGELOG.md [Unreleased] section" "section not found"
    fi
else
    check "FAIL" "CHANGELOG.md exists" "file not found"
fi

# ---------------------------------------------------------------------------
# 3. No uncommitted changes
# ---------------------------------------------------------------------------
echo ""
echo "Working tree:"
if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null | head -1)
    if [[ -z "$untracked" ]]; then
        check "PASS" "Working tree clean"
    else
        check "WARN" "Working tree clean" "untracked files present"
    fi
else
    check "FAIL" "Working tree clean" "uncommitted changes detected"
fi

# ---------------------------------------------------------------------------
# 4. On main/master branch
# ---------------------------------------------------------------------------
echo ""
echo "Branch:"
current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
    check "PASS" "On main/master branch" "$current_branch"
else
    check "FAIL" "On main/master branch" "currently on $current_branch"
fi

# ---------------------------------------------------------------------------
# 5. CI checks passing
# ---------------------------------------------------------------------------
echo ""
echo "CI status:"
if command -v gh &>/dev/null; then
    # Try to get status of latest commit
    ci_status=$(gh run list --limit 1 --json conclusion --jq '.[0].conclusion' 2>/dev/null || true)
    if [[ "$ci_status" == "success" ]]; then
        check "PASS" "CI checks passing"
    elif [[ -z "$ci_status" ]]; then
        check "WARN" "CI checks passing" "no recent workflow runs found"
    else
        check "FAIL" "CI checks passing" "last run: $ci_status"
    fi
else
    check "WARN" "CI checks passing" "gh CLI not available"
fi

# ---------------------------------------------------------------------------
# 6. Release workflow exists
# ---------------------------------------------------------------------------
echo ""
echo "Release infrastructure:"
if [[ -f .github/workflows/release.yml ]]; then
    check "PASS" "Release workflow exists" ".github/workflows/release.yml"

    # Check required permissions
    has_id_token=false
    has_attestations=false
    if grep -qP 'id-token\s*:\s*write' .github/workflows/release.yml 2>/dev/null; then
        has_id_token=true
    fi
    if grep -qP 'attestations\s*:\s*write' .github/workflows/release.yml 2>/dev/null; then
        has_attestations=true
    fi

    if $has_id_token && $has_attestations; then
        check "PASS" "Release workflow permissions" "id-token:write, attestations:write"
    else
        missing=""
        $has_id_token || missing="id-token:write"
        $has_attestations || missing="${missing:+$missing, }attestations:write"
        check "FAIL" "Release workflow permissions" "missing: $missing"
    fi
else
    check "FAIL" "Release workflow exists" ".github/workflows/release.yml not found"
    check "FAIL" "Release workflow permissions" "no workflow file"
fi

# ---------------------------------------------------------------------------
# 7. No lightweight version tags
# ---------------------------------------------------------------------------
echo ""
echo "Tag integrity:"
lightweight_tags=0
while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    tagname="${ref##*/}"
    objtype=$(git cat-file -t "$ref" 2>/dev/null || echo "unknown")
    if [[ "$objtype" != "tag" ]]; then
        ((lightweight_tags++)) || true
    fi
done < <(git for-each-ref --format='%(refname)' 'refs/tags/v*' 2>/dev/null)

if ((lightweight_tags == 0)); then
    check "PASS" "No lightweight version tags"
else
    check "FAIL" "No lightweight version tags" "${lightweight_tags} lightweight tag(s) found"
fi

# ---------------------------------------------------------------------------
# 8. Git signing configured
# ---------------------------------------------------------------------------
echo ""
echo "Signing:"
signing_key=$(git config user.signingkey 2>/dev/null || true)
gpg_format=$(git config gpg.format 2>/dev/null || true)
if [[ -n "$signing_key" ]] || [[ -n "$gpg_format" ]]; then
    detail=""
    [[ -n "$gpg_format" ]] && detail="format=$gpg_format"
    [[ -n "$signing_key" ]] && detail="${detail:+$detail, }key configured"
    check "PASS" "Git signing configured" "$detail"
else
    check "FAIL" "Git signing configured" "no signingkey or gpg.format set"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================"
total=$((pass_count + fail_count + warn_count))
echo "Results: ${pass_count} passed, ${fail_count} failed, ${warn_count} warnings (${total} checks)"
echo ""
if ((fail_count == 0)); then
    echo "OVERALL: PASS"
    exit 0
else
    echo "OVERALL: FAIL"
    exit 1
fi
