import { describe, it, expect } from "vitest";
import { shouldShowDesktop, type DesktopPermission, type NotifyPrefs } from "./notify";

const prefs = (over: Partial<NotifyPrefs>): NotifyPrefs => ({
  enabled: true,
  sound: "chime",
  customName: null,
  customData: null,
  volume: 0.5,
  desktop: true,
  ...over,
});

const ctx = (over: Partial<{ supported: boolean; permission: DesktopPermission; focused: boolean }>) => ({
  supported: true,
  permission: "granted" as DesktopPermission,
  focused: false,
  ...over,
});

describe("shouldShowDesktop", () => {
  it("shows when enabled, granted, supported and unfocused", () => {
    expect(shouldShowDesktop(prefs({}), ctx({}))).toBe(true);
  });

  it("suppresses when the window is focused (the beep + UI cover that)", () => {
    expect(shouldShowDesktop(prefs({}), ctx({ focused: true }))).toBe(false);
  });

  it("stays silent when the pref is off", () => {
    expect(shouldShowDesktop(prefs({ desktop: false }), ctx({}))).toBe(false);
  });

  it("stays silent without granted permission", () => {
    expect(shouldShowDesktop(prefs({}), ctx({ permission: "default" }))).toBe(false);
    expect(shouldShowDesktop(prefs({}), ctx({ permission: "denied" }))).toBe(false);
    expect(shouldShowDesktop(prefs({}), ctx({ permission: "unsupported" }))).toBe(false);
  });

  it("stays silent when notifications are unsupported", () => {
    expect(shouldShowDesktop(prefs({}), ctx({ supported: false }))).toBe(false);
  });
});
