# TER Re-Publishing Without Re-Tagging

This reference covers TYPO3-specific recovery when the TYPO3 Extension
Repository (TER) needs a re-upload but the Git tag is fine as-is.

## When to Use

You need to re-push to TER but NOT re-tag when:

- **Release notes were edited after the initial publish** — TER's upload
  comment is built from the GitHub release body, so editing the release
  on GitHub doesn't automatically refresh TER. A re-publish does.
- **The initial `tailor ter:publish` failed transiently** (idle timeout,
  TER API hiccup) but the tag is already pushed and the GitHub release
  is already created correctly.
- **A TER-only fix** (e.g. a broken upload comment from a previous
  release workflow version) without introducing a new version.

Re-tagging (delete tag, re-create, push) is NOT appropriate in any of
these cases — the tag itself is already correct and immutable releases
will refuse a second publish attempt on the same tag name anyway.

## The `workflow_dispatch`-Only Caller Pattern

Add a dedicated manual-trigger caller alongside the normal tag-triggered
`release.yml`. Pattern used across netresearch TYPO3 extensions
(t3x-nr-llm, t3x-nr-mcp-agent, t3x-nr-image-optimize):

```yaml
# .github/workflows/ter-publish.yml
name: Publish to TER (manual)

on:
  workflow_dispatch:

permissions: {}

jobs:
  publish-to-ter:
    uses: netresearch/typo3-ci-workflows/.github/workflows/publish-to-ter.yml@main
    permissions:
      contents: read
    secrets:
      TYPO3_TER_ACCESS_TOKEN: ${{ secrets.TYPO3_TER_ACCESS_TOKEN }}
```

That is the whole file. No inputs, no outputs.

**A note on `TYPO3_EXTENSION_KEY`.** Older caller workflows (including
the `release-typo3.yml` template shipped alongside this reference) pass
both `TYPO3_EXTENSION_KEY` and `TYPO3_TER_ACCESS_TOKEN`. The shared
`publish-to-ter.yml` in `netresearch/typo3-ci-workflows` marks
`TYPO3_EXTENSION_KEY` as `required: false` with the description
`Deprecated: extension key is auto-resolved from composer.json`. The
downstream "Resolve extension key" step reads
`extra.typo3/cms.extension-key` from `composer.json` and hard-errors if
it's missing, so the composer.json entry is the single source of truth.
New callers should omit the forward; existing callers can keep it but
it's a no-op.

Triggered via:

```bash
gh workflow run ter-publish.yml --repo owner/ext --ref main
# or --ref TYPO3_12 on a maintenance branch
```

## Why `--ref <branch>`, not `--ref <tag>`

GitHub's `workflow_dispatch` API rejects `--ref <tag>` with HTTP 422 if
the workflow file does not exist at that tag. Common situation: the
`ter-publish.yml` caller was added *after* older tags were published, so
they don't have the file.

Dispatching against the branch (`main`, `TYPO3_12`) always works. The
shared `publish-to-ter.yml` reusable workflow in
`netresearch/typo3-ci-workflows` reads the version from `ext_emconf.php`
(single source of truth), then derives the matching release tag by
trying `v${VERSION}` first and falling back to bare `${VERSION}`. That
lets it look up the GitHub release body for the TER upload comment even
when invoked from a branch ref.

## What Gets Re-Published

The shared workflow produces identical output between the tag-triggered
`release.yml` and the manual `ter-publish.yml`:

1. Reads `ext_emconf.php` version (say `1.1.1`)
2. Finds matching release — `v1.1.1` or `1.1.1`
3. Fetches the release body via `gh release view`
4. Strips HTML, truncates to ~1900 chars using codepoint-aware slicing
5. Calls `tailor ter:publish --comment "$COMMENT" "$VERSION"`

TER accepts re-uploads of the same version number — the upload comment
simply gets overwritten. This is the documented behaviour of the
`POST /extension/{key}/{version}` endpoint.

## Triggering From the CLI

```bash
# Main branch — re-push the current version on main
gh workflow run ter-publish.yml --repo owner/ext --ref main

# Maintenance branch — re-push the current version on TYPO3_12
gh workflow run ter-publish.yml --repo owner/ext --ref TYPO3_12

# Watch until done
RUN=$(gh run list --repo owner/ext --workflow=ter-publish.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN" --repo owner/ext --exit-status
```

## Codepoint-Safe Comment Truncation

TER has a ~2000 character limit on upload comments. Byte-based truncation
with `head -c 1900` splits multi-byte UTF-8 sequences (emoji, em-dashes,
accented characters) mid-codepoint and produces invalid UTF-8 that TER
rejects or mis-renders.

The shared workflow uses `python3` for truncation because:

- Guaranteed codepoint-level slicing via Python's `str` indexing
- No locale assumptions beyond `LANG=*.UTF-8` (always set on
  `ubuntu-latest`)
- Independent of whether the runner's `awk` is `gawk` or `mawk`
  (ubuntu-latest historically ships both and codepoint support differs)
- No `RS=""` paragraph-mode side effects — preserves blank lines,
  leading/trailing whitespace, and the original line-break structure up
  to the truncation boundary
- Installed on every GitHub Actions runner

```bash
COMMENT=$(
    printf '%s' "$RELEASE_BODY" \
      | sed 's/<[^>]*>//g' \
      | python3 -c 'import sys; sys.stdout.write(sys.stdin.read()[:1900])'
)
```

**Caveat on the `sed` step.** The HTML-stripping regex `<[^>]*>` is
deliberately dumb: it also removes **non-HTML** content wrapped in
angle brackets. If your release notes contain any of the following,
they will be silently dropped from the TER comment:

- GFM autolinks — `<https://github.com/...>` vanishes
- Markdown placeholder syntax — `<prev-tag>`, `<version>`, `<name>`
- Generic type examples in code fences — `<T>`, `<UserResponse>`
- Literal angle-bracket content in prose — `<noreply@github.com>`

If your project routinely uses any of these in release notes, either:

1. Switch to a whitelist-based sanitizer (e.g. strip only specific
   known-unsafe HTML tags), or
2. Skip HTML stripping entirely and rely on TER's own rendering.

The full GitHub release body is always available via the release
page link appended to the comment, so the tradeoff between safety
and readability is mostly cosmetic.

Note: use `printf '%s'`, not `echo`. `echo "$BODY"` interprets release
bodies starting with `-n` / `-e` / `--` as options rather than emitting
them literally.

## Tag Format Compatibility

Historic TYPO3 extensions used bare-version tags (`1.0.3`, `1.1.0`);
modern signed-tag convention uses a `v` prefix (`v2.2.2`, `v1.1.1`).
Both forms are valid Git tags and both should be accepted by release
tooling.

The shared `publish-to-ter.yml` regex is:

```
^refs/tags/v?[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$
```

And the version variable strips both prefixes:

```bash
TAG="${GITHUB_REF#refs/tags/}"
VERSION="${TAG#v}"
```

If a custom per-project caller has its own tag-check or version-resolve
logic, apply the same pattern. See the
`netresearch/typo3-ci-workflows/.github/workflows/publish-to-ter.yml`
reference implementation.

## Related

- `recovery-procedures.md` — generic release recovery
- `release-process.md` — the standard release flow
- `immutable-releases.md` — why we can't just re-tag
