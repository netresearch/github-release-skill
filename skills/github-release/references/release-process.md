# Release Process

## Overview

The complete flow from "create a release" to "release published on GitHub."

## Why a bare `gh release create` Is Forbidden

`gh release create` without `--verify-tag` does the following harmful things:

1. **Creates a lightweight tag** if the tag doesn't exist — lightweight tags have no signature, no author metadata, and cannot be retroactively converted to annotated tags.
2. **Burns the tag name permanently** — since GitHub immutable releases (GA Oct 2025), once a release uses a tag name, that name can never be reused. Not even `gh release delete` followed by `git push --delete origin vX.Y.Z` recovers it. GitHub returns: `"tag_name was used by an immutable release"`.
3. **Bypasses CI** — no provenance attestation, no SBOM, no artifact signing. The release is created directly with whatever you attach manually.
4. **Skips version file bumps** — source code still shows the old version.

`--verify-tag` removes the first two: gh's own help (2.100.0) reads *"Abort in case the git tag doesn't already exist in the remote repository"*, so the invocation can only publish against a tag that was pushed on purpose — and `guard-lightweight-tag.py` is what makes sure that tag was annotated and signed. Points 3 and 4 are not about the flag at all: they are about whether a workflow is doing the work, and they are why the flag is an exemption rather than a licence.

So the hooks block `gh release create` only without `--verify-tag` (and `--verify-tag=false` counts as without), and `gh release delete` always. `gh release edit` is allowed only for `--notes`/`--notes-file` flags (release description overhaul). Reading `--help` is allowed for any subcommand.

**Which of the two flows applies is a property of the repository, not a preference.** If a workflow creates the release object, that workflow is the only thing that may create it. If none does — because the supply-chain workflows listen on `release: published`, which a `GITHUB_TOKEN`-created release never fires (see `typo3-ter-publishing.md`) — then a human credential must create it, and `gh release create … --verify-tag` is that step. That second case is a gap to close rather than a flow to keep: the build then runs in the repository, which is SLSA Build Level 2 at best. Add a tag-push release workflow that calls the org reusable for the artefact (`release-source-archive.yml`, `release-go-app.yml`, `release-typo3-extension.yml` — see `ci-workflow-templates.md`), and the first case applies from then on. Establish which case you are in by reading the workflows, not by trying the command:

```bash
grep -rln "on:" .github/workflows | xargs grep -ln "release:" ; grep -rn "gh release create\|softprops/action-gh-release\|create-release" .github/workflows
```

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
6. For TYPO3 extensions, also update the rendered docs changelog:
   Documentation/Changelog.rst, or Documentation/Changelog/Index.rst where the
   extension keeps it as a directory. Measured over twelve agent trials
   preparing one release, this was the one file none of them touched — while
   ext_emconf.php and CHANGELOG.md were updated in every unaided trial. Nothing
   downstream catches it: TER publishes, CI stays green, and docs.typo3.org
   serves the old version.
7. Commit: "chore: prepare release vX.Y.Z"
8. Push branch and open PR
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

#### A release is a milestone — batch related changes into one

A release is a verified milestone, not a reflex after every merged commit.
Group related work into **one** release: a licensing change, two workflow
fixes and new checkpoints make one minor release, not four. A patch release
needs at least one meaningful fix; formatting alone, such as a trailing
newline, waits for the next real release. If the previous release went out
less than an hour ago, add the new change to the next one instead of cutting
another. The green-CI precondition is checked by
`scripts/validate-pre-release.sh` ("CI checks passing"): a failed run of HEAD
fails it, while unfinished or missing runs only warn.

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

The netresearch `release-go-app.yml` orchestrator appends `## Container image` and `## Verify your download` sections after `## Changes`; the library and source-archive orchestrators — every TYPO3 extension release among them — start their CI blocks with `## Installation`, followed by blocks such as `## Publication status`, `## Security` and `## SBOM`. Replacing the whole body with your narrative destroys them (and the verify commands are non-trivial — see supply-chain-security.md on `--signer-workflow`). Capture the tail and re-append it:

```bash
# jq -j writes the body exactly as stored; `--jq .body` appends a newline the
# stored body does not have, and the recipe would publish it
gh release view vX.Y.Z --repo owner/repo --json body | jq -j .body > /tmp/orig.md
# everything from the FIRST CI block on — whichever of them the body opens with
awk '/^## (Installation|Container image|Verify your download)$/{f=1} f' /tmp/orig.md > /tmp/tail.md
cat my-narrative.md /tmp/tail.md > /tmp/final.md                 # narrative replaces ONLY ## Changes
gh release edit vX.Y.Z --repo owner/repo --notes-file /tmp/final.md
```

