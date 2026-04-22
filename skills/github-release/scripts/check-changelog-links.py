#!/usr/bin/env python3
"""check-changelog-links.py - Verify Keep-a-Changelog reference-style links.

Keep-a-Changelog projects commonly use reference-style section headers:

    ## [0.5.0] - 2026-04-19

...and define the link target at the bottom of the file:

    [Unreleased]: https://github.com/owner/repo/compare/v0.5.0...HEAD
    [0.5.0]: https://github.com/owner/repo/compare/v0.4.0...v0.5.0

When a new release is added it is easy to add the header without adding the
matching footer link (or to forget updating the `[Unreleased]` compare range).
The rendered CHANGELOG then shows a broken `[0.5.0]` link — a regression that
Copilot review tends to catch late in the PR cycle instead of the skill
catching it locally.

This script parses CHANGELOG.md and reports:

  1. Any `## [X.Y.Z]` (or `## [X.Y.Z-prerelease]`) header without a matching
     footer link definition.
  2. A stale `[Unreleased]: .../compare/<previous>...HEAD` range when the
     newest release is not `<previous>`.

Exits:
  0 - all references resolve / file absent / no reference-style headers used
  1 - a CHANGELOG error was detected. Either:
        * one or more reference-style headers lack a footer link, or
        * the `[Unreleased]: .../compare/<from>...HEAD` range is stale
          (i.e., `<from>` is not the newest released version in the
          header list).
  2 - environment error (file unreadable, etc.)

Usage: check-changelog-links.py [path-to-changelog]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HEADER_RE = re.compile(
    r"^##\s+\[(?P<version>[^\]]+)\](?:\s*[-\u2013]\s*[0-9A-Za-z.\- ]+)?\s*$"
)
# Matches footer definitions like: [0.5.0]: https://...
FOOTER_RE = re.compile(r"^\[(?P<key>[^\]]+)\]:\s*(?P<url>\S.*)\s*$")
# Matches an Unreleased compare range ending in HEAD. The capture group must
# allow dots so it can match common forms like `v0.5.0...HEAD` or `0.5.0...HEAD`
# (the previous `[^./]+` class excluded dots and therefore missed semver
# versions entirely — it would only match refs like `main` or `abc1234`).
UNRELEASED_COMPARE_RE = re.compile(r"/compare/(?P<from>[^/]+?)\.\.\.HEAD\s*$")


def main(argv: list[str]) -> int:
    path = Path(argv[1]) if len(argv) > 1 else Path("CHANGELOG.md")
    if not path.exists():
        # No CHANGELOG is a separate concern; do not flag here.
        return 0

    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"error: cannot read {path}: {exc}", file=sys.stderr)
        return 2

    header_versions: list[str] = []
    footer_keys: dict[str, str] = {}

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        match = HEADER_RE.match(line)
        if match:
            header_versions.append(match.group("version"))
            continue
        match = FOOTER_RE.match(line)
        if match:
            footer_keys[match.group("key")] = match.group("url")

    if not header_versions:
        # Plain headers (no reference-style) — nothing to validate.
        return 0

    # Only enforce if the project is actually using reference-style links.
    # Detect that by the presence of at least one footer key that matches any
    # header version or the literal "Unreleased".
    uses_reference_style = (
        any(key in footer_keys for key in header_versions)
        or "Unreleased" in footer_keys
    )
    if not uses_reference_style:
        return 0

    missing: list[str] = []
    for version in header_versions:
        # Skip the textual "Unreleased" entry from header scan — tracked
        # separately below. `## [Unreleased]` is valid without a date.
        if version.lower() == "unreleased":
            continue
        if version not in footer_keys:
            missing.append(version)

    warnings: list[str] = []

    # Check Unreleased compare range points at the newest released version.
    # Newest release = first non-Unreleased header (Keep-a-Changelog orders
    # releases newest-first).
    newest_release = next(
        (v for v in header_versions if v.lower() != "unreleased"),
        None,
    )
    unreleased_url = footer_keys.get("Unreleased")
    if newest_release and unreleased_url:
        compare_match = UNRELEASED_COMPARE_RE.search(unreleased_url)
        if compare_match:
            compare_from = compare_match.group("from")
            expected = f"v{newest_release}"
            # Accept either `vX.Y.Z` or bare `X.Y.Z` in the compare range.
            if compare_from not in {expected, newest_release}:
                warnings.append(
                    f"[Unreleased] compare range starts at {compare_from!r} "
                    f"but newest release is {newest_release!r} "
                    f"(expected {expected!r})"
                )

    if not missing and not warnings:
        return 0

    print(f"CHANGELOG link-reference issues in {path}:")
    for version in missing:
        print(
            f"  MISSING footer link for [{version}] — "
            f"add `[{version}]: <compare-URL>` at the bottom of the file"
        )
    for warning in warnings:
        print(f"  STALE   {warning}")

    if missing:
        print("")
        print(
            "Add the missing footer link(s) and update the "
            "`[Unreleased]: .../compare/vX.Y.Z...HEAD` range to the newest "
            "released version."
        )
        return 1
    # Only warnings -> still signal non-zero so the mechanical check
    # registers, but the checkpoint severity is `warning` so the skill
    # surfaces it as a suggestion rather than a hard stop.
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
