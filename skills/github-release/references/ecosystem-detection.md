# Ecosystem Detection

## Purpose

Identify which version files need updating based on the project's ecosystem. A project may span multiple ecosystems (e.g., a TYPO3 extension is both PHP/Composer and TYPO3-specific).

## Detection Strategy

1. Check for ecosystem-specific files in priority order
2. A project can match multiple ecosystems — update ALL matching version files
3. Always check for generic files (CHANGELOG.md, VERSION) regardless of ecosystem

## Ecosystem Patterns

### TYPO3

**Detection**: `ext_emconf.php` exists in project root or extension directory.

| File | Field/Pattern | Example |
|------|--------------|---------|
| `ext_emconf.php` | `'version' => 'X.Y.Z'` | `'version' => '13.8.1'` |
| `composer.json` | `"version": "X.Y.Z"` | `"version": "13.8.1"` |
| `composer.json` | `extra.typo3/cms.version` (separate from `"version"`) | `"extra": {"typo3/cms": {"version": "13.8.1"}}` |
| `Documentation/guides.xml` | `version=` **and** `release=` attributes | `version="13.8.1" release="13.8.1"` |
| `Documentation/Changelog.rst` | rendered changelog page — add a `Version X.Y.Z (date)` section | `Version 13.8.1 (2026-...)` |
| `CHANGELOG.md` | stamp `[Unreleased]` → `[X.Y.Z] - date` **and** the footer compare links | `[13.8.1]: .../compare/v13.8.0...v13.8.1` |
| `Documentation/**/*.rst` | `.. versionadded:: X.Y.Z` | `.. versionadded:: 13.8.0` |
| `Documentation/**/*.rst` | `.. versionchanged:: X.Y.Z` | `.. versionchanged:: 13.8.1` |

Notes:

- **`composer.json` has TWO independent version surfaces.** Besides the
  top-level `"version"`, TYPO3 14's deprecation #108345 (drop the `ext_emconf.php`
  version in favour of composer metadata) means extensions also carry
  `extra.typo3/cms.version` (+ `providesPackages`). It is a *different* field from
  `"version"` and is easy to miss — a mismatch fails the extension's own
  `VersionConsistencyTest` in CI. Bump both.
- **`Documentation/guides.xml`** carries both `version` and `release` attributes;
  update both. This file drifts silently (it renders docs.typo3.org) and is a
  frequent miss.
- **`CHANGELOG.md`** needs the footer compare-link block updated too, not just the
  section stamp — the `[Unreleased]` link and a new `[X.Y.Z]` link.
- RST `versionadded`/`versionchanged` directives should only be updated when they
  reference the **current release being prepared**, not historical entries.

### PHP / Composer

**Detection**: `composer.json` exists (without `ext_emconf.php` for pure PHP).

| File | Field/Pattern | Example |
|------|--------------|---------|
| `composer.json` | `"version": "X.Y.Z"` | `"version": "2.1.0"` |

Note: Many Composer packages omit the `version` field entirely, relying on Git tags. Only update if the field already exists.

### Node.js

**Detection**: `package.json` exists.

| File | Field/Pattern | Example |
|------|--------------|---------|
| `package.json` | `"version": "X.Y.Z"` | `"version": "3.0.1"` |
| `package-lock.json` | `"version": "X.Y.Z"` (root) | `"version": "3.0.1"` |

Note: Update `package-lock.json` by running `npm install --package-lock-only` after bumping `package.json`, not by manual editing.

### Go

**Detection**: `go.mod` exists.

| File | Field/Pattern | Example |
|------|--------------|---------|
| `go.mod` | Module path for major versions | `module example.com/foo/v2` |

Note: Go is primarily tag-driven. Minor and patch releases require no file changes — only the Git tag. Major version bumps (v2+) require updating the module path in `go.mod` and all internal imports.

### Python

**Detection**: `pyproject.toml` or `setup.py` or `setup.cfg` exists.

| File | Field/Pattern | Example |
|------|--------------|---------|
| `pyproject.toml` | `version = "X.Y.Z"` | `version = "1.4.0"` |
| `setup.py` | `version="X.Y.Z"` | `version="1.4.0"` |
| `setup.cfg` | `version = X.Y.Z` | `version = 1.4.0` |
| `src/*/__init__.py` | `__version__ = "X.Y.Z"` | `__version__ = "1.4.0"` |
| `*/__init__.py` | `__version__ = "X.Y.Z"` | `__version__ = "1.4.0"` |

### Rust

**Detection**: `Cargo.toml` exists.

| File | Field/Pattern | Example |
|------|--------------|---------|
| `Cargo.toml` | `version = "X.Y.Z"` (under `[package]`) | `version = "0.5.2"` |
| `Cargo.lock` | Auto-updated | Run `cargo check` after bumping |

Note: Update `Cargo.lock` by running `cargo check` after bumping `Cargo.toml`, not by manual editing.

### Skill Repositories

**Detection**: `.claude-plugin/plugin.json` or `skills/*/SKILL.md` exists.

| File | Field/Pattern | Example |
|------|--------------|---------|
| `.claude-plugin/plugin.json` | `"version": "X.Y.Z"` | `"version": "0.1.0"` |
| `skills/*/SKILL.md` | `version: "X.Y.Z"` (in frontmatter `metadata`) | `version: "0.1.0"` |

Note: `skills/*/SKILL.md` is a glob — a repo may ship **multiple** skills (e.g. `jira-communication` + `jira-syntax`). Bump the `metadata.version` in **every** SKILL.md so each equals `plugin.json`.

Note: On GitHub this match is a **required CI check** — `Skill Validation` runs a step *"Validate SKILL.md metadata.version matches plugin.json"*, so a bump PR that touches only `plugin.json` is BLOCKED until every SKILL.md is bumped too. On GitLab the `ci-components/claude-code-skill` pipeline's `validate:version` only checks `plugin.json` (v-stripped) against the tag, not SKILL.md — bump SKILL.md anyway for consistency.

### Generic (Always Check)

These files are ecosystem-independent and should always be checked:

| File | Field/Pattern | Example |
|------|--------------|---------|
| `CHANGELOG.md` | Add new `## [X.Y.Z] - YYYY-MM-DD` section | `## [1.5.0] - 2026-04-10` |
| `VERSION` | Plain text version string | `1.5.0` |

## Multi-Ecosystem Projects

A single project may match multiple ecosystems. For example:

- **TYPO3 extension**: TYPO3 + PHP/Composer + Generic
- **Node.js library with Rust bindings**: Node.js + Rust + Generic
- **Full-stack monorepo**: May have Node.js frontend + Python backend + Generic

Update ALL matching version files. Report which files were updated in the PR description.
