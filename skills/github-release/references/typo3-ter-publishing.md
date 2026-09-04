# TYPO3 TER Publishing Gotchas

This reference covers TYPO3-specific failure modes when publishing an
extension *for the first time* on a given version (initial publish, not
re-publish — for re-publishing without re-tagging, see
`ter-republish.md`).

## Version Match Required Between Tag and `ext_emconf.php`

`tailor ter:publish` validates that the version it is uploading matches
the `'version'` key in `ext_emconf.php`. If they disagree it aborts
with:

```
configured version does not match
```

`ext_emconf.php` is the **single source of truth** for this validation.
Bump it before tagging (e.g. `'version' => '0.6.0'` for tag `v0.6.0`).

`Documentation/guides.xml` (`version=` and `release=` attributes on the
`<project>` element) should also be kept in sync — not because TER
validates against it, but because docs.typo3.org renders the wrong
version banner if it drifts. Same release branch, same commit, same PR.

The Git tag (`v0.6.0`) is the second source of truth that must agree
with `ext_emconf.php` at the moment CI runs `tailor ter:publish`. The
release-prep PR pattern documented in `release-process.md` (Phase 1)
already enforces this ordering — bump version files in the release
branch, merge the PR, *then* tag the merge commit. The reason that
ordering exists, beyond clean history, is that any other ordering
produces a tag pointing at commits with stale version files and TER
refuses the upload.

**Don't tag first, bump second.** A signed tag at the wrong commit is
not free to fix: deleting and recreating a signed tag burns the GPG
signature on the new tag (different SHA), invalidates any provenance
attestation that referenced the old SHA, and on GitHub immutable
releases (GA Oct 2025) burns the tag name permanently if a release was
already created against it.

## `v` Prefix Mismatch in Custom Publish Workflows

Git tags conventionally use a `v` prefix (`v0.6.0`); `ext_emconf.php`
stores the bare version (`0.6.0`). A workflow that compares
`${GITHUB_REF#refs/tags/}` directly against the `ext_emconf.php` value
will compare `v0.6.0` against `0.6.0` and silently fail validation.

The fix is to derive the bare version in a `run:` step (GitHub Actions
`env:` blocks do **not** perform shell parameter expansion — `${TAG#v}`
in `env:` is taken literally), and pass `github.ref` straight to
`actions/checkout`:

```yaml
- uses: actions/checkout@<sha>
  with:
    ref: ${{ github.ref }}              # refs/tags/v0.6.0 — finds the tag

- name: Resolve version
  run: |
    TAG="${GITHUB_REF#refs/tags/}"      # v0.6.0 — for human-facing logs
    VERSION="${TAG#v}"                  # 0.6.0  — for ext_emconf.php compare + tailor
    echo "TAG=$TAG" >> "$GITHUB_ENV"
    echo "VERSION=$VERSION" >> "$GITHUB_ENV"

- name: Publish
  run: |
    test "$VERSION" = "$(php -r '$EM_CONF=[]; include "ext_emconf.php"; echo $EM_CONF[basename(__DIR__)]["version"];')" \
      || { echo "::error::tag $TAG vs ext_emconf.php mismatch"; exit 1; }
    tailor ter:publish --comment "..." "$VERSION"
```

`actions/checkout` wants the raw ref so it can find the tag; the
`ext_emconf.php` comparison and the `tailor ter:publish` argument want
the bare version. Conflating them produces the same `configured version
does not match` failure as section 1 above, but for a different reason
— the comparison is wrong, not the file content.

**If you use the shared reusable workflow you get this for free.**
`netresearch/typo3-ci-workflows`'s `publish-to-ter.yml` already
implements the strip pattern (see the regex and `VERSION="${TAG#v}"`
snippet in `ter-republish.md` § Tag Format Compatibility). Both
`templates/release-typo3.yml` and `templates/ter-publish.yml` in this
skill repo wire that workflow up correctly.

This gotcha only bites if you write your own per-project publish
workflow that bypasses the shared reusable workflow. If you do, mirror
the three-variable pattern.

## A 500 From the Publish Is Not a Failed Publish

TER can apply the upload and still answer with an error. `tailor` reports
what it received, so the job goes red:

```
Publishing version 5.0.2 of extension contexts
==============================================

 [WARNING] Could not publish version 5.0.2 of extension contexts.
           Reason: Unknown (Status 500)

##[error]Process completed with exit code 1.
```

The version was on TER anyway. Ask the API before concluding anything —
never re-cut a version off the exit code alone:

```bash
curl -s -H 'Accept: application/json' \
  https://extensions.typo3.org/api/v1/extension/<key>/versions \
  | jq -r '[.[0][].number] | sort_by(split(".")|map(tonumber? // 0)) | reverse | .[0:5]'
```

