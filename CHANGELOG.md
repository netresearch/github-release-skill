# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file starts at 0.12.1. Earlier releases are on the
[releases page](https://github.com/netresearch/github-release-skill/releases);
their notes were not backfilled here rather than reconstructed after the fact.

## [Unreleased]

## [1.0.4] - 2026-09-20

### Changed

- `references/recovery-procedures.md`: a release workflow that never fired looks like nothing at all — no run, no failure, no red check — so the recovery path now starts by establishing whether the workflow was dispatched, rather than by reading a run that does not exist

## [1.0.3] - 2026-09-18

### Added

- `references/npm-staged-publishing.md`, named in the skill's contents list. `npm stage publish` puts a version into npm's staging area rather than the registry, where it is not installable until a maintainer approves it with 2FA — so an automated workflow can produce a release without holding a credential that can publish on its own. The page carries the version floor (`npm stage` first shipped in npm 11.15.0, and what decides a CI job is the npm its Node bundles, so Node 22.23.2 at npm 10.9.8 has no such command while Node 24 does), the two registry states a release workflow walks into, and how to capture the stage id. All of it read out of `npm-stage(1)` and `lib/commands/stage/` as shipped with npm 12.0.2
- `references/recovery-procedures.md` distinguishes the two re-run flavours where the fix lives in a reusable workflow. GitHub resolves `uses: org/repo/.github/workflows/x.yml@main` again only on a full `gh run rerun`; `--failed` and `--job` stay locked to the first attempt's SHA, so the reflex re-run keeps executing the pre-fix copy and fails identically. The section names `gh run view <run-id> --json jobs` as where a `--job` id is read rather than guessed, and the `referenced_workflows` query that says which copy a run actually used
- `references/release-process.md` documents that a dispatch input feeding `actions/checkout` must carry a full 40-character commit SHA. An abbreviated one is an unqualified ref, so checkout fetches it as a branch or tag name: either nothing matches and every job dies at checkout, or something does and the run goes green against a commit nobody asked about. The section carries the post-checkout assertion that catches the silent case

### Fixed

- `guard-lightweight-tag.py` no longer blocks a force-push whose tag refs are all bare major pointers (`v4`). A moving major pointer is not a published release — consumers pin it because it moves, and the block's advice to cut `vX.Y.Z+1` is meaningless for it, while the immutable releases it points at are untouched. Blocking it did not prevent the move, it pushed the author to the tags API, which cannot sign the tag

## [1.0.2] - 2026-09-17

### Fixed

- The changelog entry for 1.0.1 identified the benchmark case the description was measured on by its identifier. A case name in a skill is readable by an agent working on that case, and the finding does not need it: what the runs showed is that the last file a release touches is the one left behind, which holds wherever a project states its version in more than one place

## [1.0.1] - 2026-09-17

### Fixed

- The skill description now names every file a version lives in. Measured over eighteen release-preparation runs under a small model: agents prepared the release and updated three of the four places a TYPO3 extension states its version, and eight of nine failures in one round were `CHANGELOG.md` alone, with `ext_emconf.php`, `guides.xml` and the rendered changelog page all carrying the new version. `references/ecosystem-detection.md` already lists every file with the pattern to change, but a reference is read only by an agent that opens the skill, and these runs mostly did not — the description is what reaches it
- The description named "the rendered changelog page" as a role rather than a place. The skill's own reference allows two layouts — `Documentation/Changelog.rst` for a single file, `Documentation/Changelog/Index.rst` for a directory — so naming one path would be wrong for extensions using the other. The description now names the directory, which covers both, and the reference keeps the two filenames
- Two references and the two remaining script comments cited a repository by name for observations that do not need one: a Packagist block after a retag, a release run where four publication paths failed independently, `grep -q` behind a pipe reporting a found match as a failure, and a comparison across release lines asking a v12 patch for blocks a v13 line introduced. The mechanism is the finding and the name applies to one repository only; the measurements stay (52,989 bytes, first match at byte 2,474, 25 of 40 runs at 141)

## [1.0.0] - 2026-09-16

### Added

### Changed

### Fixed

## [0.12.3] - 2026-09-11

### Changed

- The two PreToolUse guards now share one invocation splitter,
  `scripts/_invocations.py`. It was developed in the tag guard (issue #105, plus
  the heredoc handling in 0.12.2) while the release guard kept a simpler copy,
  and the copies drifted apart until one was blind to what the other handled.
  The tag guard's behaviour is unchanged: its 67 cases pass before and after.

### Fixed

- `guard-gh-release.py` judged a whole Bash call as one string and required
  `gh` to sit directly after a separator, so ten dangerous shapes walked past
  it. A newline is a command separator exactly as `;` is, but the call was
  flattened with `" ".join(command.split())` and the separator set held only
  `[;&|]` — so `gh release create` on its own line was never seen. Nor was one
  behind a prefix: `sudo gh release create`, `GH_TOKEN=x gh release delete`,
  one inside a loop body or a subshell, and `gh api …/releases -X DELETE` on
  its own line. Under immutable releases a `gh release create` burns that tag
  name permanently, so this was the wrong direction to be wrong in. The guard
  now splits the call into invocations and judges each on its own, anchored at
  the start of the invocation — so the words inside `echo "never run gh release
  create v1.2.3"` or inside a heredoc body stay words.

## [0.12.2] - 2026-09-11

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

[Unreleased]: https://github.com/netresearch/github-release-skill/compare/v1.0.4...HEAD
[1.0.4]: https://github.com/netresearch/github-release-skill/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/netresearch/github-release-skill/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/netresearch/github-release-skill/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/netresearch/github-release-skill/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/netresearch/github-release-skill/compare/v0.12.3...v1.0.0
[0.12.3]: https://github.com/netresearch/github-release-skill/compare/v0.12.2...v0.12.3
[0.12.2]: https://github.com/netresearch/github-release-skill/compare/v0.12.1...v0.12.2
[0.12.1]: https://github.com/netresearch/github-release-skill/compare/v0.12.0...v0.12.1
