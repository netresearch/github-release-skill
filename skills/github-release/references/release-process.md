# Release Process

## Overview

The complete flow from "create a release" to "release published on GitHub."

## Why `gh release create` Is Forbidden

`gh release create` does the following harmful things:

1. **Creates a lightweight tag** if the tag doesn't exist — lightweight tags have no signature, no author metadata, and cannot be retroactively converted to annotated tags.
2. **Burns the tag name permanently** — since GitHub immutable releases (GA Oct 2025), once a release uses a tag name, that name can never be reused. Not even `gh release delete` followed by `git push --delete origin vX.Y.Z` recovers it. GitHub returns: `"tag_name was used by an immutable release"`.
3. **Bypasses CI** — no provenance attestation, no SBOM, no artifact signing. The release is created directly with whatever you attach manually.
4. **Skips version file bumps** — source code still shows the old version.

The hooks in this repository block `gh release create` and `gh release delete` to prevent these outcomes. `gh release edit` is allowed only for `--notes`/`--notes-file` flags (release description overhaul).

## The Correct Release Flow

### Phase 1: Preparation

```
0. Triage open issues from the current work stream (see "Issue gate" below)
1. Detect ecosystem (see ecosystem-detection.md)
2. Determine next version number:
   - From conventional commits (feat → minor, fix → patch, BREAKING CHANGE → major)
   - From explicit user input ("bump to 2.0.0")
3. Create release branch:
   git checkout -b release/vX.Y.Z
4. Bump all version files for the detected ecosystem
5. Update CHANGELOG.md: add the new [X.Y.Z] section AND bump the footer
   link-references (Keep a Changelog) — repoint the [Unreleased]: line to
   compare/vX.Y.Z...HEAD and add a [X.Y.Z]: .../compare/vPREVIOUS...vX.Y.Z line.
   The footer LABEL is the plain version ([X.Y.Z]:), while the compare URL uses
   the v-prefixed git tags (vPREVIOUS...vX.Y.Z). The footer drifts silently if
   only the heading is changed (a prior release's compare link may even be
   missing); a reviewer bot will flag the dangling [Unreleased]: ref.
6. Commit: "chore: prepare release vX.Y.Z"
7. Push branch and open PR
```

#### Issue Gate (Step 0) — Never tag over an untriaged known issue

Before
tagging, list open issues (`gh issue list --state open`), and for each issue
**created or touched during the current work stream**, classify it:

- *regression introduced by this release* → must be fixed before tagging;
- *pre-existing latent* → usually not a blocker, but say so explicitly to the
  user before tagging;
- *test-only / infra* → not a blocker.

Anything of **unclear severity** — including an issue you filed yourself whose
text hypothesises "production bug" — is decided by the user, not silently
shipped. A user's task order that includes "release" does **not** delegate that
judgment away. Surface the open issues with a one-line severity read and get an
explicit go, or fix first. Shipping a release with a known open bug from the
same stream, then being asked "why did you release with known bugs?", is the
failure this gate prevents.

#### Release authorization is per-release — momentum is not a mandate

