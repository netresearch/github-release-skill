# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
"""Split a Bash tool call into the individual invocations it runs.

Shared by the PreToolUse guards in this directory. Two copies of one parser
drift, so this module is the one copy (issue #105, the heredoc handling in
v0.12.2, and the eleven cases measured on 2026-09-11 that walked past the
release guard's own simpler splitting).

The command is read with tree-sitter-bash, a real parser for the shell
grammar. Up to 1.5.1 this module split the text with regular expressions, and
every review of that splitter found shapes it had not foreseen: an escaped
quote, "{" inside a word, "<<" as an arithmetic shift, bash 5.3's ${ cmd; },
$'...' quoting (#159). Each was a way for a release command to pass unseen.
bashlex was measured and rejected: it raises on "[[ ... ]]", "$(( ... ))",
"case" and a quoted heredoc delimiter, all common in agent commands, so a
regex fallback would have stayed. tree-sitter does not raise; it marks what
it cannot read with ERROR nodes and keeps parsing around them.

What the parser gives, this module turns into the text the guards judge: one
string per simple command, in the order the commands appear, with nested
commands (a subshell, a "$( )", a loop body, a heredoc body that bash expands)
listed as commands of their own. On top of the grammar it follows the script
a shell is handed to run (issue #157): the argument of "bash -c" and of
"eval", a heredoc or here-string read by a shell on stdin, and text piped into
a shell. A script file ("bash release.sh") is not read.
"""

import itertools
import re
import shlex
import time

import tree_sitter_bash
from tree_sitter import Language, Parser

_PARSER = Parser(Language(tree_sitter_bash.language()))


# What may stand between the start of an invocation and the command it runs:
# shell keywords opening a loop or a conditional, an env assignment, and the
# usual command wrappers. The parser already separates loop bodies and
# conditions, so the keywords rarely reach this pattern; the wrappers and
# assignments do ("TZ=UTC …", "sudo …"). It stays a prefix match on purpose:
# searching for "git tag" anywhere in the invocation would also fire on the
# words inside an unrelated argument, e.g. echo "run git tag v1.2.3 to tag".
INVOCATION_PREFIX = (
    r"(?:(?:then|else|elif|do|if|while|until|sudo|command|time|exec|env|nohup)\s+"
    # The value of an assignment may hold a ${...} with blanks inside
    # ("a=${X:-foo bar} git tag v1"); \S* stopped at the blank and the prefix
    # failed, hiding the command. Quoted spans and escaped characters carry
    # blanks the same way ('A="x y" gh release create', "A=x\ y git tag").
    # Each alternative starts with a different character, so the pattern
    # cannot backtrack.
    r"|[A-Za-z_][A-Za-z0-9_]*="
    r"""(?:"(?:\\.|[^"\\])*"|'[^']*'|\$\{[^}]*\}|\\.|[^\s$"'\\]|\$(?!\{))*\s+)*"""
)


def command_word(name: str) -> str:
    """A pattern for the word that names the program `name` (issue #158).

    The shell runs the same program for "gh", "\\gh" (the backslash only
    bypasses an alias), "'gh'", "\"gh\"" and "/usr/bin/gh", so all of them
    name it. A directory part may be quoted along with the name
    ("\"/usr/bin/gh\""). The pattern ends at the end of the word.
    """
    return (
        r"""(?:\\|["'])?(?:[^\s"'/;&|()]*/)*""" + re.escape(name) + r"""["']?(?=\s|$)"""
    )


# One shell word: quoted spans, escaped characters and plain characters, up to
# the next blank. Every alternative starts with a different character, so it
# cannot backtrack.
_WORD = r"""(?:"(?:\\.|[^"\\])*"|'[^']*'|\\.|[^\s"'\\])+"""

