#!/usr/bin/env bash
# Self-test for detect-ecosystem.sh skill-version extraction — no network.
#
# Pins the regression fixed alongside it: the Netresearch skill layout nests the
# version under `metadata:`, so it is INDENTED. The old `^version:` match only
# saw a column-0 key and reported an empty version for every such repo — the
# version-sync check then silently could not see the file it was checking.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$HERE/../detect-ecosystem.sh"

fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude-plugin" "$TMP/skills/demo"
echo '{"version":"1.0.0"}' >"$TMP/.claude-plugin/plugin.json"

# skillver <frontmatter-content> -> the version detect-ecosystem.sh reports
skillver() {
  printf '%s' "$1" >"$TMP/skills/demo/SKILL.md"
  (cd "$TMP" && bash "$DETECT" 2>/dev/null) |
    sed -n 's|^version-file:skills/demo/SKILL\.md:||p'
}

check "nested metadata.version, quoted" "0.9.0" "$(skillver '---
name: demo
metadata:
  author: Netresearch DTT GmbH
  version: "0.9.0"
---

body
')"

check "nested metadata.version, unquoted" "1.2.3" "$(skillver '---
name: demo
metadata:
  version: 1.2.3
---
')"

check "nested, single-quoted" "2.0.0" "$(skillver "---
name: demo
metadata:
  version: '2.0.0'
---
")"

# Backward compatibility: a column-0 key must keep working.
check "top-level version key" "9.9.9" "$(skillver '---
name: demo
version: 9.9.9
---
')"

# A `version:` inside prose must not win over the real one.
check "prose decoy does not shadow metadata" "4.5.6" "$(skillver '---
name: demo
description: "mentions version: 0.0.0 in prose"
metadata:
  version: "4.5.6"
---
')"

# Only the frontmatter counts — a body code fence is not a version declaration.
check "body code fence ignored" "" "$(skillver '---
name: demo
---

```yaml
version: "6.6.6"
```
')"

check "no version anywhere" "" "$(skillver '---
name: demo
---

body
')"

# Trailing whitespace after the value must be stripped.
check "trailing spaces stripped" "3.1.4" "$(skillver '---
name: demo
metadata:
  version: "3.1.4"
---
')"

# ---------------------------------------------------------------------------
# World of Warcraft addon manifests
# ---------------------------------------------------------------------------
# An addon states its version only in its .toc, so a repo without these lines
# reports no version file at all and release-status.sh can never finish.

ADDON="$(mktemp -d)"
trap 'rm -rf "$TMP" "$ADDON"' EXIT

# detect_in <dir> -> the detector's output for that directory
detect_in() { (cd "$1" && bash "$DETECT" 2>/dev/null); }

mkdir -p "$ADDON/QuickRoute"
printf '## Interface: 120100\n## Title: QuickRoute\n## Version: 1.16.0\n' \
  >"$ADDON/QuickRoute/QuickRoute.toc"

check "addon in its own folder is detected" \
  "ecosystem:wow-addon" \
  "$(detect_in "$ADDON" | grep '^ecosystem:')"

check "version comes from the .toc" \
  "version-file:QuickRoute/QuickRoute.toc:1.16.0" \
  "$(detect_in "$ADDON" | grep '^version-file:')"

# A manifest at the repository root, the single-folder layout.
ROOTADDON="$(mktemp -d)"
printf '## Interface: 110200\n## Version: 2.0.1\n' >"$ROOTADDON/Thing.toc"
check "manifest at the repository root" \
  "version-file:Thing.toc:2.0.1" \
  "$(detect_in "$ROOTADDON" | grep '^version-file:')"
rm -rf "$ROOTADDON"

# Every flavour manifest is reported, so a release that moves only some of them
# fails the version-sync check instead of shipping a mismatch.
printf '## Interface: 11507\n## Version: 1.16.0\n' \
  >"$ADDON/QuickRoute/QuickRoute_Vanilla.toc"
printf '## Interface: 40402\n## Version: 1.15.0\n' \
  >"$ADDON/QuickRoute/QuickRoute_Cata.toc"
check "every flavour manifest is reported" \
  "QuickRoute/QuickRoute.toc:1.16.0 QuickRoute/QuickRoute_Cata.toc:1.15.0 QuickRoute/QuickRoute_Vanilla.toc:1.16.0" \
  "$(detect_in "$ADDON" | sed -n 's/^version-file://p' | sort | tr '\n' ' ' | sed 's/ $//')"
rm -f "$ADDON/QuickRoute/QuickRoute_Vanilla.toc" "$ADDON/QuickRoute/QuickRoute_Cata.toc"

# .toc is not exclusive to addons: a LaTeX table of contents carries no
# `## Interface:` line and must not turn a repository into an addon.
LATEX="$(mktemp -d)"
printf '\\contentsline {section}{Intro}{1}\n' >"$LATEX/paper.toc"
check "a .toc without an Interface line is not an addon" \
  "" \
  "$(detect_in "$LATEX" | grep -c '^ecosystem:wow-addon' | sed 's/^0$//')"
rm -rf "$LATEX"

# Manifests are commonly CRLF; the carriage return must not survive into the
# version, where it would make an equal version compare unequal.
printf '## Interface: 120100\r\n## Version: 1.16.0\r\n' \
  >"$ADDON/QuickRoute/QuickRoute.toc"
check "CRLF manifest yields a clean version" \
  "version-file:QuickRoute/QuickRoute.toc:1.16.0" \
  "$(detect_in "$ADDON" | grep '^version-file:')"

if [ "$fail" = 0 ]; then
  echo "detect-ecosystem.test.sh: all checks passed"
else
  echo "detect-ecosystem.test.sh: FAILURES" >&2
fi
exit "$fail"