A release is outward-facing and (once published) immutable, so **cutting or
even staging one requires an explicit, current instruction for *that* release**
— not inference from a finished feature cycle. Authorization does not carry
forward: "do the release" for version N does not authorize version N+1, and
"fix these issues / finish this PR" never authorizes a release at all. The
autonomous pipeline for feature work *ends* at merged PRs + green CI + closed
issues; then stop and report "release-ready — say the word to cut X.Y.Z". Do
not create `release/*` branches, bump versions, or arm a release PR to
auto-merge without a per-release go. (Staging counts: a bumped, auto-merged
release PR is a release the user did not ask for. "Did you release? I wasn't
asking for a release." is the failure this prevents.)

### Phase 2: Review and Merge

```
1. PR passes CI checks (lint, test, build)
2. Reviewer approves version bumps and changelog
3. PR is merged to main (squash or merge commit per project convention)
```

### Phase 3: Tag Creation

After the PR is merged into main:

```
1. git checkout main && git pull          # advance to main's post-merge HEAD
2. git fetch origin main &&
   [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
     || { echo "ABORT: HEAD != remote tip"; exit 1; }  # MANDATORY pre-tag verification
3. git tag -s vX.Y.Z -m "vX.Y.Z"          # tags main's HEAD
4. git push origin vX.Y.Z                 # release orchestrator picks it up
```

**The pre-tag verification (step 2) is mandatory, not advisory.**
Bare-repo/worktree layouts can have a stale local `main` that "switch to
main" happily lands on — "pull latest" then looks satisfied while HEAD is
still commits behind the remote tip, and the tag lands on pre-merge code.
On mismatch, abort: do not tag, do not push. Cross-check against the API
when in doubt: `gh api repos/{owner}/{repo}/commits/main --jq .sha` must
equal `git rev-parse HEAD`.

**Reconcile the CHANGELOG against the whole range before tagging — position
is not content.** Step 2 proves you are tagging main's tip; it does *not*
prove the CHANGELOG describes what that tip actually contains. Between the
moment the release PR was prepared and the moment you tag, *other* PRs can
merge onto main — features from a parallel work stream, dependency bumps,
another author's fix — none of them in the `[X.Y.Z]` section you wrote at
prep time. Tagging then ships them undocumented. Immediately before the tag:

```bash
PREVIOUS_TAG=$(git describe --tags --abbrev=0)         # the last release tag
git log --first-parent --pretty='%s' "$PREVIOUS_TAG"..HEAD   # everything the tag will ship
```

Diff that list against the `[X.Y.Z]` CHANGELOG section and add every merged
feature/fix that is missing (read the PR/ADR to describe it accurately). Do
not trust a CHANGELOG written when the release PR opened — main drifts past a
staged release. If reconciling adds material, land it as a `docs(changelog)`
PR and re-verify step 2 before tagging.

The tag MUST be:
- **Annotated** (`-a` or `-s`), never lightweight
- **Signed** (`-s` for GPG/SSH signing) — required for SLSA L1+
- **On `main`'s HEAD after the PR merges** — not on the `release/vX.Y.Z` branch tip, not on an older commit, proven by the pre-tag verification above

**Why `main`'s post-merge HEAD and not the release branch tip:** depending on the project's merge strategy, `main`'s HEAD after merge is one of:

- The original branch-tip commit, if the PR was fast-forwarded;
- A new squash commit, if the PR was squash-merged;
- A new merge commit, if the PR was merge-committed.

The tag must point to whatever is now the tip of `main` — that is what consumers will check out, what CI will build artifacts from, and what shows up as "the release commit" on the GitHub release page. With squash- or merge-commit strategies, the `release/vX.Y.Z` branch tip is *not* on `main`'s first-parent history, so tagging it produces a tag that doesn't correspond to any commit on `main`.

In practice: do NOT `git tag` from inside the worktree on the `release/vX.Y.Z` branch. Switch to `main`, pull, then tag — the steps above already enforce this order.

### Phase 4: CI Release Workflow

The tag push triggers the release workflow (e.g., `.github/workflows/release.yml`):

```
1. CI validates version tag matches version files
2. CI builds artifacts (binaries, archives, etc.)
3. CI generates checksums (SHA256SUMS.txt)
4. CI generates SBOM if configured (SPDX or CycloneDX)
5. CI creates provenance attestation if configured (SLSA)
6. CI publishes the GitHub Release with all artifacts and auto-generated release notes
```

### Phase 5: Release Description Overhaul

After CI publishes the release, the agent overhauls the auto-generated description into a narrative format:

```
1. Wait for CI release workflow to complete successfully
2. Review the commits included in the release (git log prev_tag..new_tag)
3. List who contributed to what — scripts/harvest-contributors.sh --repo owner/repo --from <prev_tag> --to <new_tag>
   prints merged-PR authors and the reporters of the issues those PRs closed
   (bots excluded) — a lookup for step 4, NOT a section to paste
4. Write a narrative release description covering:
   - What changed and why it matters
   - Context for skipped versions or notable decisions
   - Grouped by theme (features, fixes, infrastructure), not by commit
   - Each contributor @mentioned INLINE at the change they touched, by role
     (reporter / PR author / committer / reviewer / discussant). Do NOT add a
     Contributors section — GitHub builds the Contributors avatar row itself from
     these inline @mentions (mentions_count).
5. Update via: gh release edit vX.Y.Z --notes-file notes.md
   (use --notes-file, not --notes "...", to avoid shell-quoting issues with multi-line Markdown)
```

The auto-generated notes (PR titles, contributor lists) are a starting point, not the final product. The agent's description should read like a changelog entry written for humans.

#### The overhaul is part of the release, not an optional follow-up

Two starting points are equally unacceptable as a final release body:

- a flat auto-generated `## Changes` / `## What's Changed` list of PR titles (often padded with chore noise — dependency digest bumps, lint-fix PRs); and
- a CI-generated **stub** — some release workflows auto-create the release on tag push with a placeholder body like `Release vX.Y.Z — see CHANGELOG.md for details`.

In both cases the release is not finished until the body is a hand-written `## Highlights` narrative. Do this **proactively, every time** — do not wait to be asked, and do not report the release as "done" while the body is still a PR-title list or a stub. The stub appears only once the tag pipeline finishes (the workflow creates the release), so the overhaul step has to wait for that completion before it can edit the body. For repos that append boilerplate sections (Installation, verification/Sigstore, SBOM), preserve those verbatim and replace only the change summary.

#### Never hard-wrap the body — soft newlines render as line breaks

A GitHub release body renders as **comment-context GitHub-Flavored Markdown**, where a single soft newline inside a paragraph becomes a hard `<br>`. So an 80-column hard-wrapped paragraph shows up as a column of ragged short lines, not a flowing paragraph. Write every paragraph and list item as **one long logical line** and let the viewport soft-wrap.

This is the opposite of a `CHANGELOG.md` (or any rendered `.md` file in a repo), which follows CommonMark where soft newlines collapse to spaces — so hard-wrapping is fine *there*. **Do not copy hard-wrapped changelog prose verbatim into the release body:** join each wrapped paragraph back into a single line first. Fenced code blocks are exempt — their internal newlines are intentional and survive correctly in both contexts.

#### Preserve the CI-appended blocks mechanically — do not retype them

The netresearch `release-go-app.yml` orchestrator appends `## Container image` and `## Verify your download` sections after `## Changes`. Replacing the whole body with your narrative destroys them (and the verify commands are non-trivial — see supply-chain-security.md on `--signer-workflow`). Capture the tail and re-append it:

```bash
gh release view vX.Y.Z --repo owner/repo --json body --jq .body > /tmp/orig.md
awk '/^## Container image/{f=1} f' /tmp/orig.md > /tmp/tail.md   # everything from the first CI block on
cat my-narrative.md /tmp/tail.md > /tmp/final.md                 # narrative replaces ONLY ## Changes
gh release edit vX.Y.Z --repo owner/repo --notes-file /tmp/final.md
```

Then re-check the emitted verify commands are correct for a reusable-workflow build (`--signer-workflow`, not `--repo` alone).

**Publish behaviour differs by orchestrator.** `release-go-app.yml` (go apps) publishes the release **directly** on tag push — not a draft — with all assets attached, so the overhaul edits a live release. `golib-create-release.yml` (go libraries) creates a **draft** that must be published manually with `gh release edit vX.Y.Z --draft=false` (a permitted flag) after CI finishes. Check `gh release view --json isDraft` to know which you have. Note: `gh release view --json isLatest` is NOT a valid field — query `gh api repos/OWNER/REPO/releases/latest` for the latest tag instead.

#### Verify each publication claim before reporting the release done

Tag-push is not the finish line. If the body (or a boilerplate section the workflow appends) asserts a package was published — TER, Packagist, docs, npm — **independently confirm each claim before reporting success**, rather than trusting the template's wording. Many release workflows publish AND verify these channels themselves; do not assume a channel is a separate manual step without reading the release workflow. Quick checks: Packagist `https://repo.packagist.org/p2/<vendor>/<pkg>.json` (note tags are `v`-prefixed), TER `https://extensions.typo3.org/api/v1/extension/<ext_key>/versions`, docs an `HTTP 200` on the versioned docs URL. Report what you verified, not what the template claimed.
#### Crediting contributors — inline, never a hand-written section

**GitHub builds the "Contributors" row itself.** The avatar row above the release's Assets is generated from the `@mentions` in the body (the release object's `mentions_count`): every `@mention` anywhere in the body feeds it, and with none, `mentions_count` is `null` and the row does not render. So you **never hand-write a `## Contributors` section** — it would duplicate the row GitHub already draws and lump everyone together, losing who did what.

