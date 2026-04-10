#!/usr/bin/env bash
#
# check-release-workflow.sh - Check if the project has a proper release workflow.
#
# Examines .github/workflows/release.yml for required features and reports
# PRESENT/MISSING per item.
#
set -euo pipefail

WORKFLOW=".github/workflows/release.yml"

present_count=0
missing_count=0

report() {
    local status="$1" label="$2" detail="${3:-}"
    if [[ "$status" == "PRESENT" ]]; then
        ((present_count++)) || true
        printf "  PRESENT  %s" "$label"
    else
        ((missing_count++)) || true
        printf "  MISSING  %s" "$label"
    fi
    if [[ -n "$detail" ]]; then
        printf " (%s)" "$detail"
    fi
    printf "\n"
}

echo "Release workflow analysis"
echo "========================="
echo ""

# ---------------------------------------------------------------------------
# 1. Workflow file exists
# ---------------------------------------------------------------------------
if [[ ! -f "$WORKFLOW" ]]; then
    report "MISSING" "Release workflow file" "$WORKFLOW not found"
    echo ""
    echo "========================="
    echo "Results: 0 present, 1 missing"
    echo ""
    echo "OVERALL: No release workflow found"
    exit 1
fi

report "PRESENT" "Release workflow file" "$WORKFLOW"
workflow_content=$(cat "$WORKFLOW")

# ---------------------------------------------------------------------------
# 2. Triggers on push tags v*
# ---------------------------------------------------------------------------
echo ""
echo "Triggers:"
if echo "$workflow_content" | grep -qE "tags:[[:space:]]*\[?['\"]?v\*" 2>/dev/null || \
   echo "$workflow_content" | grep -qE "^[[:space:]]+-[[:space:]]+['\"]?v\*" 2>/dev/null; then
    report "PRESENT" "Push tag trigger (v*)"
else
    report "MISSING" "Push tag trigger (v*)"
fi

if echo "$workflow_content" | grep -q 'workflow_dispatch' 2>/dev/null; then
    report "PRESENT" "workflow_dispatch trigger"
else
    report "MISSING" "workflow_dispatch trigger"
fi

# ---------------------------------------------------------------------------
# 3. Permissions
# ---------------------------------------------------------------------------
echo ""
echo "Permissions:"
if echo "$workflow_content" | grep -qE 'id-token[[:space:]]*:[[:space:]]*write' 2>/dev/null; then
    report "PRESENT" "id-token: write"
else
    report "MISSING" "id-token: write"
fi

if echo "$workflow_content" | grep -qE 'attestations[[:space:]]*:[[:space:]]*write' 2>/dev/null; then
    report "PRESENT" "attestations: write"
else
    report "MISSING" "attestations: write"
fi

if echo "$workflow_content" | grep -qE 'contents[[:space:]]*:[[:space:]]*write' 2>/dev/null; then
    report "PRESENT" "contents: write"
else
    report "MISSING" "contents: write"
fi

# ---------------------------------------------------------------------------
# 4. Reusable workflows
# ---------------------------------------------------------------------------
echo ""
echo "Reusable workflows:"
if echo "$workflow_content" | grep -qE 'netresearch/typo3-ci-workflows' 2>/dev/null; then
    report "PRESENT" "netresearch/typo3-ci-workflows"
elif echo "$workflow_content" | grep -qE 'netresearch/\.github' 2>/dev/null; then
    report "PRESENT" "netresearch/.github reusable workflows"
else
    report "MISSING" "Netresearch reusable workflows" "netresearch/typo3-ci-workflows or netresearch/.github"
fi

# ---------------------------------------------------------------------------
# 5. SBOM generation
# ---------------------------------------------------------------------------
echo ""
echo "Supply chain security:"
if echo "$workflow_content" | grep -qE 'anchore/sbom-action|syft|cyclonedx|spdx' 2>/dev/null; then
    match=$(echo "$workflow_content" | grep -oE 'anchore/sbom-action|syft|cyclonedx|spdx' | head -1)
    report "PRESENT" "SBOM generation" "$match"
else
    report "MISSING" "SBOM generation" "anchore/sbom-action or similar"
fi

# ---------------------------------------------------------------------------
# 6. Signing
# ---------------------------------------------------------------------------
if echo "$workflow_content" | grep -qE 'cosign-installer|cosign|sigstore' 2>/dev/null; then
    match=$(echo "$workflow_content" | grep -oE 'cosign-installer|cosign|sigstore' | head -1)
    report "PRESENT" "Signing" "$match"
else
    report "MISSING" "Signing" "cosign-installer or similar"
fi

# ---------------------------------------------------------------------------
# 7. Attestation
# ---------------------------------------------------------------------------
if echo "$workflow_content" | grep -qE 'actions/attest-build-provenance|actions/attest' 2>/dev/null; then
    match=$(echo "$workflow_content" | grep -oE 'actions/attest-build-provenance|actions/attest' | head -1)
    report "PRESENT" "Attestation" "$match"
else
    report "MISSING" "Attestation" "actions/attest-build-provenance or similar"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================="
total=$((present_count + missing_count))
echo "Results: ${present_count} present, ${missing_count} missing (${total} checks)"
