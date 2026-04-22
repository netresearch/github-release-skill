# Recovery Procedures

## Burned Tag Name

**Symptom**: `422 Validation Failed: tag_name was used by an immutable release and cannot be reused`

**Cause**: A release was published (not draft) against this tag name. The name is permanently consumed.

**Recovery**:

1. Accept the version number is lost — there is no technical recovery
2. Determine the next appropriate version:
   - If `v1.0.0` was burned: release as `v1.0.1` (or `v1.1.0` if changes warrant)
   - If a pre-release like `v2.0.0-rc.1` was burned: use `v2.0.0-rc.2`
3. Update all version files to the new number
4. Add a CHANGELOG.md entry explaining the skip:
   ```markdown
   ## [1.0.1] - 2026-04-10
   Note: v1.0.0 was skipped due to a burned tag name from an immutable release.
   ```
5. Follow the standard release flow with the new version number
6. Fix the root cause — ensure CI uses draft-first pattern going forward

## Draft Release Stuck (CI Workflow Failed)

**Symptom**: Tag was pushed, but no draft release appeared (or draft is incomplete).

**Cause**: The CI release workflow failed or was not triggered.

**Recovery**:

1. Check workflow status:
   ```bash
   gh run list --workflow=release.yml --limit=5
   gh run view <run-id> --log-failed
   ```
2. If the workflow failed mid-run:
   ```bash
   gh run rerun <run-id>
   ```
3. If the workflow was never triggered:
   - Verify the workflow file exists and has correct `on: push: tags:` trigger
   - Verify the tag was actually pushed: `git ls-remote --tags origin | grep vX.Y.Z`
   - Manually trigger if the workflow supports `workflow_dispatch`
4. If the draft exists but is incomplete:
   - Re-run the failed workflow to re-attach artifacts
   - Or manually upload artifacts to the draft via GitHub UI
5. **User publishes**: once the draft looks correct, the user publishes via GitHub UI

**Important**: The tag is NOT burned while the release is in draft state. If the draft is fundamentally broken, you can delete it and recreate.

## Lightweight Tag Already Pushed