Check `/tmp/tail.md` before the edit: an empty file means the body carries none of these headings, and the edit would drop whatever CI appended. Read the body and add its first CI heading to the pattern. Observed 2026-09-24 on six TYPO3 extension releases: the first CI block of each was `## Installation`, so the `## Container image` cut captured nothing, and the capture with `--jq .body` put one extra trailing newline into the first body published from it.

Then re-check the emitted verify commands are correct for a reusable-workflow build (`--signer-workflow`, not `--repo` alone).

**Capture the body BEFORE the first `gh release edit`, and never rebuild a lost block from a sibling release.** The capture above only works while the original body still exists; after the edit it is gone, and the reflex is to copy the block out of the previous release and rewrite its version strings. That previous release is an output of the same pipeline and usually carries the same damage — so the repair inherits it, and the check cannot object, because its comparison set is exactly those siblings: a block destroyed in every release on the line is invisible to `release-notes-status.sh` and the verdict reads `ok`. The authority is the workflow that emits the block. Read the `Compose release body` step of the orchestrator (`release-go-app.yml` around line 790) and reconstruct from it. Observed 2026-09-22 on `netresearch/ldap-manager` v1.7.0: the overhaul destroyed `## Container image` and `## Verify your download`, the checker flagged only the second, the first was restored from v1.6.0 — which had lost it to an earlier overhaul — and both releases went out without the image reference.

**Publish behaviour differs by orchestrator.** `release-go-app.yml` (go apps) publishes the release **directly** on tag push — not a draft — with all assets attached, so the overhaul edits a live release. `golib-create-release.yml` (go libraries) creates a **draft** that must be published manually with `gh release edit vX.Y.Z --draft=false` (a permitted flag) after CI finishes. Check `gh release view --json isDraft` to know which you have. Note: `gh release view --json isLatest` is NOT a valid field — query `gh api repos/OWNER/REPO/releases/latest` for the latest tag instead.

#### Verify each publication claim before reporting the release done

Tag-push is not the finish line. If the body (or a boilerplate section the workflow appends) asserts a package was published — TER, Packagist, docs, npm — **independently confirm each claim before reporting success**, rather than trusting the template's wording. Many release workflows publish AND verify these channels themselves; do not assume a channel is a separate manual step without reading the release workflow. Quick checks: Packagist `https://repo.packagist.org/p2/<vendor>/<pkg>.json` (note tags are `v`-prefixed), TER `https://extensions.typo3.org/api/v1/extension/<ext_key>/versions`, docs an `HTTP 200` on the versioned docs URL. Report what you verified, not what the template claimed.

**Parse the TER response before you believe its answer.** That endpoint returns a **nested** array — `[[{"number": "0.29.0", …}, …]]` — not a flat list, and TER numbers carry no `v` prefix while Packagist's do. The obvious one-liner therefore throws on the outer list, and a check written as "if this fails, the channel is not serving it" reports a publication failure that did not happen. That is the exact false negative this whole paragraph exists to prevent, so verify against the shape:

```bash
curl -sf "https://extensions.typo3.org/api/v1/extension/<ext_key>/versions" | python3 -c '
import json, sys
d = json.load(sys.stdin)
versions = [v["number"] for v in (d[0] if d and isinstance(d[0], list) else d)]
print("<X.Y.Z>" in versions)'
```

An HTTP error and a parse error are different outcomes and deserve different words: say "TER answered, 0.29.0 is listed", or "TER answered and my parse was wrong", never "TER query failed" for the second.

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

**Where the release workflow builds the body from `CHANGELOG.md`, the credit belongs in the CHANGELOG entry.** Some workflows extract the new version's section with `sed` and publish it as the body — `netresearch/terraform-provider-ad` does. Such a body carries exactly the `@mentions` its CHANGELOG entries carry. If the entries credit nobody, every release fails `release-notes-status.sh` with `MISSING CREDITS` and needs a hand edit after publishing, and a release nobody edits stays uncredited: that repository's v0.5.3 still is. Write the credit into the entry itself — `([#43](https://github.com/owner/repo/pull/43) by @login)` — so the extraction publishes it. For a release already out without it, add the credit with `gh release edit --notes-file`, and credit the next entries in the CHANGELOG. Use the bare `@login` in `CHANGELOG.md` too: the copied `[@login](https://github.com/login)` arrives in the body as a plain link, which is not a mention and notifies nobody. A profile link is fine in a `README.md` or `CONTRIBUTING.md`, which are read in the repository tree and never copied into a release body.

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

