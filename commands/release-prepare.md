---
name: release-prepare
description: "Prepare a release: bump versions and create PR, but don't tag (user tags manually)"
---

# Release Preparation

Prepare a release by bumping versions and creating a PR. This command does NOT
create a tag -- the user is responsible for tagging after the PR is merged.

## Steps

### 1. Detect ecosystem

Run `detect-ecosystem.sh` from the skill's scripts directory to identify:
- Project type (TYPO3 extension, PHP library, Node package, Go module, generic)
- All version files that need updating
- Current version across all detected files

Report findings to the user before proceeding.

### 2. Suggest next version

Run `suggest-version.sh` from the skill's scripts directory to analyze recent commits
and suggest the next semantic version. Present the suggestion and let the user
confirm or override with their preferred version number.

### 3. Validate pre-release readiness

Run `validate-pre-release.sh` from the skill's scripts directory. If any checks fail,
report the issues and ask the user whether to proceed or abort.

### 4. Create release branch

Create and switch to a new branch named `release/vX.Y.Z` where X.Y.Z is the
confirmed version number.

### 5. Update version files

Update ALL version files detected in step 1 to the new version number. This may
include files like `composer.json`, `package.json`, `ext_emconf.php`,
`Documentation/Settings.cfg`, `version.go`, or others depending on the ecosystem.

### 6. Update CHANGELOG.md

If a CHANGELOG.md exists:
- Rename the `[Unreleased]` section to `[X.Y.Z] - YYYY-MM-DD` (using today's date)
- Add a new empty `[Unreleased]` section above it with standard subsection headers

### 7. TYPO3-specific: scan documentation

For TYPO3 extensions only: scan `Documentation/*.rst` files for any references to
unreleased versions or version placeholders that need updating.

### 8. Commit changes

Create a single commit with the message: `chore: release vX.Y.Z`

Stage only the files that were modified in steps 5-7.

### 9. Push branch and create PR

Push the release branch to the remote and create a pull request targeting the main
branch. The PR title should be `chore: release vX.Y.Z` and the body should
summarize the version changes.

## After PR merge

Remind the user to create the signed tag manually after the PR is merged:

```bash
git checkout main && git pull
git tag -s vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
```

**IMPORTANT**: NEVER use `gh release create`. NEVER create lightweight tags.
Always use `git tag -s` to create signed annotated tags.
