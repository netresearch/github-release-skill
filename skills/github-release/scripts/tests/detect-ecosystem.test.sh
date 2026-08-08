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

if [ "$fail" = 0 ]; then
  echo "detect-ecosystem.test.sh: all checks passed"
else
  echo "detect-ecosystem.test.sh: FAILURES" >&2
fi
exit "$fail"
