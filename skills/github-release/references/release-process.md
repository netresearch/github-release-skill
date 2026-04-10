# Release Process

## Overview

The complete flow from "create a release" to "release published on GitHub."

## Why `gh release create` Is Forbidden

`gh release create` does the following harmful things:

1. **Creates a lightweight tag** if the tag doesn't exist — lightweight tags have no signature, no author metadata, and cannot be retroactively converted to annotated tags.
2. **Burns the tag name permanently** — since GitHub immutable releases (GA Oct 2025), once a release uses a tag name, that name can never be reused. Not even `gh release delete` followed by `git push --delete origin vX.Y.Z` recovers it. GitHub returns: `"tag_name was used by an immutable release"`.
3. **Bypasses CI** — no provenance attestation, no SBOM, no artifact signing. The release is created directly with whatever you attach manually.
4. **Skips version file bumps** — source code still shows the old version.

The hooks in this repository block `gh release create`, `gh release delete`, and `gh release edit` to prevent these outcomes.

## The Correct Release Flow

### Phase 1: Preparation

```
1. Detect ecosystem (see ecosystem-detection.md)
2. Determine next version number:
   - From conventional commits (feat → minor, fix → patch, BREAKING CHANGE → major)
   - From explicit user input ("bump to 2.0.0")
3. Create release branch:
   git checkout -b release/vX.Y.Z
4. Bump all version files for the detected ecosystem
5. Update CHANGELOG.md with new section
6. Commit: "chore: prepare release vX.Y.Z"
7. Push branch and open PR
```

### Phase 2: Review and Merge

```
1. PR passes CI checks (lint, test, build)
2. Reviewer approves version bumps and changelog
3. PR is merged to main (squash or merge commit per project convention)
```

### Phase 3: Tag Creation

After the PR is merged into main:

```
1. git checkout main && git pull
2. git tag -s vX.Y.Z -m "vX.Y.Z"
3. git push origin vX.Y.Z
```

The tag MUST be:
- **Annotated** (`-a` or `-s`), never lightweight
- **Signed** (`-s` for GPG/SSH signing) — required for SLSA L1+
- **On the merge commit** — not on the branch, not on an older commit

### Phase 4: CI Release Workflow

The tag push triggers the release workflow (e.g., `.github/workflows/release.yml`):

```
1. CI creates a DRAFT release (not published)
2. CI builds artifacts (binaries, archives, etc.)
3. CI generates SBOM (SPDX or CycloneDX)
4. CI creates provenance attestation (SLSA)
5. CI signs artifacts with Sigstore/cosign
6. CI attaches all artifacts to the draft release
```

### Phase 5: Publish

The draft release is reviewed and published by a human:

```
1. Navigate to GitHub Releases page
2. Review the draft: changelog, artifacts, attestations
3. Click "Publish release"
4. Immutability locks in — the release is now permanent
```

## Draft-First Pattern

Always create releases as drafts first. This is critical because:

- **Immutability is irreversible** — once published, the release (and its tag name) are locked forever
- **Artifacts can be verified** before the release goes public
- **Changelog can be reviewed** for accuracy
- **If CI fails**, the draft can be deleted and recreated without burning the tag name (drafts are not yet immutable)

## When Publish Fails

If the CI workflow creates the draft but something goes wrong:

1. **Workflow failed mid-run**: Re-run the workflow. The draft release may already exist; the workflow should handle idempotent creation.
2. **Artifacts are wrong**: Delete the draft release (safe — drafts are not immutable), fix the issue, re-run.
3. **Everything looks correct but user needs to publish**: Direct the user to the GitHub Releases page. The skill cannot publish on behalf of the user — this is an intentional human gate.

## Version Tag Format

- Always use `v` prefix: `v1.0.0`, `v2.3.1`
- Follow SemVer 2.0.0: `vMAJOR.MINOR.PATCH`
- Pre-releases: `v1.0.0-rc.1`, `v2.0.0-beta.3`
- No build metadata in tags (build metadata is not sortable)
