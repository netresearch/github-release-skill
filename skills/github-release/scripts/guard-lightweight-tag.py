#!/usr/bin/env python3
"""
PreToolUse hook that blocks dangerous git tag operations.

Blocks:
  - Lightweight version tags (git tag v* without -s or -a)
  - Version tag deletion (git tag -d v*)
  - Remote version tag deletion (git push --delete origin v*, git push origin :refs/tags/v*)
  - Force-pushing tags (git push -f with tag refs)

Allows:
  - Signed tags: git tag -s v*
  - Annotated tags: git tag -a v*
  - Listing tags: git tag -l, git tag --list
  - Verifying tags: git tag -v v*
  - Non-version tags (tags not matching v* pattern)

Exit codes:
  0 = allow the command
  2 = block the command
"""

import json
import re
import sys


def parse_command(input_data: str) -> str:
    """Extract the command string from hook input (JSON via stdin)."""
    if not input_data:
        return ""
    try:
        data = json.loads(input_data)
        return data.get("command", "")
    except (json.JSONDecodeError, TypeError):
        return input_data


def block(reason: str, suggestion: str) -> None:
    """Print a YAML-formatted block reason to stderr and exit 2."""
    print(
        f"""---
blocked: true
reason: |
  {reason}
suggestion: |
  {suggestion}
---""",
        file=sys.stderr,
    )
    sys.exit(2)


def has_version_tag_arg(args: str) -> bool:
    """Check if any argument looks like a version tag (v*)."""
    # Match v followed by a digit, with optional prefix like refs/tags/
    return bool(re.search(r"(?:^|\s|/)v\d", args))


def check_command(command: str) -> None:
    """Check the command and block dangerous tag operations."""
    # Normalise whitespace.
    cmd = " ".join(command.split())

    # ---------------------------------------------------------------
    # 1. Check "git tag" commands
    # ---------------------------------------------------------------
    # Match "git tag ..." anywhere in the command (after separators).
    tag_match = re.search(
        r"(?:^|[;&|]\s*|&&\s*|\|\|\s*)git\s+tag\b(.*)",
        cmd,
    )
    if tag_match:
        tag_args = tag_match.group(1).strip()

        # Allow listing: -l, --list, or bare "git tag" with no args.
        if not tag_args or re.match(r"^(-l|--list)\b", tag_args):
            return

        # Allow verification: -v (but not -v as part of a version like v1.0).
        if re.match(r"^-v\s", tag_args) or tag_args == "-v":
            return

        # Check for tag deletion: git tag -d <tag>
        if re.search(r"(?:^|\s)-d\b", tag_args):
            if has_version_tag_arg(tag_args):
                block(
                    "Deleting a version tag is dangerous. Tags are immutable "
                    "references that downstream consumers and CI pipelines depend on.",
                    "If the tag points to a bad commit, create a new patch "
                    "release (vX.Y.Z+1) instead of deleting the existing tag.",
                )
            # Non-version tag deletion is allowed.
            return

        # If we get here, it is a tag creation command.
        # Only process if it targets a version tag.
        if has_version_tag_arg(tag_args):
            # Allow signed tags (-s or --sign).
            if re.search(r"(?:^|\s)(-s|--sign)\b", tag_args):
                return
            # Allow annotated tags (-a or --annotate).
            if re.search(r"(?:^|\s)(-a|--annotate)\b", tag_args):
                return
            # Combined short flags like -sa, -as are also fine.
            if re.search(r"(?:^|\s)-[a-z]*[sa][a-z]*\b", tag_args):
                return

            # This is a lightweight version tag -- block it.
            block(
                "Lightweight version tags lack metadata (author, date, message) "
                "and cannot be signed. Version tags MUST be annotated (-a) or "
                "signed (-s) to ensure traceability and integrity.",
                "Use 'git tag -s vX.Y.Z -m \"Release vX.Y.Z\"' for a signed tag, "
                "or 'git tag -a vX.Y.Z -m \"Release vX.Y.Z\"' for an annotated tag.",
            )

        # Non-version tag -- allow.
        return

    # ---------------------------------------------------------------
    # 2. Check "git push" commands for tag deletion / force-push
    # ---------------------------------------------------------------
    push_match = re.search(
        r"(?:^|[;&|]\s*|&&\s*|\|\|\s*)git\s+push\b(.*)",
        cmd,
    )
    if push_match:
        push_args = push_match.group(1).strip()

        # Check for remote tag deletion via colon refspec: git push origin :refs/tags/v*
        if re.search(r":refs/tags/v\d", push_args):
            block(
                "Deleting a remote version tag removes a published release reference. "
                "This can break downstream consumers, CI pipelines, and package "
                "managers that depend on the tag.",
                "If the tag points to a bad commit, create a new patch release "
                "(vX.Y.Z+1) instead. Never delete published version tags.",
            )

        # Check for --delete flag with version tag: git push --delete origin v*
        # Also handles: git push origin --delete v*
        if re.search(r"--delete\b", push_args) and has_version_tag_arg(push_args):
            block(
                "Deleting a remote version tag removes a published release reference. "
                "This can break downstream consumers, CI pipelines, and package "
                "managers that depend on the tag.",
                "If the tag points to a bad commit, create a new patch release "
                "(vX.Y.Z+1) instead. Never delete published version tags.",
            )

        # Check for force-push with tag refs: git push -f origin refs/tags/v*
        # or git push --force origin v* (when pushing tags)
        has_force = bool(
            re.search(r"(?:^|\s)(-f\b|--force\b|--force-with-lease\b)", push_args)
        )
        if has_force:
            # Check if pushing tag refs.
            if re.search(r"refs/tags/v\d", push_args):
                block(
                    "Force-pushing version tags rewrites published release history. "
                    "This is extremely dangerous as consumers may have already "
                    "fetched the original tag.",
                    "Create a new version tag (vX.Y.Z+1) instead of force-pushing "
                    "an existing one.",
                )
            # Check for --tags flag with force.
            if re.search(r"--tags\b", push_args):
                block(
                    "Force-pushing all tags rewrites published release history. "
                    "This can break every version reference that downstream "
                    "consumers depend on.",
                    "Push tags individually without --force, or create new version "
                    "tags for corrections.",
                )


def main() -> None:
    try:
        input_data = sys.stdin.read()
    except Exception:
        sys.exit(0)

    command = parse_command(input_data)
    if not command:
        sys.exit(0)

    # Quick pre-check: skip if command does not mention git at all.
    if "git" not in command.lower():
        sys.exit(0)

    check_command(command)
    # If we get here, the command is allowed.
    sys.exit(0)


if __name__ == "__main__":
    main()
