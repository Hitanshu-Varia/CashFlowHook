import { describe, expect, it } from "vitest";
import { buildSnapshot } from "../lib/dashboard.js";

describe("Credit Desk demo model", () => {
  it("has a complete 16-scenario grid", () => {
    expect(buildSnapshot(true).scenarios).toHaveLength(16);
  });

  it("moves the treasury leg from unwindable to earning-locked on a gate shut", () => {
    const open = buildSnapshot(true);
    const shut = buildSnapshot(false);

    expect(open.earningLockedUsd).toBe(0);
    expect(shut.earningLockedUsd).toBe(1_360);
    expect(shut.unwindableNowUsd).toBe(open.unwindableNowUsd - 1_360);
    expect(shut.requiresStepUp).toBe(true);
  });

  it("uses the contract-aligned 2% autonomous per-draw cap", () => {
    const snapshot = buildSnapshot(true);
    expect(snapshot.drawCapUsd).toBe(54.34);
  });
});