# git's own options between "git" and its subcommand (git(1)). "git -C <dir>
# tag v1.2.3" is how an agent addresses a worktree, and it ran past the tag
# guard because "tag" had to follow "git" directly. The options that take the
# next word as their value are named; any other word starting with "-" is a
# flag. The flag alternative excludes the named ones, so each word has exactly
# one reading and a long run of options cannot backtrack.
_GIT_VALUE_OPTIONS = r"(?:C|c|-git-dir|-work-tree|-namespace|-config-env|-attr-source)"
GIT_GLOBAL_OPTIONS = (
    r"(?:\s+(?:-"
    + _GIT_VALUE_OPTIONS
    + r"\s+"
    + _WORD
    + r"|-(?!"
    + _GIT_VALUE_OPTIONS
    + r"(?:\s|$))\S*))*"
)

# gh accepts -R/--repo in front of the subcommand: "gh -R o/r release delete".
GH_GLOBAL_OPTIONS = (
    r"(?:\s+(?:(?:-R|--repo)\s+" + _WORD + r"|--repo=" + _WORD + r"|-R" + _WORD + r"))*"
)


# Shells whose script is followed: the operand of -c, or stdin when there is
# no -c and no script file (or -s is given). They share these options.
_SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
# Words that run the command after them. Their own options and env-style
# assignments are skipped to reach that command.
_WRAPPERS = {"sudo", "command", "exec", "env", "nohup", "time"}
# Shell options that take the next word as their value.
_SHELL_VALUE_OPTIONS = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}
# Commands whose arguments become a shell's script when piped into it.
_ECHOERS = {"echo", "printf"}
# A script inside a script inside a script ... is followed this deep, and an
# error inside a part already parsed again counts as one more level. The bound
# is about runaway input, not about any command an agent writes.
_MAX_DEPTH = 8
# Parsing is linear on a command the grammar accepts, but error recovery is
# not: measured with tree-sitter-bash 0.25.1, 3,000 "echo ==;" (27 KB) take
# 0.9 s for one parse and 6,000 take 3.5 s. Every nested parse after this many
# seconds is replaced by the coarse cut, so the parses that follow an error
# cannot add up past the hook's 10-second timeout. The first parse is not
# bounded; a guard that times out blocks the call (hooks.json).
_REPARSE_BUDGET_SECONDS = 2.0

_ANSI_C_ESCAPE = re.compile(
    r"\\(?:x([0-9A-Fa-f]{1,2})|u([0-9A-Fa-f]{1,4})|U([0-9A-Fa-f]{1,8})"
    r"|([0-7]{1,3})|c(.)|(.))",
    re.DOTALL,
)
_ANSI_C_SIMPLE = {
    "a": "\a",
    "b": "\b",
    "e": "\x1b",
    "E": "\x1b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "v": "\v",
    "\\": "\\",
    "'": "'",
    '"': '"',
    "?": "?",
}


def _decode_ansi_c(body: str) -> str:
    """The value bash gives the inside of $'...' (bash(1), QUOTING)."""

    def one(match):
        hex2, u4, u8, octal, control, other = match.groups()
        if hex2 or u4 or u8:
            return chr(min(int(hex2 or u4 or u8, 16), 0x10FFFF))
        if octal:
            return chr(int(octal, 8) & 0xFF)
        if control:
            return chr(ord(control) & 0x1F)
        return _ANSI_C_SIMPLE.get(other, "\\" + other)

    return _ANSI_C_ESCAPE.sub(one, body)


def _text(node, data: bytes) -> str:
    return data[node.start_byte : node.end_byte].decode("utf-8", "replace")


def _render(node, data: bytes) -> str:
    """The text of `node` as the guards read it.

    A $'...' string is rewritten into plain single quotes holding its value.
    The guards split arguments with shlex, which does not know ANSI-C quoting:
    it read the escaped quote in $'a\\'' as the closing one, every quote after
    it shifted, and a real "-X DELETE" ended up inside a quote bash never
    opens (issue #159). A backslash-newline continuation becomes a blank.
    """
    spans = []
    stack = [node]
    while stack:
        current = stack.pop()
        if current.type == "ansi_c_string":
            spans.append(current)
            continue
        stack.extend(current.children)
    spans.sort(key=lambda n: n.start_byte)
    parts, cursor = [], node.start_byte
    for span in spans:
        parts.append(data[cursor : span.start_byte].decode("utf-8", "replace"))
        body = _text(span, data)[2:-1]  # drop "$'" and "'"
        parts.append(shlex.quote(_decode_ansi_c(body)))
        cursor = span.end_byte
    parts.append(data[cursor : node.end_byte].decode("utf-8", "replace"))
    return "".join(parts).replace("\\\n", " ")


