import { lazy, Suspense, useEffect, useState } from "react";
import type * as Monaco from "monaco-editor";
import { api } from "../api";
import type { ScriptsConfig } from "../types";

// Monaco is haro's one editor engine; lazy-load it so opening the Runbook doesn't
// pull the ~heavy editor into first paint (it downloads on demand, once).
const MonacoEditor = lazy(() => import("./MonacoEditor"));

// A compact, chromeless Monaco used as a command field — multi-line (so a setup
// can be `nvm use 24` then `npm install`), mono, no gutter / line-numbers / minimap,
// auto-growing to content. `import type` above keeps this a plain object (erased at
// compile), so referencing it never drags Monaco into the main bundle.
const CMD_OPTS: Monaco.editor.IStandaloneEditorConstructionOptions = {
  lineNumbers: "off",
  minimap: { enabled: false },
  glyphMargin: false,
  folding: false,
  lineDecorationsWidth: 0,
  lineNumbersMinChars: 0,
  overviewRulerLanes: 0,
  hideCursorInOverviewRuler: true,
  overviewRulerBorder: false,
  renderLineHighlight: "none",
  scrollBeyondLastLine: false,
  wordWrap: "on",
  contextmenu: false,
  fontSize: 12.5,
  padding: { top: 6, bottom: 6 },
  scrollbar: { horizontal: "hidden", verticalScrollbarSize: 8, useShadows: false },
};

// Chromeless command field, self-loading (each shares the one lazy Monaco module).
function CmdField(props: {
  value: string;
  onChange: (v: string) => void;
  theme: string;
  language: string;
  placeholder?: string;
  minHeight?: number;
  maxHeight?: number;
}) {
  return (
    <Suspense fallback={<div className="mon-loading dim">…</div>}>
      <MonacoEditor
        value={props.value}
        onChange={props.onChange}
        theme={props.theme}
        language={props.language}
        options={CMD_OPTS}
        transparent
        autoHeight
        minHeight={props.minHeight ?? 32}
        maxHeight={props.maxHeight ?? 220}
        placeholder={props.placeholder}
      />
    </Suspense>
  );
}

/** In-app editor for the project's `[scripts]` — so you configure setup/dev
 *  commands without hand-editing `.haro/settings.toml`. Saves to
 *  settings.local.toml (personal) or promotes to settings.toml (committed →
 *  the whole team inherits it). The login-shell toggle makes nvm/asdf/pyenv work. */
