# GitHub Immutable Releases

## What Are Immutable Releases?

GitHub immutable releases became generally available in October 2025. Once a release is **published**, it becomes permanently immutable:

- The release **cannot be deleted**
- The release **cannot be edited** (title, body, assets are locked)
- The associated **tag name is permanently burned**

Immutability applies to all repositories on GitHub.com and GitHub Enterprise Cloud. Self-hosted GitHub Enterprise Server may have different behavior depending on version.

## When Does Immutability Take Effect?

| Release State | Mutable? | Tag Name Burned? |
|--------------|----------|-----------------|
| **Draft** | Yes — can edit, delete, change assets | No — tag name is reserved but not burned |
| **Published** | No — fully immutable | Yes — permanently, no recovery |
| **Pre-release** (published) | No — fully immutable | Yes — permanently, no recovery |

Key distinction: **draft releases are still mutable**. This is why the draft-first pattern is critical.

## Tag Name Burning

When a release is published against a tag name, that tag name is **permanently consumed**. This is the most dangerous aspect of immutable releases.

### What "burned" means

- The tag name (e.g., `v1.0.0`) can never be used for another release on this repository
- Deleting the Git tag (`git push --delete origin v1.0.0`) does not free the name
- Deleting the release (if it were possible) would not free the name
- **GitHub Support cannot recover burned tag names** — this is by design for supply chain integrity

### The error message

When you attempt to create a release with a burned tag name:

```
422 Validation Failed: tag_name was used by an immutable release and cannot be reused
```

This error is permanent and unrecoverable for that tag name in that repository.

### How tag names get burned accidentally

1. **`gh release create v1.0.0`** — creates a lightweight tag AND publishes immediately (not as draft). The tag name is instantly burned.
2. **Publishing too early** — clicking "Publish" on a draft before verifying contents. Once published, there is no "unpublish."
3. **CI workflow that auto-publishes** — if the workflow creates a non-draft release, the tag is burned on first run. A failed re-run cannot reuse it.

## Why `gh release delete` Doesn't Fix It

`gh release delete` can only delete **draft** releases. Published releases cannot be deleted due to immutability. Even if you could delete the release object, the tag name remains burned — the burning is tied to the publication event, not the release object's existence.

## The Only Recovery: New Version Number

If a tag name is burned (whether by accident or by a flawed release):

1. **Accept the loss** — `v1.0.0` is gone forever for this repository
2. **Bump to the next version** — release as `v1.0.1` (or `v1.1.0` depending on the situation)
3. **Document the skip** — note in CHANGELOG.md that a version was skipped and why
4. **Fix the process** — ensure CI uses draft-first pattern to prevent recurrence

See `recovery-procedures.md` for detailed recovery steps.

## Implications for Release Workflows

### Do

- Always create releases as **drafts** first
- Use CI to create draft releases — humans publish after review
- Use signed annotated tags (`git tag -s`) — they carry author and signature metadata
- Test the full release workflow on a non-production repository first

### Do Not

- Never use `gh release create` without `--draft` flag (and even then, prefer CI)
- Never auto-publish releases in CI — always leave as draft for human review
- Never delete and recreate tags expecting to reuse the name
- Never assume a failed release can be "retried" with the same version number

## When Moving a Tag IS Safe

Tag-name burning is tied to **release publication**, not to the tag push itself. A tag pushed to the remote is *not* automatically burned. Burning happens only when `gh release create` (or the equivalent REST/GraphQL API call, or the Release workflow's create-release step) actually creates the release object.

This means: **if a release workflow fails before the create-release step runs** — e.g., a broken reusable-workflow reference, a failing build, a failing SBOM step, a failing signing step — the tag name is still available to re-use. The workflow never reached the publication event, so the tag name is not burned.

### Verify before moving

Always confirm the tag name is not burned before deleting and re-pushing:

```bash
gh release view vX.Y.Z
```

- Output of `release not found` (exit 1) → the tag name is **unburned** and safe to move.
- Any other output, including a draft or published release → the tag name is **burned**. Do not move it; bump the version instead (see "The Only Recovery" above).

### Safe move flow

If `gh release view` reports "release not found" and the tag needs to point at a corrected commit (typically the fix for whatever broke the workflow):

```bash
# 1. Delete the local tag
git tag -d vX.Y.Z

# 2. Delete the remote tag (pushing an empty ref)
git push origin :vX.Y.Z

# 3. Re-create the signed annotated tag at the corrected commit
git tag -s vX.Y.Z -m "vX.Y.Z" <new-sha>

# 4. Push the tag — this re-triggers the release workflow
git push origin vX.Y.Z
```

The re-push triggers the release workflow again against the corrected commit. If the workflow now succeeds, it creates the release and the tag name is burned from that point forward.

### Hard rule

**Never move a tag after a successful release.** Once `gh release view vX.Y.Z` returns any release object (draft or published), the tag name is off-limits. See "The Only Recovery: New Version Number" above.

### Real-world example: t3x-nr-vault v0.5.0

A production release session hit this exact situation:

1. Version bump PR merged on `main`.
2. Signed tag `v0.5.0` pushed.
3. Release workflow failed immediately with "workflow file not found" — the release.yml referenced `netresearch/skill-repo-skill/.github/workflows/slsa-provenance.yml@<sha>` but that file had been consolidated into `release.yml` upstream.
4. Verification step:
   ```bash
   $ gh release view v0.5.0
   release not found
   ```
5. Because the workflow never reached the create-release step, the tag name was unburned. Safe move flow applied: `git tag -d v0.5.0 && git push origin :v0.5.0`, fix the release.yml reference on main, re-sign `v0.5.0` at the fix commit, re-push.
6. Workflow succeeded on the re-push. `v0.5.0` was published — from that point forward the tag name is burned, as expected.

The mechanical checkpoint `GR-12` (`validate-reusable-workflows.sh`) catches this class of failure before the tag is ever pushed.

## Timeline

| Date | Event |
|------|-------|
| 2025-06 | Immutable releases announced in beta |
| 2025-10 | General availability — all repos affected |
| 2025-10+ | Tag name burning enforced retroactively on all published releases |
