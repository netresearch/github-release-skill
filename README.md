<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# github-release-skill

Claude Code skill plugin for safe, automated GitHub releases with supply chain security.

## Problem

AI coding agents (Claude Code, Copilot, etc.) naturally reach for a bare `gh release create` when asked to "create a release". This:

1. Creates **lightweight unsigned tags** instead of signed annotated tags
2. Creates **immutable releases** that permanently burn tag names (no recovery)
3. **Bypasses CI pipelines** that handle SBOMs, attestations, and signing

This skill prevents these mistakes structurally via hooks and provides the correct release orchestration.

## Features

- **Guard hooks**: Block `gh release delete`, `gh release edit` beyond notes, a `gh release create` that could create the tag (i.e. without `--verify-tag`), and lightweight tag creation — at the tool level
- **Ecosystem detection**: Auto-detect project type (TYPO3, PHP, Node.js, Go, Python, Rust, skill repos)
- **Version management**: Suggest next semver version from conventional commits, update all version files
- **Release orchestration**: Version bump PR → merge → signed tag → CI handles the rest
- **Health checks**: Validate release workflow, tag integrity, supply chain security
- **CI templates**: Release workflow templates with SBOM, cosign, attestation support

## Commands

| Command | Description |
|---------|-------------|
| `/release` | Full release: detect, bump, PR, tag, CI |
| `/release-prepare` | Version bump PR only (tag manually) |
| `/release-status` | Release health check |

## Installation

### Claude Code Marketplace (recommended)

Installed automatically via the Netresearch marketplace.

### Composer

```bash
composer require --dev netresearch/github-release-skill
```

### npm (Node Projects)

```bash
npm install --save-dev \
  @netresearch/agent-skill-coordinator \
  github:netresearch/github-release-skill
```

Requires [@netresearch/agent-skill-coordinator](https://github.com/netresearch/node-agent-skill-coordinator), which discovers the skill in `node_modules` and registers it in `AGENTS.md` via a `postinstall` hook. For pnpm, also allowlist the coordinator's postinstall:

```json
{
  "pnpm": {
    "onlyBuiltDependencies": ["@netresearch/agent-skill-coordinator"]
  }
}
```

> **Limitation:** This installation method only registers the skill's `SKILL.md` content (procedural knowledge that the agent reads). The slash commands (`/release`, `/release-prepare`, `/release-status`) and the PreToolUse guard hooks defined in `.claude-plugin/` are **not** loaded by Claude Code when the skill is installed via npm — those require Claude Code's plugin mechanism. To get the full skill (slash commands + guard hooks + procedural knowledge), install via the [Claude Code Marketplace](#claude-code-marketplace-recommended) instead.

### Manual

Download the latest release and extract to `~/.claude/plugins/`.

## How It Works

1. **Hooks intercept** dangerous commands before execution
2. **Ecosystem detection** finds all version files in the project
3. **Version bump** updates all files and promotes CHANGELOG
4. **PR workflow** ensures changes go through review and CI
5. **Signed tag** (`git tag -s`) triggers the release workflow
6. **CI pipeline** creates the GitHub release with SBOMs, signatures, and attestations

## Supported Ecosystems

| Ecosystem | Version Files |
|-----------|--------------|
| TYPO3 | ext_emconf.php, composer.json, Documentation/guides.xml |
| PHP/Composer | composer.json |
| Node.js | package.json, package-lock.json |
| Go | Tags only (no version files) |
| Python | pyproject.toml, setup.py |
| Rust | Cargo.toml |
| Skill repos | plugin.json, SKILL.md metadata |

## Governance and policies

This repository follows the Netresearch organisation policies:

- [Governance](https://github.com/netresearch/.github/blob/main/GOVERNANCE.md): ownership, roles, how decisions are made and disputes resolved, and continuity.
- [Roadmap](https://github.com/netresearch/.github/blob/main/ROADMAP.md): planned and explicitly excluded work for the coming year.
- [Handling of dependency and code analysis findings](https://github.com/netresearch/.github/blob/main/SECURITY.md#handling-of-dependency-and-code-analysis-findings): thresholds, deadlines and the exception process for dependency (SCA) and static analysis (SAST) findings.
- [Secret management](https://github.com/netresearch/.github/blob/main/SECURITY.md#secret-management): how CI and release credentials are stored, accessed and rotated.
- [Access roster](https://github.com/netresearch/.github/blob/main/docs/access-roster.md): who holds administrative access to this repository and the organisation.

The security assurance case for this skill (threat model, trust boundaries, countermeasures and limits) is in [docs/SECURITY-ASSURANCE.md](docs/SECURITY-ASSURANCE.md).

Checks that run on pull requests in this repository:

- Every pull request: Skill Validation (`lint.yml` and `validate.yml`: skill structure, markdownlint, yamllint, actionlint, JSON syntax, ShellCheck, ruff, checkpoint schema; `validate.yml` runs ShellCheck at style severity), Eval Validation (`eval-validate.yml`) and Script Tests (`script-tests.yml`, every `skills/github-release/scripts/tests/*.test.sh`).
- Pull requests to `main`: `security.yml` with Betterleaks (secret scanning), zizmor (workflow static analysis), dependency review, Composer Audit and Opengrep SAST; Harness Verification (`harness-verify.yml`) and Template Drift (`check-template-drift.yml`). The organisation's security policy sets when dependency review and Opengrep fail: see [dependencies](https://github.com/netresearch/.github/blob/main/SECURITY.md#dependencies-software-composition-analysis) and [static analysis (SAST)](https://github.com/netresearch/.github/blob/main/SECURITY.md#static-analysis-sast).
- Also on every pull request: Labeler (`labeler.yml`), the DCO sign-off check and SonarCloud Code Analysis (both GitHub Apps) and, for dependency-update pull requests, auto-merge (`auto-merge-deps.yml`). CodeQL for `actions` and `python` runs through GitHub's default setup.

## License

- Code: [MIT](LICENSE-MIT)
- Content (skill instructions, documentation): [CC BY-SA 4.0](LICENSE-CC-BY-SA-4.0)
