import { useEffect, useState, type ReactNode } from "react";
import { api } from "../api";
import { Monitor, Bell, Sliders, Gauge, X } from "./icons";
import { NotificationSettingsBody } from "./NotificationSettings";
import { UsagePanel } from "./Usage";
import { THEMES, type ThemeId } from "../themes";
import type { NotifyPrefs } from "../notify";
import type { UpdateStatus } from "../types";
import {
  clampDuration,
  TOAST_POSITIONS,
  type ToastPrefs,
} from "../toast";

type Tab = "display" | "notifications" | "usage" | "system";

const TABS: { id: Tab; label: string; icon: ReactNode }[] = [
  { id: "display", label: "Display", icon: <Monitor /> },
  { id: "notifications", label: "Notifications", icon: <Bell /> },
  { id: "usage", label: "Usage", icon: <Gauge /> },
  { id: "system", label: "System", icon: <Sliders /> },
];

/** The app-wide Settings surface: a left tab-rail + a content pane, opened from
 *  the appbar gear. Only truly global controls live here — Display (theme) and
 *  Notifications (agent-done sound), mirroring the appbar controls they replace.
 *  Custom instructions are per-project, so they live in the project-settings
 *  modal's Instructions tab, not here. */
export function SettingsModal({
  theme,
  setTheme,
  notifPrefs,
  setNotifPrefs,
  toastPrefs,
  setToastPrefs,
  initialTab,
  onClose,
}: {
  theme: ThemeId;
  setTheme: (t: ThemeId) => void;
  notifPrefs: NotifyPrefs;
  setNotifPrefs: (p: NotifyPrefs) => void;
  toastPrefs: ToastPrefs;
  setToastPrefs: (p: ToastPrefs) => void;
  initialTab?: Tab;
  onClose: () => void;
}) {
  const [tab, setTab] = useState<Tab>(initialTab ?? "display");

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="settings-scrim" onMouseDown={onClose}>
      <div className="settings-modal" role="dialog" aria-label="settings" onMouseDown={(e) => e.stopPropagation()}>
        <nav className="settings-rail">
          <div className="settings-rail-head">Settings</div>
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

          {tab === "display" && (
            <section className="settings-section">
              <h3 className="settings-h">Theme</h3>
              <p className="settings-sub dim">
                haro ships one trademark theme. It applies everywhere and is remembered on
                this device.
              </p>
              {/* Single-theme lock — haro ships ONE trademark look, so THEMES only ever
                  has the one entry; this still renders it as a card (rather than a bare
                  label) so Display shows which theme is active and stays ready for a
                  second family to be added back to the registry later. */}
              <div className="theme-grid">
                {THEMES.map((t) => (
                  <button
                    key={t.id}
                    className={"theme-card" + (theme === t.id ? " theme-card-on" : "")}
                    onClick={() => setTheme(t.id)}
                    aria-pressed={theme === t.id}
                  >
                    <span className="theme-swatches">
                      {t.swatches.map((c, i) => (
                        <span key={i} className="theme-swatch" style={{ background: c }} />
                      ))}
                    </span>
                    <span className="theme-card-meta">
                      <span className="theme-card-label">{t.label}</span>
                      <span className="theme-card-tag dim">{t.tagline}</span>
                    </span>
                  </button>
                ))}
              </div>
            </section>
          )}

          {tab === "notifications" && (
            <>
              <section className="settings-section">
                <h3 className="settings-h">Sound</h3>
                <p className="settings-sub dim">
                  A sound plays whenever an agent finishes, in any workspace, not just the open one.
                </p>
                <NotificationSettingsBody prefs={notifPrefs} onChange={setNotifPrefs} layout="panel" />
              </section>
              <ToastTab prefs={toastPrefs} onChange={setToastPrefs} />
            </>
          )}

          {tab === "usage" && <UsagePanel />}

          {tab === "system" && <SystemTab />}
        </div>
      </div>
    </div>
  );
}

/** Toast controls: where the success/error pills appear and how long they dwell
 *  before sliding out. Both apply immediately (App persists on change) and the
 *  "test" button fires a sample toast so the choice is visible right away. */
