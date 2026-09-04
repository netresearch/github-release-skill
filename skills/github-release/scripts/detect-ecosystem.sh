#!/usr/bin/env bash
#
# detect-ecosystem.sh - Scan current directory and report detected ecosystems and version files.
#
# Output format (one line per finding):
#   ecosystem:<name>
#   version-file:<path>:<version>
#   docs-version-ref:<path>:<directive>::<version>
#   changelog:<path>
#
set -euo pipefail

# Extract a JSON field value using grep/sed (no jq dependency)
# Usage: json_field <file> <field>
json_field() {
    local file="$1" field="$2"
    sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" 2>/dev/null | head -1 || true
}

# Extract version from ext_emconf.php
emconf_version() {
    sed -n "s/.*'version'[[:space:]]*=>[[:space:]]*'\([^']*\)'.*/\1/p" "$1" 2>/dev/null | head -1 || true
}

# Extract version from a Cargo.toml (top-level only, before first [dependencies] etc.)
cargo_version() {
    sed -n '/^\[package\]/,/^\[/{/^version\s*=/p}' "$1" 2>/dev/null \
        | sed -n 's/.*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' || true
}

# Extract version from pyproject.toml [project] section
pyproject_version() {
    sed -n '/^\[project\]/,/^\[/{/^version\s*=/p}' "$1" 2>/dev/null \
        | sed -n 's/.*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' || true
}

# Extract version from setup.py
setup_py_version() {
    sed -n 's/.*version[[:space:]]*=[[:space:]]*['"'"'"]\([^'"'"'"]*\).*/\1/p' "$1" 2>/dev/null | head -1 || true
}

# Extract version from pom.xml (first occurrence, project-level)
pom_version() {
    # Grab version outside of <parent> and <dependency> blocks - simplified: first <version> child of <project>
    sed -n '/<project/,/<\/project>/{/<parent>/,/<\/parent>/d; s/.*<version>\(.*\)<\/version>.*/\1/p;}' "$1" 2>/dev/null \
        | head -1 || true
}

# Extract version from go.mod module line (Go modules don't carry semver in go.mod itself,
# but the module path may contain /v2 etc.)
go_mod_version() {
    sed -n 's/^module[[:space:]]\{1,\}.*\/v\([0-9]\{1,\}\).*/\1/p' "$1" 2>/dev/null | head -1 || true
}

# Extract version from guides.xml
guides_xml_version() {
    sed -n 's/.*<release>[[:space:]]*\([^<[:space:]]\{1,\}\).*/\1/p' "$1" 2>/dev/null | head -1 \
        || sed -n 's/.*release="\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1 \
        || true
}

# Extract version from a World of Warcraft addon .toc manifest.
# Manifests are commonly CRLF. The trailing [[:space:]]*$ is what takes the
# carriage return off the value — [:space:] includes \r — so nothing else has
# to strip it; the CRLF case is pinned by a test.
toc_version() {
    sed -n 's/^##[[:space:]]*Version:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$1" 2>/dev/null \
        | head -1 || true
}

# ---------------------------------------------------------------------------
# TYPO3
# ---------------------------------------------------------------------------
if [[ -f ext_emconf.php ]]; then
    echo "ecosystem:typo3"
    ver=$(emconf_version ext_emconf.php)
    echo "version-file:ext_emconf.php:${ver}"

    # composer.json (may or may not have version for TYPO3 extensions)
    if [[ -f composer.json ]]; then
        cver=$(json_field composer.json version)
        echo "version-file:composer.json:${cver}"
    fi

    # Documentation/guides.xml
    if [[ -f Documentation/guides.xml ]]; then
        gver=$(guides_xml_version Documentation/guides.xml)
        echo "version-file:Documentation/guides.xml:${gver}"
    fi

    # Scan Documentation/**/*.rst for versionadded / versionchanged directives
    if [[ -d Documentation ]]; then
        while IFS= read -r rstfile; do
            grep -E '^\.\.[[:space:]]+(versionadded|versionchanged)::' "$rstfile" 2>/dev/null | while IFS= read -r match; do
                directive=$(echo "$match" | grep -oE '(versionadded|versionchanged)' || true)
                dver=$(echo "$match" | sed -n 's/.*::[[:space:]]*\([^[:space:]]\{1,\}\).*/\1/p' || true)
                if [[ -n "$directive" ]]; then
                    echo "docs-version-ref:${rstfile}:${directive}::${dver}"
                fi
            done || true
        done < <(find Documentation -name '*.rst' -type f 2>/dev/null)
    fi
fi

