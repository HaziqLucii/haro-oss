import { useEffect, useRef, useState } from "react";
import { Play, X } from "./icons";
import {
  BUILTIN_SOUNDS,
  desktopPermission,
  desktopSupported,
  playNotify,
  requestDesktopPermission,
  type DesktopPermission,
  type NotifyPrefs,
} from "../notify";

// Custom audio is stored as a data URL in localStorage (~5MB budget), so keep
// uploads small — a notification sound only needs a second or two.
const MAX_CUSTOM_BYTES = 1_000_000;

/** Popover for the agent-done sound: enable, pick a built-in tone or your own
 *  .mp3, set volume, and test it. Fires for every workspace, not just the open
 *  one — so you're aware whenever an agent finishes. A thin wrapper around
 *  {@link NotificationSettingsBody}, which the Settings page also renders inline. */
export function NotificationSettings({
  prefs,
  onChange,
  onClose,
}: {
  prefs: NotifyPrefs;
  onChange: (p: NotifyPrefs) => void;
  onClose: () => void;
}) {
  return (
    <div className="notif-pop" role="dialog" aria-label="notification sound">
      <div className="notif-head">
        <span className="notif-title">agent-done sound</span>
        <button className="ghost btn-icon" onClick={onClose} title="close">
          <X />
        </button>
      </div>
      <NotificationSettingsBody prefs={prefs} onChange={onChange} />
    </div>
  );
}

/** The notification-sound fields on their own — no popover chrome — so both the
 *  appbar popover and the Settings page can render them.
 *
 *  `layout="popover"` (default) keeps the compact `.notif-*` rows sized for the
 *  300px appbar popover. `layout="panel"` renders the same fields as
 *  `.settings-row`/`.settings-k`/`.settings-check` — the Settings modal's own
 *  row system (already used by the Toasts section right below this one) —
 *  instead of a second, differently-spaced row convention living in the same
 *  pane. */