**Rule:** this guidance does **not** override the policy above. Where a workflow publishes the release, it does so and the agent does not run `gh release create` at all. This subsection applies to the tag-only case: repos without a publishing workflow, where the release is created by hand against an already-pushed signed tag. There, pass `--latest=false` for non-default-branch releases:

```bash
# Backport release on TYPO3_11 branch while main is on v13.
# The tag was created with git tag -s and pushed first; --verify-tag makes gh
# abort rather than create it, which is the condition the guard checks for.
gh release create v11.0.17 \
  --verify-tag \
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

#### A dispatch input that feeds `actions/checkout` must carry a FULL commit SHA

`actions/checkout` resolves a value it does not recognise as a 40-character SHA by fetching it as a branch or tag name:

```
git fetch --depth=1 origin +refs/heads/3f677090*:... +refs/tags/3f677090*:...
```

An abbreviated SHA is an unqualified ref, so checkout looks for a branch and then a tag of that name. Two outcomes, and the quiet one is worse:

- **Nothing matches** — the fetch brings back nothing and every job in the run dies at checkout, before any step that would have said something useful. The `git fetch` line above with your value spliced into the refspecs is the tell.
- **Something matches** — a branch or tag that happens to carry that name is checked out instead, the run goes green, and the evidence describes a commit nobody asked about. Nothing in the log looks wrong.

Because the second outcome is silent, a job that takes a ref input is worth one assertion after checkout:

```yaml
- name: Confirm the checked-out commit
  run: |
    test "$(git rev-parse HEAD)" = "$EXPECTED" \
      || { echo "::error::checked out $(git rev-parse HEAD), expected $EXPECTED"; exit 1; }
  env:
    EXPECTED: ${{ inputs.ref }}
```

This bites hardest on a pre-release evidence check, where the input is naturally a commit rather than a tag:

```bash
# wrong — dies at checkout in every job
gh workflow run release-evidence.yml -f ref=3f677090