export function RunbookPanel({
  projectId,
  theme,
  onSaved,
}: {
  projectId: string;
  theme: string;
  onSaved?: (cfg: ScriptsConfig) => void;
}) {
  const [setup, setSetup] = useState("");
  const [run, setRun] = useState("");
  const [loginShell, setLoginShell] = useState(false);
  const [runMode, setRunMode] = useState("concurrent");
  const [archive, setArchive] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // Custom instructions (Tier-1): shared (team) + local (personal) edited one
  // scope at a time; both are concatenated into every agent run's system prompt.
  const [instrShared, setInstrShared] = useState("");
  const [instrLocal, setInstrLocal] = useState("");
  const [instrScope, setInstrScope] = useState<"local" | "shared">("local");
  const [instrNote, setInstrNote] = useState<string | null>(null);
  const [instrBusy, setInstrBusy] = useState(false);

  useEffect(() => {
    api
      .getProjectScripts(projectId)
      .then((c) => {
        setSetup(c.setup ?? "");
        setRun(c.run ?? "");
        setLoginShell(c.login_shell);
        setRunMode(c.run_mode || "concurrent");
        setArchive(c.archive ?? null);
      })
      .catch(() => {});
    api
      .getProjectInstructions(projectId)
      .then((c) => {
        setInstrShared(c.shared);
        setInstrLocal(c.local);
      })
      .catch(() => {});
  }, [projectId]);

  const saveInstructions = async () => {
    if (instrBusy) return;
    setInstrBusy(true);
    setInstrNote(null);
    const text = instrScope === "shared" ? instrShared : instrLocal;
    try {
      const c = await api.saveProjectInstructions(projectId, text, instrScope);
      setInstrShared(c.shared);
      setInstrLocal(c.local);
      setInstrNote(
        instrScope === "shared"
          ? "saved to instructions.md (team) · applies next run"
          : "saved to instructions.local.md (personal) · applies next run",
      );
      setTimeout(() => setInstrNote(null), 2500);
    } catch (e) {
      setInstrNote(e instanceof Error ? e.message : "save failed");
    } finally {
      setInstrBusy(false);
    }
  };

  const save = async (target: "local" | "shared") => {
    if (busy) return;
    setBusy(true);
    setNote(null);
    try {
      const cfg = await api.saveProjectScripts(projectId, {
        setup: setup.trim() || null,
        run: run.trim() || null,
        archive,
        run_mode: runMode,
        login_shell: loginShell,
        target,
      });
      setNote(target === "shared" ? "promoted to settings.toml (team)" : "saved to settings.local.toml");
      onSaved?.(cfg);
      setTimeout(() => setNote(null), 2500);
    } catch (e) {
      setNote(e instanceof Error ? e.message : "save failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="runbook">
      <div className="rb-field">
        <span className="rb-k">setup</span>
        <div className="rb-editor">
          <CmdField
            value={setup}
            onChange={setSetup}
            theme={theme}
            language="shell"
            placeholder="e.g. npm install   (multi-line ok, runs as a script)"
          />
        </div>
      </div>
      <div className="rb-field">
        <span className="rb-k">dev</span>
        <div className="rb-editor">
          <CmdField
            value={run}
            onChange={setRun}
            theme={theme}
            language="shell"
            placeholder="e.g. npm run dev   (uses $HARO_PORT)"
          />
        </div>
      </div>
      <label className="rb-toggle">
        <input
          type="checkbox"
          className="switch"
          checked={loginShell}
          onChange={(e) => setLoginShell(e.target.checked)}
        />
        <span>
          run through login shell <span className="dim">· needed for nvm / asdf / pyenv</span>
        </span>
      </label>
      <div className="rb-actions">
        {note && <span className="dim rb-note">{note}</span>}
        <button className="ghost" onClick={() => save("local")} disabled={busy} title="save personal override (settings.local.toml)">
          save
        </button>
        <button
          className="primary"
          onClick={() => save("shared")}
          disabled={busy}
          title="commit for the whole team (settings.toml)"
        >
          promote to team
        </button>
      </div>
      <div className="rb-hint dim">
        Env available to scripts: <code>$HARO_PORT</code>, <code>$HARO_WORKSPACE_PATH</code>,{" "}
        <code>$HARO_ROOT_PATH</code>. Chain steps with <code>&amp;&amp;</code> or new lines.
      </div>

      <div className="rb-divider" />

      <div className="rb-section-head">
        <span className="rb-section-title rule-title">custom instructions</span>
        <div className="rb-scope">
          <button
            className={"chip" + (instrScope === "local" ? " chip-on" : "")}
            onClick={() => setInstrScope("local")}
            title="personal · instructions.local.md (gitignored)"
          >
            personal
          </button>
          <button
            className={"chip" + (instrScope === "shared" ? " chip-on" : "")}
            onClick={() => setInstrScope("shared")}
            title="team · instructions.md (committed)"
          >
            team
          </button>
        </div>
      </div>
      <div className="rb-field">
        <div className="rb-editor rb-editor-tall">
          <CmdField
            value={instrScope === "shared" ? instrShared : instrLocal}
            onChange={instrScope === "shared" ? setInstrShared : setInstrLocal}
            theme={theme}
            language="markdown"
            minHeight={96}
            maxHeight={320}
            placeholder={
              "Standing instructions the agent follows every run, e.g.\n" +
              "Before finishing, write a brief CHANGES.md of what changed, then stop and ask me to review before committing."
            }
          />
        </div>
      </div>
      <div className="rb-actions">
        {instrNote && <span className="dim rb-note">{instrNote}</span>}
        <button className="primary" onClick={saveInstructions} disabled={instrBusy}>
          save {instrScope}
        </button>
      </div>
      <div className="rb-hint dim">
        Appended to every agent run in this project via Claude Code's{" "}
        <code>--append-system-prompt</code>. Team + personal both apply (team first). This is soft
        guidance: the agent usually complies, but it's not enforced like the gate.
      </div>
    </div>
  );
}
