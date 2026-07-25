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

**GitHub is only half the picture.** Moving a tag is safe only when no
package registry has consumed it — see "Wrong tag already pushed:
registries publish on tag push" below before applying the safe move flow.

### Verify before moving

Always confirm the tag name is not burned before deleting and re-pushing.
Burning is tied to **publication** — a draft release does *not* burn the tag
name, so the check has to distinguish draft from published.

The safest programmatic check uses `--json isDraft`:

```bash
STATE=$(gh release view "vX.Y.Z" --json isDraft 2>/dev/null || echo "notfound")
if [[ "$STATE" == "notfound" ]] || [[ "$STATE" == *'"isDraft":true'* ]]; then
    echo "Safe to move (no release OR draft only — tag name not burned)"
else
    echo "BURNED — release is published; bump the version instead"
fi
```

Interpretation:

- `notfound` (gh returns non-zero, typically "release not found") → the tag
  name is **unburned** and safe to move.
- `{"isDraft":true}` → a **draft** release exists. The tag name is
  **unburned** (GitHub reserves the name but does not lock it until
  publication), so the tag is still safe to move. If you do move it, delete
  the stale draft first (`gh release delete vX.Y.Z`) so the re-triggered
  workflow can recreate it cleanly.
- `{"isDraft":false}` → a **published** release exists. The tag name is
  **burned**. Do not move it; bump the version instead (see "The Only
  Recovery" above).

### Wrong tag already pushed: registries publish on tag push

A pushed `v*` tag must be treated as **published immediately**, regardless
of what GitHub shows. Package registries (Packagist, TER) consume the tag
push via webhook within seconds — a failed or never-started GitHub release
workflow proves nothing about whether the version is already live
downstream. Deleting and re-tagging "a minute later" is already too late.

- **NEVER delete + re-tag a version that might be on a registry.** Check
  Packagist explicitly before any move:

  ```bash
  # 200 = published on Packagist; 404 = absent (use lowercase names)
  curl -s -o /dev/null -w '%{http_code}' \
    https://repo.packagist.org/p2/vendor/package.json
  ```

  A consumer installing the package via a `repositories` VCS entry in its
  `composer.json` does NOT mean the package is absent from Packagist —
  verify against the registry, never infer from consumer configuration.
- **Packagist stable versions are immutable.** After a delete + re-tag,
  Packagist keeps serving the original ref and sends maintainers an
  "attempted update blocked" warning — the moved tag silently diverges
  from what consumers actually install.
- **Recovery is fix-forward.** Tag the NEXT patch version with the
  intended content. Only restore the bad tag — pointed at the exact ref
  the registry serves — if the registry requests it (Packagist does: it
  expects the tag to keep matching the version it already serves).
- **When pushing such a restore tag**: disable the release workflow first
  (`gh workflow disable release.yml`), push the tag, and expect a queued
  tag event to spawn a run anyway — cancel that run before it publishes
  artifacts from the old commit, then re-enable the workflow.

Real incident (a netresearch extension release): a tag was pushed from a
stale local `main`, then deleted and re-tagged about one minute later —
but the Packagist webhook had already published the bad ref. Recovery
required shipping a fix-forward patch release, then restoring the
original tag to the registry-served ref under the workflow-disabled
procedure above.

### After a blocked retag: what the state actually is

The maintainer mail ("attempted update to version vX.Y.Z blocked, because a
published stable version's source/dist reference changed") describes a
*version-scoped* refusal, not a frozen package. Before planning anything,
establish these four facts.

**The block is per version — the next version still publishes.** Packagist
keeps serving the old reference for the affected version and continues to
crawl everything else, so the fix-forward release is not itself blocked.
Confirm it on the package: a tag pushed *after* the retag appears normally
(observed in `netresearch/t3x-nr-image-optimize`: `v2.4.0` stayed pinned to
the pre-retag ref while `v1.3.0`, tagged 40 minutes later, published as
usual). Do not delay the remedy waiting for the block to "clear" — it does
not clear.

**Read `repo.packagist.org/p2/`, not `packagist.org/packages/`.** The p2
endpoint is what Composer resolves against; the `packagist.org/packages/
<vendor>/<package>.json` endpoint is the UI/legacy one and lags noticeably
behind. A freshly published version can be present in p2 and simultaneously
absent from the legacy endpoint — reading the legacy one first leads
straight to a false "the fix was not picked up".

```bash
# authoritative: version → the reference Composer will install
curl -s https://repo.packagist.org/p2/vendor/package.json \
  | jq -r '.packages["vendor/package"][] | "\(.version) \(.source.reference)"' | head -5
```

**The affected version carries a permanent badge.** Its entry on the package
page renders a `retag-blocked-alert` — *"Upstream re-tag blocked — Packagist
may no longer match the VCS repo for this version"* — linking to
<https://packagist.org/about/version-immutability>. That badge is the record
of the incident; it does not go away and nothing you publish later removes
it.

**Withdrawal is a soft-delete, and it is rarely the right move.** Per the
page above, *"Maintainers can soft-delete a version they own from the package
page. Such versions are hidden from Composer metadata but still listed on the
page (grayed out), and can be recovered by the maintainer at any time."* So a
bad version can be pulled — but when the only defect is wrong metadata and
the code is identical, hiding it removes a working, installable version and
breaks every exact-version pin on it. Reserve soft-delete for versions that
ship broken or unsafe *code*; for a metadata defect, ship the next patch and
leave the old version in place. (TER has no equivalent per-version lever at
all — see `ter-republish.md`.)

### Verify the remedy the way a consumer would

Registry metadata agreeing with the tag is necessary, not sufficient — the
question is what a `composer require` actually resolves and unpacks. After
the fix-forward release, prove both ends:

```bash
# 1. resolution: does the constraint land on the new version?
mkdir -p /tmp/verify && cd /tmp/verify
printf '{"require":{},"minimum-stability":"stable"}' > composer.json
composer require --dry-run --no-interaction --ignore-platform-reqs \
  "vendor/package:^2.4"          # => "Installing vendor/package (v2.4.1)"

# 2. payload: does the artifact the registry serves carry the right metadata?
curl -sL "$(curl -s https://repo.packagist.org/p2/vendor/package.json \
  | jq -r '.packages["vendor/package"][] | select(.version=="v2.4.1") | .dist.url')" -o pkg.zip
unzip -q pkg.zip && grep -rn "'version'" */ext_emconf.php
```

Step 2 is the one that catches this class of bug: the whole incident is a
release whose *metadata inside the archive* disagreed with the version it was
published under, and only unpacking what the registry hands out shows that.

### Safe move flow

Apply this flow only when BOTH the tag name is unburned on GitHub (no
release or draft only, per the verification step) AND the version is not
on any registry (per the registry check above).

If the verification step above reports the tag name is unburned (no release
or draft only) and the tag needs to point at a corrected commit (typically
the fix for whatever broke the workflow):

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

**Never move a tag after a successful (published) release.** Once
`gh release view vX.Y.Z --json isDraft` returns `{"isDraft":false}`, the tag
name is off-limits — see "The Only Recovery: New Version Number" above. A
draft release (`{"isDraft":true}`) does *not* burn the tag name; the top of
"When Moving a Tag IS Safe" explains why, and the verification step above
tells you how to distinguish the two.

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