**Symptom**: `git cat-file -t vX.Y.Z` returns `commit` instead of `tag` (meaning it's lightweight, not annotated).

**Cause**: Someone ran `git tag vX.Y.Z` without `-s` or `-a`, or `gh release create` created it.

**Recovery if no release was published against it**:

1. Delete the remote tag:
   ```bash
   git push --delete origin vX.Y.Z
   ```
2. Delete the local tag:
   ```bash
   git tag -d vX.Y.Z
   ```
3. Create a proper signed annotated tag:
   ```bash
   git tag -s vX.Y.Z -m "vX.Y.Z"
   ```
4. Push the new tag:
   ```bash
   git push origin vX.Y.Z
   ```

**Recovery if a release WAS published**: The tag name is burned. Follow the "Burned Tag Name" procedure above.

## Missing CI Release Workflow

**Symptom**: Tags are pushed but no release is ever created.

**Cause**: The repository has no release workflow configured.

**Recovery**:

1. Check for existing workflow:
   ```bash
   ls .github/workflows/release.yml 2>/dev/null
   gh workflow list
   ```
2. If no workflow exists, scaffold one from the templates in `ci-workflow-templates.md`
3. Choose the appropriate template based on the project ecosystem
4. Commit the workflow to the default branch (it must be on `main`/`master` for tag triggers to work)
5. Test by creating a pre-release tag (e.g., `v0.0.1-test.1`)

## Version File Drift

**Symptom**: Different version files show different version numbers, or version files don't match the latest Git tag.

**Cause**: Manual edits, partial bumps, or version bumps done outside the release process.

**Detection**:

```bash
# Compare Git tags to version files
git describe --tags --abbrev=0    # Latest tag
# Then check each ecosystem's version files
```

**Recovery**:

1. Determine the canonical version:
   - If a release exists: use the released version
   - If only tags exist: use the latest tag
   - If tags and files disagree: the tag is authoritative (it's what consumers see)
2. Run ecosystem detection to identify all version files
3. Update all version files to match the canonical version
4. Commit: `fix: align version files to vX.Y.Z`
5. Do NOT create a new tag — this is a correction commit, not a release

## Release Body Clobbered After Manual Edit

**Symptom**: You edited the release description via
`gh release edit vX.Y.Z --notes-file notes.md` (overhaul step) to add a
narrative summary, then re-ran the release workflow (to fix a downstream
failure like a TER publish timeout), and the carefully-written notes got
replaced with auto-generated `## Changes` / commit-list content.

**Cause**: Many release workflows use `softprops/action-gh-release` with
a `body:` input that regenerates the release description from the commit
log. Re-running the workflow executes the `Create Release` step again,
which detects the release already exists and *patches* it with the
freshly regenerated body — overwriting the manual edit.

**Prevention**: After the manual overhaul step, do NOT re-run the
release workflow. If a downstream sub-job failed (TER publish, artifact
upload, etc.), re-run only that job, or trigger it via a separate
dispatcher workflow that does NOT include the release-creation step.
See `ter-republish.md` for the TYPO3-specific pattern using a
`workflow_dispatch`-only caller.

**Recovery** (body already clobbered):

1. Re-apply the manual notes:
   ```bash
   gh release edit vX.Y.Z --repo owner/repo --notes-file notes.md
   ```
2. If the release body is the source for TER/Packagist/other downstream
   systems, re-trigger those publishes via their own dispatcher
   workflows — NOT by re-running the release workflow itself.
3. Add a note to the project's release checklist: "after editing
   release notes, re-run only downstream publishers, never the full
   release workflow."

## Mis-Tagged SemVer Release (Scope Larger Than Version Bump Implies)

**Symptom**: A release was tagged (and published, and consumed by TER /
Packagist / downstream pipelines) as e.g. `v2.2.2` but actually contains
new user-facing features, a major dependency bump, or behavioural
changes that should have warranted a minor or major bump per SemVer.

**Cause**: The release was assembled from an accumulated `[Unreleased]`
section over many months. The person cutting the release didn't audit
the full scope before picking a version increment.

**Recovery**: The tag cannot be recalled — it's already immutable on
GitHub and downstream consumers (Composer / npm / pip lockfiles, TER)
already reference it. The only honest recovery is documentation:

1. **Do NOT delete the tag.** Consumers who pinned to it would get
   broken builds. Let the mis-tag stand.

2. **Do NOT ship a "replacement" release at a higher number with the
   same content.** Downstream consumers already on `^2.2` would see
   both `2.2.2` and `2.3.0` resolving to effectively identical code —
   they'd correctly pick the newer number and the old `2.2.2` would
   persist as a "zombie version" that nobody should use but is still
   there.

3. **Rewrite the release notes and CHANGELOG entry to acknowledge the
   mis-tag.** Lead with a prominent versioning note:

   ```markdown
   ## [2.2.2]

   > **Versioning note.** 2.2.2 is tagged as a patch but contains
   > ~N commits since 2.2.1, including new user-facing features
   > (list them) and a `$dep` v3 → v4 dependency bump. By SemVer
   > this should have been 2.3.0. The tag is kept because 2.2.2 is
   > already published on $registry and GitHub and cannot be
   > recalled. Consumers pinning to `^2.2` receive all the changes
   > below.
   ```

4. **Enumerate the full scope in Added / Changed / Fixed sections**
   rather than hiding it behind a one-line "also contains other
   commits" disclaimer. Honesty beats a misleadingly small patch note.

5. **Call out any behaviour changes prominently** with an
   `### Upgrading` block at the top of the section, especially for
   default-on features that previously weren't there (new auto-running
   event listeners, changed optimization pipelines, etc.). Provide a
   copy-paste opt-out snippet.

6. **Update the GitHub release body** via
   `gh release edit vX.Y.Z --notes-file notes.md` with the same content
   so readers landing on the release page see the correction.

7. **Add a release-flow improvement** for the future: before cutting a
   release, run `git log --oneline <prev-tag>..HEAD --no-merges | wc -l`
   and count feat / fix / BREAKING CHANGE commits. If the increment
   doesn't match the detected conventional-commit impact, stop and
   reconsider the version number before tagging.

## Branch Protection Blocks the [RELEASE] Commit

**Symptom**: On a repository with signed-commits / required-review
branch protection, `git push origin main` of the version-bump commit
fails with `push declined due to repository rule violations`.

**Cause**: Branch protection requires all changes to main go through a
PR — even the `[RELEASE] vX.Y.Z` commit authored by the release flow.

**Recovery**: Always route the version bump through a PR:

```bash
# From the just-committed local main
git reset --soft HEAD~1              # un-commit the bump, keep staged
git checkout -b release/vX.Y.Z       # move to a release branch
git commit -S --signoff -m "[RELEASE] vX.Y.Z"
git push -u origin release/vX.Y.Z
gh pr create --base main --head release/vX.Y.Z \
  --title "[RELEASE] vX.Y.Z" --body "Release PR"
# merge, then tag + push from the new main
```

Update the project's release scripts/commands to produce a PR by default
rather than a direct push — branch protection should be the norm, not
something the release flow gets surprised by.

## Checklist: Pre-Release Health Check

Run these checks before starting any release:

- [ ] All version files agree on current version
- [ ] Latest Git tag matches version files
- [ ] Latest tag is annotated and signed: `git cat-file -t <tag>` returns `tag`
- [ ] CI release workflow exists and is functional
- [ ] No burned tag names blocking the target version
- [ ] CHANGELOG.md is up to date
- [ ] Default branch is clean (no uncommitted changes)
- [ ] The commit scope between the last tag and HEAD matches the
      selected version increment. Count by conventional-commit type:
      ```bash
      git log <prev-tag>..HEAD --no-merges --format='%s' \
        | awk -F: '{print $1}' | sort | uniq -c | sort -rn
      ```
      Red flags for a patch bump:
      - any `feat` entries at all (implies minor at minimum)
      - any `BREAKING CHANGE` in the full message body: `git log <prev-tag>..HEAD --grep='BREAKING CHANGE'` (implies major)
      - total commit count significantly larger than previous patch releases on this project (harder to eyeball — useful as a "pause and re-read the log" signal)
