# Release Process

## Overview

The complete flow from "create a release" to "release published on GitHub."

## Why `gh release create` Is Forbidden

`gh release create` does the following harmful things:

1. **Creates a lightweight tag** if the tag doesn't exist — lightweight tags have no signature, no author metadata, and cannot be retroactively converted to annotated tags.
2. **Burns the tag name permanently** — since GitHub immutable releases (GA Oct 2025), once a release uses a tag name, that name can never be reused. Not even `gh release delete` followed by `git push --delete origin vX.Y.Z` recovers it. GitHub returns: `"tag_name was used by an immutable release"`.
3. **Bypasses CI** — no provenance attestation, no SBOM, no artifact signing. The release is created directly with whatever you attach manually.
4. **Skips version file bumps** — source code still shows the old version.

The hooks in this repository block `gh release create` and `gh release delete` to prevent these outcomes. `gh release edit` is allowed only for `--notes`/`--notes-file` flags (release description overhaul).

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
1. CI validates version tag matches version files
2. CI builds artifacts (binaries, archives, etc.)
3. CI generates checksums (SHA256SUMS.txt)
4. CI generates SBOM if configured (SPDX or CycloneDX)
5. CI creates provenance attestation if configured (SLSA)
6. CI publishes the GitHub Release with all artifacts and auto-generated release notes
```

### Phase 5: Release Description Overhaul

After CI publishes the release, the agent overhauls the auto-generated description into a narrative format:

```
1. Wait for CI release workflow to complete successfully
2. Review the commits included in the release (git log prev_tag..new_tag)
3. Write a narrative release description covering:
   - What changed and why it matters
   - Context for skipped versions or notable decisions
   - Grouped by theme (features, fixes, infrastructure), not by commit
4. Update via: gh release edit vX.Y.Z --notes "..."
```

The auto-generated notes (PR titles, contributor lists) are a starting point, not the final product. The agent's description should read like a changelog entry written for humans.

## When CI Fails

If the release workflow fails:

1. **Workflow failed mid-run**: Re-run the workflow. If a release already exists, the workflow should handle idempotent creation.
2. **Artifacts are wrong**: Fix the issue and re-run the workflow.
3. **Startup failure**: Check that the caller workflow grants all permissions required by the reusable workflow (e.g., `contents: write`, `pull-requests: write`).

## Version Tag Format

- Always use `v` prefix: `v1.0.0`, `v2.3.1`
- Follow SemVer 2.0.0: `vMAJOR.MINOR.PATCH`
- Pre-releases: `v1.0.0-rc.1`, `v2.0.0-beta.3`
- No build metadata in tags (build metadata is not sortable)
