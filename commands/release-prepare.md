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

If a CHANGELOG.md exists, it must gain a **populated** entry for this version —
never emit an empty section. Do not just rename `[Unreleased]`: when changes
are merged PR-by-PR without touching the changelog, `[Unreleased]` is empty and
a rename yields a hollow version heading.

1. **Derive the entries from the commit log.** List merged work since the last
   release tag and group the user-facing changes under standard headers (Added
   / Changed / Fixed / Documentation / Removed), dropping chore/ci/release-bump
   noise. Match the file's existing entry style — heading format, and whether
   entries cite PR/MR numbers (map commits to PRs with
   `gh api repos/OWNER/REPO/commits/<sha>/pulls` when they do).

   ```bash
   # --first-parent yields one line per merged PR in both merge-commit and
   # squash/rebase repos; the fallback covers a first release with no tag yet.
   git log --oneline --first-parent "$(git describe --tags --abbrev=0 2>/dev/null)"..HEAD 2>/dev/null \
     || git log --oneline --first-parent HEAD
   ```

2. **Backfill missing versions.** If tags exist between the newest CHANGELOG
   entry and the last release (a prior version shipped without an entry), add a
   section for each, scoped to its own `<prev-tag>..<tag>` range. Some repos
   require this explicitly (e.g. jira-skill `AGENTS.md`: "Backfill any missing
   CHANGELOG entries").

3. **Add the new section.** For Keep a Changelog files, move the derived
   entries into a new `[X.Y.Z] - YYYY-MM-DD` heading (today's date) and leave an
   empty `[Unreleased]` above it. If the file keeps link-reference definitions
   at the bottom (`[Unreleased]: …/compare/vX…HEAD`, `[X.Y.Z]: …`), add the new
   version's definition and repoint `[Unreleased]` — `check-changelog-links.py`
   fails otherwise. For other formats, insert the version heading at the top in
   the file's own style (e.g. `## X.Y.Z (YYYY-MM-DD)`).

Keep entries plain and factual — no editorializing (see
`skills/github-release/references/no-editorializing.md`).

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