**Credit each contributor inline at the change they touched, by role** — reporter, PR author, committer / co-author, reviewer, discussant, whatever the contribution was. One change can name several:

```markdown
- Entry deletion now enforces ownership (IDOR) — reported by @alice, fixed in #560 by @bob, reviewed by @carol.
```

Use a bare `@username`, never `[@username](url)`: GitHub renders the avatar chip only for a bare mention; a markdown link degrades it to a plain hyperlink. (This is the one place the "format references as clickable links" habit is wrong — a bare `@mention` is already clickable *and* shows the avatar.) Add a `**Full Changelog**: <compare-url>` line at the end to match GitHub's own release format.

**Finding who to mention.** `scripts/harvest-contributors.sh --from <prev> --to <new>` lists merged-PR authors and the reporters of the issues those PRs closed (bots excluded, humans only) — a lookup so you know whom to place where; it does **not** emit a section. Reviewers and discussants are not in that list — pull them from the PR/issue when the contribution warrants credit.

**Check the harvest against the range's real commit authors — in both directions:**

```bash
gh api repos/owner/repo/compare/<from>...<to> --jq '.commits[].author.login?' | sort -u
```

- **Over-credit:** a harvested author *not* in that list is a false credit (older versions grepped `#N` out of a dependency-bump changelog or an HTML entity like `&#8203;`) — drop it.
- **Under-credit:** the harvest sees only *merged-PR* authors. A **direct-push** human (no PR) appears in the compare list above under their own login — mention them if the harvest missed them. A commit **authored by a filtered bot but co-authored by a human** (e.g. the Copilot agent) shows the **bot** login in the compare list, not the human — never credit the bot; the human is the committer / `Co-authored-by`. List the real people in the range and credit anyone the harvest missed:

  ```bash
  git log --format='%an <%ae>%n%cn <%ce>%n%(trailers:key=Co-authored-by,valueonly,separator=%n)' <from>..<to> | sort -u | grep .
  ```

  One person per line (the `%n` separator keeps multiple co-authors from colliding), deduped; the emails map names back to GitHub accounts.

