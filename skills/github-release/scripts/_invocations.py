#!/usr/bin/env python3
"""Split a Bash tool call into the individual invocations it runs.

Shared by the PreToolUse guards in this directory. It lived in
guard-lightweight-tag.py first, where issue #105 and the heredoc handling in
v0.12.2 were worked out. guard-gh-release.py carried its own, simpler
splitting and was therefore blind to what this one already handled:
measured on 2026-09-11, eleven cases walked past it, among them
"gh release create" on its own line, behind sudo, inside a loop and inside a
subshell. Two copies of one parser drift; this module is the one copy.
"""

import re

# A quoted argument, an escaped character, or a run of separators between
# invocations. The quoted and escape alternatives come first so that a
# separator inside quotes is consumed as part of the argument rather than
# splitting it: a commit message holding a ";" is one invocation, not two. The
# separator set carries the grouping constructs, so an invocation inside a
# subshell, a brace group or a command substitution is still seen (issue #112).
#
# The escapes are not decoration. A double-quoted argument may contain \", and
# reading that as the closing quote shifts every quote after it by one, which
# swallows the separators around the next invocation and hides it. An escaped
# separator outside quotes is likewise literal text, not a separator: the shell
# passes it to the command rather than ending it.
QUOTED_SPAN_OR_SEPARATOR = re.compile(
    r"""\"(?:\\.|[^"\\])*\"|'[^']*'|\\.|(?P<sep>[;&|\n(){}]+)"""
)


# What may stand between the start of an invocation and the "git" that runs it:
# shell keywords opening a loop or a conditional, an env assignment, and the
# usual command wrappers. Matching these keeps a guarded invocation guarded when
# it sits in a loop body ("do git tag v1.2.3") or carries a prefix
# ("TZ=UTC …", "sudo …"). It stays a prefix match on purpose: searching for
# "git tag" anywhere in the segment would also fire on the word inside an
# unrelated argument, e.g. echo "run git tag v1.2.3 to tag".
INVOCATION_PREFIX = (
    r"(?:(?:then|else|elif|do|if|while|until|sudo|command|time|exec|env|nohup)\s+"
    r"|[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"
)


# The line that opens a heredoc: "<<WORD", "<< WORD", "<<-WORD", with the
# delimiter optionally quoted. Only the delimiter is captured; the terminator is
# that same word alone on a line (indented, for the "<<-" form).
#
# "(?<!<)" and "(?!<)" keep a here-STRING out: "cat <<< hello" feeds one word on
# stdin and opens no body, but without the guards the second and third "<" read
# as "<<" and "hello" becomes a delimiter.
HEREDOC_OPENER = re.compile(
    r"(?<!<)<<-?(?!<)\s*(?:'([^']+)'|\"([^\"]+)\"|([A-Za-z_][A-Za-z0-9_]*))"
)


def strip_heredoc_bodies(command: str) -> str:
    """Drop heredoc bodies, keeping the opener line and everything after the
    terminator.

    A heredoc body is DATA the command writes, not commands it runs. Writing a
    file that documents "git tag -d v1.2.3" is not deleting a tag, but the body
    reached split_invocations as if it were script: its separators split it into
    invocations, and a quoted example was then judged as a real one.

    This is not a cosmetic warning. A denied call runs NONE of its parts, so the
    file is never written and re-running the same call is denied identically --
    the guard blocks the commit messages, tests and docs that quote its own
    examples, including this repository's own test file.

    Nothing is dropped unless the terminator is actually there. Stripping is how
    an invocation becomes invisible to the rest of the guard, so it may only
    happen where a body provably ends: "<<" also appears as an arithmetic left
    shift, and "$(( FLAG << SHIFT ))" looks exactly like an opener whose
    delimiter is SHIFT. Stripping on sight would then swallow the remainder of
    the command -- a real "git tag -d vX.Y.Z" on a later line included.
    """
    lines, out, index = command.split("\n"), [], 0
    while index < len(lines):
        line = lines[index]
        out.append(line)
        index += 1
        opener = HEREDOC_OPENER.search(line)
        if not opener:
            continue
        delimiter = next(group for group in opener.groups() if group)
        # ".strip()" also covers the indented terminator of the "<<-" form.
        end = index
        while end < len(lines) and lines[end].strip() != delimiter:
            end += 1
        if end >= len(lines):
            continue  # no terminator: not a heredoc, keep every line as script
        out.append(lines[end])
        index = end + 1
    return "\n".join(out)


def split_invocations(command: str) -> list:
    """Split a shell command into its individual invocations.

    Bounds every later check to a single invocation. Without this, a capture
    that starts at "git tag" runs to the end of the whole command, so an
    unrelated token further along the script decides the verdict (issue #105).
    Heredoc bodies are removed first -- they are data, not invocations. Line
    continuations are folded next so that a wrapped invocation stays one segment
    instead of splitting at the newline.
    """
    folded = strip_heredoc_bodies(command).replace("\\\n", " ")
    segments, start = [], 0
    for match in QUOTED_SPAN_OR_SEPARATOR.finditer(folded):
        if match.group("sep") is None:
            continue  # a quoted argument: separators inside it are literal text
        segments.append(folded[start : match.start()])
        start = match.end()
    segments.append(folded[start:])
    return [segment.strip() for segment in segments if segment.strip()]
