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

## Related

- `ter-republish.md` — re-publishing without re-tagging; tag-format
  compatibility regex
- `release-process.md` — the version-bump-then-tag ordering (Phase 1
  through Phase 3) that prevents the version-match failure
- `templates/release-typo3.yml` — tag-triggered TYPO3 release caller
- `templates/ter-publish.yml` — `workflow_dispatch` re-publish caller