def _word_value(node, data: bytes) -> str:
    """The value of one argument node after quote removal, as far as the text
    shows it. Expansions stay as written ("$X"); their value is unknown."""
    text = _render(node, data)
    try:
        words = shlex.split(text)
    except ValueError:
        return text
    return " ".join(words)


def _program_and_args(command, data: bytes):
    """The basename of the program a command node runs, and the argument nodes
    after it, looking through wrappers such as sudo and env."""
    words = [
        child
        for child in command.children
        if child.is_named
        and child.type not in ("variable_assignment", "comment")
        and not child.type.endswith("_redirect")
    ]
    index = 0
    while index < len(words):
        name = _word_value(words[index], data).rsplit("/", 1)[-1]
        if name not in _WRAPPERS:
            return name, words[index + 1 :]
        index += 1
        while index < len(words):
            value = _word_value(words[index], data)
            if value.startswith("-") or re.match(r"[A-Za-z_][A-Za-z0-9_]*=", value):
                index += 1
            else:
                break
    return "", []


def _shell_script(command, data: bytes):
    """How a command node runs a shell, if it does.

    Returns None when the command is not a shell. Otherwise returns a pair:
    the script given with -c (None when there is no -c), and whether the shell
    reads its script from stdin -- no -c and no script file, or -s.
    """
    program, args = _program_and_args(command, data)
    if program == "eval":
        # eval joins its arguments and runs them, which is "bash -c" in place.
        return " ".join(_word_value(arg, data) for arg in args), False
    if program not in _SHELLS:
        return None
    has_c = has_s = False
    index = 0
    while index < len(args):
        value = _word_value(args[index], data)
        if value == "--" or value == "-":
            index += 1
            break
        if value in _SHELL_VALUE_OPTIONS:
            index += 2
            continue
        if value.startswith("--"):
            index += 1
            continue
        if len(value) > 1 and value[0] in "-+":
            if value[0] == "-":
                has_c = has_c or "c" in value[1:]
                has_s = has_s or "s" in value[1:]
            index += 1
            continue
        break
    operand = _word_value(args[index], data) if index < len(args) else None
    if has_c:
        return operand, False
    return None, has_s or operand is None


def _feeds_shell(command, data: bytes) -> bool:
    """Whether `command` is a shell that reads its script from stdin."""
    shell = _shell_script(command, data)
    return bool(shell and shell[1])


def _first_command(node):
    """The first command node in `node`, depth first, or None."""
    stack = [node]
    while stack:
        current = stack.pop()
        if current.type == "command":
            return current
        stack.extend(reversed(current.children))
    return None


