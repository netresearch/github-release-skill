# CI Workflow Templates

## TYPO3 Projects

TYPO3 extensions at Netresearch use shared CI workflows:

- **Repository**: [netresearch/typo3-ci-workflows](https://github.com/netresearch/typo3-ci-workflows)
- **Usage**: Reference via `uses: netresearch/typo3-ci-workflows/.github/workflows/release.yml@main`
- These workflows handle TER upload, documentation rendering, and release creation

## Organization-Wide Workflows

Netresearch maintains org-level reusable workflows:

- **Repository**: [netresearch/.github](https://github.com/netresearch/.github)
- Contains shared release, CI, and quality workflows
- Projects should prefer org workflows over per-repo copies to reduce maintenance

## GitHub Release Only (No Package Registry)

A project installed straight from its repository (a herdr plugin, for example) publishes nothing to PyPI, npm, Packagist or TER; the release carries the tagged source tree as an archive plus a checksum file. The org `python-release.yml` covers this with `publish-pypi: false`. Pattern from [netresearch/herdr-bg-activity](https://github.com/netresearch/herdr-bg-activity/blob/main/.github/workflows/release.yml):

```yaml
on:
  push:
    tags: ['v*.*.*']

permissions: {}

jobs:
  release:
    uses: netresearch/.github/.github/workflows/python-release.yml@main
    permissions:
      contents: write
      id-token: write
    with:
      publish-pypi: false
      package-manager: pip
      # Fail before building when the tag and the manifest disagree.
      check-cmd: >-
        python -c 'import os, tomllib;
        v = tomllib.load(open("herdr-plugin.toml", "rb"))["version"];
        t = os.environ["GITHUB_REF_NAME"].removeprefix("v");
        assert v == t, f"tag {t} != herdr-plugin.toml version {v}"'
      build-cmd: >-
        mkdir -p dist &&
        git archive --format=tar.gz --prefix="my-plugin-${GITHUB_REF_NAME}/"
        -o "dist/my-plugin-${GITHUB_REF_NAME}.tar.gz" HEAD &&
        (cd dist && sha256sum -- *.tar.gz > SHA256SUMS.txt)
      release-files: 'dist/*'

  # python-release.yml uploads dist/ as the `dist` artifact but attests nothing.
  attest:
    needs: release
    uses: netresearch/.github/.github/workflows/attest-release-files.yml@main
    permissions:
      id-token: write
      attestations: write
    with:
      subject-path: 'dist/*'  # same value as release-files
```

Provenance is a separate reusable, `attest-release-files.yml`, rather than an input on `python-release.yml`: it needs `attestations: write`, and a called workflow's job permissions are checked at startup, so adding that scope to `python-release.yml` would fail every caller that does not grant it. The reusable workflow is the signer, so verification has to name it; `--repo` alone checks the signer against the caller repository and fails:

```bash
gh attestation verify <file> --repo <owner>/<repo> \
  --signer-workflow netresearch/.github/.github/workflows/attest-release-files.yml
```

## Generic Release Workflow Structure

For projects that don't use shared workflows, use this template as a starting point:

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write
  id-token: write
  attestations: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Verify tag is annotated and signed
        run: |
          TAG_TYPE=$(git cat-file -t "${GITHUB_REF_NAME}")
          if [ "$TAG_TYPE" != "tag" ]; then
            echo "::error::Tag ${GITHUB_REF_NAME} is lightweight (type: $TAG_TYPE). Only annotated tags are allowed."
            exit 1
          fi
          # Verify signature (fails if unsigned)
          git tag -v "${GITHUB_REF_NAME}" 2>/dev/null || echo "::warning::Tag signature verification failed"

      - name: Build artifacts
        run: |
          # Project-specific build steps here
          echo "Build artifacts for ${GITHUB_REF_NAME}"

      - name: Generate SBOM
        uses: anchore/sbom-action@v0
        with:
          format: spdx-json
          output-file: sbom.spdx.json
          artifact-name: sbom

      - name: Create draft release
        uses: softprops/action-gh-release@v2
        with:
          draft: true
          generate_release_notes: true
          files: |
            dist/*
            sbom.spdx.json

      - name: Attest build provenance
        uses: actions/attest-build-provenance@v2
        with:
          subject-path: dist/*

      - name: Attest SBOM
        uses: actions/attest-sbom@v2
        with:
          subject-path: dist/*
          sbom-path: sbom.spdx.json

      - name: Sign with cosign
        uses: sigstore/cosign-installer@v3
      - run: |
          for f in dist/*; do
            cosign sign-blob --yes --oidc-issuer https://token.actions.githubusercontent.com "$f" > "${f}.sig"
          done
```

## Required Permissions

| Permission | Why | Required For |
|------------|-----|-------------|
| `contents: write` | Create releases, upload assets | `softprops/action-gh-release` |
| `id-token: write` | OIDC token for Sigstore keyless signing | `cosign sign-blob`, SLSA provenance |
| `attestations: write` | GitHub artifact attestations | `actions/attest-build-provenance`, `actions/attest-sbom` |
| `packages: write` | Push to container registry | Container image releases only |

## Triggers

### Tag Push (Recommended)

```yaml
on:
  push:
    tags:
      - 'v*'
```

This triggers on any tag matching `v*` (e.g., `v1.0.0`, `v2.0.0-rc.1`). This is the recommended trigger because:
- Only signed annotated tags should be pushed (enforced by workflow verification step)
- The tag commit is the exact commit that was reviewed and merged
- No ambiguity about what is being released

### Manual Dispatch (Supplementary)

```yaml
on:
  workflow_dispatch:
    inputs:
      tag:
        description: 'Tag to release'
        required: true
```

Useful as a fallback when re-running a failed release workflow.

## Draft-First Pattern

The key line in the workflow template is:

```yaml
draft: true
```

This ensures:
1. The release is created as a draft — mutable and not yet permanent
2. Artifacts are attached to the draft for review
3. A human reviews and publishes via the GitHub UI
4. Immutability only locks in when the human clicks "Publish"

**Never set `draft: false`** in automated workflows. The publish step is an intentional human gate that prevents accidental tag burning and ensures release quality.

## Ecosystem-Specific Steps

### PHP / Composer

```yaml
- name: Validate composer.json
  run: composer validate --strict

- name: Build (if applicable)
  run: composer install --no-dev --optimize-autoloader
```

### Node.js

```yaml
- uses: actions/setup-node@v4
  with:
    node-version: 'lts/*'

- name: Build
  run: npm ci && npm run build
```

### Go

```yaml
- uses: actions/setup-go@v5
  with:
    go-version: 'stable'

- name: Build binaries
  run: |
    GOOS=linux GOARCH=amd64 go build -o dist/app-linux-amd64
    GOOS=darwin GOARCH=arm64 go build -o dist/app-darwin-arm64
```

### Rust

```yaml
- uses: dtolnay/rust-toolchain@stable

- name: Build release binary
  run: cargo build --release
```
