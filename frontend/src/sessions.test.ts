import { describe, it, expect } from "vitest";
import {
  DEFAULT_SESSION,
  mergeSession,
  mergeSessions,
  nextSessionId,
  sessionLabel,
} from "./sessions";

describe("mergeSession", () => {
  it("appends a new id once, preserving order", () => {
    expect(mergeSession(["main"], "s2")).toEqual(["main", "s2"]);
  });
  it("is a no-op for an id already present", () => {
    const list = ["main", "s2"];
    expect(mergeSession(list, "s2")).toBe(list); // same ref — no churn
  });
});

describe("mergeSessions", () => {
  it("unions incoming into the list, deduped, first-seen order", () => {
    expect(mergeSessions(["main"], ["main", "s2", "s3"])).toEqual(["main", "s2", "s3"]);
  });
  it("keeps an already-open (unsaved) tab not yet in the fetched set", () => {
    expect(mergeSessions(["main", "s5"], ["main", "s2"])).toEqual(["main", "s5", "s2"]);
  });
});

describe("nextSessionId", () => {
  it("is s2 for a lone primary session", () => {
    expect(nextSessionId([DEFAULT_SESSION])).toBe("s2");
  });
  it("increments past the highest existing s<n>, not the length", () => {
    expect(nextSessionId(["main", "s2", "s5"])).toBe("s6");
  });
  it("ignores non-conforming ids", () => {
    expect(nextSessionId(["main", "weird"])).toBe("s2");
  });
});

describe("sessionLabel", () => {
  it("labels by position, 1-based", () => {
    const list = ["main", "s2", "s5"];
    expect(sessionLabel(list, "main")).toBe("session 1");
    expect(sessionLabel(list, "s2")).toBe("session 2");
    expect(sessionLabel(list, "s5")).toBe("session 3");
  });
  it("falls back to the raw id when absent", () => {
    expect(sessionLabel(["main"], "ghost")).toBe("ghost");
  });
});
