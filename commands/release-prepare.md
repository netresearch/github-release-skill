---
# SPDX-License-Identifier: CC-BY-SA-4.0
# SPDX-FileCopyrightText: Netresearch DTT GmbH
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

Run `suggest-version.sh` from the skill's scripts directory: it asks git-cliff
(`uvx git-cliff@latest --bumped-version`, with the skill's own configuration) for the next
semantic version from the commits since the last tag. Present the suggestion and let the user
confirm or override with their preferred version number.
On a 0.x version, read `[Unreleased]`, the pending `changelog.d/` fragments
(`removed`, `upgrading`, bullets opening with `**BREAKING`) and the API diff for a
breaking change before presenting it: the middle number rises only for one, and
those changelog BREAKING entries outrank git-cliff's suggestion
(`references/release-process.md`, which also lists the inputs git-cliff answers
differently).

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

Then sweep the rest of the repository for the previous version string — the
version files detected in step 1 are not every place that states it (a README
compatibility table naming the latest release is the common miss):

```bash
git -C "$(git rev-parse --show-toplevel)" grep -nF '<previous version>' -- ':!CHANGELOG*' ':!*.lock' ':!*-lock.json' ':!*.lock.json'
```

Update each hit that names the current release, and leave a hit that is
history (a "since" note, an upgrade guide) with its reason in the PR body.

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

Create a single commit with the message: `chore(release): vX.Y.Z`

Stage only the files that were modified in steps 5-7.

### 9. Push branch and create PR

Push the release branch to the remote and create a pull request targeting the main
branch. The PR title should be `chore(release): vX.Y.Z` and the body should
summarize the version changes.

When the repository has a pull request template (`pull_request_template.md` in
any letter case, or a `PULL_REQUEST_TEMPLATE/` directory, in `.github/`, `docs/`
or the repository root), write the body in its sections: fill a test-plan section with the checks you ran locally and
their results, and answer a related-issues section (the release PR usually closes
none — say so). A body that skips the template's sections fails description checks
such as CodeRabbit's.
A repository without its own template uses the owner's default from the
`<owner>/.github` repository, in the same locations; it is not in the clone, so
read it with `gh api repos/<owner>/.github/contents/<path> --jq .content | base64 -d`.

## After PR merge

Remind the user to create the signed tag manually after the PR is merged:

```bash
git checkout main && git pull
git tag -s vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
```

**IMPORTANT**: this command stops before the tag. Never create lightweight tags;
the release step uses `git tag -s`, and any later `gh release create` carries
`--verify-tag`.
