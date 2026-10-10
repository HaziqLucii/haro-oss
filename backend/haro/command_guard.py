"""A speed bump in front of the agent's shell: refuse a command that matches a known way to destroy
work or to print a secret, before it runs.

It is a text match on what the agent is about to run, nothing more. The agent's shell can reach
the same files through any command or language this list does not know (``python -c``, a script it
wrote a minute ago), so a command that passes was not checked and one that is refused was only
recognised. The restore point haro pins at the start of every run (``restore_point.py``) and the
tamper alarm stay the real safety net. ``[agent] command_guard = false`` turns it off.

Two groups, one label per refusal (shown on the receipt, never claimed to be complete):
  * destroying work: ``git reset --hard``, ``git clean -f``, ``git checkout .``, ``git restore .``,
    ``git push --force``, and ``rm -r`` aimed at the whole worktree, ``.git``, a path outside the
    worktree (``/tmp`` is fine), the home directory, or something it cannot resolve;
  * printing secrets: reading ``.env`` and key files by name, ``printenv``, ``env`` with no command,
    ``echo $SOME_TOKEN``, and the Read tool on the same files. ``.env.example`` and friends are
    ordinary files and stay readable.
"""

from __future__ import annotations

import os
import re
import shlex
import tempfile

_OPERATORS = frozenset({";", "&&", "||", "|", "&", "|&", "(", ")"})
#: Commands that run another command, with the options that take a value (so the value is not
#: mistaken for the command). ``timeout`` also takes a duration before the command.
_WRAPPER_VALUE_FLAGS: dict[str, frozenset[str]] = {
    "sudo": frozenset({"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "--user", "--group"}),
    "doas": frozenset({"-u", "-C"}),
    "env": frozenset({"-u", "-C", "-S", "--unset", "--chdir"}),
    "nice": frozenset({"-n", "--adjustment"}),
    "ionice": frozenset({"-c", "-n", "-p", "-P", "-u"}),
    "timeout": frozenset({"-s", "-k", "--signal", "--kill-after"}),
    "xargs": frozenset({"-I", "-n", "-P", "-d", "-E", "-L", "-s", "-a"}),
    "nohup": frozenset(), "time": frozenset(), "command": frozenset(), "exec": frozenset(),
    "builtin": frozenset(), "setsid": frozenset(), "stdbuf": frozenset({"-i", "-o", "-e"}),
}
_GREPS = frozenset({"grep", "egrep", "fgrep", "rg", "ag", "ack"})
_SHELLS = frozenset({"bash", "sh", "zsh", "dash", "fish"})
_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

_PUBLIC_ENV_SUFFIXES = frozenset({"example", "sample", "template", "dist", "defaults", "tpl"})
_KEY_FILES = re.compile(r"(\.pem|\.key|\.p12|\.pfx)$|^(id_rsa|id_dsa|id_ecdsa|id_ed25519)$")
_SECRET_NAMES = frozenset({".npmrc", ".netrc", ".pgpass"})
_SECRET_DIRS = frozenset({".ssh", ".aws", ".gnupg"})
_SECRET_VAR = re.compile(r"\$\{?(?:[A-Z0-9_]*_)?(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIALS?)(?:_[A-Z0-9_]*)?\}?(?![A-Za-z0-9_])")
_ENVIRON = re.compile(r"/proc/[^/\s]+/environ")

#: Commands that name a file without reading what is in it.
_NOT_READERS = frozenset({
    "ls", "stat", "test", "[", "[[", "touch", "rm", "mkdir", "chmod", "chown", "which", "file",
    "wc", "echo", "printf", "ln", "cp", "mv", "dirname", "basename", "realpath", "readlink", "git", "true", ":",
})


_HEREDOC = re.compile(r"<<-?\s*(?:'([^']+)'|\"([^\"]+)\"|\\?([A-Za-z_][A-Za-z0-9_]*))")


def _drop_heredocs(command: str) -> str:
    """The text between ``<<EOF`` and ``EOF`` is data (a commit message, a file being written), not
    commands, so it is not checked."""
    out: list[str] = []
    ends: list[str] = []
    for line in command.split("\n"):
        if ends:
            if line.strip() == ends[0]:
                ends.pop(0)
            continue
        out.append(line)
        ends = [next(g for g in m.groups() if g) for m in _HEREDOC.finditer(line)]
    return "\n".join(out)


def _strip_write_redirects(seg: list[str]) -> list[str]:
    """Drop ``> file``, ``>> file``, ``2> file`` and ``>&``: the target is written to, not an argument."""
    out: list[str] = []
    i = 0
    while i < len(seg):
        tok = seg[i]
        if set(tok) <= set("<>&|") and ">" in tok:
            if out and out[-1].isdigit():
                out.pop()
            i += 2
            continue
        out.append(tok)
        i += 1
    return out


def _split_lines(command: str) -> str:
    """A newline or a backtick outside quotes separates commands like ``;`` does."""
    out: list[str] = []
    quote = ""
    i = 0
    while i < len(command):
        ch = command[i]
        if ch == "\\" and quote != "'" and i + 1 < len(command):
            out.append(command[i : i + 2])
            i += 2
            continue
        if quote:
            if ch == quote:
                quote = ""
        elif ch in "'\"":
            quote = ch
        elif ch in "\n`":
            ch = " ; "
        out.append(ch)
        i += 1
    return "".join(out)


def _tokens(command: str) -> list[str] | None:
    lex = shlex.shlex(_split_lines(_drop_heredocs(command)), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    try:
        return list(lex)
    except ValueError:
        return None


def _segments(tokens: list[str]) -> list[list[str]]:
    out: list[list[str]] = [[]]
    for tok in tokens:
        if tok in _OPERATORS:
            out.append([])
        else:
            out[-1].append(tok)
    return [s for s in out if s]


def _strip_wrappers(seg: list[str]) -> list[str]:
    i, last = 0, ""
    while i < len(seg):
        tok = seg[i]
        if _ASSIGN.match(tok):
            i += 1
            continue
        base = os.path.basename(tok)
        flags = _WRAPPER_VALUE_FLAGS.get(base)
        if flags is None:
            break
        i += 1
        last = base
        while i < len(seg) and seg[i].startswith("-") and seg[i] != "--":
            flag = seg[i]
            i += 1
            if flag in flags and i < len(seg):
                i += 1
        if base == "timeout" and i < len(seg):
            i += 1
    if last == "env" and i >= len(seg):
        return ["env"]
    return seg[i:]


def _is_secret_path(raw: str) -> bool:
    path = raw.strip().strip("\"'`)(<>@;").rstrip("\\")
    if not path:
        return False
    base = os.path.basename(path.rstrip("/"))
    if base == ".env":
        return True
    if base.startswith(".env."):
        return base.rsplit(".", 1)[-1].lower() not in _PUBLIC_ENV_SUFFIXES
    if base in _SECRET_NAMES or _KEY_FILES.search(base):
        return not base.endswith(".pub")
    parts = {p for p in path.replace("\\", "/").split("/") if p}
    return bool(parts & _SECRET_DIRS)


def _secret_label(path: str) -> str:
    name = os.path.basename(path.strip().strip("\"'").rstrip("/"))
    return f"read of {name or path}"


def _tmp_roots() -> tuple[str, ...]:
    raw = ("/tmp", "/var/tmp", tempfile.gettempdir())
    return tuple(dict.fromkeys([*raw, *(os.path.realpath(p) for p in raw)]))


def _rm_refusal(args: list[str], worktree: str, cwd: str | None) -> str | None:
    recursive = any(
        a == "--recursive" or (a.startswith("-") and not a.startswith("--") and ("r" in a or "R" in a))
        for a in args
    )
    if "--no-preserve-root" in args:
        return "rm -r --no-preserve-root"
    if not recursive:
        return None
    root = os.path.realpath(worktree)
    home = os.path.expanduser("~")
    for target in (a for a in args if not a.startswith("-") or a == "-"):
        t = target.replace("${HOME}", "~").replace("$HOME", "~")
        if "$" in t or "`" in t:
            return "rm -r on a path it cannot resolve"
        if cwd is None and not os.path.isabs(os.path.expanduser(t)):
            return "rm -r on a path it cannot resolve"
        resolved = os.path.normpath(os.path.join(cwd or root, os.path.expanduser(t)))
        parent = os.path.dirname(resolved)
        if resolved == os.path.normpath(home):
            return "rm -r on the home directory"
        if re.search(r"[*?\[]", os.path.basename(resolved)) and (parent == root or os.path.realpath(parent) == root):
            return "rm -r on the whole worktree"
        if resolved == root:
            return "rm -r on the whole worktree"
        if resolved == os.path.join(root, ".git") or resolved.startswith(os.path.join(root, ".git") + os.sep):
            return "rm -r on .git"
        if resolved == root or resolved.startswith(root + os.sep):
            continue
        if any(resolved.startswith(t + os.sep) for t in _tmp_roots()):
            continue
        return "rm -r outside the worktree"
    return None


def _git_refusal(args: list[str]) -> str | None:
    rest = list(args)
    while rest and rest[0].startswith("-"):
        flag = rest.pop(0)
        if flag in ("-C", "-c", "--git-dir", "--work-tree", "--namespace") and rest:
            rest.pop(0)
    if not rest:
        return None
    sub, tail = rest[0], rest[1:]
    flags = [a for a in tail if a.startswith("-")]
    plain = [a for a in tail if not a.startswith("-")]
    short = "".join(f.lstrip("-") for f in flags if not f.startswith("--"))
    if sub == "reset" and "--hard" in tail:
        return "git reset --hard"
    if sub == "clean" and ("--force" in tail or "f" in short) and "n" not in short and "--dry-run" not in tail:
        return "git clean -f"
    if sub == "checkout" and (set(plain) & {".", ":/"} or "--force" in tail or "f" in short):
        return "git checkout ."
    if sub == "restore" and set(plain) & {".", ":/"}:
        staged_only = ("--staged" in tail or "S" in short) and "--worktree" not in tail and "W" not in short
        return None if staged_only else "git restore ."
    if sub == "push" and ("--force" in tail or "--force-with-lease" in tail or "--mirror" in tail or "f" in short):
        return "git push --force"
    return None


def _segment_refusal(seg: list[str], worktree: str, cwd: str | None, depth: int = 0) -> str | None:
    seg = _strip_wrappers(_strip_write_redirects(seg))
    if not seg:
        return None
    cmd = os.path.basename(seg[0])
    args = seg[1:]
    if cmd in _SHELLS and depth < 3:
        for i, a in enumerate(args):
            if a in ("-c", "-lc", "-ic") and i + 1 < len(args):
                return refusal_for_command(args[i + 1], worktree, depth + 1, cwd)
        return None
    if cmd == "rm":
        return _rm_refusal(args, worktree, cwd)
    if cmd == "git":
        return _git_refusal(args)
    if cmd == "printenv":
        return "printenv"
    if cmd == "env" and not args:
        return "env"
    if cmd in ("export", "declare", "typeset") and "-p" in args:
        return f"{cmd} -p"
    if cmd == "set" and not args:
        return "set"
    if cmd in ("echo", "printf") and any(_SECRET_VAR.search(a) for a in args):
        return "echo of a secret variable"
    if any(_ENVIRON.search(a) for a in args):
        return "read of the process environment"
    if cmd not in _NOT_READERS:
        if cmd in _GREPS and not any(a in ("-e", "--regexp") or a.startswith("--regexp=") for a in args):
            first = next((i for i, a in enumerate(args) if not a.startswith("-")), None)
            if first is not None:
                args = args[:first] + args[first + 1 :]  # the pattern is text to find, not a file
        for a in args:
            if _is_secret_path(a):
                return _secret_label(a)
    return None


def refusal_for_command(command: str, worktree: str, depth: int = 0, cwd: str | None = "") -> str | None:
    """The label of the first thing in ``command`` the guard refuses, or None. ``cd`` earlier in
    the command moves where a relative path points (``cwd`` None: a ``cd`` it could not resolve)."""
    tokens = _tokens(command)
    if tokens is None:
        return None
    here: str | None = os.path.realpath(worktree) if not cwd else cwd
    for seg in _segments(tokens):
        stripped = _strip_wrappers(_strip_write_redirects(seg))
        if stripped and os.path.basename(stripped[0]) == "cd":
            target = stripped[1] if len(stripped) > 1 else "~"
            if here is None or "$" in target or "`" in target or target == "-":
                here = None
            else:
                here = os.path.normpath(os.path.join(here, os.path.expanduser(target)))
            continue
        label = _segment_refusal(seg, worktree, here, depth)
        if label:
            return label
    return None


def refusal(tool: str, tool_input: dict, worktree: str) -> str | None:
    """The label for a refused tool call (``Bash`` or ``Read``), or None to let it run."""
    if tool == "Bash":
        command = tool_input.get("command")
        return refusal_for_command(command, worktree) if isinstance(command, str) else None
    if tool == "Read":
        raw = tool_input.get("file_path")
        if isinstance(raw, str) and _is_secret_path(os.path.join(worktree, os.path.expanduser(raw))):
            return _secret_label(raw)
    return None


def reason(label: str) -> str:
    """What the agent is told when a call is refused: what matched, that nothing ran, and what to do."""
    if label.startswith(("read of", "printenv", "env", "export", "declare", "typeset", "set", "echo of")):
        what = "it would print a secret into this conversation"
    else:
        what = "it can destroy work that is not recoverable from git"
    return (
        f"Refused by haro before it ran ({label}): {what}. Nothing was executed. Do not work around "
        "it with another command. Carry on with the rest of the task; if this was needed, say what "
        "and why so the developer can decide."
    )