(That response is a nested array and its numbers carry no `v` prefix —
see `release-process.md`, which covers the parsing trap separately.)

**The expensive part is the second-order damage.** In
`netresearch/typo3-ci-workflows`'s `release-typo3-extension.yml`,
`create-release` has `needs: publish-to-ter` and requires it to be
`success` or `skipped`. A red TER job therefore **skips the GitHub
release**, and anyone checking GitHub sees no release and reads the
whole thing as failed — while TER and Packagist are both serving the
version.

Recovery is a re-run of the failed jobs, not a new tag: the
`Check if version is already on TER` step now finds the version, the
publish step is skipped, and `create-release` runs.

```bash
gh run rerun <run-id> --repo <owner/repo> --failed
```

Before declaring a release broken, check all four targets separately —
Packagist, TER, the rendered docs, and the GitHub release object. They
fail independently, and one red job in the run does not tell you which.

*Observed 2026-08-21 on `netresearch/t3x-contexts` v5.0.2, run
32534659449.*

## `release: published` Never Fires When CI Created the Release

A workflow action performed with the default `GITHUB_TOKEN` does not
create a new workflow run. Only `workflow_dispatch` and
`repository_dispatch` are exempt unconditionally; a `pull_request`
opened, synchronized or reopened this way does create a run, but in an
approval-required state. `release: published` has no exemption at all
([docs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow#triggering-a-workflow-from-a-workflow)).

So a release-creation workflow calling `gh release create` with
`GH_TOKEN: ${{ github.token }}` does publish a real, non-draft Release
— and a separate publish workflow listening on `release: published`
never sees it. The failure is quiet in an unhelpful way: every manual
`workflow_dispatch` test of the publish workflow keeps succeeding,
because that trigger was never subject to the restriction, so the
pipeline looks healthy while its advertised automatic path has never
run once.

**Our pipelines avoid this by construction, not by configuration.**
`netresearch/typo3-ci-workflows/.github/workflows/release-typo3-extension.yml`
calls `publish-to-ter.yml` as a `needs:` job inside the same run and
creates the GitHub Release afterwards. There is no event hop, so there
is nothing to fail. The gotcha only applies to a hand-rolled workflow
that chains two runs together — a repository outside the org, or one
that copied a standalone publish workflow instead of calling the
reusable one.

If you are maintaining such a workflow, trigger it on the tag push
itself rather than on the Release:

```yaml
on:
  push:
    tags:
      - 'v[0-9]+.[0-9]+.[0-9]+'
  release:
    types: [published]
```

Keep `release: published` as a secondary trigger: it still covers a
Release created by hand in the UI for a tag whose push never published.
Two triggers mean the same version can be attempted twice, so make the
workflow idempotent first — `curl -I` the version's TER download URL and
skip the upload on `200`. Do not assume that guard exists; the reusable
`publish-to-ter.yml` has it in a precheck step, a copied standalone
workflow may not.

Mind the pattern grammar: branch and tag filters support `*`, `**`,
`?`, `+`, `[]` and `!` — there is **no** `{n,m}` quantifier
([filter pattern cheat sheet](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#filter-pattern-cheat-sheet)).
A pattern like `v[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}` matches `{1,3}`
literally and therefore matches no real tag at all, which reproduces
the exact silence this section is about.

## `.gitattributes` Has No Effect on the TER Artifact

`tailor ter:publish` packs the **working directory**, not the git tree.
Given neither `--path` nor `--artefact`,
`UploadExtensionVersionCommand` hands `getcwd()` to
`VersionService::createZipArchiveFromPath()`; given `--path` it hands
that directory. Either way the method walks the filesystem through
`RecursiveDirectoryIterator` and never calls `git archive`, so
`export-ignore` — honoured only by `git archive`, and therefore by the
GitHub source tarball and the Composer dist built from it — does not
reach the upload. The only filter tailor applies is its own
`conf/ExcludeFromPackaging.php`. That asymmetry is the tell: a Composer
install of the same tag can look right while the TER artifact does not.

The overlap between the two lists is what hides this. Of the 26
`export-ignore` entries in one extension's `.gitattributes`, 15 were in
the published zip; of the 11 that were not, 9 sit in tailor's default
list anyway (`Tests`, `Build`, `.github`, `.ddev`, `Makefile`,
`composer.lock`, `.editorconfig`, `.gitignore`, and `.gitattributes`
itself) and 2 did not exist in the checkout. So the setting looks like
it works right up to the first path that only `.gitattributes` knows —
which then ships: `AGENTS.md`, a DDEV landing page (`index.html`), a
healthcheck stub (`phpstatus`), `renovate.json`, `crowdin.yml`,
`DDEV_SETUP.md` and six analysis reports, in a 176-entry artifact.

`crowdin.yml` is the instructive case. Tailor's default list carries
the `crowdin.yaml` spelling and not the `.yml` one, so a project that
configures nothing at all still inherits that gap.

**The override replaces the default list; it merges nothing.** The
exclude file is chosen by the `TYPO3_EXCLUDE_FROM_PACKAGING`
environment variable and must return an array carrying both keys, even
if one is empty:

```php
return [
    'directories' => ['.build', 'vendor', 'tests'],
    'files' => ['AGENTS.md', 'renovate.json'],
];
```

`VersionService::getExcludeConfiguration()` returns that array
verbatim. A path that does not exist raises `InvalidArgumentException`
and a missing `directories` or `files` key raises
`RequiredConfigurationMissing`, but an array that merely omits tailor's
own entries raises nothing — and the zip then carries `vendor/`,
`.git/` and the whole test suite. Compose the override onto the
defaults instead of restating them:

```php
$tailorDefaults = require __DIR__ . '/TailorDefaults-1.7.0.php';

return [
    'directories' => array_merge($tailorDefaults['directories'], [
        '.serena',
    ]),
    'files' => array_merge($tailorDefaults['files'], [
        'AGENTS.md',
        'crowdin.yml',
    ]),
];
```

The snapshot is a committed copy of the `conf/ExcludeFromPackaging.php`
that `typo3/tailor:^1` installs, so every upstream entry exists in one
place and refreshing the snapshot is the whole update. It also goes
stale silently when tailor adds an entry — diff it against
`vendor/typo3/tailor/conf/ExcludeFromPackaging.php` in a test if that
matters to you.

**The two keys match by different rules**, both case-insensitive, from
`VersionService::createZipArchiveFromPath()`:

- `directories` — `preg_match('/^' . $entry . '/i', $path)` against the
  path relative to the extension root. A root-anchored **prefix** match,
  and a `false` on a directory prunes the whole subtree. So `build` also
  matches `buildkite`, and the `/i` is why the lowercase defaults
  `build` and `tests` catch TYPO3's `Build/` and `Tests/`.
- `files` — `preg_match('/' . $entry . '$/i', $filename)` against the
  **basename** only. A **suffix** match, which is why the defaults omit
  leading dots (`gitignore` matches `.gitignore`) and why a file rule
  cannot be scoped to the root: `AGENTS.md` also removes the scoped
  copies under `Classes/`, `Documentation/` and `Resources/`.

**Entries are interpolated into the pattern raw.** No released tailor
runs them through `preg_quote()`: `quoteExcludePattern()` exists only on
`main` and is in no tag, `2.0.0` included — and `VersionService.php` is
byte-identical between `1.7.0` and `2.0.0`, so everything above holds
for both. Keep entries plain: `.` is a wildcard, a literal `/`
terminates the delimiter, and a nested directory needs the escaped form
`Resources\/Private\/Build`.

**In CI, pass the file through the reusable workflow's input.**
`netresearch/typo3-ci-workflows`'s `publish-to-ter.yml` takes an
`exclude-from-packaging` input
([#245](https://github.com/netresearch/typo3-ci-workflows/pull/245)),
forwarded by `release-typo3-extension.yml` and `republish.yml`. It sets
`TYPO3_EXCLUDE_FROM_PACKAGING` for the publish step, and rejects an
absolute path, a `..` component and a file missing from the checkout
before tailor runs.

```yaml
jobs:
  release:
    uses: netresearch/typo3-ci-workflows/.github/workflows/release-typo3-extension.yml@main
    with:
      exclude-from-packaging: Build/ExcludeFromPackaging.php
```

A republish has to pass the same value. The `workflow_dispatch` caller
in `ter-republish.md` takes no inputs, and dispatching that one repacks
the unfiltered set over a correct upload.

*Observed 2026-09-03 on `netresearch/t3x-nr-temporal-cache` 0.9.0 — 176
zip entries, 15 of the 26 `export-ignore`d paths among them.*

## Related

- `ter-republish.md` — re-publishing without re-tagging; tag-format
  compatibility regex
- `release-process.md` — the version-bump-then-tag ordering (Phase 1
  through Phase 3) that prevents the version-match failure
- `templates/release-typo3.yml` — tag-triggered TYPO3 release caller
- `templates/ter-publish.yml` — `workflow_dispatch` re-publish caller
- `typo3-conformance` skill, `references/ter-publishing.md` — the audit
  side: what a conformance check looks for in a publish setup
