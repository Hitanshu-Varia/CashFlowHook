import { describe, expect, it } from "vitest";
import { keccak256, toHex } from "viem";
import {
  buildDailyFees,
  buildStreamRecord,
  defaultWindowStart,
  eligibleTakers,
  takerCsv,
  takerRoot,
  takerSummary,
} from "../src/events.js";
import type { FeeSnapshot } from "../src/types.js";

const OWNER = "0x0000000000000000000000000000000000000b0b" as const;
const A = "0x0000000000000000000000000000000000000a01" as const;
const B = "0x0000000000000000000000000000000000000a02" as const;
const POS = keccak256(toHex("position-1"));

describe("taker diversity", () => {
  it("deduplicates, sorts, and excludes the owner", () => {
    const takers = eligibleTakers([B, A, B, OWNER, A], OWNER);
    expect(takers).toEqual([A, B]);
  });

  it("rejects malformed addresses", () => {
    expect(() => eligibleTakers(["not-an-address"], OWNER)).toThrow("invalid address");
  });

  it("caps the sample at 64 and commits to the full sorted set hash", () => {
    const raw = Array.from({ length: 70 }, (_, i) => {
      const value = (i + 1).toString(16).padStart(40, "0");
      return `0x${value}`;
    });
    const summary = takerSummary(raw, OWNER);
    expect(summary.count).toBe(70);
    expect(summary.sample).toHaveLength(64);
    expect(summary.sample[0]).toBe(`0x${"1".padStart(40, "0")}`);
    expect(summary.csvSha256).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it("hashes a deterministic CSV", () => {
    expect(takerCsv([A, B])).toBe(`taker\n${A}\n${B}\n`);
  });
});

describe("seven-day fee window", () => {
  const start = 1_800_000_000;
  const snapshots: FeeSnapshot[] = [
    { ts: start - 1, feesOwedWad: 999n },
    { ts: start, feesOwedWad: 10n },
    { ts: start + 86_399, feesOwedWad: 5n },
    { ts: start + 86_400, feesOwedWad: 7n },
    { ts: start + 7 * 86_400, feesOwedWad: 999n },
  ];

  it("buckets only snapshots inside the window", () => {
    const fees = buildDailyFees(snapshots, start);
    expect(fees).toEqual([15n, 7n, 0n, 0n, 0n, 0n, 0n]);
  });

  it("uses the last fully closed seven-day window by default", () => {
    expect(defaultWindowStart(1_800_000_123)).toBe(1_799_971_200 - 7 * 86_400);
  });

  it("builds an owner-excluded, hash-pinned record", () => {
    const { record, sample } = buildStreamRecord({
      strategyPosId: POS,
      excludedOwner: OWNER,
      windowStartTs: start,
      snapshots,
      rawTakers: [A, B, A, OWNER],
    });
    expect(record.dailyFees).toEqual([15n, 7n, 0n, 0n, 0n, 0n, 0n]);
    expect(record.distinctTakers).toBe(2n);
    expect(record.excludedOwner.toLowerCase()).toBe(OWNER.toLowerCase());
    expect(sample).toEqual([A, B]);
    expect(record.rootHash).toBe(takerRoot(sample));
  });
});
