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
import shlex
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
#
# The call is read as the argv the shell will hand to gh, not matched as text.
# Two regexes did this before, and each shape they did not foresee was a way
# through: a quoted endpoint path ("repos/$R/releases/$ID"), a flag value with
# a space in it (-f body="new notes"), the long form --raw-field, --field=x.
# Their flags group also backtracked exponentially on a run of dash-words,
# which a 2-second hook timeout turns into a question of what the harness does
# on timeout. shlex splits the words the way the shell does, in linear time.
GH_API_RE = re.compile(INVOCATION_PREFIX + r"gh\s+api(?=\s|$)")

# A release endpoint anywhere in a word: a bare or leading-slash path, a full
# URL, or a path whose quoting shlex could not resolve ($'...').
_RELEASE_PATH_RE = re.compile(r"repos/[^/\s]+/[^/\s]+/releases(?:[/?#]|$)")

# gh api flags that take a value, from `gh api --help` (gh 2.101.0). The value
# is consumed so it cannot be read as the endpoint.
_VALUE_FLAGS = {
    "-X": "method",
    "--method": "method",
    "-f": "data",
    "--raw-field": "data",
    "-F": "data",
    "--field": "data",
    "--input": "data",
    "-H": None,
    "--header": None,
    "-q": None,
    "--jq": None,
    "-t": None,
    "--template": None,
    "--hostname": None,
    "--cache": None,
    "-p": None,
    "--preview": None,
}
_MUTATING_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
_SAFE_METHODS = {"GET", "HEAD"}


def _gh_api_mutates_release(args: str):
    """Return the method name if a gh api call mutates a release, else None.

    `args` is the text after `gh api`. gh sends POST when a field or an input
    body is present and no method is given, so data alone is a mutation unless
    the method is GET or HEAD (then the fields become query parameters).
    """
    try:
        words = shlex.split(args, comments=True)
    except ValueError:
        # Unbalanced quotes: the shell will not run this as written, but a
        # release path in it is reason enough not to guess.
        return "UNPARSEABLE" if _RELEASE_PATH_RE.search(args) else None
    method = None
    has_data = False
    positionals = []
    i = 0
    while i < len(words):
        word = words[i]
        name, value = word, None
        if word.startswith("--") and "=" in word:
            name, value = word.split("=", 1)
        elif len(word) > 2 and word[:2] in ("-X", "-f", "-F", "-H", "-q", "-t", "-p"):
            name, value = word[:2], word[2:]
        if name in _VALUE_FLAGS:
            if value is None:
                i += 1
                value = words[i] if i < len(words) else ""
            kind = _VALUE_FLAGS[name]
            if kind == "method":
                method = value
            elif kind == "data":
                has_data = True
        elif not word.startswith("-") or word == "-":
            positionals.append(word)
        i += 1
    if not any(_RELEASE_PATH_RE.search(w) for w in positionals):
        return None
    if method is not None:
        upper = method.upper()
        if upper in _SAFE_METHODS:
            return None
        # A mutating method, or one the guard cannot read ("$M").
        return upper if upper in _MUTATING_METHODS else method
    return "POST" if has_data else None


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
    api = GH_API_RE.match(cmd)
    if api:
        method = _gh_api_mutates_release(cmd[api.end() :])
        if method:
            block(
                f"Direct API call to release endpoint with {method} method "
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
