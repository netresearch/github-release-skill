---
name: github-release
description: "Use when creating releases, version bumps, tagging, release health checks, or when user says 'release', 'tag', 'version bump'. Also activates on gh release commands to BLOCK them and redirect to safe process."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires gh CLI, git with GPG/SSH signing configured."
metadata:
  author: Netresearch DTT GmbH
  version: "0.1.0"
  repository: https://github.com/netresearch/github-release-skill
allowed-tools: Bash(gh:*) Bash(git:*) Read Write Edit Glob Grep
---

# GitHub Release Skill

## Critical Rules

**NEVER run `gh release create` or `gh release delete`.**

These commands are blocked by hooks. GitHub immutable releases (GA Oct 2025) make tag names permanent — a lightweight tag created by `gh release create` burns that tag name forever with no recovery path. CI handles release creation from signed tags.

**`gh release edit` is allowed ONLY for `--notes` / `--notes-file`** to overhaul the release description after CI publishes. All other `gh release edit` flags are blocked.

## Release Flow

1. **Detect ecosystem** — identify version files for the project type (see `references/ecosystem-detection.md`)
2. **Determine next version** — based on conventional commits or user input (major/minor/patch)
3. **Bump version files** — update all ecosystem-specific version files consistently
4. **Update CHANGELOG.md** — add release section with date and changes
5. **Create release branch and PR** — `release/vX.Y.Z` branch, open PR for review
6. **After PR merge** — create signed annotated tag: `git tag -s vX.Y.Z -m "vX.Y.Z"`
7. **Push tag** — `git push origin vX.Y.Z` triggers CI workflow
8. **CI publishes release** — with artifacts, checksums, and auto-generated release notes
9. **Overhaul release description** — rewrite the auto-generated notes into a narrative summary using `gh release edit vX.Y.Z --notes "..."`

## Commands

- `/release` — full release flow (detect, bump, PR, tag)
- `/release-prepare` — bump versions and open PR only (no tag)
- `/release-status` — check release health (version drift, unsigned tags, missing workflows)

## Delegation

- **Supply chain security** (SLSA, SBOMs, attestations): delegate to `enterprise-readiness` skill
- **Branch strategy and conventional commits**: delegate to `git-workflow` skill

## References

- `references/release-process.md` — complete flow documentation
- `references/ecosystem-detection.md` — version file patterns per ecosystem
- `references/immutable-releases.md` — GitHub immutable releases and tag burning
- `references/supply-chain-security.md` — SLSA, Sigstore, SBOMs, attestations
- `references/recovery-procedures.md` — burned tags, stuck drafts, version drift
- `references/ci-workflow-templates.md` — CI workflow structure and templates