def _stdin_scripts(node, data: bytes) -> list:
    """Scripts that `node` hands to a shell on stdin (issue #157).

    A heredoc or a here-string redirected into a shell, the same piped into a
    shell ("cat <<EOF | bash"), and the arguments of echo or printf piped into
    a shell. Each is a script bash runs, not data it writes.
    """
    scripts = []
    if node.type in ("heredoc_redirect", "herestring_redirect"):
        # The redirect hangs off a redirected_statement, or, for a here-string,
        # off the command itself.
        statement = node.parent
        if statement is not None and statement.type == "redirected_statement":
            receiver = statement.child_by_field_name("body")
        else:
            receiver = statement
        # "cat <<EOF | bash": the rest of the opener line, the pipe included,
        # sits inside the heredoc_redirect node.
        piped = next((c for c in node.children if c.type == "pipeline"), None)
        target = _first_command(piped) if piped is not None else None
        if (
            receiver is not None
            and receiver.type == "command"
            and _feeds_shell(receiver, data)
        ) or (target is not None and _feeds_shell(target, data)):
            if node.type == "heredoc_redirect":
                body = next(
                    (c for c in node.children if c.type == "heredoc_body"), None
                )
                if body is not None:
                    scripts.append(_text(body, data))
            else:
                value = [c for c in node.children if c.is_named]
                if value:
                    scripts.append(_word_value(value[-1], data))
    elif node.type == "pipeline":
        stages = [c for c in node.children if c.is_named]
        for previous, stage in itertools.pairwise(stages):
            receiver = _first_command(stage)
            if receiver is None or not _feeds_shell(receiver, data):
                continue
            source = (
                previous
                if previous.type == "command"
                else previous.child_by_field_name("body")
            )
            if source is None or source.type != "command":
                continue
            program, args = _program_and_args(source, data)
            if program in _ECHOERS:
                scripts.append("\n".join(_word_value(a, data) for a in args))
    return scripts


# Past the depth limit or the time budget, a nested script or a part the
# parser could not read is cut at every character that can end a command,
# quotes or not. Coarse on purpose: a piece
# that merely starts with a guarded word can only add a block, never hide a
# command.
_COARSE_SEPARATORS = re.compile(r"[\n;&|(){}]+")


def _error_region(error, data: bytes):
    """The text after the token the parser stumbled on, to the end of the line
    the ERROR node ends on.

    Commands the parser cannot place are not commands it may drop. Measured
    with tree-sitter-bash 0.25.1: "echo ==; gh release create v1" reads the
    ";" as an error and the gh words as arguments of echo; "${ git tag v1; }"
    (bash 5.3) and an unterminated heredoc come out as ERROR nodes too. The
    region starts after the first token of the ERROR node, so it is shorter
    than the text it came from, and it is parsed again on its own.
    """
    first = error.children[0] if error.children else error
    end = data.find(b"\n", error.end_byte)
    end = len(data) if end < 0 else end
    return data[first.end_byte : end].decode("utf-8", "replace"), end


def _collect(command: str, out: list, depth: int, deadline: float) -> None:
    if depth > _MAX_DEPTH or (depth and time.monotonic() > deadline):
        text = command.replace("\\\n", " ")
        out.extend(piece.strip() for piece in _COARSE_SEPARATORS.split(text))
        return
    data = command.encode("utf-8")
    stack = [_PARSER.parse(data).root_node]
    # ERROR nodes inside a region already parsed again are covered by it.
    covered_until = -1
    while stack:
        node = stack.pop()
        if node.type == "ERROR" and node.start_byte >= covered_until:
            region, covered_until = _error_region(node, data)
            _collect(region, out, depth + 1, deadline)
        if node.type == "command":
            out.append(_render(node, data).strip())
            shell = _shell_script(node, data)
            if shell is not None and shell[0] is not None:
                _collect(shell[0], out, depth + 1, deadline)
        for script in _stdin_scripts(node, data):
            _collect(script, out, depth + 1, deadline)
        stack.extend(reversed(node.children))


def split_invocations(command: str) -> list:
    """Split a shell command into its individual invocations.

    Bounds every later check to a single invocation. Without this, a capture
    that starts at "git tag" runs to the end of the whole command, so an
    unrelated token further along the script decides the verdict (issue #105).

    A heredoc body is data the command writes -- "cat > note.md <<'EOF'"
    documenting "git tag -d v1.2.3" is not deleting a tag -- so it yields no
    invocation, except where bash runs it: a "$( )" in the body of an unquoted
    delimiter, and a body that a shell reads as its script.

    A part the parser cannot read (an ERROR node) is parsed again from the
    token after the error to the end of its line (_error_region), and past the
    depth or time limit it is cut coarsely; either way its commands are judged.
    """
    out = []
    _collect(command, out, 0, time.monotonic() + _REPARSE_BUDGET_SECONDS)
    return [segment for segment in out if segment]
