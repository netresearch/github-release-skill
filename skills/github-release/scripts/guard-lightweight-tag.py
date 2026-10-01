#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
"""
PreToolUse hook that blocks dangerous git tag operations.

Blocks:
  - Lightweight version tags (git tag v* without -s or -a)
  - Version tag deletion (git tag -d v*)
  - Remote version tag deletion (git push --delete origin v*, git push origin :refs/tags/v*)
  - Force-pushing tags (git push -f with tag refs)

Allows:
  - Signed tags: git tag -s v*
  - Annotated tags: git tag -a v*, and the -m/-F forms that imply -a
  - Listing and inspecting tags: git tag -l, --list, and the flags that imply
    list mode (-n, --contains, --no-contains, --points-at, --merged,
    --no-merged). --sort, --format, --column, -i and --omit-empty do not imply
    it, so with a version name and no -l they count as a creation.
  - Verifying tags: git tag -v v*
  - Non-version tags (tags not matching v* pattern)

Does not see (known limit):
  - A tag name that never appears as an argument of the guarded command,
    because a pipeline supplies it: echo vX.Y.Z | xargs git tag. Reading that
    would mean predicting what the left-hand side produces.

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
    # Match v followed by a digit at the start of an argument: after whitespace,
    # after a path separator (refs/tags/vX.Y.Z), or just inside a quote, because
    # a quoted tag name creates exactly the same tag as the bare form.
    return bool(re.search(r"""(?:^|[\s/"'])v\d""", args))


# "git tag" is judged by its words, split the way the shell splits them, not by
# searching the raw text. A text search read a flag spelled inside a quoted
# value ("--format='%(refname) -l '") or after a shell comment ("v1.2.3 # -l")
# as a real option and let the creation through, and read "v1" inside a
# format string as a tag name.

# Options that put "git tag" into list mode, so a version argument after them
# is a pattern or a ref to compare against, not a tag to create. git-tag(1)
# says "Implies --list" for -n, --contains, --no-contains and --points-at;
# --merged and --no-merged do the same in git 2.55.0 although the page does
# not say so. The other listing options (--sort, --format, --column,
# --no-column, -i/--ignore-case, --omit-empty) only shape a listing: without
# -l/--list, "git tag --sort=-v:refname v1.2.3" creates the lightweight tag
# v1.2.3, so they must not exempt a command from the creation check.
_LIST_OPTIONS = {
    "--list",
    "--contains",
    "--no-contains",
    "--points-at",
    "--merged",
    "--no-merged",
}
# Options that make the new tag an annotated or signed tag object. -m, -F and
# --trailer imply -a when -a/-s/-u are absent (git-tag(1)).
_ANNOTATING_OPTIONS = {
    "--annotate",
    "--sign",
    "--local-user",
    "--message",
    "--file",
    "--trailer",
}
# Long options whose value is the next word when no "=" is attached. The value
# is consumed so that it is never read as an option or as the tag name; one
# consequence is that "git tag --sort -l v1.2.3" counts as a creation (git
# itself rejects it: "unknown field name: l").
_VALUE_OPTIONS = {
    "--message",
    "--file",
    "--local-user",
    "--format",
    "--sort",
    "--cleanup",
    "--trailer",
}
# Short options in a group such as -sa: a value letter ends the group, and the
# rest of the word, or else the next word, is its value. -n takes only an
# attached number and ends the group too.
_SHORT_VALUE_LETTERS = "mFu"
_SHORT_ANNOTATING_LETTERS = "asmFu"

# A shell comment: an unquoted "#" that begins a word. A "#" inside a word or
# inside quotes is text.
_COMMENT_START = re.compile(
    r"""\"(?:\\.|[^"\\])*\"|'[^']*'|\\.|(?P<comment>(?:^|(?<=\s))#)"""
)


def _without_comment(args: str) -> str:
    """Cut a command's arguments at a real shell comment."""
    for match in _COMMENT_START.finditer(args):
        if match.group("comment") is not None:
            return args[: match.start()]
    return args


def _is_version_name(word: str) -> bool:
    """Whether a tag-name argument names a version tag (vX..., refs/tags/vX...).

    A leading "$" is what shlex leaves of ANSI-C quoting: bash turns
    $'v1.2.3' into v1.2.3, shlex into $v1.2.3.
    """
    word = word.strip()
    return bool(re.match(r"\$?v\d", word) or re.search(r"/v\d", word))


def _long_option_modes(name: str) -> set:
    """The modes a long option sets: list, verify, delete, annotate."""
    modes = set()
    if name in _LIST_OPTIONS:
        modes.add("list")
    if name in _ANNOTATING_OPTIONS:
        modes.add("annotate")
    if name == "--verify":
        modes.add("verify")
    if name == "--delete":
        modes.add("delete")
    return modes


# What each short option letter sets; a letter missing here sets nothing.
_SHORT_MODES = {
    "l": "list",
    "n": "list",
    "v": "verify",
    "d": "delete",
    **dict.fromkeys(_SHORT_ANNOTATING_LETTERS, "annotate"),
}


