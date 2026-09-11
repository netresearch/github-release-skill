# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file starts at 0.12.1. Earlier releases are on the
[releases page](https://github.com/netresearch/github-release-skill/releases);
their notes were not backfilled here rather than reconstructed after the fact.

## [Unreleased]

### Added

### Changed

### Fixed

- The tag guard read heredoc bodies as script. A heredoc body is data the
  command writes, not commands it runs, so a file documenting
  `git tag -d vX.Y.Z` was judged as a deletion of that tag. The body reached
  `split_invocations` intact, its separators split it into segments, and a
  quoted example was then checked as a real invocation. Because a denied call
  runs none of its parts, the file was never written and re-running the same
  call was denied identically -- so the guard blocked the commit messages,
  docs and tests that quote its own examples, this repository's included.
  Bodies are now dropped before splitting; the opener line, the terminator
  and everything around them are still inspected, including the `<<-`
  indented and unquoted-delimiter forms. Dropping only happens where a body
  provably ends: `<<` is also an arithmetic left shift, so `$(( FLAG <<
  SHIFT ))` looks exactly like an opener whose delimiter is `SHIFT`, and a
  here-string (`<<<`) looks like one whose delimiter is its word. Neither is
  ever terminated, and stripping on sight would have swallowed the rest of
  the command -- a real tag deletion on a later line included.

## [0.12.1] - 2026-09-09

### Fixed

- The tag guard judged a whole command by its first `git tag` occurrence. It
  collapsed newlines into spaces and captured to the end of the command, so one
  match decided the verdict for everything after it — in both directions. A
  read-only listing was blocked when a later, unrelated line held a version
  token, and once that first match returned early on `-l`, a real tag creation,
  tag deletion or tag force-push further along the same command was never
  examined ([#105](https://github.com/netresearch/github-release-skill/issues/105)).
- Splitting the command applied separators wherever they appeared and ignored
  grouping entirely. An invocation inside a subshell, a brace group or a command
  substitution was invisible, while a separator inside a quoted argument split
  one invocation into two and reported a commit message as a lightweight tag.
  A `\"` inside a double-quoted argument was read as the closing quote, which
  hid the invocation that followed
  ([#112](https://github.com/netresearch/github-release-skill/issues/112)).
- The guard blocked forms that create no lightweight tag: the read-only
  inspection flags git treats as implying `--list` (`-n`, `--contains`,
  `--points-at`, `--merged`, `--sort`, `--format`, `--column`, `--ignore-case`),
  and `-m`/`-F`, which imply `-a`. It allowed a quoted tag name, which creates
  exactly the tag the bare form creates. `git tag --delete vX.Y.Z` was reported
  as a lightweight tag rather than as a deletion.

### Changed

- The shipped TER callers (`templates/release-typo3.yml`, `templates/ter-publish.yml`
  and the pattern in `references/ter-republish.md`) show how to pass
  `exclude-from-packaging`, commented out with the reason beside it: the shared
  workflow fails the job when the path does not exist, so an active line would
  break every adopter without that exact file
  ([#104](https://github.com/netresearch/github-release-skill/issues/104)).
- `references/ter-republish.md` no longer names three specific extension
  repositories where a generic phrase carries the same meaning
  ([#92](https://github.com/netresearch/github-release-skill/issues/92)).
- The `netresearch/skill-repo-skill` pre-commit hook moves to v2.0.1.

[Unreleased]: https://github.com/netresearch/github-release-skill/compare/v0.12.1...HEAD
[0.12.1]: https://github.com/netresearch/github-release-skill/compare/v0.12.0...v0.12.1
