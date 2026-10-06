import { lazy, Suspense, useEffect, useState } from "react";
import type * as Monaco from "monaco-editor";
import { api } from "../api";

// Monaco is haro's one editor engine; lazy-load it so it downloads on demand (once)
// rather than riding in first paint's bundle.
const MonacoEditor = lazy(() => import("./MonacoEditor"));

// A roomier Monaco than the Runbook's command fields — line numbers on, so
// instructions.md reads and edits like a real document. `import type` keeps this a
// plain object (erased at compile), so it never drags Monaco into the main bundle.
const DOC_OPTS: Monaco.editor.IStandaloneEditorConstructionOptions = {
  lineNumbers: "on",
  lineNumbersMinChars: 3,
  minimap: { enabled: false },
  glyphMargin: false,
  folding: false,
  overviewRulerLanes: 0,
  overviewRulerBorder: false,
  renderLineHighlight: "line",
  scrollBeyondLastLine: false,
  wordWrap: "on",
  fontSize: 13,
  padding: { top: 8, bottom: 8 },
  scrollbar: { verticalScrollbarSize: 10, useShadows: false },
};

/** The per-project custom-instructions editor body — the Tier-1 standing prompt every
 *  agent run in the project inherits via Claude Code's `--append-system-prompt`. Personal
 *  (`instructions.local.md`, gitignored) and team (`instructions.md`, committed) are edited
 *  one scope at a time; both concatenate into every run (team first). Shared by the
 *  app-wide Settings (with a project picker above it) and the project ⚙ (keyed to one
 *  project), so there's a single source of truth for the editor. */
export function ProjectInstructions({
  projectId,
  theme,
}: {
  projectId: string;
  theme: string; // "<family>-<mode>" — forwarded to MonacoEditor, which resolves it
}) {
  const [shared, setShared] = useState("");
  const [local, setLocal] = useState("");
  const [scope, setScope] = useState<"local" | "shared">("local");
  const [note, setNote] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!projectId) return;
    setNote(null);
    api
      .getProjectInstructions(projectId)
      .then((c) => {
        setShared(c.shared);
        setLocal(c.local);
      })
      .catch(() => {
        setShared("");
        setLocal("");
      });
  }, [projectId]);

  const save = async () => {
    if (busy || !projectId) return;
    setBusy(true);
    setNote(null);
    const text = scope === "shared" ? shared : local;
    try {
      const c = await api.saveProjectInstructions(projectId, text, scope);
      setShared(c.shared);
      setLocal(c.local);
      setNote(
        scope === "shared"
          ? "saved to instructions.md (team) · applies next run"
          : "saved to instructions.local.md (personal) · applies next run",
      );
      setTimeout(() => setNote(null), 2800);
    } catch (e) {
      setNote(e instanceof Error ? e.message : "save failed");
    } finally {
      setBusy(false);
    }
  };

  if (!projectId) {
    return <p className="dim">Add a project first to configure its instructions.</p>;
  }

  return (
    <>
      <div className="settings-row">
        <span className="settings-k">Scope</span>
        <div className="rb-scope">
          <button
            className={"chip" + (scope === "local" ? " chip-on" : "")}
            onClick={() => setScope("local")}
            title="personal · instructions.local.md (gitignored)"
          >
            personal
          </button>
          <button
            className={"chip" + (scope === "shared" ? " chip-on" : "")}
            onClick={() => setScope("shared")}
            title="team · instructions.md (committed)"
          >
            team
          </button>
        </div>
      </div>

      <div className="settings-editor">
        <Suspense fallback={<div className="mon-loading dim">loading editor…</div>}>
          <MonacoEditor
            value={scope === "shared" ? shared : local}
            onChange={scope === "shared" ? setShared : setLocal}
            theme={theme}
            language="markdown"
            options={DOC_OPTS}
            transparent
            height="340px"
            placeholder={
              "Standing instructions the agent follows every run, e.g.\n" +
              "Always update the matching TODO item before you commit.\n" +
              "Before finishing, write a brief CHANGES.md and stop for review."
            }
          />
        </Suspense>
      </div>

      <div className="settings-actions">
        {note && <span className="dim settings-note">{note}</span>}
        <button className="primary" onClick={save} disabled={busy}>
          save {scope}
        </button>
      </div>
    </>
  );
}
