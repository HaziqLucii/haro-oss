import { useEffect, useState, type ReactNode } from "react";
import type { AgentConfig, EnvConfig, GateConfig, Project, RolesConfig, WorkflowConfig } from "../types";
import { api } from "../api";
import { GitBranch, Gear, Check, Star, Key, Pencil, Sliders, X } from "./icons";
import { ProjectRemote } from "./ProjectRemote";
import { ProjectInstructions } from "./ProjectInstructions";
import { RunbookPanel } from "./RunbookPanel";

export type ProjectSettingsTab =
  | "git"
  | "setup"
  | "gate"
  | "agent"
  | "roles"
  | "environment"
  | "instructions";
type Tab = ProjectSettingsTab;

const TABS: { id: Tab; label: string; icon: ReactNode }[] = [
  { id: "git", label: "Git", icon: <GitBranch /> },
  { id: "setup", label: "Setup", icon: <Gear /> },
  { id: "gate", label: "Gate", icon: <Check /> },
  { id: "agent", label: "Agent", icon: <Star /> },
  { id: "roles", label: "Roles", icon: <Sliders /> },
  { id: "environment", label: "Environment", icon: <Key /> },
  { id: "instructions", label: "Instructions", icon: <Pencil /> },
];

const MODELS: { value: AgentConfig["default_model"]; label: string; hint: string }[] = [
  { value: "sonnet", label: "Sonnet", hint: "The cheaper default, right for most work." },
  { value: "opus", label: "Opus", hint: "Most capable; ~5× the per-token cost. Save it for hard tasks." },
  { value: "haiku", label: "Haiku", hint: "Fastest and cheapest: light/mechanical work." },
  { value: "fable", label: "Fable", hint: "Fable 5." },
];

const EFFORTS: { value: AgentConfig["default_effort"]; label: string }[] = [
  { value: "", label: "default (~medium)" },
  { value: "low", label: "low" },
  { value: "medium", label: "medium" },
  { value: "high", label: "high" },
  { value: "xhigh", label: "xhigh" },
  { value: "max", label: "max" },
];

const RUNNERS: { value: GateConfig["runner"]; label: string; hint: string }[] = [
  { value: "vitest", label: "Vitest", hint: "JS/TS test suite: the default, with the live grid." },
  { value: "pytest", label: "pytest", hint: "Python test suite (JUnit-XML)." },
  { value: "command", label: "Command", hint: "Any shell command: exit 0 is green, non-zero is red." },
  { value: "offense", label: "Offense (JSON)", hint: "A linter emitting JSON offenses → the live grid." },
];

const SCOPES: { value: GateConfig["default_scope"]; label: string; hint: string }[] = [
  { value: "all", label: "All tests", hint: "Full suite on every auto-gate, always trustworthy." },
  { value: "impacted", label: "Impacted only", hint: "Only tests the diff affects, faster; run full before ship." },
];

const COVERAGE: { value: GateConfig["coverage_guard"]; label: string; hint: string }[] = [
  { value: "off", label: "Off", hint: "Don't measure coverage on the green path." },
  { value: "warn", label: "Warn", hint: "Note a coverage drop, but stay green." },
  { value: "block", label: "Block", hint: "A coverage drop turns the gate red." },
];

const TAMPER: { value: GateConfig["tamper_alarm"]; label: string; hint: string }[] = [
  { value: "warn", label: "Warn", hint: "Flag a weakened suite as green*, but stay green (default)." },
  { value: "block", label: "Block", hint: "A tampered suite (removed/skipped tests) turns the gate red." },
  { value: "off", label: "Off", hint: "Don't check the suite for tampering." },
];

const FORMATS: { value: string; label: string }[] = [
  { value: "theme-check", label: "shopify theme check" },
  { value: "eslint", label: "eslint -f json" },
  { value: "ruff", label: "ruff --output-format json" },
];

const MERGE_MODES: { value: WorkflowConfig["merge_mode"]; label: string; hint: string }[] = [
  { value: "both", label: "PR + Merge", hint: "Offer both: open a PR or merge locally." },
  { value: "pr", label: "PR only", hint: "Hide Merge: everything ships through a PR." },
  { value: "merge", label: "Merge only", hint: "Skip the PR ceremony, merge directly." },
];

/** Per-project settings surface — a left tab-rail + content pane, opened from the
 *  gear on each project row in the sidebar. Project-level config the project's
 *  workspaces inherit (distinct from the app-wide Settings in the sidebar foot).
 *  Git tab: the base branch new worktrees fork from, the `origin` remote/host, and
 *  the ship policy (`[workflow] merge_mode`). Setup tab: the project's `[scripts]`
 *  (setup/dev commands) + custom instructions, project-level so every workspace
 *  inherits them. Gate tab: the test runner + command, gate dir, auto-gate scope,
 *  merge-result gating, and the flaky/coverage guards — where a stack preset's choice
 *  lands and a dev overrides it. Agent tab: the `[agent]` cost/model guardrails (default
 *  model + reasoning effort, per-run budget ceiling, cost warning). Roles tab: the
 *  `[roles]` plan→scout→build→refute loop config (notes/workflow-roles-plan.md) — each
 *  step's own model/effort, so approving a plan can't silently build at the plan's model.
 *  Environment tab: the worktree `.env` seed (`.haro/.env`, gitignored) new workspaces
 *  are seeded with.
 *  Instructions tab: the Tier-1 standing prompt every run inherits — so all project config
 *  lives behind the one ⚙. */
