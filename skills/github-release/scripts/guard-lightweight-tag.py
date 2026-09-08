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
  - Listing and inspecting tags: git tag -l, --list, -n, --contains,
    --points-at, --merged, --sort, --format, --column, --ignore-case
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
    """Extract the command string from hook input (JSON via stdin).

    Claude Code's PreToolUse payload nests the command under `tool_input`;
    only reading a top-level `command` made this guard a silent no-op in the
    harness it is installed into. The flat shape stays supported for direct
    invocation and for the tests.
    """
    if not input_data:
        return ""
    try:
        data = json.loads(input_data)
    except (json.JSONDecodeError, TypeError):
        return input_data
    if not isinstance(data, dict):
        return ""
    tool_input = data.get("tool_input")
    if isinstance(tool_input, dict) and tool_input.get("command"):
        return tool_input["command"]
    return data.get("command", "")


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


# Flags that make "git tag" a read-only query. git treats any of them as
# implying --list, so they can carry a version argument (a shell pattern, or a
# ref to compare against) without being a tag creation.
READ_ONLY_TAG_FLAG = re.compile(
    r"(?:^|\s)(?:-l|--list|-n\d*|--contains|--no-contains|--points-at"
    r"|--merged|--no-merged|--sort|--format|--column|--no-column"
    r"|-i|--ignore-case|--omit-empty)(?:=|\s|$)"
)


def split_invocations(command: str) -> list:
    """Split a shell command into its individual invocations.

    Bounds every later check to a single invocation. Without this, a capture
    that starts at "git tag" runs to the end of the whole command, so an
    unrelated token further along the script decides the verdict (issue #105).
    Line continuations are folded first so that a wrapped invocation stays one
    segment instead of splitting at the newline.
    """
    folded = command.replace("\\\n", " ")
    return [
        segment.strip() for segment in re.split(r"[;&|\n]+", folded) if segment.strip()
    ]


def check_tag_invocation(segment: str) -> None:
    """Block dangerous "git tag" forms in a single invocation."""
    tag_match = re.match(r"git\s+tag\b(.*)", segment)
    if not tag_match:
        return

    tag_args = tag_match.group(1).strip()

    # Allow bare "git tag" and every read-only listing/inspection form.
    if not tag_args or READ_ONLY_TAG_FLAG.search(tag_args):
        return

    # Allow verification: -v (but not -v as part of a version like v1.0,
    # nor the -v inside a value such as --sort=-v:refname).
    if re.search(r"(?:^|\s)(-v|--verify)(?:\s|$)", tag_args):
        return

    # Check for tag deletion: git tag -d <tag> / git tag --delete <tag>
    if re.search(r"(?:^|\s)(-d|--delete)\b", tag_args):
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


def check_push_invocation(segment: str) -> None:
    """Block tag deletion and tag force-push in a single "git push"."""
    push_match = re.match(r"git\s+push\b(.*)", segment)
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


def check_command(command: str) -> None:
    """Check every invocation in the command and block dangerous tag operations.

    Each invocation is judged on its own arguments. Checking only the first
    "git tag" occurrence let everything after it through: an opening
    "git tag -l" returned early and a later creation, deletion or tag
    force-push in the same command was never seen.
    """
    for segment in split_invocations(command):
        check_tag_invocation(segment)
        check_push_invocation(segment)


def main() -> None:
    try:
        input_data = sys.stdin.read()
    except Exception:  # noqa: BLE001 - hook must fail open on any stdin error, never block the tool call
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
