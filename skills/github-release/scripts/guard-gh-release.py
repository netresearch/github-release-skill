#!/usr/bin/env python3
"""
PreToolUse hook that blocks dangerous GitHub release operations.

Blocks:
  - gh release create, unless --verify-tag is set (see below)
  - gh release delete (always)
  - gh release edit (unless only --notes or --notes-file flags are used)
  - gh api calls to release endpoints with mutating HTTP methods

Allows:
  - gh release view/list/download (read-only)
  - gh release create --verify-tag (publishes against an already-pushed tag)
  - gh release edit --notes "..." (release description overhaul)
  - gh release edit --notes-file ... (release description overhaul)
  - gh release <anything> --help (reading the help runs nothing)
  - gh run commands (workflow management)
  - Any non-release gh commands

Exit codes:
  0 = allow the command
  2 = block the command
"""

import json
import re
import sys

# Both guards share one invocation parser; sys.path[0] is this directory when
# the hook is run as a script, so the sibling module resolves.
from _invocations import INVOCATION_PREFIX, split_invocations


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


def _indent(text: str) -> str:
    """Indent every line by two spaces, as a YAML block scalar requires.

    A message spanning several lines used to emit its continuation lines at
    column 0, which ends the block scalar and leaves the rest as stray YAML.
    """
    return "\n".join("  " + line if line else "" for line in text.split("\n"))


def block(reason: str, suggestion: str) -> None:
    """Print a YAML-formatted block reason to stderr and exit 2."""
    print(
        f"""---
blocked: true
reason: |
{_indent(reason)}
suggestion: |
{_indent(suggestion)}
---""",
        file=sys.stderr,
    )
    sys.exit(2)


# "gh release <subcommand>" at the START of one invocation. The invocation is
# produced by split_invocations, so a separator -- a newline included -- has
# already ended the previous command, and INVOCATION_PREFIX absorbs sudo, an env
# assignment or a loop keyword standing in front of "gh".
GH_RELEASE_RE = re.compile(INVOCATION_PREFIX + r"gh\s+release\s+(\S+)")

# Read-only subcommands that are safe.
ALLOWED_RELEASE_SUBCOMMANDS = {"view", "list", "download"}

# gh api calls to release endpoints with mutating methods.
# Matches patterns like:
#   gh api repos/owner/repo/releases -X POST
#   gh api /repos/owner/repo/releases --method DELETE
#   gh api repos/owner/repo/releases/123 -X PATCH
#   gh api -X PATCH "repos/$R/releases/$ID" -f name=v1
# The path may be quoted: a script with variables writes it that way, and
# requiring it bare let every quoted form skip the check below.
GH_API_RELEASE_RE = re.compile(
    INVOCATION_PREFIX
    + r"""
    gh\s+api\s+                      # gh api
    (?:(?:-\w+|--\w[\w-]*)(?:[\s=]+(?:"[^"]*"|'[^']*'|\S+))?\s+)*  # optional flags (e.g. -X POST, --method=PATCH, -H "...")
    ["']?/?repos/[^\s"']+/releases   # release endpoint path, bare or quoted
    """,
    re.VERBOSE,
)

MUTATING_METHOD_RE = re.compile(
    r"""
    (?:-X|--method)[\s=]*["']?(POST|PUT|PATCH|DELETE)
    """,
    re.VERBOSE | re.IGNORECASE,
)


# Flags for gh release edit that modify metadata other than notes.
# See: gh release edit --help
# Uses \b word boundaries to avoid prefix collisions with future flags.
_DANGEROUS_EDIT_FLAGS = re.compile(
    r"""
    (?:^|\s)
    (?:
        --draft\b
        |--prerelease\b
        |--latest\b
        |--tag\b
        |--target\b
        |--title\b
        |-t\b
        |--discussion-category\b
        |--verify-tag\b
    )
    """,
    re.VERBOSE,
)


# "--verify-tag" is what makes a create safe. gh's own help (2.100.0): "Abort
# in case the git tag doesn't already exist in the remote repository." So the
# invocation cannot create a tag, which is the outcome the create block exists
# to prevent; what it publishes is a tag somebody pushed on purpose.
#
# Whether it is ON takes two readings of pflag, not one. It accepts a value
# ("--verify-tag=false" turns the safeguard back off), and it accepts the flag
# REPEATED, keeping the last value — so "--verify-tag --verify-tag=false"
# leaves it off while the first occurrence looks reassuring. Hence every
# occurrence is collected and only the last one decides. The accepted spellings
# are pflag's own for a boolean in long form (flag.go: 1, 0, t, f, true, false,
# TRUE, FALSE, True, False); a bare occurrence is true.
_VERIFY_TAG_OCCURRENCE = re.compile(r"(?:^|\s)--verify-tag(?:=(\S*))?(?=\s|$)")
_PFLAG_TRUE = {"", "1", "t", "T", "true", "TRUE", "True"}