export function ProjectSettingsModal({
  project,
  theme,
  initialTab,
  onRemoteChanged,
  onDefaultBranchChanged,
  onAgentChanged,
  onRolesChanged,
  onClose,
}: {
  project: Project;
  theme: string;
  initialTab?: Tab;
  onRemoteChanged: (url: string | null) => void;
  onDefaultBranchChanged: (branch: string) => void;
  onAgentChanged: (cfg: AgentConfig) => void;
  onRolesChanged: (cfg: RolesConfig) => void;
  onClose: () => void;
}) {
  const [tab, setTab] = useState<Tab>(initialTab ?? "git");

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="settings-scrim" onMouseDown={onClose}>
      <div
        className="settings-modal"
        role="dialog"
        aria-label={`${project.name} settings`}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <nav className="settings-rail">
          <div className="settings-rail-head" title={project.name}>
            {project.name}
          </div>
          {TABS.map((t) => (
            <button
              key={t.id}
              className={"settings-tab" + (tab === t.id ? " settings-tab-on" : "")}
              onClick={() => setTab(t.id)}
            >
              <span className="settings-tab-icon">{t.icon}</span>
              {t.label}
            </button>
          ))}
        </nav>

        <div className="settings-pane">
          <button className="ghost btn-icon settings-close" onClick={onClose} title="close (Esc)">
            <X />
          </button>

          {tab === "git" && (
            <div className="settings-section">
              <BaseBranch project={project} onChanged={onDefaultBranchChanged} />

              <section className="settings-section">
                <h3 className="settings-h">Git remote</h3>
                <p className="settings-sub dim">
                  The <code>origin</code> remote lives in the repo's shared <code>.git</code>, so
                  every workspace pushes and opens PRs through it. Without one, merges stay local.
                </p>
                <ProjectRemote
                  projectId={project.id}
                  url={project.remote_url ?? null}
                  onChanged={onRemoteChanged}
                />
              </section>

              <MergeMode projectId={project.id} />
            </div>
          )}

          {tab === "setup" && (
            <div className="settings-section">
              <h3 className="settings-h">Setup</h3>
              <p className="settings-sub dim">
                The <code>setup</code> / <code>dev</code> commands and standing instructions
                every workspace in this project inherits. Save personal (<code>.local</code>) or
                promote to the team's committed <code>.haro/</code> config.
              </p>
              <RunbookPanel projectId={project.id} theme={theme} />
            </div>
          )}

          {tab === "gate" && <GateSettings projectId={project.id} />}

          {tab === "agent" && (
            <AgentSettings projectId={project.id} onSaved={onAgentChanged} />
          )}

          {tab === "roles" && (
            <RolesSettings projectId={project.id} onSaved={onRolesChanged} />
          )}

          {tab === "environment" && <EnvSettings projectId={project.id} />}

          {tab === "instructions" && (
            <div className="settings-section">
              <h3 className="settings-h">Custom instructions</h3>
              <p className="settings-sub dim">
                A standing prompt every agent run in this project inherits via Claude Code's{" "}
                <code>--append-system-prompt</code>. Team + personal both apply (team first).
              </p>
              <ProjectInstructions projectId={project.id} theme={theme} />
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

/** The base branch a new worktree forks from. `create_workspace` seeds each new
 *  workspace off the project's default branch (as `origin/<default>` when a remote
 *  is linked), so this picks the fork point for every future workspace. */
function BaseBranch({
  project,
  onChanged,
}: {
  project: Project;
  onChanged: (branch: string) => void;
}) {
  const [branches, setBranches] = useState<string[]>([]);
  const [value, setValue] = useState<string>("");
  const [loading, setLoading] = useState(true);
  const [note, setNote] = useState<string | null>(null);
  const [err, setErr] = useState(false);

  useEffect(() => {
    let live = true;
    setLoading(true);
    api
      .listBranches(project.id)
      .then((r) => {
        if (!live) return;
        setBranches(r.branches);
        setValue(r.default);
      })
      .catch(() => live && setErr(true))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [project.id]);

  const pick = async (next: string) => {
    const prev = value;
    setValue(next);
    setNote(null);
    setErr(false);
    try {
      const p = await api.setDefaultBranch(project.id, next);
      onChanged(p.default_branch);
      setNote(`new workspaces branch from ${next}`);
    } catch (e) {
      setValue(prev);
      setErr(true);
      setNote(e instanceof Error ? e.message : "couldn't set base branch");
    }
  };

  return (
    <section className="settings-section">
      <h3 className="settings-h">Base branch</h3>
      <p className="settings-sub dim">
        The branch each new workspace forks from. When a remote is linked, workspaces
        branch off the integrated <code>origin/</code> tip.
      </p>
      <div className="settings-row">
        <span className="settings-k">Branch</span>
        {loading ? (
          <span className="dim settings-note">loading branches…</span>
        ) : branches.length ? (
          <select
            className="settings-select"
            value={value}
            onChange={(e) => pick(e.target.value)}
          >
            {branches.map((b) => (
              <option key={b} value={b}>
                {b}
              </option>
            ))}
          </select>
        ) : (
          <span className="dim settings-note">no branches found</span>
        )}
        {note && (
          <span className={(err ? "settings-err " : "dim ") + "settings-note"}>{note}</span>
        )}
      </div>
    </section>
  );
}

/** Serialize the current gate config to the `[gate]` block it produces on disk, so
 *  the dev can inspect exactly what gets written (mirrors `config.write_project_gate`;
 *  the flaky/coverage guards land under `[workflow]` and aren't part of this block). */
function previewGateToml(cfg: GateConfig): string {
  const q = (s: string) => `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
  const lines: string[] = [];
  if (cfg.runner && cfg.runner !== "vitest") lines.push(`runner = ${q(cfg.runner)}`);
  if (cfg.command.trim() && (cfg.runner === "command" || cfg.runner === "offense"))
    lines.push(`command = ${q(cfg.command.trim())}`);
  if (cfg.format.trim() && cfg.runner === "offense") lines.push(`format = ${q(cfg.format.trim())}`);
  const dir = cfg.gate_dir.replace(/^\/+|\/+$/g, "");
  if (dir) lines.push(`dir = ${q(dir)}`);
  if (cfg.default_scope === "impacted") lines.push(`default_scope = "impacted"`);
  if (cfg.merge_result) lines.push(`merge_result = true`);
  if (cfg.watch) lines.push(`watch = true`);
  return lines.length ? `[gate]\n${lines.join("\n")}` : "# [gate] · defaults (vitest, full suite)";
}

/** The Gate tab: pick the test runner + command, gate dir, auto-gate scope,
 *  merge-result gating, and the flaky/coverage guards. Where the §2 stack preset's
 *  choice lands and a dev overrides it; surfaces the generated `[gate]` block. */
function GateSettings({ projectId }: { projectId: string }) {
  const [cfg, setCfg] = useState<GateConfig | null>(null);
  const [scope, setScope] = useState<"local" | "shared">("shared");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [err, setErr] = useState(false);

  useEffect(() => {
    let live = true;
    api
      .getGate(projectId)
      .then((g) => live && setCfg(g))
      .catch(() => live && setErr(true));
    return () => {
      live = false;
    };
  }, [projectId]);

  if (!cfg) {
    return (
      <div className="settings-section">
        <h3 className="settings-h">Gate</h3>
        <span className={(err ? "settings-err " : "dim ") + "settings-note"}>
          {err ? "couldn't load gate config" : "loading…"}
        </span>
      </div>
    );
  }

  const set = <K extends keyof GateConfig>(k: K, v: GateConfig[K]) =>
    setCfg({ ...cfg, [k]: v });
  const isCommand = cfg.runner === "command" || cfg.runner === "offense";

  const save = async () => {
    setBusy(true);
    setNote(null);
    setErr(false);
    try {
      const g = await api.setGate(projectId, cfg, scope);
      setCfg(g);
      setNote(
        scope === "shared"
          ? "saved to settings.toml (team)"
          : "saved to settings.local.toml (personal)"
      );
    } catch (e) {
      setErr(true);
      setNote(e instanceof Error ? e.message : "save failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="settings-section">
      <h3 className="settings-h">Gate</h3>
      <p className="settings-sub dim">
        The project's definition of "correct": the runner the auto-gate runs and what
        can block a green gate. Every workspace inherits it; a workspace can't merge
        until this gate is green.
      </p>

      <div className="settings-row">
        <span className="settings-k">Runner</span>
        <select
          className="settings-select"
          value={cfg.runner}
          onChange={(e) => set("runner", e.target.value as GateConfig["runner"])}
        >
          {RUNNERS.map((r) => (
            <option key={r.value} value={r.value}>
              {r.label}
            </option>
          ))}
        </select>
        <span className="dim settings-note">{RUNNERS.find((r) => r.value === cfg.runner)?.hint}</span>
      </div>

      {isCommand && (
        <div className="settings-row">
          <span className="settings-k">Command</span>
          <input
            className="settings-select"
            value={cfg.command}
            placeholder="shopify theme check"
            onChange={(e) => set("command", e.target.value)}
          />
        </div>
      )}

      {cfg.runner === "offense" && (
        <div className="settings-row">
          <span className="settings-k">Format</span>
          <select
            className="settings-select"
            value={cfg.format || "theme-check"}
            onChange={(e) => set("format", e.target.value)}
          >
            {FORMATS.map((f) => (
              <option key={f.value} value={f.value}>
                {f.label}
              </option>
            ))}
          </select>
          <span className="dim settings-note">the JSON offense format the command emits</span>
        </div>
      )}

      <div className="settings-row">
        <span className="settings-k">Gate dir</span>
        <input
          className="settings-select"
          value={cfg.gate_dir}
          placeholder="(repo root)"
          onChange={(e) => set("gate_dir", e.target.value)}
        />
        <span className="dim settings-note">subdir to run the gate in (monorepo, e.g. frontend)</span>
      </div>

      <div className="settings-row">
        <span className="settings-k">Auto-gate scope</span>
        <select
          className="settings-select"
          value={cfg.default_scope}
          onChange={(e) => set("default_scope", e.target.value as GateConfig["default_scope"])}
        >
          {SCOPES.map((s) => (
            <option key={s.value} value={s.value}>
              {s.label}
            </option>
          ))}
        </select>
        <span className="dim settings-note">
          {SCOPES.find((s) => s.value === cfg.default_scope)?.hint}
        </span>
      </div>

      <div className="settings-row">
        <span className="settings-k">Merge result</span>
        <label className="settings-check">
          <input
            type="checkbox"
            className="switch"
            checked={cfg.merge_result}
            onChange={(e) => set("merge_result", e.target.checked)}
          />
          gate the worktree merged onto the latest base branch
        </label>
      </div>

      <div className="settings-row">
        <span className="settings-k">Flaky guard</span>
        <label className="settings-check">
          <input
            type="checkbox"
            className="switch"
            checked={cfg.flaky_rerun}
            onChange={(e) => set("flaky_rerun", e.target.checked)}
          />
          re-run once on red; a pass-on-retry doesn't block green
        </label>
      </div>

      <div className="settings-row">
        <span className="settings-k">Coverage guard</span>
        <select
          className="settings-select"
          value={cfg.coverage_guard}
          onChange={(e) => set("coverage_guard", e.target.value as GateConfig["coverage_guard"])}
        >
          {COVERAGE.map((c) => (
            <option key={c.value} value={c.value}>
              {c.label}
            </option>
          ))}
        </select>
        <span className="dim settings-note">
          {COVERAGE.find((c) => c.value === cfg.coverage_guard)?.hint}
        </span>
      </div>

      {cfg.coverage_guard !== "off" && (
        <div className="settings-row">
          <span className="settings-k">Tolerance</span>
          <input
            className="settings-select"
            type="number"
            min={0}
            step={0.5}
            value={cfg.coverage_tolerance}
            onChange={(e) => set("coverage_tolerance", Math.abs(Number(e.target.value) || 0))}
          />
          <span className="dim settings-note">allowed drop before tripping (percentage points)</span>
        </div>
      )}

      {/* Live Gate (backlog/live-gate.md). Off by default — it's the one gate knob that
          costs CPU continuously, so it's a comfort choice, not a policy one. Framed as
          advisory on purpose: it cannot make anything mergeable. */}
      {/* Code to check (backlog/code-to-check.md): the diff-level signal. On by default,
          because unlike the live gate it costs one coverage run on an already-green gate
          rather than CPU on every save, and it is advisory either way. */}
      <div className="settings-row">
        <span className="settings-k">Code to check</span>
        <label className="settings-check">
          <input
            type="checkbox"
            className="switch"
            checked={cfg.code_to_check !== "off"}
            onChange={(e) => set("code_to_check", e.target.checked ? "warn" : "off")}
          />
          list what nothing checked in the diff (advisory, never blocks a merge)
        </label>
        <span className="dim settings-note">
          A green gate says the tests passed, not that they covered what changed. This lists
          added lines no test ran, files no test imports, and the facts a test cannot vouch
          for: a dependency change, a touched secret, a deletion, a migration.
        </span>
      </div>

      {/* Verified Hunks (backlog/verified-hunks.md). On by default: it's evidence, never
          a verdict (it can't block a merge), and it reuses the coverage map "code to
          check" already measures on a green gate, so there's nothing extra to opt into.
          Copy says "executed", never "verified": a line that ran is not a line an
          assertion checked. */}
      <div className="settings-row">
        <span className="settings-k">Per-line proof</span>
        <label className="settings-check">
          <input
            type="checkbox"
            className="switch"
            checked={cfg.verified_hunks}
            onChange={(e) => set("verified_hunks", e.target.checked)}
          />
          badge the ship diff with which added lines the green suite executed
        </label>
        <span className="dim settings-note">
          Sorts the files the suite never executed to the top of the ④ ship diff and collapses
          the fully-executed ones, so a big agent diff shrinks to the part nothing ran. Needs
          the vitest runner and a coverage provider; adds no extra test run.
        </span>
      </div>

      <div className="settings-row">
        <span className="settings-k">Live gate</span>
        <label className="settings-check">
          <input
            type="checkbox"
            className="switch"
            checked={cfg.watch}
            onChange={(e) => set("watch", e.target.checked)}
          />
          re-run impacted tests as you save (advisory, never a merge verdict)
        </label>
        <span className="dim settings-note">
          Keeps a live verdict in the side rail while you edit. The ③ gate’s full-scope run
          stays the only thing that can ship.
        </span>
      </div>

      <div className="settings-row">
        <span className="settings-k">Tamper alarm</span>
        <select
          className="settings-select"
          value={cfg.tamper_alarm}
          onChange={(e) => set("tamper_alarm", e.target.value as GateConfig["tamper_alarm"])}
        >
          {TAMPER.map((t) => (
            <option key={t.value} value={t.value}>
              {t.label}
            </option>
          ))}
        </select>
        <span className="dim settings-note">
          {TAMPER.find((t) => t.value === cfg.tamper_alarm)?.hint}
        </span>
      </div>

      <section className="settings-section">
        <h3 className="settings-h">Generated config</h3>
        <pre className="settings-toml">{previewGateToml(cfg)}</pre>
      </section>

      <div className="settings-row">
        <span className="settings-k">Scope</span>
        <div className="rb-scope">
          <button
            className={"chip" + (scope === "local" ? " chip-on" : "")}
            onClick={() => setScope("local")}
            title="personal · settings.local.toml (gitignored)"
          >
            personal
          </button>
          <button
            className={"chip" + (scope === "shared" ? " chip-on" : "")}
            onClick={() => setScope("shared")}
            title="team · settings.toml (committed)"
          >
            team
          </button>
        </div>
      </div>
      <div className="settings-actions">
        {note && <span className={(err ? "settings-err " : "dim ") + "settings-note"}>{note}</span>}
        <button className="primary" onClick={save} disabled={busy}>
          save {scope}
        </button>
      </div>
    </div>
  );
}

/** Serialize the current agent config to the `[agent]` block it produces on disk
 *  (mirrors `config.write_project_agent` — defaults omitted so the block stays minimal). */
function previewAgentToml(cfg: AgentConfig): string {
  const q = (s: string) => `"${s}"`;
  const lines: string[] = [];
  // Both backends persist independently now; `adapter` only marks the default backend.
  if (cfg.adapter === "local") lines.push(`adapter = ${q("local")}`);
  if (cfg.local_base_url && cfg.local_base_url !== "http://localhost:11434/v1")
    lines.push(`local_base_url = ${q(cfg.local_base_url)}`);
  if (cfg.local_model && cfg.local_model !== "qwen2.5-coder")
    lines.push(`local_model = ${q(cfg.local_model)}`);
  if (cfg.default_model && cfg.default_model !== "sonnet")
    lines.push(`default_model = ${q(cfg.default_model)}`);
  if (cfg.default_effort) lines.push(`default_effort = ${q(cfg.default_effort)}`);
  if (cfg.max_budget_usd !== 5.0) lines.push(`max_budget_usd = ${cfg.max_budget_usd}`);
  if (cfg.cost_warn_usd !== 20.0) lines.push(`cost_warn_usd = ${cfg.cost_warn_usd}`);
  if (cfg.max_parallel !== 4) lines.push(`max_parallel = ${cfg.max_parallel}`);
  return lines.length ? `[agent]\n${lines.join("\n")}` : "# [agent] · defaults (sonnet, $5 cap)";
}

/** The Agent tab: the project's `[agent]` cost/model guardrails — the default model +
 *  reasoning effort a run inherits when it doesn't pick its own (an explicit per-run pick
 *  still wins), the HARD per-run budget ceiling, and the SOFT cumulative cost warning.
 *  Every workspace in the project inherits these; surfaces the generated `[agent]` block. */
function AgentSettings({
  projectId,
  onSaved,
}: {
  projectId: string;
  onSaved: (cfg: AgentConfig) => void;
}) {
  const [cfg, setCfg] = useState<AgentConfig | null>(null);
  const [scope, setScope] = useState<"local" | "shared">("shared");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [err, setErr] = useState(false);

  useEffect(() => {
    let live = true;
    api
      .getAgent(projectId)
      .then((a) => live && setCfg(a))
      .catch(() => live && setErr(true));
    return () => {
      live = false;
    };
  }, [projectId]);

  if (!cfg) {
    return (
      <div className="settings-section">
        <h3 className="settings-h">Agent</h3>
        <span className={(err ? "settings-err " : "dim ") + "settings-note"}>
          {err ? "couldn't load agent config" : "loading…"}
        </span>
      </div>
    );
  }

  const set = <K extends keyof AgentConfig>(k: K, v: AgentConfig[K]) =>
    setCfg({ ...cfg, [k]: v });

  const save = async () => {
    setBusy(true);
    setNote(null);
    setErr(false);
    try {
      const a = await api.setAgent(projectId, cfg, scope);
      setCfg(a);
      onSaved(a); // let the composer re-seed its model/effort from the new default
      setNote(
        scope === "shared"
          ? "saved to settings.toml (team)"
          : "saved to settings.local.toml (personal)"
      );
    } catch (e) {
      setErr(true);
      setNote(e instanceof Error ? e.message : "save failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="settings-section">
      <h3 className="settings-h">Agent</h3>
      <p className="settings-sub dim">
        Cost and model guardrails every workspace inherits. A run that doesn't pick its own
        model/effort gets these defaults; an explicit per-run pick still wins.
      </p>

      <div className="settings-row">
        <span className="settings-k">Default backend</span>
        <select
          className="settings-select"
          value={cfg.adapter}
          onChange={(e) => set("adapter", e.target.value as AgentConfig["adapter"])}
        >
          <option value="claude-code">Claude Code (cloud)</option>
          <option value="local">Local model: Ollama · llama.cpp</option>
        </select>
        <span className="dim settings-note">
          which backend a new run pre-selects. A run can switch backend in the composer.
          Both backends' settings below always apply.
        </span>
      </div>

      <section className="settings-section">
        <h3 className="settings-h">Claude Code</h3>
        <div className="settings-row">
          <span className="settings-k">Default model</span>
          <select
            className="settings-select"
            value={cfg.default_model}
            onChange={(e) => set("default_model", e.target.value as AgentConfig["default_model"])}
          >
            {MODELS.map((m) => (
              <option key={m.value} value={m.value}>
                {m.label}
              </option>
            ))}
          </select>
          <span className="dim settings-note">
            {MODELS.find((m) => m.value === cfg.default_model)?.hint}
          </span>
        </div>

        <div className="settings-row">
          <span className="settings-k">Default effort</span>
          <select
            className="settings-select"
            value={cfg.default_effort}
            onChange={(e) => set("default_effort", e.target.value as AgentConfig["default_effort"])}
          >
            {EFFORTS.map((ef) => (
              <option key={ef.value || "default"} value={ef.value}>
                {ef.label}
              </option>
            ))}
          </select>
          <span className="dim settings-note">reasoning-effort budget: higher burns more thinking tokens</span>
        </div>

        <div className="settings-row">
          <span className="settings-k">Max budget</span>
          <input
            className="settings-select"
            type="number"
            min={0}
            step={1}
            value={cfg.max_budget_usd}
            onChange={(e) => set("max_budget_usd", Math.abs(Number(e.target.value) || 0))}
          />
          <span className="dim settings-note">hard per-run USD ceiling: a run stops when it crosses this (0 = uncapped)</span>
        </div>

        <div className="settings-row">
          <span className="settings-k">Cost warning</span>
          <input
            className="settings-select"
            type="number"
            min={0}
            step={1}
            value={cfg.cost_warn_usd}
            onChange={(e) => set("cost_warn_usd", Math.abs(Number(e.target.value) || 0))}
          />
          <span className="dim settings-note">soft heads-up on a workspace's cumulative spend (0 = off)</span>
        </div>

        <div className="settings-row">
          <span className="settings-k">Max parallel</span>
          <input
            className="settings-select"
            type="number"
            min={0}
            step={1}
            value={cfg.max_parallel}
            onChange={(e) => set("max_parallel", Math.abs(Math.trunc(Number(e.target.value) || 0)))}
          />
          <span className="dim settings-note">
            how many agents may run at once across every workspace; the rest wait as queued (0 = unlimited)
          </span>
        </div>
      </section>

      <section className="settings-section">
        <h3 className="settings-h">Local model (Ollama · llama.cpp)</h3>
        <div className="settings-row">
          <span className="settings-k">Server URL</span>
          <input
            className="settings-select"
            type="text"
            placeholder="http://localhost:11434/v1"
            value={cfg.local_base_url}
            onChange={(e) => set("local_base_url", e.target.value)}
          />
          <span className="dim settings-note">
            OpenAI-compatible endpoint: Ollama :11434/v1, llama.cpp :8080/v1. In Docker use
            host.docker.internal; keep this in personal (.local) if devices differ.
          </span>
        </div>

        <div className="settings-row">
          <span className="settings-k">Default model</span>
          <input
            className="settings-select"
            type="text"
            placeholder="qwen2.5-coder"
            value={cfg.local_model}
            onChange={(e) => set("local_model", e.target.value)}
          />
          <span className="dim settings-note">
            fallback model tag when a run doesn't pick one. The composer lists what's installed.
            Must support tool calling.
          </span>
        </div>
      </section>

      <section className="settings-section">
        <h3 className="settings-h">Generated config</h3>
        <pre className="settings-toml">{previewAgentToml(cfg)}</pre>
      </section>

      <div className="settings-row">
        <span className="settings-k">Scope</span>
        <div className="rb-scope">
          <button
            className={"chip" + (scope === "local" ? " chip-on" : "")}
            onClick={() => setScope("local")}
            title="personal · settings.local.toml (gitignored)"
          >
            personal
          </button>
          <button
            className={"chip" + (scope === "shared" ? " chip-on" : "")}
            onClick={() => setScope("shared")}
            title="team · settings.toml (committed)"
          >
            team
          </button>
        </div>
      </div>
      <div className="settings-actions">
        {note && <span className={(err ? "settings-err " : "dim ") + "settings-note"}>{note}</span>}
        <button className="primary" onClick={save} disabled={busy}>
          save {scope}
        </button>
      </div>
    </div>
  );
}

function previewRolesToml(cfg: RolesConfig): string {
  const q = (s: string) => `"${s}"`;
  const lines: string[] = [];
  if (cfg.enabled) lines.push(`enabled = true`);
  if (cfg.plan) lines.push(`plan = ${q(cfg.plan)}`);
  if (cfg.build) lines.push(`build = ${q(cfg.build)}`);
  if (cfg.review) lines.push(`review = ${q(cfg.review)}`);
  if (cfg.scout) lines.push(`scout = ${q(cfg.scout)}`);
  if (cfg.review_enforce !== "off") lines.push(`review_enforce = ${q(cfg.review_enforce)}`);
  if (cfg.review_max_rounds !== 2) lines.push(`review_max_rounds = ${cfg.review_max_rounds}`);
  return lines.length ? `[roles]\n${lines.join("\n")}` : "# [roles] · off";
}

const ROLE_MODELS: { value: string; label: string }[] = [
  { value: "", label: "default (project's Agent tab)" },
  { value: "opus", label: "Opus" },
  { value: "sonnet", label: "Sonnet" },
  { value: "haiku", label: "Haiku" },
  { value: "fable", label: "Fable" },
];

// Haiku 4.5 only accepts low|medium|high (no xhigh/max) — see the plan's CLI facts.
// Scout is Haiku-only in Phase 2, so its effort options never need the wider set.
const ROLE_EFFORTS: { value: string; label: string }[] = [
  { value: "", label: "default" },
  { value: "low", label: "low" },
  { value: "medium", label: "medium" },
  { value: "high", label: "high" },
  { value: "xhigh", label: "xhigh" },
  { value: "max", label: "max" },
];

function splitRole(shorthand: string): { model: string; effort: string } {
  const [model, effort] = shorthand.split(":");
  return { model: model || "", effort: effort || "" };
}

function joinRole(model: string, effort: string): string {
  if (!model) return "";
  return effort ? `${model}:${effort}` : model;
}

/** One role's model + effort pickers, encoding/decoding the "model:effort" shorthand
 *  the backend stores. `hasEffort` hides the effort picker for scout, which the CLI
 *  never accepts a reasoning-effort flag for (Haiku-only, low|medium|high anyway). */
function RoleRow({
  label,
  hint,
  value,
  onChange,
  hasEffort = true,
}: {
  label: string;
  hint: string;
  value: string;
  onChange: (next: string) => void;
  hasEffort?: boolean;
}) {
  const { model, effort } = splitRole(value);
  return (
    <div className="settings-row">
      <span className="settings-k">{label}</span>
      <select
        className="settings-select"
        value={model}
        onChange={(e) => onChange(joinRole(e.target.value, effort))}
      >
        {ROLE_MODELS.map((m) => (
          <option key={m.value || "default"} value={m.value}>
            {m.label}
          </option>
        ))}
      </select>
      {hasEffort && (
        <select
          className="settings-select"
          value={effort}
          onChange={(e) => onChange(joinRole(model, e.target.value))}
          disabled={!model}
        >
          {ROLE_EFFORTS.map((ef) => (
            <option key={ef.value || "default"} value={ef.value}>
              {ef.label}
            </option>
          ))}
        </select>
      )}
      <span className="dim settings-note">{hint}</span>
    </div>
  );
}

/** The Review role row: on/off toggle + model/effort + max fix rounds, all inline —
 *  the refuter IS the review role, so there's no separate section for it. Toggling
 *  off writes review_enforce="off"; on writes "warn" ("block" was cut 2026-09-17,
 *  making this a true binary). */
function ReviewRoleRow({
  value,
  enforce,
  maxRounds,
  onValueChange,
  onEnforceChange,
  onMaxRoundsChange,
}: {
  value: string;
  enforce: RolesConfig["review_enforce"];
  maxRounds: number;
  onValueChange: (next: string) => void;
  onEnforceChange: (next: RolesConfig["review_enforce"]) => void;
  onMaxRoundsChange: (next: number) => void;
}) {
  const { model, effort } = splitRole(value);
  const on = enforce === "warn";
  return (
    <div className="settings-row">
      <span className="settings-k">Review</span>
      <button
        className={"chip" + (on ? " chip-on" : "")}
        onClick={() => onEnforceChange(on ? "off" : "warn")}
      >
        {on ? "on" : "off"}
      </button>
      <select
        className="settings-select"
        value={model}
        disabled={!on}
        onChange={(e) => onValueChange(joinRole(e.target.value, effort))}
      >
        {ROLE_MODELS.map((m) => (
          <option key={m.value || "default"} value={m.value}>
            {m.label}
          </option>
        ))}
      </select>
      <select
        className="settings-select"
        value={effort}
        disabled={!on || !model}
        onChange={(e) => onValueChange(joinRole(model, e.target.value))}
      >
        {ROLE_EFFORTS.map((ef) => (
          <option key={ef.value || "default"} value={ef.value}>
            {ef.label}
          </option>
        ))}
      </select>
      <input
        className="settings-select"
        type="number"
        min={0}
        max={10}
        step={1}
        disabled={!on}
        title="max fix rounds"
        value={maxRounds}
        onChange={(e) =>
          onMaxRoundsChange(Math.max(0, Math.min(10, Math.trunc(Number(e.target.value) || 0))))
        }
      />
      <span className="dim settings-note">
        {on
          ? "Re-checks a green gate's diff against the plan; a FAIL arms up to this many build fix rounds. Never blocks the gate."
          : "Never runs."}
      </span>
    </div>
  );
}

/** The Roles tab: the `[roles]` plan→scout→build→refute loop config
 *  (notes/workflow-roles-plan.md). Off by default — flipping it on replaces the
 *  composer's model/effort pickers with a role strip, so approving a plan resolves
 *  to the BUILD role's own model/effort instead of whatever the plan step happened
 *  to be running (the "forgot to flip two dropdowns" trap). Review is the refuter:
 *  its row's own on/off toggle (review_enforce) gates whether it ever runs. */
function RolesSettings({
  projectId,
  onSaved,
}: {
  projectId: string;
  onSaved: (cfg: RolesConfig) => void;
}) {
  const [cfg, setCfg] = useState<RolesConfig | null>(null);
  const [scope, setScope] = useState<"local" | "shared">("shared");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [err, setErr] = useState(false);

  useEffect(() => {
    let live = true;
    api
      .getRoles(projectId)
      .then((r) => live && setCfg(r))
      .catch(() => live && setErr(true));
    return () => {
      live = false;
    };
  }, [projectId]);

  if (!cfg) {
    return (
      <div className="settings-section">
        <h3 className="settings-h">Roles</h3>
        <span className={(err ? "settings-err " : "dim ") + "settings-note"}>
          {err ? "couldn't load roles config" : "loading…"}
        </span>
      </div>
    );
  }

  const set = <K extends keyof RolesConfig>(k: K, v: RolesConfig[K]) =>
    setCfg({ ...cfg, [k]: v });

  const save = async () => {
    setBusy(true);
    setNote(null);
    setErr(false);
    try {
      const r = await api.setRoles(projectId, cfg, scope);
      setCfg(r);
      onSaved(r); // let the composer re-seed its role strip / pickers
      setNote(
        scope === "shared"
          ? "saved to settings.toml (team)"
          : "saved to settings.local.toml (personal)"
      );
    } catch (e) {
      setErr(true);
      setNote(e instanceof Error ? e.message : "save failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="settings-section">
      <h3 className="settings-h">Roles</h3>
      <p className="settings-sub dim">
        Give each step of the plan → scout → build → refute workflow its own model
        and reasoning effort. When on, the composer shows this workflow instead of
        the plain model/effort pickers — that's what stops "approve a plan" from
        silently building at the (pricier) plan model.
      </p>

      <div className="settings-row">
        <span className="settings-k">Roles</span>
        <button
          className={"chip" + (cfg.enabled ? " chip-on" : "")}
          onClick={() => set("enabled", !cfg.enabled)}
        >
          {cfg.enabled ? "on" : "off"}
        </button>
        <span className="dim settings-note">
          off ⇒ today's behaviour, byte-identical: the composer's pickers, the plain
          `[agent]` default_model/default_effort fallback.
        </span>
      </div>

      <section className="settings-section">
        <h3 className="settings-h">haro. workflow</h3>
        <RoleRow
          label="Plan"
          hint="Plan Mode runs (the composer's 'plan first' toggle, or a plan sent explicitly)."
          value={cfg.plan}
          onChange={(v) => set("plan", v)}
        />
        <RoleRow
          label="Build"
          hint="Everything else, including 'approve plan → implement' — always THIS role's model, never the plan's."
          value={cfg.build}
          onChange={(v) => set("build", v)}
        />
        <ReviewRoleRow
          value={cfg.review}
          enforce={cfg.review_enforce}
          maxRounds={cfg.review_max_rounds}
          onValueChange={(v) => set("review", v)}
          onEnforceChange={(v) => set("review_enforce", v)}
          onMaxRoundsChange={(v) => set("review_max_rounds", v)}
        />
        <RoleRow
          label="Scout"
          hint="The read-only mapping sub-agent, injected into every plan/build run."
          value={cfg.scout}
          onChange={(v) => set("scout", v)}
          hasEffort={false}
        />
      </section>

      <section className="settings-section">
        <h3 className="settings-h">Generated config</h3>
        <pre className="settings-toml">{previewRolesToml(cfg)}</pre>
      </section>

      <div className="settings-row">
        <span className="settings-k">Scope</span>
        <div className="rb-scope">
          <button
            className={"chip" + (scope === "local" ? " chip-on" : "")}
            onClick={() => setScope("local")}
            title="personal · settings.local.toml (gitignored)"
          >
            personal
          </button>
          <button
            className={"chip" + (scope === "shared" ? " chip-on" : "")}
            onClick={() => setScope("shared")}
            title="team · settings.toml (committed)"
          >
            team
          </button>
        </div>
      </div>
      <div className="settings-actions">
        {note && <span className={(err ? "settings-err " : "dim ") + "settings-note"}>{note}</span>}
        <button className="primary" onClick={save} disabled={busy}>
          save {scope}
        </button>
      </div>
    </div>
  );
}

/** The Environment tab: the worktree `.env` seed. A worktree is a clean checkout,
 *  so a gitignored `.env` from the main repo never lands in it — this is the dotenv
 *  block every NEW workspace is seeded with, so setup/run/tests that read secrets
 *  work in a fresh worktree. Stored in `.haro/.env`, always gitignored (it holds
 *  secrets) — hence no team/personal split, unlike the other tabs. Existing workspaces
 *  are untouched; edit their `.env` in the workspace itself. */
function EnvSettings({ projectId }: { projectId: string }) {
  const [content, setContent] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [err, setErr] = useState(false);

  useEffect(() => {
    let live = true;
    api
      .getEnv(projectId)
      .then((e) => live && setContent(e.content))
      .catch(() => live && setErr(true));
    return () => {
      live = false;
    };
  }, [projectId]);

  const save = async () => {
    if (content === null) return;
    setBusy(true);
    setNote(null);
    setErr(false);
    try {
      const e: EnvConfig = await api.setEnv(projectId, content);
      setContent(e.content);
      setNote(e.content.trim() ? "saved to .haro/.env (gitignored)" : "seed cleared");
    } catch (ex) {
      setErr(true);
      setNote(ex instanceof Error ? ex.message : "save failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="settings-section">
      <h3 className="settings-h">Environment</h3>
      <p className="settings-sub dim">
        The <code>.env</code> every <strong>new</strong> workspace is seeded with. A worktree is a
        clean checkout, so a gitignored <code>.env</code> never carries over, paste your secrets
        here once and each new workspace starts with them. Stored in{" "}
        <code>.haro/.env</code> and always gitignored; never committed. Existing workspaces
        keep their own <code>.env</code>, edit those in the workspace.
      </p>

      {content === null ? (
        <span className={(err ? "settings-err " : "dim ") + "settings-note"}>
          {err ? "couldn't load environment" : "loading…"}
        </span>
      ) : (
        <>
          <textarea
            className="settings-env"
            value={content}
            spellCheck={false}
            placeholder={"API_KEY=…\nDATABASE_URL=…"}
            onChange={(e) => setContent(e.target.value)}
          />
          <div className="settings-actions">
            {note && (
              <span className={(err ? "settings-err " : "dim ") + "settings-note"}>{note}</span>
            )}
            <button className="primary" onClick={save} disabled={busy}>
              save
            </button>
          </div>
        </>
      )}
    </div>
  );
}

/** Which ④ ship actions the project offers (`[workflow] merge_mode`). A team policy,
 *  so it saves to the committed `settings.toml` by default; "personal" writes the
 *  gitignored `.local` override. */
function MergeMode({ projectId }: { projectId: string }) {
  const [mode, setMode] = useState<WorkflowConfig["merge_mode"]>("both");
  const [scope, setScope] = useState<"local" | "shared">("shared");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [err, setErr] = useState(false);

  useEffect(() => {
    let live = true;
    api
      .getWorkflow(projectId)
      .then((w) => live && setMode(w.merge_mode))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [projectId]);

  const save = async () => {
    setBusy(true);
    setNote(null);
    setErr(false);
    try {
      const w = await api.setWorkflow(projectId, mode, scope);
      setMode(w.merge_mode);
      setNote(scope === "shared" ? "saved to settings.toml (team)" : "saved to settings.local.toml (personal)");
    } catch (e) {
      setErr(true);
      setNote(e instanceof Error ? e.message : "save failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="settings-section">
      <h3 className="settings-h">Ship mode</h3>
      <p className="settings-sub dim">
        Which actions the ④ ship step offers. A repo with no remote always falls back to a
        local merge.
      </p>
      <div className="settings-row">
        <span className="settings-k">Mode</span>
        <select
          className="settings-select"
          value={mode}
          onChange={(e) => setMode(e.target.value as WorkflowConfig["merge_mode"])}
        >
          {MERGE_MODES.map((m) => (
            <option key={m.value} value={m.value}>
              {m.label}
            </option>
          ))}
        </select>
        <span className="dim settings-note">{MERGE_MODES.find((m) => m.value === mode)?.hint}</span>
      </div>
      <div className="settings-row">
        <span className="settings-k">Scope</span>
        <div className="rb-scope">
          <button
            className={"chip" + (scope === "local" ? " chip-on" : "")}
            onClick={() => setScope("local")}
            title="personal · settings.local.toml (gitignored)"
          >
            personal
          </button>
          <button
            className={"chip" + (scope === "shared" ? " chip-on" : "")}
            onClick={() => setScope("shared")}
            title="team · settings.toml (committed)"
          >
            team
          </button>
        </div>
      </div>
      <div className="settings-actions">
        {note && (
          <span className={(err ? "settings-err " : "dim ") + "settings-note"}>{note}</span>
        )}
        <button className="primary" onClick={save} disabled={busy}>
          save {scope}
        </button>
      </div>
    </section>
  );
}
