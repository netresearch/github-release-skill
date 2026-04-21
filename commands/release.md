---
name: release
description: "Full release orchestration: detect ecosystem, bump versions, create PR, tag, and trigger CI release"
---

# Release Orchestration

Execute the full release workflow for the current project. Follow each step in order,
pausing for user confirmation where indicated.

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

### 10. Tag after merge

**Wait for the user to confirm the PR has been merged**, then:
- Switch to the main branch and pull latest
- Create a **signed, annotated** tag: `git tag -s vX.Y.Z -m "vX.Y.Z"`
- Push the tag: `git push origin vX.Y.Z`

**IMPORTANT**: NEVER use `gh release create`. NEVER create lightweight tags.
Always use `git tag -s` to create signed annotated tags. The CI workflow
triggered by the tag push handles GitHub release creation.

### 11. Monitor CI

Check the release workflow status:
```
gh run list --workflow=release.yml --limit=1
```

If the run is still in progress, report the URL so the user can watch it.
If it completed, report success or failure with a link to the run.

### 12. Overhaul release description

After CI publishes the release, rewrite the auto-generated release notes into a
narrative description. The auto-generated notes (PR titles, contributor lists) are
a starting point, not the final product.

1. Review commits since the previous tag: `git log prev_tag..vX.Y.Z --oneline --no-merges`
2. Check for skipped versions (tags without corresponding GitHub Releases)
3. Write a narrative body covering what changed and why, grouped by theme
4. Update via: `gh release edit vX.Y.Z --notes "..."`

The description should read like a changelog written for humans — not a list of
commit messages or PR titles.

### 13. Report result

Summarize what was done:
- Version bumped from X.Y.Z to A.B.C
- Files modified
- PR URL
- Tag created
- Release workflow status
- Release description overhauled
