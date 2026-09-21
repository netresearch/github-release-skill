---
name: github-release
description: "Use when creating releases, version bumps, tagging, release health checks, or when user says 'release', 'tag', 'version bump'. A version lives in every file that states it: a TYPO3 extension carries it in ext_emconf.php, composer.json, Documentation/guides.xml, the changelog page under Documentation/ and CHANGELOG.md, and updating some of them ships metadata that disagrees with itself. Also activates on gh release commands to BLOCK them and redirect to safe process."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires gh CLI, git with GPG/SSH signing configured."
metadata:
  author: Netresearch DTT GmbH
  version: "1.0.4"
  repository: https://github.com/netresearch/github-release-skill
allowed-tools: Bash(gh:*) Bash(git:*) Read Write Edit Glob Grep
---

# GitHub Release Skill

## Critical Rules

**NEVER run `gh release delete`, and never `gh release create` without `--verify-tag`.**

Blocked by hooks. Immutable releases (GA Oct 2025) make tag names permanent — a bare `gh release create` creates the tag when it is missing, that tag is lightweight, and the name is burned forever. `--verify-tag` aborts unless the tag already exists on the remote, so the invocation can only publish a tag somebody pushed on purpose; the guard allows it for that reason (`--verify-tag=false` stays blocked).

Where the repository has a workflow that publishes the release, that workflow does it and you do not run `gh release create` at all. Where it does not, **add one** — for a project shipped as its source tree, a tag-push caller of `netresearch/.github`'s `release-source-archive.yml` (`references/ci-workflow-templates.md`). Publishing by hand against the pushed signed tag (*Tag-only repositories* below) is the step for a release that cannot wait for that workflow, not a flow to keep.

**`gh release edit` is allowed ONLY for `--notes` / `--notes-file`** to overhaul the release description after CI publishes. All other `gh release edit` flags are blocked.

**No editorializing** in release notes, PR/commit text and docs — state what a release does, not how good the work is; no self-praise or narrating the expected. See `references/no-editorializing.md`.

## Start Here

`scripts/release-status.sh -R owner/repo` reports the phase and a computed
`NEXT`, exiting 0 only when finished. `scripts/release-notes-status.sh`
checks the published body.

## Release Flow

1. **Detect ecosystem** — find the project type's version files (see `references/ecosystem-detection.md`)
2. **Determine next version** — from conventional commits or user input (major/minor/patch)
3. **Bump version files** — every ecosystem-specific one, consistently
4. **Update CHANGELOG.md** — add a release section with date and changes
5. **Create release branch and PR** — `release/vX.Y.Z`, always via PR (branch protection typically blocks direct pushes)
6. **After PR merge** — `git checkout main && git pull`, assert HEAD equals the remote tip (stale-worktree guard), then tag `main`'s HEAD, never the `release/vX.Y.Z` tip: `git tag -s vX.Y.Z -m "vX.Y.Z"` — see `references/release-process.md` Phase 3.
7. **Push tag** — `git push origin vX.Y.Z` triggers CI
8. **CI publishes release** — artifacts, checksums, auto-generated notes
9. **Overhaul release description** — rewrite CI's notes into a narrative; `@mention` every contributor **and reporter** inline at their change, never as a `## Contributors` section. Source them from `scripts/harvest-contributors.sh`, never `git log`. Verify with `scripts/release-notes-status.sh`. See `references/release-process.md` Phase 5.
10. **Do NOT re-run the release workflow after step 9** — many regenerate the body each run, overwriting the overhaul. For downstream retries, use a dispatcher — see `references/ter-republish.md`.

### Tag-only repositories

**This state is a gap to close, not a flow to keep.** A repository in it gets its provenance from a workflow that runs after a hand-made release, so the build happens in the repository itself — SLSA Build Level 2 at best, because GitHub grants Level 3 only when the build runs inside a reusable the repository cannot edit. The fix is a release workflow on the tag push that calls the org reusable for the artefact: `release-source-archive.yml` (source tree), `release-go-app.yml` (Go), `release-typo3-extension.yml` (TYPO3). It builds, generates SBOMs, signs, attests and creates the release in one run; see `references/ci-workflow-templates.md`. Until that workflow exists:

Some repositories have no workflow that creates the release object. Their supply-chain workflows listen on `release: published` instead — provenance attestation, SBOM upload, registry publish — and that event never fires for a release created with `GITHUB_TOKEN` (`references/typo3-ter-publishing.md` has the mechanism). The release therefore has to be created by a human credential, which is `gh` on your machine:

```bash
git tag -s vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z   # Docker/image workflows run on the tag
gh release create vX.Y.Z --title "vX.Y.Z" --verify-tag --notes-file <notes>
```

**Run that second command under your own credential, never a workflow's.** It is the whole point of this branch of the flow: `gh` authenticated as `GITHUB_TOKEN` creates the release without firing `release: published`, so every downstream job stays silent and the release looks complete while carrying no provenance and no SBOM. Locally that means the `gh` you are logged into; from automation it means a PAT or a GitHub App installation token in `GH_TOKEN`, and `${{ github.token }}` is exactly the value that must not appear there.

Steps 8 and 9 collapse into that second command: it publishes and carries the notes, so there is no CI-generated body to overhaul afterwards. Everything downstream — provenance, SBOM, registry publish — hangs off the `release: published` it fires, so verify it landed rather than assuming: `gh attestation verify <asset> --repo owner/repo` for the archive, `cosign verify` for an image. `scripts/release-status.sh` still reports `NEXT: prepare-release — no version file found` for a repository that states its version nowhere; that is the version-file question, not the release one.

## Commands

- `/release` — full release flow (detect, bump, PR, tag)
- `/release-prepare` — bump versions and open PR only (no tag)
- `/release-status` — check release health (version drift, unsigned tags, missing workflows)

## Delegation

- **Supply chain security** (SLSA, SBOMs, attestations): delegate to `enterprise-readiness` skill
- **Branch strategy and conventional commits**: delegate to `git-workflow` skill

## References

- `references/release-process.md`
- `references/ecosystem-detection.md` — version-file patterns
- `references/immutable-releases.md` — immutable releases, tag burning
- `references/supply-chain-security.md` — SLSA, Sigstore
- `references/recovery-procedures.md` — burned tags, stuck drafts, drift, body clobbering
- `references/ter-republish.md` — TER re-publish
- `references/typo3-ter-publishing.md` — TYPO3 TER publish gotchas
- `references/ci-workflow-templates.md` — CI workflow templates
- `references/npm-staged-publishing.md` — `npm stage publish`: version floor, the two states it refuses, capturing the stage id
- `references/no-editorializing.md` — no self-praise
