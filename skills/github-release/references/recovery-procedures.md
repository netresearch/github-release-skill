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
   **Which flavour of re-run matters when the fix lives in a reusable workflow.** [The documentation is explicit](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations): *"Re-running all jobs in a workflow will use the reusable workflow from the specified reference"*, while *"Re-running failed jobs or a specific job in a workflow will use the reusable workflow from the same commit SHA of the first attempt."*

   So a caller binding `uses: org/repo/.github/workflows/x.yml@main` picks up a fix merged after the run only on a **full** re-run:

   ```bash
   gh run rerun <run-id>              # re-resolves @main — picks the fix up
   gh run rerun <run-id> --failed     # locked to the first attempt's SHA — does not
   gh run rerun <run-id> --job <id>   # same lock
   ```

   `--job` takes the job's `databaseId`. That is the number in the Actions URL (`…/runs/<run-id>/job/<id>`), but when the id came from anywhere else, read it rather than guess:

   ```bash
   gh run view <run-id> --json jobs --jq '.jobs[] | "\(.databaseId)  \(.name)"'
   ```

   `--failed` is the reflex, because it is cheaper and the skill recommends it elsewhere for a flaky signing step. When the failure is in the reusable itself, it is the one that cannot work. Observed: `--failed` on a release run kept executing the pre-fix copy and failed identically; the fix arrived only on a run that resolved `@main` again. Confirm which copy a run used:

   ```bash
   gh api repos/OWNER/REPO/actions/runs/<run-id> \
     --jq '[.referenced_workflows[]? | "\(.path) @ \(.sha[0:8])"]'
   ```

   Only if a full re-run is unavailable or also fails does a **fresh** run become the answer. `release.yml` usually triggers on tag push alone, so that means deleting and re-pushing the tag — safe as far as the publish steps are idempotent (`publish-to-ter.yml` HEADs the download URL and skips a version already on TER) and worth confirming per step first.
3. If the workflow was never triggered:
   - Verify the workflow file exists and has correct `on: push: tags:` trigger
   - Verify the tag was actually pushed: `git ls-remote --tags origin | grep vX.Y.Z`
   - Manually trigger if the workflow supports `workflow_dispatch`
4. If the draft exists but is incomplete:
   - Re-run the failed workflow to re-attach artifacts
   - Or manually upload artifacts to the draft via GitHub UI
5. **User publishes**: once the draft looks correct, the user publishes via GitHub UI

**Important**: The tag is NOT burned while the release is in draft state. If the draft is fundamentally broken, you can delete it and recreate.

## Draft Is Expected (Netresearch Go Libraries) — Publishing Is Human-Gated

**Symptom**: A Go-library release workflow ran to `success`, all artifacts (SBOMs, signed `checksums.txt`, provenance) are attached, but `gh release view vX.Y.Z --json isDraft` reports `draft=true`. Older tags (e.g. the previous minor) sit as drafts too.

**Cause — this is by design, not a failure.** The `netresearch/.github` reusable `golib-create-release.yml` exposes a `draft` input that **defaults to `true`** ("recommended"). A repo whose `release.yml` calls it with no `with:` block inherits that default, so every release is created as a draft for a human to review and publish. (Contrast: the **application** reusable `release-go-app.yml` publishes directly — those releases come out `draft=false`.)

**You cannot publish it from the CLI.** The release guard blocks every mutating path, so do not burn turns trying:

```bash
gh release edit vX.Y.Z --draft=false           # blocked: only --notes/--notes-file allowed
gh api --method PATCH repos/OWNER/REPO/releases/ID -F draft=false   # blocked: mutating release ops must go through CI
```

**Resolution**:

1. Everything up to the publish gate is your job and is finishable: signed tag, artifacts, and an overhauled narrative body (editing `--notes` **is** allowed — do it while the release is still a draft).
2. **The user publishes** the reviewed draft via the GitHub UI (Releases → edit the draft → *Publish release*). Hand them the releases URL; do not present the draft as an incomplete deliverable.
3. To make **future** releases auto-publish instead of drafting, change the repo's `release.yml` to pass `draft: false` to the reusable (a normal PR) — this is a deliberate policy change, so confirm with the maintainer rather than doing it unprompted.

## Release Workflow Startup-Failure (Deleted `@main` Reusable)

**Symptom**: The tag push triggered the release workflow, but the run shows
**`failure` with ZERO jobs** — `gh run view <id> --json jobs` returns
`{"jobs":[],"total":0}` and the run page says *"This run likely failed because
of a workflow file issue."* No release is created.