def _read_short_group(word: str, modes: set) -> int:
    """Record the modes of a short group such as -sa; return 1 if it consumes
    the next word as a value, else 0."""
    for j in range(1, len(word)):
        letter = word[j]
        if letter in _SHORT_MODES:
            modes.add(_SHORT_MODES[letter])
        if letter == "n":
            return 0
        if letter in _SHORT_VALUE_LETTERS:
            return 1 if j == len(word) - 1 else 0
    return 0


def _scan_tag_words(words: list):
    """Split "git tag" words into the modes their options set and the names."""
    modes = set()
    names = []
    options_done = False
    i = 0
    while i < len(words):
        word = words[i]
        if options_done or word == "-" or not word.startswith("-"):
            names.append(word)
        elif word == "--":
            options_done = True
        elif word.startswith("--"):
            name, eq, _ = word.partition("=")
            modes |= _long_option_modes(name)
            if name in _VALUE_OPTIONS and not eq:
                i += 1
        else:
            i += _read_short_group(word, modes)
        i += 1
    return modes, names


def _judge_tag_args(args: str):
    """One reading of a "git tag" argument string.

    Returns "delete" for the deletion of a version tag, "lightweight" for the
    creation of a lightweight version tag, and None for everything else.
    """
    try:
        # No comments=True: shlex would treat a "#" inside a word as a
        # comment, which bash does not. Comments are cut by _without_comment.
        words = shlex.split(args)
    except ValueError:
        # Unbalanced quotes: the shell will not run this as written, but a
        # version token in it is reason enough not to guess.
        return "lightweight" if has_version_tag_arg(args) else None

    modes, names = _scan_tag_words(words)

    has_version = any(_is_version_name(name) for name in names)
    # Deletion first: "git tag -d --sort=refname vX" deletes, while -d next to
    # a list-mode option makes git refuse to run at all.
    if "delete" in modes:
        return "delete" if has_version else None
    if modes & {"list", "verify"}:
        return None
    if has_version and "annotate" not in modes:
        return "lightweight"
    return None


def check_tag_invocation(segment: str) -> None:
    """Block dangerous "git tag" forms in a single invocation.

    The arguments are judged twice, with and without a trailing shell comment
    cut off, and the command is blocked if either reading blocks it: the
    comment cutter is a text scan, so a "#" it misreads can only cost a block,
    never hide a creation. The price is paid in the safe direction: a comment
    that names a version tag after a non-version creation ("git tag nightly
    # v1.2.3") is blocked, and so is any command naming a version whose
    trailing comment holds an apostrophe ("# don't"), a listing included,
    because the uncut reading cannot be parsed.

    The segment can span lines: a quoted multi-line -m message stays inside
    one invocation, so the arguments are captured with DOTALL. Without it the
    capture stopped at the first newline of the message, and the cut-off,
    unbalanced quote blocked an annotated tag with a multi-line message
    whenever the version stood before that newline.
    """
    tag_match = re.match(
        INVOCATION_PREFIX + r"git\s+tag\b(.*)", segment, flags=re.DOTALL
    )
    if not tag_match:
        return

    tag_args = tag_match.group(1).strip()
    verdict = _judge_tag_args(_without_comment(tag_args)) or _judge_tag_args(tag_args)

    if verdict == "delete":
        block(
            "Deleting a version tag is dangerous. Tags are immutable "
            "references that downstream consumers and CI pipelines depend on.",
            "If the tag points to a bad commit, create a new patch "
            "release (vX.Y.Z+1) instead of deleting the existing tag.",
        )
    if verdict == "lightweight":
        block(
            "Lightweight version tags lack metadata (author, date, message) "
            "and cannot be signed. Version tags MUST be annotated (-a) or "
            "signed (-s) to ensure traceability and integrity.",
            "Use 'git tag -s vX.Y.Z -m \"Release vX.Y.Z\"' for a signed tag, "
            "or 'git tag -a vX.Y.Z -m \"Release vX.Y.Z\"' for an annotated tag.",
        )

    # Non-version tag -- allow.


def targets_only_major_pointer(push_args: str) -> bool:
    """True when every tag ref in this push is a bare major pointer (`v4`).

    A moving major pointer is not a published release: consumers pin it *because*
    it moves, and `vX.Y.Z+1` — what the force-push block advises — is meaningless
    for it. The immutable `vX.Y.Z` releases it points at are untouched, and the
    convention is guarded on the server side by the repository's own pointer
    check. Blocking the force-push here does not prevent the move, it pushes the
    author to the tags API, which cannot sign the tag.
    """
    refs = re.findall(r"(?:refs/tags/)?(v\d[\w.\-]*)", push_args)
    return bool(refs) and all(re.fullmatch(r"v\d+", ref) for ref in refs)


def check_push_invocation(segment: str) -> None:
    """Block tag deletion and tag force-push in a single "git push"."""
    push_match = re.match(INVOCATION_PREFIX + r"git\s+push\b(.*)", segment)
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
            if re.search(
                r"refs/tags/v\d", push_args
            ) and not targets_only_major_pointer(push_args):
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
