from haro.config import (
    _PLATFORM_CONTRACTS,
    TRUST_CONDITIONS,
    _toml_str,
    combined_instructions,
    copy_worktree_includes,
    load_project_settings,
    read_env,
    read_instructions,
    seed_worktree_env,
    write_env,
    write_instructions,
    write_project_agent,
    write_project_gate,
    write_project_merge_mode,
    write_project_scripts,
    write_project_trust,
)

# The platform-level standing blocks (backlog format, gate integrity, backlog
# close-out) that combined_instructions prepends to every run, ahead of a
# project's own team/personal instructions.
PLATFORM = "\n\n".join(_PLATFORM_CONTRACTS)


def test_toml_str_basic():
    assert _toml_str("npm install") == '"npm install"'


def test_toml_str_escapes_quotes_and_backslashes():
    assert _toml_str('say "hi"') == '"say \\"hi\\""'
    assert _toml_str("a\\b") == '"a\\\\b"'


def test_toml_str_multiline_uses_triple_quotes():
    out = _toml_str("nvm use 24\nnpm ci")
    assert out.startswith('"""')
    assert out.endswith('"""')
    assert "nvm use 24" in out


def test_instructions_write_read_roundtrip(tmp_path):
    write_instructions(str(tmp_path), "team rules", target="shared")
    write_instructions(str(tmp_path), "my rules", target="local")
    shared, local = read_instructions(str(tmp_path))
    assert shared == "team rules"
    assert local == "my rules"
    # the platform contracts always ship first, then team, then personal
    assert combined_instructions(str(tmp_path)) == (
        PLATFORM + "\n\nteam rules\n\nmy rules"
    )


def test_instructions_empty_text_removes_file(tmp_path):
    write_instructions(str(tmp_path), "temp", target="local")
    write_instructions(str(tmp_path), "   ", target="local")  # blank → unset
    _, local = read_instructions(str(tmp_path))
    assert local == ""
    assert not (tmp_path / ".haro" / "instructions.local.md").exists()


def test_instructions_absent_is_empty(tmp_path):
    assert read_instructions(str(tmp_path)) == ("", "")
    # No project instructions, but the platform contracts are always injected,
    # so an agent is still taught the backlog format + gate integrity on a fresh repo.
    assert combined_instructions(str(tmp_path)) == PLATFORM