export function NotificationSettingsBody({
  prefs,
  onChange,
  layout = "popover",
}: {
  prefs: NotifyPrefs;
  onChange: (p: NotifyPrefs) => void;
  layout?: "popover" | "panel";
}) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [note, setNote] = useState<string | null>(null);
  const [perm, setPerm] = useState<DesktopPermission>(() => desktopPermission());
  const set = (patch: Partial<NotifyPrefs>) => onChange({ ...prefs, ...patch });

  // The browser doesn't push permission changes, so re-read on mount (e.g. the
  // user granted it via the site settings while this popover was closed).
  useEffect(() => {
    setPerm(desktopPermission());
  }, []);

  const enableDesktop = async () => {
    let p = desktopPermission();
    if (p === "default") p = await requestDesktopPermission();
    setPerm(p);
    // Only flip the pref on when we can actually deliver — a granted permission.
    set({ desktop: p === "granted" });
  };

  const onPickFile = (file: File | undefined) => {
    if (!file) return;
    if (file.size > MAX_CUSTOM_BYTES) {
      setNote(`too large (${(file.size / 1e6).toFixed(1)} MB), keep it under 1 MB`);
      return;
    }
    const reader = new FileReader();
    reader.onload = () => {
      set({ sound: "custom", customName: file.name, customData: String(reader.result) });
      setNote(null);
    };
    reader.onerror = () => setNote("couldn't read that file");
    reader.readAsDataURL(file);
  };

  if (layout === "panel") {
    return (
      <>
        <label className="settings-check">
          <input
            type="checkbox"
            className="switch"
            checked={prefs.enabled}
            onChange={(e) => set({ enabled: e.target.checked })}
          />
          beep when an agent finishes <span className="dim">· any workspace</span>
        </label>

        <div className={"notif-body" + (prefs.enabled ? "" : " notif-disabled")}>
          <div className="settings-row">
            <span className="settings-k">Sound</span>
            <div className="rb-scope">
              {BUILTIN_SOUNDS.map((s) => (
                <button
                  key={s}
                  className={"chip" + (prefs.sound === s ? " chip-on" : "")}
                  onClick={() => set({ sound: s })}
                >
                  {s}
                </button>
              ))}
              <button
                className={"chip" + (prefs.sound === "custom" ? " chip-on" : "")}
                onClick={() => (prefs.customData ? set({ sound: "custom" }) : fileRef.current?.click())}
                title={prefs.customName ?? "upload an .mp3"}
              >
                custom
              </button>
            </div>
          </div>

          <div className="settings-row">
            <span className="settings-k">Custom file</span>
            <div className="notif-custom">
              <button className="ghost" onClick={() => fileRef.current?.click()}>
                choose .mp3…
              </button>
              <span className="dim notif-fname">{prefs.customName ?? "none"}</span>
              <input
                ref={fileRef}
                type="file"
                accept="audio/*"
                style={{ display: "none" }}
                onChange={(e) => onPickFile(e.target.files?.[0])}
              />
            </div>
          </div>

          <div className="settings-row">
            <span className="settings-k">Volume</span>
            <input
              type="range"
              min={0}
              max={1}
              step={0.05}
              value={prefs.volume}
              onChange={(e) => set({ volume: Number(e.target.value) })}
              style={{ flex: 1 }}
            />
            <button className="ghost" onClick={() => playNotify({ ...prefs, enabled: true })}>
              <Play /> test
            </button>
          </div>
          {note && <p className="settings-note dim">{note}</p>}
        </div>

        <div className="rb-divider" />

        <label className="settings-check">
          <input
            type="checkbox"
            className="switch"
            checked={prefs.desktop && perm === "granted"}
            disabled={!desktopSupported()}
            onChange={(e) => {
              if (e.target.checked) void enableDesktop();
              else set({ desktop: false });
            }}
          />
          desktop notification <span className="dim">— gate + agent-done, even when unfocused</span>
        </label>
        {!desktopSupported() ? (
          <p className="settings-note dim">this browser has no notification support</p>
        ) : perm === "denied" ? (
          <p className="settings-note dim">
            blocked — enable notifications for this site in your browser settings
          </p>
        ) : prefs.desktop && perm === "granted" ? (
          <p className="settings-note dim">only fires when the haro window isn't focused</p>
        ) : null}
      </>
    );
  }

  return (
    <>
      <label className="rb-toggle">
        <input
          type="checkbox"
          className="switch"
          checked={prefs.enabled}
          onChange={(e) => set({ enabled: e.target.checked })}
        />
        <span>
          beep when an agent finishes <span className="dim">· any workspace</span>
        </span>
      </label>

      <div className={"notif-body" + (prefs.enabled ? "" : " notif-disabled")}>
        <div className="notif-row">
          <span className="notif-k">sound</span>
          <div className="rb-scope">
            {BUILTIN_SOUNDS.map((s) => (
              <button
                key={s}
                className={"chip" + (prefs.sound === s ? " chip-on" : "")}
                onClick={() => set({ sound: s })}
              >
                {s}
              </button>
            ))}
            <button
              className={"chip" + (prefs.sound === "custom" ? " chip-on" : "")}
              onClick={() => (prefs.customData ? set({ sound: "custom" }) : fileRef.current?.click())}
              title={prefs.customName ?? "upload an .mp3"}
            >
              custom
            </button>
          </div>
        </div>

        <div className="notif-row">
          <span className="notif-k">custom</span>
          <div className="notif-custom">
            <button className="ghost" onClick={() => fileRef.current?.click()}>
              choose .mp3…
            </button>
            <span className="dim notif-fname">{prefs.customName ?? "none"}</span>
            <input
              ref={fileRef}
              type="file"
              accept="audio/*"
              style={{ display: "none" }}
              onChange={(e) => onPickFile(e.target.files?.[0])}
            />
          </div>
        </div>

        <div className="notif-row">
          <span className="notif-k">volume</span>
          <input
            type="range"
            min={0}
            max={1}
            step={0.05}
            value={prefs.volume}
            onChange={(e) => set({ volume: Number(e.target.value) })}
          />
        </div>

        <div className="notif-actions">
          {note && <span className="dim notif-note">{note}</span>}
          <button className="ghost" onClick={() => playNotify({ ...prefs, enabled: true })}>
            <Play /> test
          </button>
        </div>
      </div>

      <label className="rb-toggle notif-desktop">
        <input
          type="checkbox"
          className="switch"
          checked={prefs.desktop && perm === "granted"}
          disabled={!desktopSupported()}
          onChange={(e) => {
            if (e.target.checked) void enableDesktop();
            else set({ desktop: false });
          }}
        />
        <span>
          desktop notification <span className="dim">— gate + agent-done, even when unfocused</span>
        </span>
      </label>
      {!desktopSupported() ? (
        <span className="dim notif-note">this browser has no notification support</span>
      ) : perm === "denied" ? (
        <span className="dim notif-note">
          blocked — enable notifications for this site in your browser settings
        </span>
      ) : prefs.desktop && perm === "granted" ? (
        <span className="dim notif-note">only fires when the haro window isn't focused</span>
      ) : null}
    </>
  );
}