# ---------------------------------------------------------------------------
# Skill repo (plugin.json + .claude-plugin/plugin.json)
# ---------------------------------------------------------------------------
if [[ -f .claude-plugin/plugin.json ]]; then
    echo "ecosystem:skill"
    # Root plugin.json is the Agent Plugins 1.0.0 manifest and the source of
    # truth for the version; .claude-plugin/plugin.json is generated from it.
    # A repo that has not adopted the portable manifest only reports the latter.
    if [[ -f plugin.json ]]; then
        pver=$(json_field plugin.json version)
        echo "version-file:plugin.json:${pver}"
    fi
    sver=$(json_field .claude-plugin/plugin.json version)
    echo "version-file:.claude-plugin/plugin.json:${sver}"

    # skills/*/SKILL.md - version lives in the YAML frontmatter, and in the
    # Netresearch layout it is nested under `metadata:`, so it is indented:
    #
    #   metadata:
    #     version: "0.9.0"
    #
    # Match with optional leading whitespace and strip the surrounding quotes.
    # Confined to the frontmatter block so a `version:` inside a description or
    # a body code fence cannot be picked up instead.
    for skillmd in skills/*/SKILL.md; do
        [[ -f "$skillmd" ]] || continue
        mdver=$(awk '
            NR == 1 && $0 == "---" { fm = 1; next }
            fm && $0 == "---" { exit }
            fm && match($0, /^[[:space:]]*version:[[:space:]]*/) {
                v = substr($0, RSTART + RLENGTH)
                sub(/[[:space:]]+$/, "", v)
                gsub(/^["'"'"']|["'"'"']$/, "", v)
                print v
                exit
            }
        ' "$skillmd" 2>/dev/null || true)
        echo "version-file:${skillmd}:${mdver}"
    done
fi

# ---------------------------------------------------------------------------
# PHP (composer.json with version, but not already reported under TYPO3)
# ---------------------------------------------------------------------------
if [[ -f composer.json ]] && [[ ! -f ext_emconf.php ]]; then
    cver=$(json_field composer.json version)
    if [[ -n "$cver" ]]; then
        echo "ecosystem:php"
        echo "version-file:composer.json:${cver}"
    fi
fi

# ---------------------------------------------------------------------------
# Node.js
# ---------------------------------------------------------------------------
if [[ -f package.json ]]; then
    is_private=$(json_field package.json private)
    pkg_ver=$(json_field package.json version)
    if [[ "$is_private" != "true" ]] || [[ -n "$pkg_ver" ]]; then
        echo "ecosystem:nodejs"
        echo "version-file:package.json:${pkg_ver}"
        if [[ -f package-lock.json ]]; then
            lock_ver=$(json_field package-lock.json version)
            echo "version-file:package-lock.json:${lock_ver}"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Go
# ---------------------------------------------------------------------------
if [[ -f go.mod ]]; then
    echo "ecosystem:go"
    gover=$(go_mod_version go.mod)
    echo "version-file:go.mod:${gover}"
fi

# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------
if [[ -f pyproject.toml ]]; then
    echo "ecosystem:python"
    pyver=$(pyproject_version pyproject.toml)
    echo "version-file:pyproject.toml:${pyver}"
elif [[ -f setup.py ]]; then
    echo "ecosystem:python"
    pyver=$(setup_py_version setup.py)
    echo "version-file:setup.py:${pyver}"
fi

# ---------------------------------------------------------------------------
# Rust
# ---------------------------------------------------------------------------
if [[ -f Cargo.toml ]]; then
    echo "ecosystem:rust"
    rver=$(cargo_version Cargo.toml)
    echo "version-file:Cargo.toml:${rver}"
fi

# ---------------------------------------------------------------------------
# Java / Maven
# ---------------------------------------------------------------------------
if [[ -f pom.xml ]]; then
    echo "ecosystem:java"
    jver=$(pom_version pom.xml)
    echo "version-file:pom.xml:${jver}"
fi

# ---------------------------------------------------------------------------
# World of Warcraft addon
# ---------------------------------------------------------------------------
# The marker is the `## Interface:` line, not the file extension: `.toc` is a
# generic suffix that also belongs to LaTeX tables of contents and to Delphi
# type libraries, and matching on the extension alone would report those
# repositories as addons.
#
# The manifest sits at <AddonName>/<AddonName>.toc, or at the repository root
# for a single-folder layout. An addon that supports several game flavours ships
# one manifest per flavour beside it — QuickRoute.toc, QuickRoute_Vanilla.toc,
# QuickRoute_Cata.toc — each carrying its own `## Version:`. Every one is
# reported, so a release that moves only some of them fails the version-sync
# check instead of shipping a mismatch to the other flavours.
toc_manifests=()
while IFS= read -r toc; do
    case "$toc" in ./.git/*) continue ;; esac
    if grep -qE '^##[[:space:]]*Interface:' "$toc" 2>/dev/null; then
        toc_manifests+=("${toc#./}")
    fi
done < <(find . -maxdepth 2 -name '*.toc' -type f 2>/dev/null | sort)

if [[ ${#toc_manifests[@]} -gt 0 ]]; then
    echo "ecosystem:wow-addon"
    for toc in "${toc_manifests[@]}"; do
        echo "version-file:${toc}:$(toc_version "$toc")"
    done
fi

# ---------------------------------------------------------------------------
# Common files (always check)
# ---------------------------------------------------------------------------
if [[ -f CHANGELOG.md ]]; then
    echo "changelog:CHANGELOG.md"
fi

if [[ -f VERSION ]]; then
    vver=$(head -1 VERSION 2>/dev/null | tr -d '[:space:]')
    echo "version-file:VERSION:${vver}"
fi
