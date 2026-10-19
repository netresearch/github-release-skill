#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# Self-test for the changelog-fragment items of validate-pre-release.sh.
#
# A repository that keeps entries as fragments in changelog.d/ has an empty
# [Unreleased] section until the release commit runs its collect step. The
# validator must count the fragments as unreleased content, and remind the
# releaser that they still have to be collected; README.md documents the
# format and is no fragment.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../validate-pre-release.sh"
fail=0

check() { # check <name> <expected-substring> <actual>
  case "$3" in
    *"$2"*) printf 'ok   - %s\n' "$1" ;;
    *) printf 'FAIL - %s\n       expected to contain: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fail=1 ;;
  esac
}

refute() { # refute <name> <unexpected-substring> <actual>
  case "$3" in
    *"$2"*) printf 'FAIL - %s\n       expected NOT to contain: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"; fail=1 ;;
    *) printf 'ok   - %s\n' "$1" ;;
  esac
}

git_path=$(command -v git 2>/dev/null) || { echo "SKIP - git not installed"; exit 0; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/repo/changelog.d"
ln -sf "$git_path" "$work/bin/git"
# gh is not under test here: every lookup fails, which the script reports as a warning.
printf '#!/usr/bin/env bash\nexit 1\n' >"$work/bin/gh"
chmod +x "$work/bin/gh"

git -C "$work/repo" init -q -b main
git -C "$work/repo" -c user.name=t -c user.email=t@example.invalid \
  commit -q --allow-empty -m init

empty_unreleased=$'# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- First.\n'
printf '%s' "$empty_unreleased" >"$work/repo/CHANGELOG.md"

changelog_lines() {
  (cd "$work/repo" && env -i PATH="$work/bin:/usr/bin:/bin" HOME="$work" \
     bash --noprofile --norc "$SCRIPT" 2>&1) | grep -E 'Changelog fragments|\[Unreleased\]'
}

printf '# Fragments\n' >"$work/repo/changelog.d/README.md"
out=$(changelog_lines)
check "an empty [Unreleased] without fragments fails" "FAIL  CHANGELOG.md [Unreleased] has content" "$out"
refute "README.md is no fragment" "Changelog fragments collected" "$out"

printf -- '- A fix.\n' >"$work/repo/changelog.d/fix-a.fixed.md"
printf -- '- A change.\n' >"$work/repo/changelog.d/feat-b.changed.md"
out=$(changelog_lines)
check "fragments count as unreleased content" "PASS  CHANGELOG.md [Unreleased] has content (empty, but 2 fragment(s) in changelog.d/)" "$out"
check "fragments carry a collect reminder" "WARN  Changelog fragments collected (2 fragment(s)" "$out"
check "the reminder names the collect command" "composer changelog:collect" "$out"

exit "$fail"