The compare API caps at 250 commits — for a wider range, run it in two halves.

#### Narrative over implementation details

Release notes are for the people deciding whether to upgrade — users, admins, integrators — not for developers reading the diff. Lead with the user-facing story, then brief feature sections.

**Don't list:**

- Internal types, DTOs, enums, service-class names
- File paths or class paths touched by the release
- i18n unit counts or translation-bundle diffs
- Refactor details that don't change behavior

**Do describe:**

- What a user can now do that they couldn't before
- The configuration levels / option values a feature exposes
- Breaking-change surfaces with migration notes

**Bad example (diff-focused):**

> - `EnforcementLevel` enum, `EnforcementStatus` DTO, `EnforcementService`, `AdoptionStatsService`
> - 47 new i18n units in `locallang_db.xlf`
> - Refactored `UserController::indexAction` into 3 helper methods

**Good example (user-focused):**

> Per-group passkey enforcement with four levels: Off, Encourage, Required, Enforced. Admins can now configure whether a group's members may log in with passwords, are nudged toward passkeys, must enroll at least one, or must use one for every sign-in.

#### `--latest=false` for non-default-branch releases

**GitHub marks the most recently *created* release as "Latest" — by timestamp, not by SemVer.**

Creating a backport release (say v11.0.17) AFTER a newer release on a higher branch (v13.5.0) steals the "Latest" badge from v13.5.0, and users who click "Latest release" then get the old major.

**Rule:** this guidance does **not** override the policy above. On repositories guarded by this skill's hooks (including every Netresearch repo with a release workflow), manual `gh release create` stays blocked — CI creates releases from signed tags, not the agent. The rest of this subsection applies only to the rare unguarded case: repos WITHOUT a release workflow, where manual `gh release create` is the only path. In that case, pass `--latest=false` for non-default-branch releases:

```bash
# Backport release on TYPO3_11 branch while main is on v13
gh release create v11.0.17 \
  --latest=false \
  --title "v11.0.17" \
  --notes "Backport: CVE-2026-XXXX fix"
```

Default-branch (highest-version) releases keep the Latest badge; backports publish without stealing it.

**For the CI-driven flow (the common case)** — the release workflow, not the agent, creates the release, so the analogous setting is `make_latest: false` on the `softprops/action-gh-release` step (or the equivalent on whatever action publishes the release). Release workflows typically trigger on tag push (`on.push.tags`), so `github.ref_name` holds the tag (e.g. `v1.2.3`), **not** a branch name — branch-name comparisons will never match on that trigger. Drive `make_latest` from an explicit source of truth instead:

