#!/usr/bin/env bash
#
# validate-reusable-workflows.sh - Verify reusable workflow refs in release
# workflows actually resolve at their pinned SHA/ref.
#
# Motivation: When an upstream meta-package consolidates or removes a reusable
# workflow (e.g., `slsa-provenance.yml` gets merged into `release.yml`), the
# downstream caller silently keeps pointing at a file that no longer exists at
# the pinned ref. GitHub surfaces this only when a tag is pushed and the
# Release workflow tries to resolve the `uses:` reference — at which point the
# tag name may already be committed to main and the release is blocked.
#
# This script parses every `uses: <owner>/<repo>/.github/workflows/<file>.yml@<ref>`
# reference in `.github/workflows/release*.yml` and does a HEAD request against
# the raw.githubusercontent.com URL for that file at that ref. A 404 indicates
# the reusable workflow no longer exists at the pinned ref.
#
# Exits:
#   0 - all references resolve
#   1 - one or more references returned 404 (or another non-2xx)
#   2 - missing curl / other environment error
#
# Usage:
#   scripts/validate-reusable-workflows.sh
#
# The script only scans `.github/workflows/release*.yml` by default. Override
# with the WORKFLOW_GLOB env var.
#
set -euo pipefail

WORKFLOW_GLOB="${WORKFLOW_GLOB:-.github/workflows/release*.yml}"

if ! command -v curl >/dev/null 2>&1; then
    echo "error: curl not found; cannot verify reusable workflow refs" >&2
    exit 2
fi

# Collect matching workflow files (nullglob-style: no files -> empty list, no error)
shopt -s nullglob
files=( $WORKFLOW_GLOB )
shopt -u nullglob

if (( ${#files[@]} == 0 )); then
    # No release workflows to check — nothing to validate, treat as pass.
    exit 0
fi

declare -a failures=()
declare -a checked=()

check_ref() {
    local workflow_file="$1" owner="$2" repo="$3" path="$4" ref="$5"
    local url="https://raw.githubusercontent.com/${owner}/${repo}/${ref}/${path}"
    local http_code

    # -s silent, -o /dev/null discard body, -w status, -L follow redirects,
    # --max-time 15 cap latency, -I HEAD (some CDNs serve 405 on HEAD -> fall back)
    http_code=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 15 -I "$url" 2>/dev/null || echo "000")
    if [[ "$http_code" == "405" || "$http_code" == "000" ]]; then
        http_code=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || echo "000")
    fi

    checked+=( "${owner}/${repo}/${path}@${ref}" )
    if [[ "$http_code" == "200" ]]; then
        printf "  OK    %s (in %s)\n" "${owner}/${repo}/${path}@${ref}" "$workflow_file"
    else
        printf "  FAIL  %s (in %s) -> HTTP %s\n" "${owner}/${repo}/${path}@${ref}" "$workflow_file" "$http_code"
        failures+=( "${workflow_file}|${owner}/${repo}/${path}@${ref}|${http_code}" )
    fi
}

echo "Reusable workflow reference validation"
echo "======================================"

for wf in "${files[@]}"; do
    [[ -f "$wf" ]] || continue

    # Strip comments and read line-by-line. We match patterns like:
    #   uses: owner/repo/.github/workflows/file.yml@ref
    #   uses: 'owner/repo/.github/workflows/file.yml@ref'
    # Spaces, quotes, and indentation are tolerated.
    while IFS= read -r line; do
        # Strip leading whitespace + optional leading `-`
        stripped="${line#"${line%%[![:space:]]*}"}"
        # Skip comments and empties
        [[ -z "$stripped" || "$stripped" == \#* ]] && continue

        # Only lines that contain "uses:"
        [[ "$stripped" != uses:* ]] && continue

        # Extract the value after uses:
        value="${stripped#uses:}"
        # Trim leading spaces and surrounding quotes
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        # Drop inline comments
        value="${value%%#*}"
        value="${value%"${value##*[![:space:]]}"}"

        # Match owner/repo/.github/workflows/FILE.yml@REF
        if [[ "$value" =~ ^([^/]+)/([^/]+)/\.github/workflows/([^@]+)@(.+)$ ]]; then
            owner="${BASH_REMATCH[1]}"
            repo="${BASH_REMATCH[2]}"
            path=".github/workflows/${BASH_REMATCH[3]}"
            ref="${BASH_REMATCH[4]}"
            check_ref "$wf" "$owner" "$repo" "$path" "$ref"
        fi
    done < "$wf"
done

echo ""
if (( ${#checked[@]} == 0 )); then
    echo "No reusable workflow references found in: ${WORKFLOW_GLOB}"
    exit 0
fi

if (( ${#failures[@]} == 0 )); then
    echo "All ${#checked[@]} reusable workflow reference(s) resolve."
    exit 0
fi

echo "FAIL: ${#failures[@]} of ${#checked[@]} reference(s) did not resolve:"
for f in "${failures[@]}"; do
    wf="${f%%|*}"; rest="${f#*|}"
    ref_str="${rest%|*}"; code="${rest##*|}"
    echo "  - ${ref_str} (HTTP ${code}) in ${wf}"
done
echo ""
echo "Remediation: update the ref to a commit/tag where the file exists, or"
echo "remove the job if the upstream workflow has been consolidated."
exit 1
