import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { accountSnapshotUsd, portfolioSnapshotUsd } from "../src/spanMath";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

interface SpanVector {
  stockUsd: string;
  lpUsd: string;
  feeCreditBase: string;
  debt: string;
  im: string;
  bp: string;
  health: string;
  [key: string]: unknown;
}

interface RwaVector extends SpanVector {
  equityRwaUsd: string;
  navUsd: string;
  feeCreditFees: string;
  navAccrualCredit: string;
  dailyCoupon: string;
  transferRestricted: boolean;
  gateOpen: boolean;
  dailyCap: string;
  lossR1Base: string;
  lossR2: string;
  eligR1: string;
  eligR2: string;
  cStressed: string;
  unwindableNow: string;
  earningLocked: string;
}

interface SpanFile {
  count: string;
  vectors: SpanVector[];
}

interface RwaFile {
  count: string;
  vectors: RwaVector[];
}

function load<T>(name: string): T {
  // The golden files use raw JSON integers so Forge can ABI-decode them directly.
  // Quote every integer before JSON.parse so TypeScript keeps full precision.
  const text = readFileSync(resolve(root, "test-golden", name), "utf8").replace(
    /:\s*(-?\d+)(?=\s*[,}\]])/g,
    ': "$1"',
  );
  return JSON.parse(text) as T;
}

/** The golden files flatten each 16-cell grid into l0..l15 static fields. */
function expectLosses(actual: readonly bigint[], record: SpanVector, prefix: string): void {
  for (let i = 0; i < 16; i++) {
    expect(actual[i].toString(), `${prefix} l${i}`).toBe(record[`l${i}`]);
  }
}

describe("solidity/TS golden parity", () => {
  it("matches all 1,000 span vectors", () => {
    const file = load<SpanFile>("span_golden.json");
    expect(file.count).toBe("1000");
    expect(file.vectors).toHaveLength(1_000);

    for (let i = 0; i < file.vectors.length; i++) {
      const v = file.vectors[i];
      const result = accountSnapshotUsd(
        BigInt(v.stockUsd),
        BigInt(v.lpUsd),
        BigInt(v.feeCreditBase),
        BigInt(v.debt),
      );
      const prefix = `span vector ${i}`;
      expect(result.im.toString(), `${prefix} im`).toBe(v.im);
      expect(result.bp.toString(), `${prefix} bp`).toBe(v.bp);
      expect(result.health.toString(), `${prefix} health`).toBe(v.health);
      expectLosses(result.scenarioLosses, v, prefix);
    }
  });

  it("matches all 300 RWA vectors", () => {
    const file = load<RwaFile>("rwa_golden.json");
    expect(file.count).toBe("300");
    expect(file.vectors).toHaveLength(300);

    for (let i = 0; i < file.vectors.length; i++) {
      const v = file.vectors[i];
      const result = portfolioSnapshotUsd(
        BigInt(v.stockUsd),
        BigInt(v.lpUsd),
        BigInt(v.equityRwaUsd),
        BigInt(v.navUsd),
        BigInt(v.feeCreditFees),
        BigInt(v.navAccrualCredit),
        BigInt(v.dailyCoupon),
        BigInt(v.debt),
        v.transferRestricted,
        v.gateOpen,
        BigInt(v.dailyCap),
      );
      const prefix = `rwa vector ${i}`;
      expect(result.im.toString(), `${prefix} im`).toBe(v.im);
      expect(result.bp.toString(), `${prefix} bp`).toBe(v.bp);
      expect(result.health.toString(), `${prefix} health`).toBe(v.health);
      expect(result.cStressed.toString(), `${prefix} cStressed`).toBe(v.cStressed);
      expect(result.feeCreditBase.toString(), `${prefix} feeCreditBase`).toBe(v.feeCreditBase);
      expect(result.unwindableNow.toString(), `${prefix} unwindableNow`).toBe(v.unwindableNow);
      expect(result.earningLocked.toString(), `${prefix} earningLocked`).toBe(v.earningLocked);
      expect(result.lossR1Base.toString(), `${prefix} lossR1Base`).toBe(v.lossR1Base);
      expect(result.lossR2.toString(), `${prefix} lossR2`).toBe(v.lossR2);
      expect(result.eligR1.toString(), `${prefix} eligR1`).toBe(v.eligR1);
      expect(result.eligR2.toString(), `${prefix} eligR2`).toBe(v.eligR2);
      expectLosses(result.scenarioLosses, v, prefix);
    }
  });
});
