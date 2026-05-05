# Supply Chain Security

## Overview

Modern releases require more than just a tarball. Supply chain security ensures consumers can verify the provenance, integrity, and composition of released artifacts. This reference covers the key components; delegate detailed implementation to the `enterprise-readiness` skill.

## SLSA Provenance Levels

[SLSA](https://slsa.dev/) (Supply-chain Levels for Software Artifacts) defines four levels of increasing assurance:

| Level | Requirements | What It Proves |
|-------|-------------|---------------|
| **L0** | No provenance | Nothing — the default |
| **L1** | Provenance exists and is signed | The build process generated provenance metadata |
| **L2** | Hosted build service, signed provenance | A specific build service produced the artifact |
| **L3** | Hardened build platform, non-falsifiable provenance | The build was isolated and tamper-resistant |

### GitHub Actions and SLSA

GitHub Actions natively supports SLSA L1 via `actions/attest-build-provenance`. L2+ requires the [slsa-framework/slsa-github-generator](https://github.com/slsa-framework/slsa-github-generator) reusable workflows that run in isolated, hardened runners.

## Sigstore / Cosign Keyless Signing

[Sigstore](https://sigstore.dev/) enables keyless signing — no long-lived signing keys to manage.

### How it works

1. CI authenticates via OIDC (GitHub Actions identity token)
2. Sigstore issues a short-lived certificate bound to the workflow identity
3. The artifact is signed with the ephemeral key
4. The signature and certificate are recorded in the Rekor transparency log
5. Consumers verify against the transparency log — no key distribution needed

### Signing in CI

```yaml
- uses: sigstore/cosign-installer@v3
- run: |
    cosign sign-blob --yes \
      --oidc-issuer https://token.actions.githubusercontent.com \
      --bundle artifact.tar.gz.sigstore.json \
      artifact.tar.gz
```

### Output extension matters for OSSF Scorecard

**Use `.sigstore.json` for the cosign bundle output, NOT cosign's default `.bundle`.**

OSSF Scorecard's [Signed-Releases](https://github.com/ossf/scorecard/blob/main/docs/checks.md#signed-releases) check pattern-matches release-asset filenames against a fixed allowlist of signature extensions:

- `.sig`
- `.asc`
- `.minisig`
- `.sigstore`
- `.sigstore.json`
- `.intoto.jsonl`

The `.bundle` extension that `cosign sign-blob --bundle` writes by default is **not** on that list, so cosign-signed releases that use `.bundle` are reported as unsigned (`Signed-Releases` score `0/10`).

**The bytes inside the file are identical** — cosign's bundle format IS the Sigstore bundle JSON. Only the filename matters for tooling detection. `cosign verify-blob --bundle file.sigstore.json` works exactly the same as `--bundle file.bundle`.

**Concrete fix in a workflow:**

```yaml
# Wrong — Scorecard sees this as unsigned
cosign sign-blob --yes "$file" --bundle "${file}.bundle"

# Right — Scorecard recognizes this as signed
cosign sign-blob --yes "$file" --bundle "${file}.sigstore.json"
```

**Past releases cannot be retroactively fixed.** GitHub releases are immutable once assets are attached, so renaming or replacing assets on already-published releases is not possible. Only future releases benefit from the fix. Scorecard averages the Signed-Releases score over the **last 4 releases**, so the score climbs gradually as new releases ship.

Reference upstream change for the netresearch shared workflows: [netresearch/typo3-ci-workflows#84](https://github.com/netresearch/typo3-ci-workflows/pull/84) — applied to both `release.yml` and `release-typo3-extension.yml`.

### Verification

```bash
cosign verify-blob \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "github.com/org/repo" \
  --bundle artifact.tar.gz.sigstore.json \
  artifact.tar.gz
```

## GitHub Artifact Attestations

GitHub's native attestation system using `actions/attest@v4`:

```yaml
- uses: actions/attest-build-provenance@v2
  with:
    subject-path: dist/*.tar.gz

- uses: actions/attest-sbom@v2
  with:
    subject-path: dist/*.tar.gz
    sbom-path: sbom.spdx.json
```

### Verification

```bash
gh attestation verify artifact.tar.gz --owner org-name
```

This checks the Sigstore transparency log for attestations matching the artifact digest and the expected source repository.

## SBOM Generation

Software Bill of Materials (SBOM) documents all components in a release.

### Formats

| Format | Standard | Tooling |
|--------|----------|---------|
| **SPDX** | ISO/IEC 5962:2021 | `anchore/sbom-action`, `syft` |
| **CycloneDX** | OWASP standard | `anchore/sbom-action`, `cdxgen` |

### Generation in CI

```yaml
- uses: anchore/sbom-action@v0
  with:
    format: spdx-json
    output-file: sbom.spdx.json
    artifact-name: sbom
```

### What SBOMs contain

- All direct and transitive dependencies with versions
- Package URLs (purls) for each component
- License information per component
- Relationship graph (dependency tree)

## Required Workflow Permissions

Release workflows need specific permissions for attestation and signing:

```yaml
permissions:
  contents: write        # Create releases, push tags
  id-token: write        # OIDC token for Sigstore keyless signing
  attestations: write    # GitHub artifact attestations
  packages: write        # Container registry (if applicable)
```

**Security note**: These permissions should only be granted to the release workflow, not to all workflows. Use `permissions` at the job level, not the workflow level, to minimize exposure.

## Verification Commands Reference

| What to Verify | Command |
|----------------|---------|
| GitHub attestation | `gh attestation verify <artifact> --owner <org>` |
| Cosign blob signature | `cosign verify-blob --certificate-oidc-issuer <issuer> --certificate-identity-regexp <pattern> <artifact>` |
| Container signature | `cosign verify <image> --certificate-oidc-issuer <issuer> --certificate-identity-regexp <pattern>` |
| SBOM contents | `syft <artifact>` or `grype sbom:sbom.spdx.json` (for vulnerability scan) |
| SLSA provenance | `slsa-verifier verify-artifact <artifact> --source-uri github.com/org/repo` |

## Delegation

For detailed implementation of supply chain security measures, delegate to the `enterprise-readiness` skill which covers:

- Full SLSA compliance assessment and remediation
- Sigstore integration setup
- SBOM pipeline configuration
- OpenSSF Scorecard and Best Practices Badge