def test_project_settings_loads_instructions_and_workflow(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text(
        "[workflow]\nconfirm_before_commit = true\nchangelog_on_commit = true\n"
    )
    (syn / "instructions.md").write_text("always add tests")
    ps = load_project_settings(str(tmp_path))
    # the platform contracts are prepended; the project's own text follows
    assert ps.instructions == PLATFORM + "\n\nalways add tests"
    assert ps.confirm_before_commit is True
    assert ps.changelog_on_commit is True


def test_workflow_toggles_default_false(tmp_path):
    ps = load_project_settings(str(tmp_path))
    assert ps.confirm_before_commit is False
    assert ps.changelog_on_commit is False


def test_gate_merge_result_defaults_off_and_parses(tmp_path):
    assert load_project_settings(str(tmp_path)).gate_merge_result is False
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text("[gate]\nmerge_result = true\n")
    assert load_project_settings(str(tmp_path)).gate_merge_result is True


def test_verified_hunks_defaults_on_and_opts_out(tmp_path):
    # Evidence, never a verdict — on by default (usp-critique-plan.md idea 3), unlike
    # every other opt-in gate flag above. The opt-out must actually write `false`, not
    # rely on omitting a `true` that would just read back as the default anyway.
    assert load_project_settings(str(tmp_path)).verified_hunks is True
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text("[gate]\nverified_hunks = false\n")
    assert load_project_settings(str(tmp_path)).verified_hunks is False


def test_write_project_gate_verified_hunks_off_roundtrips(tmp_path):
    from haro.config import write_project_gate

    write_project_gate(
        str(tmp_path), runner="", command="", gate_format="", gate_dir="",
        default_scope="all", merge_result=False, flaky_rerun=False,
        coverage_guard="off", coverage_tolerance=0.0, verified_hunks=False,
    )
    on_disk = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "verified_hunks = false" in on_disk
    assert load_project_settings(str(tmp_path)).verified_hunks is False

    # Writing it back ON must omit the key entirely (it's the default) rather than
    # writing `true` — otherwise the on-disk file never shrinks back to minimal.
    write_project_gate(
        str(tmp_path), runner="", command="", gate_format="", gate_dir="",
        default_scope="all", merge_result=False, flaky_rerun=False,
        coverage_guard="off", coverage_tolerance=0.0, verified_hunks=True,
    )
    on_disk = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "verified_hunks" not in on_disk
    assert load_project_settings(str(tmp_path)).verified_hunks is True


def test_issue_writeback_defaults_off_and_parses(tmp_path):
    # Writing to GitHub is a visible side effect, so it stays opt-in.
    assert load_project_settings(str(tmp_path)).issue_writeback is False
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text("[backlog]\nissue_writeback = true\n")
    assert load_project_settings(str(tmp_path)).issue_writeback is True


def test_agent_guardrails_default_to_cost_conscious_values(tmp_path):
    # No [agent] table → Sonnet (not Opus), CLI-default effort, a hard per-run
    # budget cap, and a cumulative-spend warning threshold.
    ps = load_project_settings(str(tmp_path))
    assert ps.default_model == "sonnet"
    assert ps.default_effort == ""
    assert ps.max_budget_usd == 5.0
    assert ps.cost_warn_usd == 20.0


def test_agent_guardrails_are_overridable(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text(
        "[agent]\n"
        'default_model = "opus"\n'
        'default_effort = "low"\n'
        "max_budget_usd = 2.5\n"
        "cost_warn_usd = 0\n"
    )
    ps = load_project_settings(str(tmp_path))
    assert ps.default_model == "opus"
    assert ps.default_effort == "low"
    assert ps.max_budget_usd == 2.5
    assert ps.cost_warn_usd == 0.0


def test_personal_agent_override_wins_even_when_it_equals_the_default(tmp_path):
    """A personal (.local) save whose value happens to equal the global default must
    still override a non-default team value. Regression: write_project_agent used to
    OMIT default-valued keys, so the omitted `.local` key fell through to the committed
    settings.toml — the personal save silently didn't stick.
    """
    proj = str(tmp_path)
    # Team file pins non-default guardrails.
    write_project_agent(
        proj,
        default_model="opus",
        default_effort="high",
        max_budget_usd=2.0,
        cost_warn_usd=10.0,
        target="shared",
    )
    # Personal override resets everything toward the *defaults* (model=sonnet, no effort,
    # budget=5.0, warn=20.0) — the values that used to be omitted.
    write_project_agent(
        proj,
        default_model="sonnet",
        default_effort="",
        max_budget_usd=5.0,
        cost_warn_usd=20.0,
        target="local",
    )
    ps = load_project_settings(proj)
    assert ps.default_model == "sonnet"   # not the team's "opus"
    assert ps.default_effort == ""        # not the team's "high"
    assert ps.max_budget_usd == 5.0       # not the team's 2.0
    assert ps.cost_warn_usd == 20.0       # not the team's 10.0
    # The team file is untouched (personal is a separate layer).
    assert 'default_model = "opus"' in (tmp_path / ".haro" / "settings.toml").read_text()


def test_shared_agent_write_still_omits_defaults(tmp_path):
    """The minimal-block behaviour is preserved for the committed (shared) file — only
    the `.local` override layer pins defaults explicitly."""
    proj = str(tmp_path)
    write_project_agent(
        proj,
        default_model="sonnet",   # the default → should NOT be written
        default_effort="",
        max_budget_usd=5.0,       # the default → should NOT be written
        cost_warn_usd=20.0,       # the default → should NOT be written
        target="shared",
    )
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "default_model" not in text
    assert "max_budget_usd" not in text
    assert "cost_warn_usd" not in text


def test_agent_guardrails_reject_junk_and_fall_back(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text(
        "[agent]\n"
        'default_model = ""\n'          # blank → keep the Sonnet default
        'max_budget_usd = "nope"\n'      # non-numeric → fall back
    )
    ps = load_project_settings(str(tmp_path))
    assert ps.default_model == "sonnet"
    assert ps.max_budget_usd == 5.0


def test_gate_runner_and_command_default_empty(tmp_path):
    # No [gate] table → runner "" (dispatch falls back to vitest) and no command.
    ps = load_project_settings(str(tmp_path))
    assert ps.gate_runner == ""
    assert ps.gate_command == ""


def test_gate_command_runner_parses(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text(
        '[gate]\nrunner = "command"\ncommand = "make test"\n'
    )
    ps = load_project_settings(str(tmp_path))
    assert ps.gate_runner == "command"
    assert ps.gate_command == "make test"


def test_write_project_scripts_writes_gate_table_and_roundtrips(tmp_path):
    # A preset's [scripts]+[gate] written by write_project_scripts must parse back
    # to the same runner/command (the propose-and-confirm "write" step).
    write_project_scripts(
        str(tmp_path),
        setup="npm i -g @shopify/cli @shopify/theme",
        run="shopify theme dev --port $HARO_PORT",
        archive=None,
        run_mode="concurrent",
        login_shell=False,
        port_range=(4100, 4200),
        gate={
            "runner": "offense",
            "command": "shopify theme check --output json",
            "format": "theme-check",
        },
        target="shared",
    )
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "[gate]" in text
    # runner leads the table for readability.
    assert text.index("runner") < text.index("command") < text.index("format")
    ps = load_project_settings(str(tmp_path))
    assert ps.gate_runner == "offense"
    assert ps.gate_command == "shopify theme check --output json"
    assert ps.setup == "npm i -g @shopify/cli @shopify/theme"


def test_write_project_merge_mode_roundtrips(tmp_path):
    write_project_merge_mode(str(tmp_path), "pr", target="shared")
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "[workflow]" in text
    assert load_project_settings(str(tmp_path)).merge_mode == "pr"


def test_write_project_merge_mode_updates_in_place(tmp_path):
    # Writing twice must not duplicate the key (which would make the TOML invalid).
    write_project_merge_mode(str(tmp_path), "pr", target="shared")
    write_project_merge_mode(str(tmp_path), "merge", target="shared")
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert text.count("merge_mode") == 1
    assert load_project_settings(str(tmp_path)).merge_mode == "merge"


def test_write_project_merge_mode_preserves_other_tables(tmp_path):
    # The Git tab must not clobber a project's scripts/gate config when it sets the
    # ship policy — the reason it's a targeted write, not a full regenerate.
    write_project_scripts(
        str(tmp_path),
        setup="npm ci",
        run="npm run dev",
        archive=None,
        run_mode="concurrent",
        login_shell=False,
        port_range=(4100, 4200),
        gate={"runner": "command", "command": "eslint ."},
        target="shared",
    )
    write_project_merge_mode(str(tmp_path), "merge", target="shared")
    ps = load_project_settings(str(tmp_path))
    assert ps.merge_mode == "merge"
    assert ps.setup == "npm ci"
    assert ps.gate_runner == "command"
    assert ps.gate_command == "eslint ."
    assert ps.port_range == (4100, 4200)


def test_write_project_merge_mode_local_target_is_gitignored(tmp_path):
    write_project_merge_mode(str(tmp_path), "merge", target="local")
    assert (tmp_path / ".haro" / "settings.local.toml").exists()
    ignore = (tmp_path / ".haro" / ".gitignore").read_text()
    assert "settings.local.toml" in ignore


def test_write_project_scripts_omits_empty_gate(tmp_path):
    # custom/none preset → empty gate → no [gate] table (dispatch defaults to vitest).
    write_project_scripts(
        str(tmp_path),
        setup=None,
        run=None,
        archive=None,
        run_mode="concurrent",
        login_shell=False,
        port_range=(4100, 4200),
        gate={},
        target="shared",
    )
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "[gate]" not in text
    assert load_project_settings(str(tmp_path)).gate_runner == ""


def test_gate_runner_is_normalized_and_command_trimmed(tmp_path):
    # runner is lower-cased/stripped; command has surrounding whitespace trimmed.
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text(
        '[gate]\nrunner = "  Command  "\ncommand = "  shopify theme check  "\n'
    )
    ps = load_project_settings(str(tmp_path))
    assert ps.gate_runner == "command"
    assert ps.gate_command == "shopify theme check"


def test_gate_default_scope_defaults_to_all(tmp_path):
    # No [gate] table → the auto-gate runs the full suite (safe, trustworthy).
    assert load_project_settings(str(tmp_path)).gate_default_scope == "all"


def test_gate_default_scope_opt_in_impacted(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text('[gate]\ndefault_scope = "impacted"\n')
    assert load_project_settings(str(tmp_path)).gate_default_scope == "impacted"


def test_gate_default_scope_junk_falls_back_to_all(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text('[gate]\ndefault_scope = "everything"\n')
    assert load_project_settings(str(tmp_path)).gate_default_scope == "all"


def test_writing_config_creates_gitignore(tmp_path):
    write_instructions(str(tmp_path), "hi", target="local")
    gi = (tmp_path / ".haro" / ".gitignore").read_text()
    assert "instructions.local.md" in gi
    assert "settings.local.toml" in gi


def _gate(tmp_path, **kw):
    """write_project_gate with sane defaults, override only what a test cares about."""
    defaults = dict(
        runner="vitest",
        command="",
        gate_format="",
        gate_dir="",
        default_scope="all",
        merge_result=False,
        flaky_rerun=False,
        coverage_guard="off",
        coverage_tolerance=0.0,
        target="shared",
    )
    defaults.update(kw)
    return write_project_gate(str(tmp_path), **defaults)


def test_write_project_gate_command_runner_roundtrips(tmp_path):
    _gate(tmp_path, runner="command", command="shopify theme check")
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "[gate]" in text
    ps = load_project_settings(str(tmp_path))
    assert ps.gate_runner == "command"
    assert ps.gate_command == "shopify theme check"


def test_write_project_gate_defaults_emit_no_keys(tmp_path):
    # An all-default gate (vitest, full suite) should write nothing under [gate] —
    # dispatch then falls back to vitest, matching write_project_scripts's empty-gate case.
    _gate(tmp_path)
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "runner =" not in text
    ps = load_project_settings(str(tmp_path))
    assert ps.gate_runner == ""  # "" ⇒ vitest


def test_write_project_gate_scope_merge_and_dir(tmp_path):
    _gate(tmp_path, gate_dir="frontend/", default_scope="impacted", merge_result=True)
    ps = load_project_settings(str(tmp_path))
    assert ps.gate_dir == "frontend"
    assert ps.gate_default_scope == "impacted"
    assert ps.gate_merge_result is True


def test_write_project_gate_writes_workflow_guards(tmp_path):
    _gate(tmp_path, flaky_rerun=True, coverage_guard="block", coverage_tolerance=1.5)
    ps = load_project_settings(str(tmp_path))
    assert ps.flaky_rerun is True
    assert ps.coverage_guard == "block"
    assert ps.coverage_tolerance == 1.5


def test_tamper_alarm_defaults_on_to_warn(tmp_path):
    # Unlike the other guards, the tamper alarm is ON by default — "warn" is the value
    # we omit from disk, so an all-default project still loads it as "warn".
    _gate(tmp_path)
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "tamper_alarm" not in text
    assert load_project_settings(str(tmp_path)).tamper_alarm == "warn"


def test_write_project_gate_tamper_alarm_roundtrips(tmp_path):
    # Only the opt-out ("off") and opt-in-to-blocking ("block") are persisted.
    _gate(tmp_path, tamper_alarm="block")
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert 'tamper_alarm = "block"' in text
    assert load_project_settings(str(tmp_path)).tamper_alarm == "block"

    _gate(tmp_path, tamper_alarm="off")
    assert load_project_settings(str(tmp_path)).tamper_alarm == "off"

    # Back to the default clears the key again.
    _gate(tmp_path, tamper_alarm="warn")
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "tamper_alarm" not in text


def test_write_project_gate_switch_to_vitest_clears_command(tmp_path):
    # Switching runner back to vitest must drop the now-irrelevant command/format keys.
    _gate(tmp_path, runner="offense", command="eslint .", gate_format="eslint")
    _gate(tmp_path, runner="vitest")
    ps = load_project_settings(str(tmp_path))
    assert ps.gate_runner == ""
    assert ps.gate_command == ""
    assert ps.gate_format == ""


def test_write_project_gate_updates_in_place(tmp_path):
    # Writing twice must not duplicate keys (which would make the TOML invalid).
    _gate(tmp_path, runner="command", command="a")
    _gate(tmp_path, runner="command", command="b")
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert text.count("command =") == 1
    assert load_project_settings(str(tmp_path)).gate_command == "b"


def test_write_project_gate_preserves_other_tables(tmp_path):
    # The Gate tab must not clobber the project's scripts/ports or the Git tab's
    # merge_mode — it's a targeted write for the same reason merge_mode is.
    write_project_scripts(
        str(tmp_path),
        setup="npm ci",
        run="npm run dev",
        archive=None,
        run_mode="concurrent",
        login_shell=False,
        port_range=(4100, 4200),
        target="shared",
    )
    write_project_merge_mode(str(tmp_path), "merge", target="shared")
    _gate(tmp_path, runner="pytest", flaky_rerun=True)
    ps = load_project_settings(str(tmp_path))
    assert ps.setup == "npm ci"
    assert ps.port_range == (4100, 4200)
    assert ps.merge_mode == "merge"
    assert ps.gate_runner == "pytest"
    assert ps.flaky_rerun is True


def test_write_project_gate_local_target_is_gitignored(tmp_path):
    _gate(tmp_path, runner="pytest", target="local")
    assert (tmp_path / ".haro" / "settings.local.toml").exists()
    assert "settings.local.toml" in (tmp_path / ".haro" / ".gitignore").read_text()


def _agent(tmp_path, **overrides):
    """write_project_agent with sane defaults, override only what a test cares about."""
    defaults = dict(
        default_model="sonnet",
        default_effort="",
        max_budget_usd=5.0,
        cost_warn_usd=20.0,
        target="shared",
    )
    defaults.update(overrides)
    return write_project_agent(str(tmp_path), **defaults)


def test_write_project_agent_roundtrips(tmp_path):
    _agent(tmp_path, default_model="opus", default_effort="high", max_budget_usd=10.0)
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "[agent]" in text
    ps = load_project_settings(str(tmp_path))
    assert ps.default_model == "opus"
    assert ps.default_effort == "high"
    assert ps.max_budget_usd == 10.0


def test_write_project_agent_defaults_emit_no_keys(tmp_path):
    # An all-default agent config (sonnet, ~medium, $5 cap, $20 warn) writes nothing.
    _agent(tmp_path)
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "default_model" not in text
    assert "max_budget_usd" not in text
    ps = load_project_settings(str(tmp_path))
    assert ps.default_model == "sonnet"
    assert ps.max_budget_usd == 5.0


def test_write_project_agent_updates_in_place(tmp_path):
    _agent(tmp_path, default_model="opus")
    _agent(tmp_path, default_model="haiku")
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert text.count("default_model") == 1
    assert load_project_settings(str(tmp_path)).default_model == "haiku"


def test_write_project_agent_back_to_default_clears_key(tmp_path):
    # Switching back to the default model must drop the now-redundant key.
    _agent(tmp_path, default_model="opus")
    _agent(tmp_path, default_model="sonnet")
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "default_model" not in text
    assert load_project_settings(str(tmp_path)).default_model == "sonnet"


def test_write_project_agent_preserves_other_tables(tmp_path):
    # The Agent tab must not clobber scripts/ports, the Git tab's merge_mode, or the
    # Gate tab's [gate]/[workflow] guards — it's a targeted write like the others.
    write_project_scripts(
        str(tmp_path),
        setup="npm ci",
        run="npm run dev",
        archive=None,
        run_mode="concurrent",
        login_shell=False,
        port_range=(4100, 4200),
        target="shared",
    )
    write_project_merge_mode(str(tmp_path), "merge", target="shared")
    _gate(tmp_path, runner="pytest", flaky_rerun=True)
    _agent(tmp_path, default_model="opus", max_budget_usd=8.0)
    ps = load_project_settings(str(tmp_path))
    assert ps.setup == "npm ci"
    assert ps.port_range == (4100, 4200)
    assert ps.merge_mode == "merge"
    assert ps.gate_runner == "pytest"
    assert ps.flaky_rerun is True
    assert ps.default_model == "opus"
    assert ps.max_budget_usd == 8.0


def test_write_project_agent_local_target_is_gitignored(tmp_path):
    _agent(tmp_path, default_model="opus", target="local")
    assert (tmp_path / ".haro" / "settings.local.toml").exists()
    assert "settings.local.toml" in (tmp_path / ".haro" / ".gitignore").read_text()


def test_env_write_read_roundtrip_and_trailing_newline(tmp_path):
    saved = write_env(str(tmp_path), "API_KEY=abc\nDB_URL=x")
    assert saved.endswith(".haro/.env")
    # content is normalized to end with a newline (dotenv convention).
    assert (tmp_path / ".haro" / ".env").read_text() == "API_KEY=abc\nDB_URL=x\n"
    assert read_env(str(tmp_path)) == "API_KEY=abc\nDB_URL=x\n"


def test_env_write_is_always_gitignored(tmp_path):
    # `.env` holds secrets — saving it must guarantee `.haro/.gitignore` ignores it.
    write_env(str(tmp_path), "SECRET=1")
    gi = (tmp_path / ".haro" / ".gitignore").read_text()
    assert ".env" in gi.splitlines()


def test_env_empty_removes_the_seed(tmp_path):
    write_env(str(tmp_path), "A=1")
    write_env(str(tmp_path), "   ")  # blank → unset
    assert read_env(str(tmp_path)) == ""
    assert not (tmp_path / ".haro" / ".env").exists()


def test_env_absent_reads_empty(tmp_path):
    assert read_env(str(tmp_path)) == ""


def test_seed_worktree_env_copies_seed_into_fresh_worktree(tmp_path):
    project = tmp_path / "project"
    worktree = tmp_path / "wt"
    worktree.mkdir()
    write_env(str(project), "API_KEY=abc")
    assert seed_worktree_env(str(project), str(worktree)) is True
    assert (worktree / ".env").read_text() == "API_KEY=abc\n"


def test_seed_worktree_env_never_clobbers_existing_env(tmp_path):
    project = tmp_path / "project"
    worktree = tmp_path / "wt"
    worktree.mkdir()
    write_env(str(project), "API_KEY=seed")
    (worktree / ".env").write_text("API_KEY=already-here\n")
    assert seed_worktree_env(str(project), str(worktree)) is False
    assert (worktree / ".env").read_text() == "API_KEY=already-here\n"


def test_seed_worktree_env_noop_without_a_seed(tmp_path):
    project = tmp_path / "project"
    worktree = tmp_path / "wt"
    worktree.mkdir()
    assert seed_worktree_env(str(project), str(worktree)) is False
    assert not (worktree / ".env").exists()


def test_include_files_defaults_to_env_glob(tmp_path):
    # No `[files]` table → the historical `.env*` default, so nothing regresses.
    assert load_project_settings(str(tmp_path)).include_files == [".env*"]


def test_include_files_parsed_from_files_table(tmp_path):
    base = tmp_path / ".haro"
    base.mkdir()
    (base / "settings.toml").write_text(
        '[files]\ninclude = [".env*", ".npmrc", "certs/*.pem"]\n'
    )
    assert load_project_settings(str(tmp_path)).include_files == [
        ".env*",
        ".npmrc",
        "certs/*.pem",
    ]


def test_copy_worktree_includes_copies_matching_gitignored_files(tmp_path):
    project = tmp_path / "project"
    worktree = tmp_path / "wt"
    (project / "certs").mkdir(parents=True)
    worktree.mkdir()
    (project / ".env").write_text("A=1\n")
    (project / ".env.local").write_text("B=2\n")
    (project / ".npmrc").write_text("//registry/:_authToken=xyz\n")
    (project / "certs" / "dev.pem").write_text("PEM\n")
    (project / "README.md").write_text("# not matched\n")

    copied = copy_worktree_includes(
        str(project), str(worktree), [".env*", ".npmrc", "certs/*.pem"]
    )

    assert set(copied) == {".env", ".env.local", ".npmrc", "certs/dev.pem"}
    assert (worktree / ".env").read_text() == "A=1\n"
    assert (worktree / "certs" / "dev.pem").read_text() == "PEM\n"
    assert not (worktree / "README.md").exists()


def test_copy_worktree_includes_never_clobbers_existing_dest(tmp_path):
    # A file already in the worktree (e.g. the `.haro/.env` seed, or a tracked file)
    # is left untouched — the copy only fills in what's missing.
    project = tmp_path / "project"
    worktree = tmp_path / "wt"
    project.mkdir()
    worktree.mkdir()
    (project / ".env").write_text("from-root\n")
    (worktree / ".env").write_text("already-here\n")

    copied = copy_worktree_includes(str(project), str(worktree), [".env*"])

    assert copied == []
    assert (worktree / ".env").read_text() == "already-here\n"


def test_copy_worktree_includes_refuses_escaping_patterns(tmp_path):
    project = tmp_path / "project"
    worktree = tmp_path / "wt"
    project.mkdir()
    worktree.mkdir()
    (tmp_path / "secret.txt").write_text("outside\n")

    copied = copy_worktree_includes(
        str(project), str(worktree), ["../secret.txt", "/etc/hostname"]
    )

    assert copied == []
    assert not (worktree / "secret.txt").exists()


def test_gitignore_is_idempotent_and_preserves_content(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / ".gitignore").write_text("node_modules/\n")
    write_instructions(str(tmp_path), "a", target="local")
    write_instructions(str(tmp_path), "b", target="local")  # second write — no dupes
    gi = (syn / ".gitignore").read_text()
    assert "node_modules/" in gi  # hand-added line preserved
    assert gi.count("instructions.local.md") == 1
    assert gi.count("settings.local.toml") == 1


# --- user-global settings layer (cross-project defaults) ---------------------

def test_user_global_settings_supply_cross_project_defaults(tmp_path, monkeypatch):
    # A user-global settings.toml with no per-project config → its values are the
    # defaults for the project.
    user_cfg = tmp_path / "user" / "settings.toml"
    user_cfg.parent.mkdir(parents=True)
    user_cfg.write_text('[agent]\ndefault_model = "opus"\ndefault_effort = "high"\n')
    monkeypatch.setenv("HARO_USER_CONFIG", str(user_cfg))

    project = tmp_path / "proj"
    project.mkdir()
    ps = load_project_settings(str(project))
    assert ps.default_model == "opus"
    assert ps.default_effort == "high"


def test_project_config_overrides_user_global(tmp_path, monkeypatch):
    # Committed project config wins over the user-global default, key-by-key
    # (default_model overridden, default_effort inherited from user-global).
    user_cfg = tmp_path / "user" / "settings.toml"
    user_cfg.parent.mkdir(parents=True)
    user_cfg.write_text('[agent]\ndefault_model = "opus"\ndefault_effort = "high"\n')
    monkeypatch.setenv("HARO_USER_CONFIG", str(user_cfg))

    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text('[agent]\ndefault_model = "haiku"\n')
    ps = load_project_settings(str(tmp_path))
    assert ps.default_model == "haiku"   # project committed wins
    assert ps.default_effort == "high"   # inherited from user-global


def test_local_overrides_user_global_and_committed(tmp_path, monkeypatch):
    # Full precedence chain: user-global < committed < personal .local.
    user_cfg = tmp_path / "user" / "settings.toml"
    user_cfg.parent.mkdir(parents=True)
    user_cfg.write_text('[agent]\ndefault_model = "opus"\n')
    monkeypatch.setenv("HARO_USER_CONFIG", str(user_cfg))

    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text('[agent]\ndefault_model = "sonnet"\n')
    (syn / "settings.local.toml").write_text('[agent]\ndefault_model = "haiku"\n')
    assert load_project_settings(str(tmp_path)).default_model == "haiku"


def test_missing_user_global_is_harmless(tmp_path, monkeypatch):
    # Pointing at a non-existent user-global file yields the built-in defaults.
    monkeypatch.setenv("HARO_USER_CONFIG", str(tmp_path / "nope" / "settings.toml"))
    ps = load_project_settings(str(tmp_path))
    assert ps.default_model == "sonnet"
    assert ps.default_effort == ""


# --- multiple run scripts ([scripts.run.<id>] tables) ------------------------


def test_legacy_single_run_string_collapses_to_one_default_run(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text('[scripts]\nrun = "npm run dev"\n')
    ps = load_project_settings(str(tmp_path))
    assert ps.run == "npm run dev"  # back-compat: `.run` is the default command
    assert len(ps.runs) == 1
    only = ps.runs[0]
    assert (only.id, only.command, only.default) == ("app", "npm run dev", True)


def test_multiple_run_tables_parse_in_order_with_default_and_icon(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text(
        "[scripts.run.web]\n"
        'command = "npm run dev"\n'
        "default = true\n"
        "[scripts.run.worker]\n"
        'command = "npm run worker"\n'
        'icon = "gear"\n'
    )
    ps = load_project_settings(str(tmp_path))
    assert [r.id for r in ps.runs] == ["web", "worker"]  # insertion order preserved
    assert ps.run == "npm run dev"  # the default run's command
    web, worker = ps.runs
    assert (web.default, web.icon) == (True, None)
    assert (worker.default, worker.command, worker.icon) == (False, "npm run worker", "gear")


def test_run_tables_without_explicit_default_pick_the_first(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    # sub-values may be bare command strings, not just tables
    (syn / "settings.toml").write_text(
        "[scripts.run]\n" 'a = "cmd-a"\n' 'b = "cmd-b"\n'
    )
    ps = load_project_settings(str(tmp_path))
    assert [(r.id, r.default) for r in ps.runs] == [("a", True), ("b", False)]
    assert ps.run == "cmd-a"


def test_no_run_configured_yields_no_runs(tmp_path):
    ps = load_project_settings(str(tmp_path))
    assert ps.runs == []
    assert ps.run is None


def test_editor_nvim_defaults_to_auto(tmp_path):
    # No [editor] table → the safe, respectful default.
    assert load_project_settings(str(tmp_path)).nvim_mode == "auto"


def test_editor_nvim_parses_valid_modes(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text('[editor]\nnvim = "bundled"\n')
    assert load_project_settings(str(tmp_path)).nvim_mode == "bundled"


def test_editor_nvim_unknown_mode_falls_back_to_auto(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text('[editor]\nnvim = "emacs"\n')
    assert load_project_settings(str(tmp_path)).nvim_mode == "auto"


# --- [trust] autonomy ladder policy (Bet 9) ----------------------------------


def test_trust_defaults_off_and_conservative(tmp_path):
    # No [trust] table → the ladder is disarmed and every condition is required.
    ps = load_project_settings(str(tmp_path))
    assert ps.trust_enabled is False
    assert ps.trust_streak_required == 3
    assert ps.trust_auto_action == "off"
    assert ps.trust_require == {c: True for c in TRUST_CONDITIONS}


def test_trust_table_parses(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text(
        "[trust]\n"
        "enabled = true\n"
        "streak_required = 5\n"
        'auto_action = "auto_pr"\n'
    )
    ps = load_project_settings(str(tmp_path))
    assert ps.trust_enabled is True
    assert ps.trust_streak_required == 5
    assert ps.trust_auto_action == "auto_pr"


def test_trust_auto_action_junk_falls_back_to_off(tmp_path):
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text('[trust]\nauto_action = "yolo"\n')
    assert load_project_settings(str(tmp_path)).trust_auto_action == "off"


def test_trust_streak_clamps_below_one(tmp_path):
    # A 0/negative streak would auto-unlock instantly — clamp up to 1.
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text("[trust]\nstreak_required = 0\n")
    assert load_project_settings(str(tmp_path)).trust_streak_required == 1


def test_trust_require_flags_drop_a_condition(tmp_path):
    # An explicit `require_<key> = false` drops that condition; the rest stay required.
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text(
        "[trust]\nrequire_coverage = false\nrequire_no_tamper = false\n"
    )
    req = load_project_settings(str(tmp_path)).trust_require
    assert req["coverage"] is False
    assert req["no_tamper"] is False
    assert req["merge_result"] is True  # untouched → still required
    assert set(req) == set(TRUST_CONDITIONS)


def test_trust_local_can_tighten_over_committed(tmp_path):
    # The policy is team law; a `.local` override merges key-by-key (here it re-requires
    # a condition the committed file relaxed, and arms an action).
    syn = tmp_path / ".haro"
    syn.mkdir()
    (syn / "settings.toml").write_text(
        '[trust]\nauto_action = "off"\nrequire_no_flaky = false\n'
    )
    (syn / "settings.local.toml").write_text(
        '[trust]\nauto_action = "auto_pr"\nrequire_no_flaky = true\n'
    )
    ps = load_project_settings(str(tmp_path))
    assert ps.trust_auto_action == "auto_pr"
    assert ps.trust_require["no_flaky"] is True


def _trust(tmp_path, **overrides):
    """write_project_trust with all-default args, override only what a test cares about."""
    defaults = dict(
        enabled=False,
        streak_required=3,
        auto_action="off",
        require={c: True for c in TRUST_CONDITIONS},
        target="shared",
    )
    defaults.update(overrides)
    return write_project_trust(str(tmp_path), **defaults)


def test_write_project_trust_roundtrips(tmp_path):
    _trust(
        tmp_path,
        enabled=True,
        streak_required=5,
        auto_action="auto_pr",
        require={**{c: True for c in TRUST_CONDITIONS}, "no_tamper": False},
    )
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert "[trust]" in text
    ps = load_project_settings(str(tmp_path))
    assert ps.trust_enabled is True
    assert ps.trust_streak_required == 5
    assert ps.trust_auto_action == "auto_pr"
    assert ps.trust_require["no_tamper"] is False
    assert ps.trust_require["coverage"] is True


def test_write_project_trust_defaults_emit_no_keys(tmp_path):
    # An all-default trust policy (ladder off, every condition required) must write
    # nothing under [trust] — the disarmed ladder is the load-time default anyway.
    _trust(tmp_path)
    text = (tmp_path / ".haro" / "settings.toml").read_text() if (
        tmp_path / ".haro" / "settings.toml"
    ).exists() else ""
    assert "enabled =" not in text
    assert "require_" not in text
    ps = load_project_settings(str(tmp_path))
    assert ps.trust_enabled is False


def test_write_project_trust_normalizes_junk(tmp_path):
    # Junk auto_action and a sub-1 streak land where a hand-edited file would (via _parse_trust).
    _trust(tmp_path, enabled=True, streak_required=0, auto_action="yolo")
    ps = load_project_settings(str(tmp_path))
    assert ps.trust_auto_action == "off"
    assert ps.trust_streak_required == 1


def test_write_project_trust_updates_in_place(tmp_path):
    _trust(tmp_path, streak_required=4)
    _trust(tmp_path, streak_required=6)
    text = (tmp_path / ".haro" / "settings.toml").read_text()
    assert text.count("streak_required =") == 1
    assert load_project_settings(str(tmp_path)).trust_streak_required == 6


def test_write_project_trust_back_to_default_clears_key(tmp_path):
    _trust(tmp_path, enabled=True, streak_required=5)
    _trust(tmp_path)  # back to all-defaults
    text = (tmp_path / ".haro" / "settings.toml").read_text() if (
        tmp_path / ".haro" / "settings.toml"
    ).exists() else ""
    assert "streak_required =" not in text
    assert "enabled =" not in text


def test_write_project_trust_local_writes_only_delta_over_committed(tmp_path):
    # Committed team policy relaxes a condition and disarms the action. A personal
    # `.local` tightening (re-require the condition, arm auto_pr) must write ONLY those
    # two keys — the untouched ones inherit team law rather than being pinned.
    _trust(
        tmp_path,
        enabled=True,
        streak_required=5,
        auto_action="off",
        require={**{c: True for c in TRUST_CONDITIONS}, "no_flaky": False},
        target="shared",
    )
    _trust(
        tmp_path,
        enabled=True,  # matches committed → inherited, not re-pinned
        streak_required=5,  # matches committed → inherited, not re-pinned
        auto_action="auto_pr",
        require={**{c: True for c in TRUST_CONDITIONS}, "no_flaky": True},
        target="local",
    )
    local = (tmp_path / ".haro" / "settings.local.toml").read_text()
    assert 'auto_action = "auto_pr"' in local
    assert "require_no_flaky = true" in local
    # enabled/streak_required match committed → inherited, absent from the .local delta.
    assert "streak_required" not in local
    assert "enabled" not in local
    ps = load_project_settings(str(tmp_path))
    assert ps.trust_auto_action == "auto_pr"
    assert ps.trust_require["no_flaky"] is True
    assert ps.trust_streak_required == 5  # still the committed team value


def test_write_project_trust_preserves_other_tables(tmp_path):
    write_project_scripts(
        str(tmp_path),
        setup="npm ci",
        run="npm run dev",
        archive=None,
        run_mode="concurrent",
        login_shell=False,
        port_range=(4100, 4200),
        target="shared",
    )
    write_project_merge_mode(str(tmp_path), "merge", target="shared")
    _trust(tmp_path, enabled=True, auto_action="auto_pr")
    ps = load_project_settings(str(tmp_path))
    assert ps.setup == "npm ci"
    assert ps.port_range == (4100, 4200)
    assert ps.merge_mode == "merge"
    assert ps.trust_enabled is True
    assert ps.trust_auto_action == "auto_pr"


def test_write_project_trust_local_target_is_gitignored(tmp_path):
    _trust(tmp_path, enabled=True, target="local")
    assert (tmp_path / ".haro" / "settings.local.toml").exists()
    assert "settings.local.toml" in (tmp_path / ".haro" / ".gitignore").read_text()
