import { describe, it, expect } from "vitest";
import { formatCost } from "./formatCost";

describe("formatCost", () => {
  it("keeps 4 decimals for sub-dollar amounts", () => {
    expect(formatCost(0.0021)).toBe("$0.0021");
  });

  it("uses 2 decimals at a dollar or more", () => {
    expect(formatCost(1.5)).toBe("$1.50");
  });

  it("rounds sub-dollar amounts to 4 decimals", () => {
    expect(formatCost(0.00219)).toBe("$0.0022");
  });

  it("formats zero as $0.0000", () => {
    expect(formatCost(0)).toBe("$0.0000");
  });

  it("switches to 2 decimals exactly at 1", () => {
    expect(formatCost(1)).toBe("$1.00");
  });

  it("formats large amounts with 2 decimals", () => {
    expect(formatCost(1234.567)).toBe("$1234.57");
  });

  it("handles negative amounts", () => {
    expect(formatCost(-0.005)).toBe("-$0.0050");
    expect(formatCost(-2.5)).toBe("-$2.50");
  });
});
