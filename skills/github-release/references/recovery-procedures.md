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

## Checklist: Pre-Release Health Check

Run these checks before starting any release:

- [ ] All version files agree on current version
- [ ] Latest Git tag matches version files
- [ ] Latest tag is annotated and signed: `git cat-file -t <tag>` returns `tag`
- [ ] CI release workflow exists and is functional
- [ ] No burned tag names blocking the target version
- [ ] CHANGELOG.md is up to date
- [ ] Default branch is clean (no uncommitted changes)