function ToastTab({
  prefs,
  onChange,
}: {
  prefs: ToastPrefs;
  onChange: (p: ToastPrefs) => void;
}) {
  const seconds = (prefs.durationMs / 1000).toFixed(1).replace(/\.0$/, "");
  return (
    <section className="settings-section">
      <h3 className="settings-h">Toasts</h3>
      <p className="settings-sub dim">
        Merge results and other success / error messages slide in as toasts. Choose the corner
        and how long they stay before sliding out.
      </p>

      <div className="settings-row">
        <span className="settings-k">Position</span>
        <select
          className="settings-select"
          value={prefs.position}
          onChange={(e) =>
            onChange({ ...prefs, position: e.target.value as ToastPrefs["position"] })
          }
        >
          {TOAST_POSITIONS.map((p) => (
            <option key={p.value} value={p.value}>
              {p.label}
            </option>
          ))}
        </select>
      </div>

      <div className="settings-row">
        <span className="settings-k">Duration</span>
        <div className="rb-scope" style={{ gap: 10, alignItems: "center" }}>
          <input
            type="range"
            min={1}
            max={20}
            step={0.5}
            value={prefs.durationMs / 1000}
            onChange={(e) =>
              onChange({ ...prefs, durationMs: clampDuration(Number(e.target.value) * 1000) })
            }
          />
          <span className="dim" style={{ minWidth: 44, fontFamily: "var(--mono)" }}>
            {seconds}s
          </span>
        </div>
      </div>
    </section>
  );
}

/** haro has no in-app way to reload the backend process (it supervises long-lived
 *  agents, so there's deliberately no `--reload`); pick up backend code changes
 *  with an intentional restart of `./run.sh` instead. This tab is just self-update
 *  controls. */
function SystemTab() {
  return <UpdatesSection />;
}

/** Self-update controls: pick manual vs auto, see status, and trigger a
 *  rebuild+restart. Applying is idle-gated on the backend — a busy app queues it
 *  until agents finish. Renders "unavailable" on a dev/run.sh run (no build stamp). */
function UpdatesSection() {
  const [st, setSt] = useState<UpdateStatus | null>(null);
  const [working, setWorking] = useState(false);
  const [applying, setApplying] = useState(false);

  const refresh = () => api.updateStatus().then(setSt).catch(() => {});
  useEffect(() => {
    refresh();
  }, []);

  if (!st) return null;

  const setMode = async (mode: "manual" | "auto") => {
    await api.setUpdateMode(mode).catch(() => {});
    refresh();
  };
  const apply = async () => {
    setWorking(true);
    try {
      const r = await api.applyUpdate();
      if (r.applying) setApplying(true);
    } catch {
      setWorking(false);
      return;
    }
    await refresh();
    setWorking(false);
  };

  return (
    <section className="settings-section">
      <h3 className="settings-h">Updates</h3>
      <p className="settings-sub dim">
        The desktop app is a built snapshot. When your local source moves ahead, haro can rebuild
        itself, waiting until no agent or gate is running so nothing is interrupted.
      </p>
      {!st.supported ? (
        <p className="dim">
          Self-update isn't available here: you're running from source (no build stamp). Use{" "}
          <code>desktop/rebuild.sh</code>.
        </p>
      ) : (
        <>
          <div className="settings-row">
            <span className="settings-k">Mode</span>
            <div className="rb-scope">
              <button
                className={"chip" + (st.mode === "manual" ? " chip-on" : "")}
                onClick={() => setMode("manual")}
              >
                Manual
              </button>
              <button
                className={"chip" + (st.mode === "auto" ? " chip-on" : "")}
                onClick={() => setMode("auto")}
              >
                Auto
              </button>
            </div>
          </div>
          <div className="settings-row">
            <span className="settings-k">Status</span>
            <span className="dim">
              {st.available ? `Update available (${st.buildSha} → ${st.headSha})` : "Up to date"}
              {st.busy ? ` · ${st.busyReason}` : ""}
              {st.pending ? " · queued" : ""}
            </span>
          </div>
          {applying ? (
            <p className="settings-note dim">
              ⟳ Rebuilding &amp; restarting (~1 min), haro will reload itself when it's done.
            </p>
          ) : (
            st.available && (
              <div className="settings-actions">
                <button className="chip chip-on" disabled={working || st.pending} onClick={apply}>
                  {working
                    ? "…"
                    : st.busy || st.pending
                      ? "Update when agents finish"
                      : "Update & restart now"}
                </button>
              </div>
            )
          )}
        </>
      )}
    </section>
  );
}