def _verify_tag_is_on(args: str) -> bool:
    """Whether the effective --verify-tag is on, reading the LAST occurrence.

    A value pflag does not recognise makes gh exit before it does anything, so
    it counts as off: this must never be the branch that lets a command
    through.
    """
    values = _VERIFY_TAG_OCCURRENCE.findall(args)
    if not values:
        return False
    return values[-1] in _PFLAG_TRUE


# Asking for the help text runs no release operation at all. Before this, the
# guard blocked "gh release create --help", i.e. the one command that would have
# told the reader what --verify-tag does.
_HELP_FLAG = re.compile(r"(?:^|\s)(?:--help|-h)(?=\s|$)")


# An unquoted "#" at the start of a word opens a shell comment: everything
# after it is text the shell never passes to the command. Reading it as
# arguments inverts the guard -- `gh release create v1.2.3 # --verify-tag`
# offered a --verify-tag the shell discards, and bash then ran the bare create
# that can mint a lightweight tag. Applied AFTER the quoted spans are dropped,
# so a "#" inside an argument is already gone and cannot cut the line short.
_SHELL_COMMENT = re.compile(r"(?:^|\s)#.*$", re.DOTALL)


def _strip_quoted(args: str) -> str:
    """Drop quoted spans and any trailing shell comment.

    `--notes "pass --verify-tag next time"` mentions the flag; it does not set
    it, and neither does `# --verify-tag`. The quote half mirrors
    _is_notes_only_edit; the comment half is what CodeRabbit found missing on
    PR #144, where it turned the --verify-tag exemption into a bypass.
    """
    return _SHELL_COMMENT.sub("", re.sub(r'"[^"]*"|\'[^\']*\'', "", args))


def _is_notes_only_edit(args: str) -> bool:
    """Return True if gh release edit args only modify notes."""
    # Truncate at shell separators so chained commands don't pollute the check.
    # e.g. "v1.0.0 --notes '...' ; other-cmd --draft" → "v1.0.0 --notes '...'"
    args = re.split(r"\s*(?:;|&&|\|\|)\s*", args)[0]
    # Strip quoted strings to avoid false positives from notes content
    # (--notes "Changed --draft behavior" must not trigger the --draft block),
    # and the trailing shell comment with them: a --notes the shell discards is
    # not a notes-only edit.
    clean_args = _strip_quoted(args)
    has_notes = bool(
        re.search(r"(?:^|\s)(?:--notes\b|--notes-file\b|-n\b|-F\b)", clean_args)
    )
    has_dangerous = bool(_DANGEROUS_EDIT_FLAGS.search(clean_args))
    return has_notes and not has_dangerous


def check_command(command: str) -> None:
    """Check every invocation in the command for a dangerous release operation.

    Each invocation is judged on its own. The whole call used to be flattened
    with `" ".join(command.split())` and scanned as one string, which turned a
    newline into a space -- and a space is not a separator, so anything on its
    own line was never seen. `gh release create` burns a tag name permanently
    under immutable releases, so that was the wrong direction to be wrong in.
    """
    for segment in split_invocations(command):
        _check_invocation(segment)


def _check_invocation(cmd: str) -> None:
    """Block dangerous release operations in a single invocation."""
    # --- Check gh release <subcommand> ---
    # match, not search: the segment is one invocation, and "gh release create"
    # inside an unrelated argument -- echo "never run gh release create v1.2.3"
    # -- is words, not a command.
    match = GH_RELEASE_RE.match(cmd)
    if match:
        subcommand = match.group(1).lower()
        if subcommand in ALLOWED_RELEASE_SUBCOMMANDS:
            return
        # Everything below judges a release operation. Reading the help is none.
        args = _strip_quoted(cmd[match.end() :])
        if _HELP_FLAG.search(args):
            return
        if subcommand == "create":
            if _verify_tag_is_on(args):
                return
            block(
                "'gh release create' without --verify-tag creates the tag when it "
                "is missing, and that tag is lightweight: no signature, no author, "
                "and under immutable releases the name is burned permanently.",
                "Tag and push first, then publish against that tag:\n"
                "    git tag -s vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z\n"
                "    gh release create vX.Y.Z --verify-tag --notes-file <notes>\n"
                "  --verify-tag makes gh abort unless the tag already exists on the "
                "remote, so nothing can be created by accident. Where a release "
                "workflow exists, let it publish instead and do not run this at all.",
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
            edit_args = cmd[match.end() :]
            if _is_notes_only_edit(edit_args):
                return
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
    if GH_API_RELEASE_RE.match(cmd):
        # If no explicit method flag, gh api defaults to GET for bare calls,
        # but POST when -f/--field or --input is present. We block if a
        # mutating method is specified OR if data-sending flags are present.
        has_mutating_method = MUTATING_METHOD_RE.search(cmd)
        has_data_flags = re.search(r"\s(-f|--field|-F|--json-field|--input)\s", cmd)
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
    except Exception:  # noqa: BLE001 - hook must fail open on any stdin error, never block the tool call
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
