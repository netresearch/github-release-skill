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

## Timeline

| Date | Event |
|------|-------|
| 2025-06 | Immutable releases announced in beta |
| 2025-10 | General availability — all repos affected |
| 2025-10+ | Tag name burning enforced retroactively on all published releases |
