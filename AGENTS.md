# github-release-skill

AI agent skill plugin for safe GitHub releases.

## Architecture

```
.claude-plugin/plugin.json    Plugin metadata and version
hooks/hooks.json              PreToolUse guards (blocks gh release, lightweight tags)
skills/github-release/
  SKILL.md                    Core skill instructions (<500 words)
  checkpoints.yaml            Automated validation (11 mechanical + 3 LLM reviews)
  evals/evals.json            30 evaluation scenarios
  references/                 Extended documentation
  scripts/                    Guard hooks + utility scripts
  templates/                  CI workflow templates
commands/                     /release, /release-prepare, /release-status
```

## Release Process (for this skill itself)

1. Bump version in `.claude-plugin/plugin.json` AND `skills/github-release/SKILL.md` metadata
2. Commit: `chore: release vX.Y.Z`
3. Create signed tag: `git tag -s vX.Y.Z -m "vX.Y.Z"`
4. Push: `git push origin main vX.Y.Z`

**NEVER use `gh release create`.** The release workflow handles GitHub release creation.