```yaml
# Combined trigger: tag push (normal case) + workflow_dispatch with explicit
# tag + make_latest inputs (for manual backport publishes).
on:
  push:
    tags: ['v*']
  workflow_dispatch:
    inputs:
      tag:
        description: 'Tag to publish (must already exist)'
        required: true
      make_latest:
        type: boolean
        default: true

jobs:
  publish:
    steps:
      - uses: actions/checkout@...  # pinned SHA
        with:
          # CRITICAL on workflow_dispatch: ref_name is the branch the dispatch
          # was launched from (e.g. 'main'), not the tag. Without this, the job
          # builds assets from the wrong commit and publishes them to the tag.
          # On push.tags the expression below resolves to ref_name (the tag)
          # which is equivalent to the default checkout.
          # Use github.event.inputs.* (not inputs.*) so the expression stays
          # safe on push.tags runs — github.event.inputs resolves to an empty
          # string on non-dispatch events, while inputs.* is only defined
          # under workflow_dispatch / workflow_call.
          ref: ${{ github.event.inputs.tag || github.ref_name }}
          fetch-tags: true
      # ... build assets here ...
      - uses: softprops/action-gh-release@...  # pinned SHA
        with:
          # push.tags: ref_name IS the tag; workflow_dispatch: use the input.
          tag_name: ${{ github.event.inputs.tag || github.ref_name }}
          # Default to Latest on tag push; honor the boolean input on dispatch.
          # GitHub Actions expressions have no ternary — this is the idiomatic
          # and/or chain. fromJSON() parses the 'true'/'false' string from
          # github.event.inputs into an actual boolean for the `&&` short-circuit.
          make_latest: ${{ github.event_name == 'workflow_dispatch' && (fromJSON(github.event.inputs.make_latest || 'true') && 'true' || 'false') || 'true' }}
```

For dispatch-only publishes (no tag-push trigger), drop the `push:` block; the combined expressions above still work, and you can simplify if you like. For tag-push-only workflows, drop the `workflow_dispatch:` block and always use `github.ref_name` with a fixed `make_latest` — but note that the fixed approach can't express "backport, don't steal Latest" without the dispatch input.

For repos using the shared release workflow template at `skills/github-release/templates/release-generic.yml`, file a patch there to expose a `make_latest` input (keep the name underscored to match GitHub's own action parameter; hyphenated names would force bracket-expression access, which is easy to get wrong) rather than forking per-repo.

## Multi-Repo / Bulk Releases

When releasing many repositories that share one reusable release workflow (e.g. a fleet of skill or library repos), coordinate rather than firing all at once:

1. **Pilot one repo end-to-end first.** Take a single known-clean repo all the way through bump → PR → merge → tag → CI-publish before touching the rest. The pilot proves the shared reusable workflow is healthy and pins down the exact per-repo recipe. Fix any workflow breakage on the pilot, not across N repos.
2. **Survey scope from the remote, not local checkouts.** Decide which repos actually need a release with `gh api repos/OWNER/REPO/compare/$LATEST_TAG...$DEFAULT_BRANCH --jq '.ahead_by'` and inspect the commit subjects — release only repos with user-facing `feat:`/`fix:`/`docs:` changes; skip those whose only commits are `ci:`/`chore(deps):`. Local worktrees can be stale (they may still show removed workflow inputs or an old default branch); always re-survey against `origin`.
3. **Fan out in small batches.** Process ~5–7 repos per batch, not one mega-pass. Small batches keep an agent's context from being exhausted mid-fleet and avoid tripping server-side rate limits on rapid PR/clone bursts.
4. **Run the notes overhaul as a separate pass.** The Phase 5 description overhaul is the step most likely to run out of context in a combined loop — do the bump→merge→tag→publish pipeline for the whole batch first, then a second pass for narrative notes via `gh release edit --notes-file`.
5. **Handle "drift" repos.** If a repo's version file was already bumped ahead of its latest tag, the next tag is `max(natural_bump, current_version_in_file)` — use the pre-bumped value (unless that version was already published/burned, in which case bump higher).

## When CI Fails

If the release workflow fails:

1. **Workflow failed mid-run**: Re-run the workflow. If a release already exists, the workflow should handle idempotent creation.
2. **Artifacts are wrong**: Fix the issue and re-run the workflow.
3. **Startup failure**: Check that the caller workflow grants all permissions required by the reusable workflow (e.g., `contents: write`, `pull-requests: write`).

## Version Tag Format

- Always use `v` prefix: `v1.0.0`, `v2.3.1`
- Follow SemVer 2.0.0: `vMAJOR.MINOR.PATCH`
- Pre-releases: `v1.0.0-rc.1`, `v2.0.0-beta.3`
- No build metadata in tags (build metadata is not sortable)
