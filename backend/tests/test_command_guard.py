"""The command guard: a text match in front of the agent's shell and Read tool."""

from __future__ import annotations

import pytest

from haro import command_guard as g
from haro import scope_fence

WT = "/home/dev/.haro/worktrees/w1"

REFUSED = {
    "git reset --hard": "git reset --hard",
    "git reset --hard HEAD~2": "git reset --hard",
    "npm test && git reset --hard": "git reset --hard",
    "git -C sub reset --hard": "git reset --hard",
    "git clean -fdx": "git clean -f",
    "git checkout .": "git checkout .",
    "git checkout -- .": "git checkout .",
    "git restore .": "git restore .",
    "git push --force origin x": "git push --force",
    "git push -f": "git push --force",
    "rm -rf /": "rm -r outside the worktree",
    "rm -rf ~": "rm -r on the home directory",
    "rm -rf .": "rm -r on the whole worktree",
    "rm -rf *": "rm -r on the whole worktree",
    "rm -rf .git": "rm -r on .git",
    "rm -rf ../other": "rm -r outside the worktree",
    "rm -rf $DIR/x": "rm -r on a path it cannot resolve",
    "sudo rm -rf /": "rm -r outside the worktree",
    "FOO=1 git clean -fd": "git clean -f",
    "echo a; rm -rf /": "rm -r outside the worktree",
    "npm run build\nrm -rf /": "rm -r outside the worktree",
    "bash -c 'git reset --hard'": "git reset --hard",
    "cat .env": "read of .env",
    "cat .env.local": "read of .env.local",
    "head -n1 config/.env": "read of .env",
    "cat ~/.ssh/id_rsa": "read of id_rsa",
    "echo `cat .env`": "read of .env",
    "echo $(cat .env)": "read of .env",
    "while read l; do echo x; done < .env": "read of .env",
    "printenv": "printenv",
    "printenv HOME": "printenv",
    "env": "env",
    "echo $OPENAI_API_KEY": "echo of a secret variable",
    "cat /proc/self/environ": "read of the process environment",
    "timeout 5 git reset --hard": "git reset --hard",
    "sudo -u root rm -rf /": "rm -r outside the worktree",
    "nice -n 5 git clean -fd": "git clean -f",
    "env -u FOO git reset --hard": "git reset --hard",
    "cd .. && rm -rf w1": "rm -r on the whole worktree",
    "cd $X && rm -rf stuff": "rm -r on a path it cannot resolve",
    "grep KEY .env": "read of .env",
    "echo $OPENAI_API_KEY $KEYBOARD": "echo of a secret variable",
    "echo ${API_KEY}": "echo of a secret variable",
}

ALLOWED = [
    "git reset --soft HEAD~1", "git reset HEAD file", "git clean -n", "git clean -nfd", "git checkout main",
    "git checkout -- src/a.ts", "git restore --staged .", "git restore src/a.ts", "git push origin x",
    "git add .env", "rm -rf node_modules", "rm -rf build/*", "rm -rf /tmp/x", "rm file.txt", "rm -f a.txt",
    "cat .env.example", "cat id_rsa.pub", "ls -la .env", "echo hello", "env FOO=1 npm test",
    "grep -r KEY src", "pnpm install",
    "rm -rf build 2>/dev/null", "rm -rf dist >/dev/null 2>&1", "rm -rf dist &> /dev/null",
    "cd sub && rm -rf node_modules", "cd sub && rm -rf *", "cd /tmp/x && rm -rf *", "cd build && rm -rf cache",
    "grep -rn '.env' src", 'echo "$KEYBOARD"', "echo $MONKEY", "git restore -S .", "git restore --staged --source=HEAD .",
    "git commit -F - <<'EOF'\ngit reset --hard is dangerous\nrm -rf /\nEOF", "cat <<EOF > notes.md\nprintenv\nEOF", "node -e 'x'", 'echo "x; rm -rf /"', "echo .env",
]


@pytest.mark.parametrize("command,label", REFUSED.items())
def test_refused(command, label):
    assert g.refusal_for_command(command, WT) == label


@pytest.mark.parametrize("command", ALLOWED)
def test_allowed(command):
    assert g.refusal_for_command(command, WT) is None


def test_unbalanced_quotes_are_allowed_not_guessed():
    assert g.refusal_for_command("echo 'oops", WT) is None


def test_the_read_tool_is_guarded_by_file_name():
    assert g.refusal("Read", {"file_path": ".env"}, WT) == "read of .env"
    assert g.refusal("Read", {"file_path": f"{WT}/.env.production"}, WT) == "read of .env.production"
    assert g.refusal("Read", {"file_path": ".env.example"}, WT) is None
    assert g.refusal("Read", {"file_path": "src/a.ts"}, WT) is None
    assert g.refusal("Grep", {"pattern": "x"}, WT) is None


def test_the_reason_says_nothing_ran_and_does_not_halt_the_task():
    r = g.reason("git reset --hard")
    assert "Nothing was executed" in r and "git reset --hard" in r
    assert "Carry on with the rest of the task" in r
    assert "—" not in r


def test_the_hook_denies_once_per_label_and_only_when_armed_with_the_guard():
    armed = scope_fence.arm(None, WT, guard=True)
    try:
        ev = {"tool_name": "Bash", "tool_input": {"command": "git reset --hard"}}
        out = scope_fence.judge(armed.token, ev)
        assert out["hookSpecificOutput"]["permissionDecision"] == "deny"
        scope_fence.judge(armed.token, ev)
        assert armed.refused == ["git reset --hard"]
        assert scope_fence.judge(armed.token, {"tool_name": "Bash", "tool_input": {"command": "ls"}}) == {}
        assert scope_fence.judge(armed.token, {"tool_name": "Write", "tool_input": {"file_path": "x"}}) == {}
    finally:
        scope_fence.disarm(armed)
    unguarded = scope_fence.arm(None, WT, guard=False)
    try:
        assert scope_fence.judge(unguarded.token, {"tool_name": "Bash", "tool_input": {"command": "git reset --hard"}}) == {}
    finally:
        scope_fence.disarm(unguarded)


def test_a_fenced_run_keeps_judging_edits_and_the_guard_together():
    from haro.scope_fence import Fence

    armed = scope_fence.arm(Fence.build(["src"]), WT, guard=True)
    try:
        assert scope_fence.judge(armed.token, {"tool_name": "Write", "tool_input": {"file_path": "docs/x.md"}})
        assert scope_fence.judge(armed.token, {"tool_name": "Bash", "tool_input": {"command": "cat .env"}})
        assert armed.blocked == ["docs/x.md"] and armed.refused == ["read of .env"]
    finally:
        scope_fence.disarm(armed)