# right
gh workflow run release-evidence.yml -f ref="$(git rev-parse HEAD)"
```

Cost when it happened: a full evidence run — four jobs including a complete mutation pass — with nothing measured, and the run still counts as a failed attempt in the workflow's history.

For repos using the shared release workflow template at `skills/github-release/templates/release-generic.yml`, file a patch there to expose a `make_latest` input (keep the name underscored to match GitHub's own action parameter; hyphenated names would force bracket-expression access, which is easy to get wrong) rather than forking per-repo.

## Multi-Repo / Bulk Releases

When releasing many repositories that share one reusable release workflow (e.g. a fleet of skill or library repos), coordinate rather than firing all at once:

1. **Pilot one repo end-to-end first.** Take a single known-clean repo all the way through bump → PR → merge → tag → CI-publish before touching the rest. The pilot proves the shared reusable workflow is healthy and pins down the exact per-repo recipe. Fix any workflow breakage on the pilot, not across N repos.
2. **Survey scope from the remote, not local checkouts.** Decide which repos actually need a release with `gh api repos/OWNER/REPO/compare/$LATEST_TAG...$DEFAULT_BRANCH --jq '.ahead_by'` and inspect the commit subjects — release only repos with user-facing `feat:`/`fix:`/`docs:` changes; skip those whose only commits are `ci:`/`chore(deps):`. Local worktrees can be stale (they may still show removed workflow inputs or an old default branch); always re-survey against `origin`.
3. **Fan out in small batches.** Process ~5–7 repos per batch, not one mega-pass. Small batches keep an agent's context from being exhausted mid-fleet and avoid tripping server-side rate limits on rapid PR/clone bursts.
4. **Run the notes overhaul as a separate pass.** The Phase 5 description overhaul is the step most likely to run out of context in a combined loop — do the bump→merge→tag→publish pipeline for the whole batch first, then a second pass for narrative notes via `gh release edit --notes-file`.
5. **Handle "drift" repos.** If a repo's version file was already bumped ahead of its latest tag, the next tag is `max(natural_bump, current_version_in_file)` — use the pre-bumped value (unless that version was already published/burned, in which case bump higher).

## The 0.x → 1.0 Release: What Changes Besides the Number

A patch or minor release ships changes. A first stable release ships a **promise**, and three
things that were optional until then become binding. It is also the release a project does once,
so nobody has the routine.

**1. The promise itself, written where a consumer reads it.** From 1.0 on, an incompatible change
to a public class, method or setting needs a new major. Put that sentence in the changelog entry,
not only in a commit message, and set the state that carries it in the ecosystem's own metadata —
for a TYPO3 extension `'state' => 'stable'` in `ext_emconf.php`, which is a separate field from
the version and is easy to leave at `beta` while every version surface says 1.0.0.

**2. Every deprecated API the release removes has its consumers migrated first.** See the next
section for the order; at 1.0 this is not a nicety, because a 1.0 is where the removals get
batched.

**3. Every test suite the repository ships is invoked by CI.** A suite that exists but is never
run is not a gate, and a first stable release is where that gap becomes a claim about quality.
List both sides and read them side by side. This is a **prompt, not a comparison**: the two
commands do not produce matching identifiers, and neither sees a suite launched through a
project script or a reusable workflow. It is here so the question gets asked at all.

```bash
# suites the repo declares
grep -o 'name="[^"]*"' Build/phpunit*.xml phpunit*.xml 2>/dev/null | sort -u
ls -d Tests/*/ 2>/dev/null

# what CI invokes — plus the callers, which hide the command in another repository
grep -rhoE '(runTests\.sh -s [a-z:]+|phpunit[^|]*--testsuite [a-z]+|npx (playwright|vitest)[a-z ]*)' \
    .github/workflows/ | sort -u
grep -rhoE 'uses: [^ ]+\.ya?ml@' .github/workflows/ | sort -u   # follow each one
```

For every suite in the first list, name where the second list runs it, and follow a reusable
workflow into its own repository rather than assuming its name covers the suite. A suite you
cannot place is either wired up before the release or named in the release notes as not running. `nr_passkeys_fe` 1.0.0 shipped 19 end-to-end specifications that
every file skipped with a blanket `test.skip()` and no workflow invoked; the release notes had to
say so, and the suite was built for real in 1.0.1.

Two more surfaces that only matter at 1.0: the documentation version (a docs build pinned to
`main` keeps serving the pre-release manual), and a dependency range that still allows the 0.x of a
sibling package you are releasing in the same batch.

## Releasing a Dependency: the Consumer's CI Races the Registry

When the repo you just released is a **dependency of another repo you are also working on**, the consumer's PR has a window in which its CI is guaranteed to fail for a reason that has nothing to do with its code.

Sequence that causes it:

1. You merge and tag the upstream release.
2. You mark the dependent PR ready (or push to it) while the release workflow is still running.
3. The consumer's dependency-install step resolves against registry metadata that does not yet list the new version.

Every dependency-installing job fails at once, with a message that reads like a real constraint bug:

```
Root composer.json requires netresearch/nr-vault ^0.13.0,
found netresearch/nr-vault[dev-main, v0.1.0, ..., v0.12.2]
but it does not match the constraint.
```

Nothing is wrong with the PR. **Tell it apart from a genuine failure by comparing timestamps** before changing a single line:

```bash
gh run list --repo "$CONSUMER" --branch "$BRANCH" --limit 5 --json databaseId,createdAt,headSha
gh release view "v$VERSION" --repo "$UPSTREAM" --json publishedAt --jq .publishedAt
```

A run created before `publishedAt` is the race. The fix is a replay:

```bash
gh run rerun "$RUN_ID" --repo "$CONSUMER" --failed
```

This is the one case where re-running an old run is correct — the usual caveat that a re-run replays the **old commit** does not bite, because the commit was never the problem; only external package availability changed.

**Re-run every failed workflow, not just the main CI one.** Separate workflows each hold their own failure. After re-running only `ci.yml` a PR can still show several red checks from `Checks`, `E2E Tests`, or license/audit workflows. Some runs (`Copilot`) report "cannot be rerun" — harmless if the bot review itself landed.

**Avoid it entirely** by ordering the work: merge upstream → tag → wait for the release workflow **and** the registry to serve the new version → only then touch the dependent PR.

```bash
# Composer/Packagist — poll until the version is actually resolvable
composer show "netresearch/nr-vault" "$VERSION" >/dev/null 2>&1 && echo available
```

Observed 2026-07-30: 31 red checks on a consumer PR, zero real defects — CI created 16:13:27, release published 16:22:59.


## Releasing a Coupled Pair: the Consumer Migrates First

Where two packages you maintain are coupled — a frontend extension importing the backend
extension's services, a library and its bundle — a release that **removes** something they share
has an order, and the wrong order ships a combination that cannot work.

1. The consumer migrates to the new API and merges, while its constraint still allows the old
   dependency version.
2. The dependency releases the removal.
3. The consumer opens its constraint to the new major and releases.

Doing it the other way round — remove first, migrate afterwards — leaves a window in which the
published pair is broken for anyone who installs both at their newest version.

Two checks before the removal, neither of which the dependency's own repository can answer:

```bash
# the consumer's whole tree, not just Classes/ — a caller can sit in a template,
# in JavaScript, in a fixture or in configuration
git -C /path/to/consumer grep -n "removedMethodName" -- ':!vendor' ':!.Build' ':!node_modules'

# who else declares the dependency
gh search code "netresearch/the-dependency" --owner netresearch --limit 50
```

Measured in this fleet on 2026-09-20: `nr_passkeys_be` 1.0.0 removed two `RateLimiterService`
methods after a grep that covered only its own repository. `nr_passkeys_fe` called both, at three
sites. The broken pair was unreachable only because the consumer's `^0.12` constraint refused the
new major — luck, not order.

## A 0.x Minor Release: Every Consumer Pinned to the Previous Minor Refuses It

On a 0.x version the caret stops at the minor: `^0.35` admits 0.35.9 and refuses 0.36.0. So a 0.x minor release of a package other packages depend on is, for Composer, a new major. An installation that should run it cannot resolve it while **any** package in its lock still requires `^0.35` — including consumers the release never touched, which then need a widened constraint **and a release of their own** before the installation can move. Their `main` does not count; an installation resolves released versions.

List them before planning the release, from the lock of the installation that has to run it, not from memory:

```bash
# every locked package that requires the dependency, with its constraint
jq -r --arg dep netresearch/nr-llm \
  '.packages[] | select(.require[$dep]) | "\(.name) \(.version) \(.require[$dep])"' composer.lock
```

Every line whose constraint refuses the new minor is a release you owe first. Two checks per consumer before widening: its own `main` may already carry the widening unreleased, and the dependency's changelog and public API diff between the two tags decide whether the consumer needs more than the constraint — a new enum case breaks only code that matches the enum exhaustively.

Observed 2026-09-23 on the TYPO3 demo: nr-llm 0.36.0 was released for the demo, and the demo bump then found four more packages pinned to `^0.34 || ^0.35` or `^0.35`. Three of them needed a release before the lock resolved; the fourth is installed from `dev-main` and needed only a merge.

## Prove an Unproven Pipeline With an `-rc` Tag First

Before the first real tag on a pipeline that has not succeeded **in its current
form**, cut a release-candidate tag and let it run end to end.

Check the history rather than assuming, because "it released fine last year" and
"it works today" are different claims:

```bash
WID=$(gh api "repos/$REPO/actions/workflows" --jq '.workflows[]|select(.path|test("release"))|.id')
gh api "repos/$REPO/actions/workflows/$WID/runs?per_page=10" \
  --jq '.workflow_runs[]|"\(.created_at[:10]) \(.head_branch) \(.conclusion)"'
```

A run of `0` jobs with *"this run likely failed because of a workflow file
issue"* is a **startup failure** — the workflow never began. Common causes: a
caller that does not grant every permission the reusable workflow declares, or
an invalid workflow file.

```bash
git tag -s v1.1.0-rc.1 -m "v1.1.0-rc.1" && git push origin v1.1.0-rc.1
```

Most release workflows detect the `-rc` / `-alpha` / `-beta` suffix and mark the
result a prerelease, so it does not take the *Latest* badge from the real
version. If the run fails, only a candidate tag is spent — not the version you
meant to publish, which cannot be reused once its release has been created and
deleted.

**The real payoff is diagnostic.** When the actual `v1.1.0` run then fails, a
green RC tells you it is not the configuration. In one case the failure was
`GCP AsymmetricSign: CANCELLED` from Sigstore, on one of eight architectures,
with the other seven fine — transient upstream trouble. Without the RC that was
indistinguishable from a broken pipeline. Re-running the failed jobs was enough,
and because `Atomic publish` had been skipped, no release existed and the tag
was still unspent.

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