**Cause**: `release.yml` calls a reusable workflow pinned to a moving ref
(`uses: org/.github/.github/workflows/<name>.yml@main`), and that reusable was
**renamed or removed upstream** since the last release. GitHub cannot resolve the
`uses:` target, so the run fails at startup before any job begins. Pinning
reusables to `@main` makes releases silently hostage to upstream template drift.

**Diagnosis** — a startup-failure exposes no annotations, so check each reusable
still exists on the pinned ref:

```bash
# For every uses: org/.github/.github/workflows/<wf>.yml@main in release.yml:
gh api "repos/org/.github/contents/.github/workflows/<wf>.yml?ref=main" --jq '.name'
# → "Not Found" (404) is the culprit. Then find its replacement:
gh api "repos/org/.github/contents/.github/workflows?ref=main" --jq '.[].name' | grep -i release
```

**Recovery** — the tag is **NOT burned** (verify: `gh release view vX.Y.Z` →
"release not found" means no Release object was created). Fix the workflow, then
**backfill without re-tagging**:

1. Sync `release.yml` to the current template (or repoint the `uses:` refs to the
   renamed reusables), open a PR, merge it.
2. Re-trigger the SAME tag via `workflow_dispatch` — this runs the fixed workflow
   from the default branch while building the existing tag's commit:
   ```bash
   gh workflow run release.yml --ref main -f tag=vX.Y.Z
   ```
   (Requires `release.yml` to declare `workflow_dispatch` with a `tag` input — the
   standard go-app/backfill pattern.)
3. After it publishes, overhaul notes with `gh release edit vX.Y.Z --notes-file …`
   and do **not** re-run the workflow (it regenerates the body).

**Prevention**: prefer pinning org reusables to a tag/SHA over `@main`, or run a
periodic template-drift check so a removed reusable surfaces before a release.

## Sigstore/Rekor 409 on Checksum Signing

**Symptom**: The release workflow's signing/attestation step (cosign / sigstore) fails with:

```
Error: signing SHA256SUMS.txt: signing bundle: error signing bundle:
[POST /api/v1/log/entries][409] createLogEntryConflict
{"message":"an equivalent entry already exists in the transparency log with UUID ..."}
```

**Cause**: A transient conflict in the Sigstore Rekor public transparency log — an equivalent entry already exists for the artifact being signed. It is **not** a problem with your tag. If the workflow validates the tag signature and the tag-vs-version-file match *before* the signing step (as the netresearch skill-repo release workflow does), those gates have already passed by the time a 409 occurs — so recreating the tag would not help. Confirm via the failed-job log that the failure is the signing step and not an earlier validation gate; then the release simply needs the job re-run.

**Recovery**: Re-run the failed job — do **not** recreate the tag (the tag is fine, and recreating it risks burning the name):

```bash
gh run rerun <run-id> --repo <owner>/<repo> --failed
```

`--failed` re-runs only the failed jobs. This is safe: it creates no new tag and there is no published release/notes to clobber yet. In a 19-repo bulk release this hit roughly 3 repos; every re-run published cleanly on the second attempt.

## Lightweight Tag Already Pushed

