# github-release-skill

Claude Code skill plugin for safe, automated GitHub releases with supply chain security.

## Problem

AI coding agents (Claude Code, Copilot, etc.) naturally reach for `gh release create` when asked to "create a release". This:

1. Creates **lightweight unsigned tags** instead of signed annotated tags
2. Creates **immutable releases** that permanently burn tag names (no recovery)
3. **Bypasses CI pipelines** that handle SBOMs, attestations, and signing

This skill prevents these mistakes structurally via hooks and provides the correct release orchestration.

## Features

- **Guard hooks**: Block `gh release create/delete/edit` and lightweight tag creation at the tool level
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

## License

- Code: [MIT](LICENSE-MIT)
- Content (skill instructions, documentation): [CC BY-SA 4.0](LICENSE-CC-BY-SA-4.0)
