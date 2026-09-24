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
                # A "private": true package.json is local tooling, not a
                # publishable release surface — its version never tracks the
                # release and would fail the sync check on every run.
                if [[ "$path" == package.json || "$path" == package-lock.json ]] \
                    && [[ -f package.json ]] \
                    && grep -qE '"private"[[:space:]]*:[[:space:]]*true' package.json; then
                    continue
                fi
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
# 1b. Version files ahead of the latest tag (phantom / untagged release)
# ---------------------------------------------------------------------------
# A "chore: release X.Y.Z" commit that was merged but never tagged leaves the
# version files ahead of the newest tag — the prepared release silently never
# shipped (e.g. its tag-triggered workflow was cancelled). Surface it so the
# releaser decides deliberately whether to tag it or roll it into the next
# version.
if ((${#versions[@]} > 0)); then
    # Highest file version, semver-sorted — when files are out of sync the
    # sync check above already FAILed; comparing the highest against the tag
    # still yields the correct "a prepared release was never tagged" signal.
    file_version=$(printf '%s\n' "${versions[@]}" | sort -uV | tail -1)
    latest_tag=$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1)
    if [[ -n "$latest_tag" && "v${file_version}" != "$latest_tag" ]]; then
        if [[ "$(printf '%s\n' "${latest_tag#v}" "$file_version" | sort -V | tail -1)" == "$file_version" ]]; then
            check "WARN" "Version files ahead of latest tag" \
                "files say ${file_version}, newest tag is ${latest_tag} — a prepared release was never tagged"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2. CHANGELOG.md has [Unreleased] section with content
# ---------------------------------------------------------------------------
echo ""
echo "Changelog:"
if [[ -f CHANGELOG.md ]]; then
    if grep -qiE '^#+ *\[?Unreleased\]?' CHANGELOG.md; then
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
    # Grade every run of the commit that gets tagged (HEAD) on this branch.
    # An unpinned `gh run list --limit 1` returns the newest run of any
    # workflow on any branch, so a green feature branch passed a red main.
    head_sha=$(git rev-parse HEAD 2>/dev/null || true)
    ci_limit=500
    ok='(.conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral")'
    if ci_summary=$(gh run list --branch "$current_branch" --commit "$head_sha" --limit "$ci_limit" \
            --json workflowName,status,conclusion \
            --jq "[length,
                   ([.[] | select(.status != \"completed\")] | length),
                   ([.[] | select(.status == \"completed\" and ($ok | not))
                         | .workflowName + \"=\" + .conclusion] | join(\", \"))] | @tsv" \
            2>/dev/null); then
        IFS=$'\t' read -r ci_total ci_pending ci_failed <<<"$ci_summary"
        where="${head_sha:0:7} on ${current_branch}"
        if [[ -n "$ci_failed" ]]; then
            check "FAIL" "CI checks passing" "${where}: ${ci_failed}"
        elif [[ "${ci_total:-0}" == 0 ]]; then
            check "WARN" "CI checks passing" "no workflow runs for ${where} — pushed yet?"
        elif [[ "$ci_pending" != 0 ]]; then
            check "WARN" "CI checks passing" "${ci_pending} of ${ci_total} run(s) for ${where} not finished"
        elif (( ci_total >= ci_limit )); then
            # The list may be cut at the limit, so an unseen run could be red.
            check "WARN" "CI checks passing" "${ci_total} run(s) for ${where} — list may be truncated at ${ci_limit}"
        else
            check "PASS" "CI checks passing" "${ci_total} run(s) for ${where}"
        fi
    else
        check "WARN" "CI checks passing" "run lookup failed for ${current_branch}@${head_sha:0:7}"
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
    if grep -qE 'id-token[[:space:]]*:[[:space:]]*write' .github/workflows/release.yml 2>/dev/null; then
        has_id_token=true
    fi
    if grep -qE 'attestations[[:space:]]*:[[:space:]]*write' .github/workflows/release.yml 2>/dev/null; then
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