**Symptom**: `git cat-file -t vX.Y.Z` returns `commit` instead of `tag` (meaning it's lightweight, not annotated).

**Cause**: Someone ran `git tag vX.Y.Z` without `-s` or `-a`, or `gh release create` created it.

**Recovery if no release was published against it**:

**Registry check first**: if the package is on Packagist/TER, the pushed
tag is already published downstream regardless of GitHub release state —
do NOT delete + re-tag; follow "Wrong tag already pushed: registries
publish on tag push" in `immutable-releases.md` instead.

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

## Release Workflow Never Fired (Tag Pattern Does Not Match)

**Symptom**: Same as "Missing CI Release Workflow" above — a tag is pushed and
no release appears. The difference is that a workflow *does* exist and reads
correctly, so the section above sends you looking for a file that is already
there.

**Cause**: `on.push.tags` does not match how this repository spells its tags.
The common case is a workflow that lists only `'v*'` in a repository that tags
without a prefix (`12.0.2`, `13.0.6`, `14.0.0`), or the reverse. No run is
queued, no run fails, and nothing is logged anywhere.

**Why it stays invisible for weeks**: Packagist (and npm, via its own
provenance webhook) publishes from the tag independently of GitHub Actions, so
`composer require` keeps resolving the new version and the package looks
released. Only the channels the workflow owns — the GitHub release, its signed
artifacts, and the TER publish — are missing. In one extension this went
unnoticed for seven weeks.

**Detection** — the tell is an *empty* run list, not a failed one:

```bash
gh run list --workflow=release.yml --limit 5     # nothing at all → never triggered
gh release view <tag>                            # "release not found"
git ls-remote --tags origin | awk -F/ '{print $NF}' | grep -v '\^{}' | tail -5
yq '.on.push.tags' .github/workflows/release.yml
```

Hold the last two against each other: the tag spellings the repository actually
uses versus the patterns the workflow accepts. A rerun cannot help — `gh run
rerun` needs a run, and there is none.

**Recovery**:

1. Fix the trigger to accept both spellings, and say in a comment why both are
   there so the next sync from a template does not drop one:
   ```yaml
   on:
     push:
       tags:
         - 'v*'
         - '[0-9]+.[0-9]+.[0-9]+'
   ```
2. **Cut a new patch release.** A workflow fix does not trigger retroactively,
   and the tag that missed its run is not moved (see `immutable-releases.md`).
   Bump every version surface, merge, then tag the new version in the spelling
   the repository uses — that tag is what carries the missed release's content
   to the channels it never reached.
3. Do **not** reach for `gh release create` to paper over it — not even with
   `--verify-tag`, which addresses the tag, not the missing artifacts. A hand-made
   release has no artifacts, no checksums, no signatures and no registry
   publish. The guard does not stop you here: `--verify-tag` passes it, because
   what it checks is whether a tag can be created by accident, not whether the
   release is the right thing to make. This one is your judgement, not a
   control.
4. Verify against the registries rather than the run's own summary: the release
   exists, and the TER/npm page shows the new version.

The CHANGELOG entry for that patch release should say which version it
publishes and which change set it carries — they are not the same number, and a
reader looking for an artifact under the old one will not find it.

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

## Release Titles Differ From the Tag

**Symptom**: Releases carry a title such as `QuickRoute v1.21.0` while the
convention here is the bare tag (`gh release create … --title "vX.Y.Z"`),
and the maintainer wants the existing ones renamed.

**Cause**: The release workflow sets its own `--title`. The pattern
`--title "<Project> $TAG"` tends to arrive with a hand-written packaging
step and is copied from release to release without a reason.

**Prevention**: Set `--title "$TAG"` in the workflow. A store upload that
lists files outside the repository (a CurseForge `displayName`, for
example) may keep the project name; the GitHub release page shows the
repository name already.

**Recovery** (existing releases): the agent cannot do it. `guard-gh-release.py`
blocks `gh release edit --title` and every mutating `gh api` call on a
releases endpoint, with no override, and that is intended. Hand the
maintainer a script instead, and let them run it with the `!` prefix:

1. List the releases whose title is exactly `<Project> <tag>`:
   `gh api "repos/$R/releases?per_page=100" --paginate --jq '.[] | select(.name == "<Project> " + .tag_name) | "\(.id)\t\(.tag_name)"'`.
2. Dry run by default: print each planned rename and change nothing.
   Rename only on `--apply`, and only titles that match exactly.
3. Per release: `gh api -X PATCH "repos/$R/releases/$ID" -f name="$TAG"`,
   then read `.name` back and count a mismatch as a failure. Only the title
   changes; tag, notes and assets stay.
4. Run the dry run yourself first and show its output with the `--apply`
   command. The guard sees only the script call, not the `gh` calls inside
   it, so it would let `--apply` through as well: leaving `--apply` to the
   maintainer is your part, not something the guard enforces.

Measured on CybotTM/wow-quickroute (2026-09-23): 20 of 30 releases carried
the prefixed title, none marked `immutable`; all 20 were renamed and read
back without a failure. Afterwards check that no release has a title
different from its tag:
`gh api "repos/$R/releases?per_page=100" --paginate --jq '.[] | select(.name != .tag_name) | .tag_name'`
must print nothing. A release with an empty `name` shows up here too;
GitHub displays its tag as the title, so it needs no rename.

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
- [ ] CI release workflow exists, and its `on.push.tags` patterns match the
      spelling this repository actually tags in — `yq '.on.push.tags'` against
      `git ls-remote --tags origin`. "Exists" is not enough: a `v*`-only
      pattern in a repository that tags unprefixed queues no run at all, and
      the failure looks like nothing happening. See *Release Workflow Never
      Fired* above
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
