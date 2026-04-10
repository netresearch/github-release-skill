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
    grep -oP "\"${field}\"\s*:\s*\"\\K[^\"]*" "$file" 2>/dev/null || true
}

# Extract version from ext_emconf.php
emconf_version() {
    grep -oP "'version'\s*=>\s*'\\K[^']*" "$1" 2>/dev/null || true
}

# Extract version from a Cargo.toml (top-level only, before first [dependencies] etc.)
cargo_version() {
    sed -n '/^\[package\]/,/^\[/{/^version\s*=/p}' "$1" 2>/dev/null \
        | grep -oP 'version\s*=\s*"\\K[^"]*' || true
}

# Extract version from pyproject.toml [project] section
pyproject_version() {
    sed -n '/^\[project\]/,/^\[/{/^version\s*=/p}' "$1" 2>/dev/null \
        | grep -oP 'version\s*=\s*"\\K[^"]*' || true
}

# Extract version from setup.py
setup_py_version() {
    grep -oP "version\s*=\s*['\"]\\K[^'\"]*" "$1" 2>/dev/null || true
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
    grep -oP '^module\s+\S+/v\K\d+' "$1" 2>/dev/null || true
}

# Extract version from guides.xml
guides_xml_version() {
    grep -oP '<release>\s*\K[^<\s]+' "$1" 2>/dev/null \
        || grep -oP 'release="\K[^"]*' "$1" 2>/dev/null \
        || true
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
            grep -P '^\.\.\s+(versionadded|versionchanged)::' "$rstfile" 2>/dev/null | while IFS= read -r match; do
                directive=$(echo "$match" | grep -oP '(versionadded|versionchanged)' || true)
                dver=$(echo "$match" | grep -oP '::\s*\K\S+' || true)
                if [[ -n "$directive" ]]; then
                    echo "docs-version-ref:${rstfile}:${directive}::${dver}"
                fi
            done || true
        done < <(find Documentation -name '*.rst' -type f 2>/dev/null)
    fi
fi

# ---------------------------------------------------------------------------
# Skill repo (.claude-plugin/plugin.json)
# ---------------------------------------------------------------------------
if [[ -f .claude-plugin/plugin.json ]]; then
    echo "ecosystem:skill"
    sver=$(json_field .claude-plugin/plugin.json version)
    echo "version-file:.claude-plugin/plugin.json:${sver}"

    # skills/*/SKILL.md - extract version from YAML frontmatter or version: line
    for skillmd in skills/*/SKILL.md; do
        [[ -f "$skillmd" ]] || continue
        mdver=$(grep -oP '^version:\s*\K\S+' "$skillmd" 2>/dev/null | head -1 || true)
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
# Common files (always check)
# ---------------------------------------------------------------------------
if [[ -f CHANGELOG.md ]]; then
    echo "changelog:CHANGELOG.md"
fi

if [[ -f VERSION ]]; then
    vver=$(head -1 VERSION 2>/dev/null | tr -d '[:space:]')
    echo "version-file:VERSION:${vver}"
fi
