<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Security assurance case — github-release-skill

This document states what a user can expect from this repository in terms of security, and argues why that expectation holds. Every claim names the file that implements it; script and test names without a directory are under `skills/github-release/scripts/`. Reporting a vulnerability: see the [security policy](https://github.com/netresearch/.github/blob/main/SECURITY.md).

## What the repository ships

| Part | Files | Runs where |
| --- | --- | --- |
| Skill instructions for an AI agent | `skills/github-release/SKILL.md`, `skills/github-release/references/*.md`, `commands/*.md` | Read by the agent as instructions; not executed. The agent may run the `gh` and `git` commands they describe against the user's repositories. |
| Guard hooks | `hooks/hooks.json`, `skills/github-release/scripts/guard-gh-release.py`, `skills/github-release/scripts/guard-lightweight-tag.py`, `skills/github-release/scripts/_invocations.py` | On the user's machine, as Claude Code `PreToolUse` hooks on every Bash tool call, when the skill is installed as a plugin. |
| Helper scripts | `skills/github-release/scripts/*.sh`, `skills/github-release/scripts/check-changelog-links.py` | On the user's machine, with the user's `git` and `gh` authentication. |
| Templates | `skills/github-release/templates/*` | Copied by the user or the agent into the user's repository; they run there as that repository's release workflows and git hook. |
| Checkpoints | `skills/github-release/checkpoints.yaml` | Only when an assessment tool runs them in a user's project. |
| Repository checks | `skills/github-release/scripts/tests/*.test.sh`, `.github/workflows/*.yml` | In this repository's CI and on contributors' machines. |

The repository ships no server component and no container image. It stores nothing and handles no user accounts or credentials of its own; the scripts use whatever token `gh` is authenticated with.

## Security requirements

1. The guard hooks block the release operations they name in their headers — a `gh release create` that can create the tag, `gh release delete`, a `gh release edit` beyond the notes, a mutating `gh api` call on a release endpoint, a lightweight version tag, and the deletion of a version tag or a force-push that names `refs/tags/v*` or uses `--tags` — in the spellings the guards recognise (see "What a user cannot expect"). Beyond those, the release guard blocks every other `gh release` subcommand except `view`, `list` and `download` (for example `upload` and `verify`), and it errs toward blocking a `gh api` call on a release endpoint whose method it cannot read.
2. The guards never execute the command they judge.
3. The helper scripts and the checkpoints only read: they change no remote state and send no write request to GitHub.
4. Nothing committed to this repository contains a secret.
5. A release is built from a signed, annotated tag, and its archives can be verified against the build that produced them.

## Actors and trust boundaries

- **Skill user and agent.** The agent reads the skill and runs `gh` and `git` with the user's authentication. What it runs is decided by the agent and the user. `allowed-tools` in `SKILL.md` only pre-approves `gh`, `git`, `Read`, `Write`, `Edit`, `Glob` and `Grep`; it does not take any tool away from the agent.
- **Hook payload.** Claude Code passes each Bash tool call to the guards as JSON on stdin. The command text is untrusted input: the guards parse it (`parse_command` in both guards, `split_invocations` in `_invocations.py`) and only decide an exit code. Exit code 2 blocks the call; 0 allows it.
- **GitHub and registries.** The scripts read from GitHub through `gh api` and from `raw.githubusercontent.com`, `repo.packagist.org` and `extensions.typo3.org` through `curl`. Responses are treated as data and compared, not executed.
- **Assessed project.** The checkpoints run in the working directory of the project an assessment tool checks, with the privileges of whoever starts that tool.
- **Contributors and CI.** Changes reach `main` through pull requests checked by `.github/workflows/`. Workflows start from `permissions: {}` (except `validate.yml`, which grants `contents: read` at the top) and each job is granted only the scopes its reusable workflow needs. The two `pull_request_target` workflows (`auto-merge-deps.yml`, `labeler.yml`) call reusables that merge or label and do not check out pull request code; `auto-merge-deps.yml` passes two named secrets instead of `secrets: inherit`.

## Threats and countermeasures

| Threat | Countermeasure | Evidence |
| --- | --- | --- |
| An agent runs `gh release create` without an existing tag, which creates an unsigned lightweight tag and, under immutable releases, burns the tag name | Blocked unless the last `--verify-tag` occurrence is on; `--verify-tag=false`, a repeated flag, a flag inside a quoted argument or behind a shell comment do not count | `guard-gh-release.py` (`_verify_tag_is_on`, `_strip_quoted`); `tests/guard-gh-release-invocations.test.sh` |
| An agent deletes or rewrites a published release outside CI | `gh release delete`, unknown `gh release` subcommands and every `gh release edit` flag other than the notes flags are blocked; `gh api` calls on release endpoints with POST, PUT, PATCH, DELETE, an unreadable method, or data flags without GET/HEAD are blocked | `guard-gh-release.py` (`_check_invocation`, `_judge_gh_api`); `tests/guard-gh-release-invocations.test.sh` |
| An agent creates an unsigned version tag, or deletes or force-pushes one | `git tag v*` without `-s`, `-a`, `-m` or `-F` is blocked, as are `git tag -d v*`, `git push --delete … v*`, `git push … :refs/tags/v*` and force-pushes that name `refs/tags/v*` or use `--tags` (bare major pointers such as `v4` excepted) | `guard-lightweight-tag.py`; `tests/guard-tag-invocations.test.sh` |
| A guarded command hides inside a larger Bash call — on its own line, in a loop, a subshell, behind `sudo` or an env assignment | Each call is split into its invocations first, with quoting, escapes and heredoc bodies handled, and every invocation is judged on its own | `_invocations.py` (`split_invocations`, `strip_heredoc_bodies`, `INVOCATION_PREFIX`); both invocation test files |
| The payload shape changes and the guards silently stop working | The command is read from `tool_input.command`, with a top-level `command` as fallback | `parse_command` in both guards; `tests/guard-payload-shape.test.sh` |
| Crafted input makes a guard hang past its 2-second hook timeout (CWE-1333) | `gh api` arguments are split with `shlex` in linear time instead of backtracking regexes | `guard-gh-release.py` (`_judge_gh_api`); `hooks/hooks.json` (`timeout: 2`) |
| The command under judgement is executed by the guard (CWE-78) | Besides `_invocations.py`, the guards import only `json`, `re`, `shlex` and `sys`; they parse the text and exit, and nothing in them starts a process | `guard-gh-release.py`, `guard-lightweight-tag.py`, `_invocations.py` |
| A helper script changes remote state | The scripts send only read requests (`gh api` GETs, GraphQL queries, `curl` GETs); commands that would write are printed as a suggested next step, not run | `release-status.sh`, `release-notes-status.sh`, `harvest-contributors.sh`, `validate-reusable-workflows.sh` |
| A failing step continues with partial state | Every shell script directly under `scripts/` (not the tests in `scripts/tests/`) runs with `set -euo pipefail`; `release-status.sh` fetches remote files into a `mktemp -d` directory removed by an `EXIT` trap | the scripts named |
| A release is published from an unsigned tag or its archives are tampered with | The release workflow verifies that the tag is annotated and signed, publishes a Cosign-signed `SHA256SUMS.txt` and build-provenance attestations for the archives | `.github/workflows/release.yml` (calls the `netresearch/skill-repo-skill` release reusable) |
| A secret is committed | Betterleaks scans every push to `main` and every pull request to `main` | `.github/workflows/security.yml` |
| A vulnerable or malicious dependency is added | Dependency review checks the dependencies a pull request adds or changes against known vulnerabilities; Composer Audit checks the Composer dependencies; Renovate proposes updates | `.github/workflows/security.yml`, `renovate.json` |
| Insecure code or workflow patterns | Opengrep scans the code for insecure patterns; zizmor analyses the workflows; ShellCheck (at style severity in `validate.yml`) and ruff run on every pull request | `.github/workflows/security.yml`, `.github/workflows/validate.yml`, `.github/workflows/lint.yml` |
| A guard or script regresses unnoticed | Every `*.test.sh` under `scripts/tests/` runs on each pull request and push to `main` | `.github/workflows/script-tests.yml` |

Which of these checks must pass before a pull request can merge is set in the branch protection of `main`, not in this repository.

## Secure design principles applied

- **Least privilege:** the helper scripts and checkpoints only read; workflows start from explicit `permissions`.
- **Fail-safe defaults inside a guard:** an unknown `gh release` subcommand, an unreadable `gh api` method, unbalanced quotes around a release path and an unrecognised `--verify-tag` value all block (`guard-gh-release.py`).
- **Complete mediation:** each invocation of a Bash call is judged, not only the first match (`check_command` in both guards).
- **Economy of mechanism:** the guards need the Python standard library only; the scripts need bash, `git`, `gh`, `jq` and `curl`.

## What a user cannot expect

- The guards are a guard rail against mistakes, not a security boundary. They read the command text; a command assembled at run time — from a variable, a script file, or a pipeline such as `echo vX.Y.Z | xargs git tag` (documented in `guard-lightweight-tag.py`) — is not seen. They run only when the skill is installed as a Claude Code plugin; the npm installation does not load them (README.md).
- The tag guard matches the literal spelling of a command: `tag` or `push` directly after `git`, and a force-push only as `refs/tags/v*` or `--tags` together with `-f`, `--force` or `--force-with-lease` as separate arguments. Other spellings are not blocked, among them options before the subcommand (`git -C <dir> tag vX.Y.Z`, `git -c … push`), bundled short flags (`git push -fq …`), a tag named without `refs/tags/` (`git push -f origin vX.Y.Z`) and a `+` refspec without a `:refs/tags/…` destination (`git push origin +refs/tags/vX.Y.Z`). The release guard likewise needs `release` directly after `gh`: `gh -R <repo> release delete …` is not blocked.
- A guard that cannot read its input allows the command: empty or unreadable stdin exits 0 (`main` in both guards; `tests/guard-payload-shape.test.sh`).
- The skill gives guidance; the agent runs `gh` and `git` with the user's token, and a token with the necessary rights can do anything the references describe. Review what an agent proposes to run.
- The templates are examples to adapt. `release-typo3.yml` and `ter-publish.yml` call `netresearch/typo3-ci-workflows` reusables at `@main`, not at a commit SHA.
- Checkpoints GR-7, GR-12 and GR-13 run scripts from the assessed project's `vendor/bin/`; run an assessment only in projects you trust.
- Security fixes follow the supported-versions rules of the organisation's security policy; older releases may not receive them.
