#!/usr/bin/env python3
"""
PreToolUse hook that blocks dangerous GitHub release operations.

Blocks:
  - gh release create/delete (always)
  - gh release edit (unless only --notes or --notes-file flags are used)
  - gh api calls to release endpoints with mutating HTTP methods

Allows:
  - gh release view/list/download (read-only)
  - gh release edit --notes "..." (release description overhaul)
  - gh release edit --notes-file ... (release description overhaul)
  - gh run commands (workflow management)
  - Any non-release gh commands

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


# Regex that matches "gh release <subcommand>" with flexible whitespace.
# We capture the subcommand to decide allow vs block.
GH_RELEASE_RE = re.compile(
    r"""
    (?:^|[;&|]\s*|&&\s*|\|\|\s*)   # start of string or command separator
    gh\s+release\s+(\S+)            # gh release <subcommand>
    """,
    re.VERBOSE,
)

# Read-only subcommands that are safe.
ALLOWED_RELEASE_SUBCOMMANDS = {"view", "list", "download"}

# gh api calls to release endpoints with mutating methods.
# Matches patterns like:
#   gh api repos/owner/repo/releases -X POST
#   gh api /repos/owner/repo/releases --method DELETE
#   gh api repos/owner/repo/releases/123 -X PATCH
GH_API_RELEASE_RE = re.compile(
    r"""
    (?:^|[;&|]\s*|&&\s*|\|\|\s*)    # start or separator
    gh\s+api\s+                      # gh api
    (?:(?:-\w+|--\w[\w-]*)(?:\s+(?:"[^"]*"|'[^']*'|\S+))?\s+)*  # optional flags (e.g. -X POST, -H "...")
    /?repos/[^\s]+/releases          # release endpoint path
    """,
    re.VERBOSE,
)

MUTATING_METHOD_RE = re.compile(
    r"""
    (?:-X|--method)\s*(POST|PUT|PATCH|DELETE)
    """,
    re.VERBOSE | re.IGNORECASE,
)


# Flags for gh release edit that modify metadata other than notes.
# See: gh release edit --help
_DANGEROUS_EDIT_FLAGS = re.compile(
    r"""
    (?:^|\s)
    (?:
        --draft
        |--prerelease
        |--latest
        |--tag
        |--target
        |--title
        |-t\b
        |--discussion-category
        |--verify-tag
    )
    """,
    re.VERBOSE,
)


def _is_notes_only_edit(args: str) -> bool:
    """Return True if gh release edit args only modify notes."""
    has_notes = bool(re.search(r"(?:^|\s)(?:--notes(?:\s|=)|--notes-file(?:\s|=)|-n\s)", args))
    has_dangerous = bool(_DANGEROUS_EDIT_FLAGS.search(args))
    return has_notes and not has_dangerous


def check_command(command: str) -> None:
    """Check the command and block if it is a dangerous release operation."""
    # Normalise for easier matching (collapse multiple spaces).
    cmd = " ".join(command.split())

    # --- Check gh release <subcommand> ---
    for match in GH_RELEASE_RE.finditer(cmd):
        subcommand = match.group(1).lower()
        if subcommand in ALLOWED_RELEASE_SUBCOMMANDS:
            continue
        if subcommand == "create":
            block(
                "Direct 'gh release create' bypasses the CI release pipeline. "
                "Releases MUST be created by the CI/CD workflow to ensure "
                "proper provenance, signing, and artifact generation.",
                "Push a version tag (git tag -s vX.Y.Z && git push origin vX.Y.Z) "
                "to trigger the release workflow, or run the release workflow "
                "manually via 'gh workflow run'.",
            )
        elif subcommand == "delete":
            block(
                "Deleting a GitHub release is a destructive, irreversible operation. "
                "Published releases are immutable artifacts that downstream consumers "
                "may depend on.",
                "If a release contains a critical defect, create a new patch release "
                "instead (vX.Y.Z+1). If you must deprecate a release, edit its notes "
                "to mark it as deprecated via the CI pipeline.",
            )
        elif subcommand == "edit":
            # Allow notes-only edits for release description overhaul.
            # Extract the portion of the command after "gh release edit".
            edit_args = cmd[match.end():]
            if _is_notes_only_edit(edit_args):
                continue
            block(
                "Editing a GitHub release outside of notes overhaul bypasses audit "
                "controls. Only --notes and --notes-file are permitted.",
                "Use 'gh release edit vX.Y.Z --notes \"...\"' to overhaul the "
                "release description. Other release metadata should be managed "
                "through the CI release workflow.",
            )
        else:
            # Unknown subcommand -- block to be safe.
            block(
                f"Unknown 'gh release {subcommand}' subcommand. Only read-only "
                f"operations (view, list, download) are permitted outside CI.",
                "Use 'gh release view' or 'gh release list' for read-only access. "
                "All mutating release operations must go through the CI pipeline.",
            )

    # --- Check gh api calls to release endpoints ---
    if GH_API_RELEASE_RE.search(cmd):
        # If no explicit method flag, gh api defaults to GET for bare calls,
        # but POST when -f/--field or --input is present. We block if a
        # mutating method is specified OR if data-sending flags are present.
        has_mutating_method = MUTATING_METHOD_RE.search(cmd)
        has_data_flags = re.search(
            r"\s(-f|--field|-F|--json-field|--input)\s", cmd
        )
        if has_mutating_method or has_data_flags:
            method = ""
            if has_mutating_method:
                method = has_mutating_method.group(1).upper()
            block(
                f"Direct API call to release endpoint{' with ' + method + ' method' if method else ''} "
                f"bypasses the CI release pipeline. All mutating operations on "
                f"releases must go through CI.",
                "Use the CI release workflow to create or modify releases. "
                "For read-only queries, use 'gh api' without mutating methods "
                "or data flags.",
            )


def main() -> None:
    try:
        input_data = sys.stdin.read()
    except Exception:
        sys.exit(0)

    command = parse_command(input_data)
    if not command:
        sys.exit(0)

    # Quick pre-check: skip if command does not mention gh at all.
    if "gh" not in command.lower():
        sys.exit(0)

    check_command(command)
    # If we get here, the command is allowed.
    sys.exit(0)


if __name__ == "__main__":
    main()
