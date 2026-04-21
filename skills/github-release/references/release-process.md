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

#### Narrative over implementation details

Release notes are for the people deciding whether to upgrade — users, admins, integrators — not for developers reading the diff. Lead with the user-facing story, then brief feature sections.

**Don't list:**

- Internal types, DTOs, enums, service-class names
- File paths or class paths touched by the release
- i18n unit counts or translation-bundle diffs
- Refactor details that don't change behavior

**Do describe:**

- What a user can now do that they couldn't before
- The configuration levels / option values a feature exposes
- Breaking-change surfaces with migration notes

**Bad example (diff-focused):**

> - `EnforcementLevel` enum, `EnforcementStatus` DTO, `EnforcementService`, `AdoptionStatsService`
> - 47 new i18n units in `locallang_db.xlf`
> - Refactored `UserController::indexAction` into 3 helper methods

**Good example (user-focused):**

> Per-group passkey enforcement with four levels: Off, Encourage, Required, Enforced. Admins can now configure whether a group's members may log in with passwords, are nudged toward passkeys, must enroll at least one, or must use one for every sign-in.

#### `--latest=false` for non-default-branch releases

**GitHub marks the most recently *created* release as "Latest" — by timestamp, not by SemVer.**

Creating a backport release (say v11.0.17) AFTER a newer release on a higher branch (v13.5.0) steals the "Latest" badge from v13.5.0, and users who click "Latest release" then get the old major.

**Rule:** this guidance does **not** override the policy above. On repositories guarded by this skill's hooks (including every Netresearch repo with a release workflow), manual `gh release create` stays blocked — CI creates releases from signed tags, not the agent. The rest of this subsection applies only to the rare unguarded case: repos WITHOUT a release workflow, where manual `gh release create` is the only path. In that case, pass `--latest=false` for non-default-branch releases:

```bash
# Backport release on TYPO3_11 branch while main is on v13
gh release create v11.0.17 \
  --latest=false \
  --title "v11.0.17" \
  --notes "Backport: CVE-2026-XXXX fix"
```

Default-branch (highest-version) releases keep the Latest badge; backports publish without stealing it.

**For the CI-driven flow (the common case)** — the release workflow, not the agent, creates the release, so the analogous setting is `make_latest: false` on the `softprops/action-gh-release` step (or the equivalent on whatever action publishes the release). Release workflows typically trigger on tag push (`on.push.tags`), so `github.ref_name` holds the tag (e.g. `v1.2.3`), **not** a branch name — branch-name comparisons will never match on that trigger. Drive `make_latest` from an explicit source of truth instead:

```yaml
# Combined trigger: tag push (normal case) + workflow_dispatch with explicit
# tag + make_latest inputs (for manual backport publishes).
on:
  push:
    tags: ['v*']
  workflow_dispatch:
    inputs:
      tag:
        description: 'Tag to publish (must already exist)'
        required: true
      make_latest:
        type: boolean
        default: true

jobs:
  publish:
    steps:
      - uses: softprops/action-gh-release@... # pinned SHA
        with:
          # push.tags: github.ref_name IS the tag; workflow_dispatch: use the input.
          tag_name: ${{ inputs.tag || github.ref_name }}
          # push.tags defaults to latest; workflow_dispatch uses the boolean input.
          make_latest: ${{ (github.event_name == 'workflow_dispatch' && inputs.make_latest) && 'true' || (github.event_name == 'push' && 'true' || 'false') }}
```

For dispatch-only publishes (no tag-push trigger), drop the `push:` block and always use `inputs.tag` / `inputs.make_latest`. For tag-push-only workflows, drop the `workflow_dispatch:` block and always use `github.ref_name` with a fixed `make_latest` — but note that the fixed approach can't express "backport, don't steal Latest" without the dispatch input.

For repos using the shared release workflow template at `skills/github-release/templates/release-generic.yml`, file a patch there to expose a `make-latest` input rather than forking per-repo.

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
