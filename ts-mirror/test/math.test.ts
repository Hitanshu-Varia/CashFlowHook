import { describe, expect, it } from "vitest";
import { divWad, mulWad, sqrt, WAD } from "../src/wad";
import { accountSnapshotUsd, portfolioSnapshotUsd } from "../src/spanMath";
import { eligibility, rwaStress, segregated } from "../src/rwaStress";
import {
  combinedCredit,
  feeCreditFees,
  strategyScore,
} from "../src/feeMath";

const E18 = 10n ** 18n;
const f = (n: number): bigint => BigInt(n) * E18;

describe("WadMath", () => {
  it("floors mulWad and divWad", () => {
    expect(mulWad(f(3), f(2))).toBe(f(6));
    expect(divWad(f(3), f(2))).toBe(1_500_000_000_000_000_000n);
    expect(divWad(f(1), 0n)).toBe(0n);
  });

  it("matches floor sqrt", () => {
    expect(sqrt(0n)).toBe(0n);
    expect(sqrt(1n)).toBe(1n);
    expect(sqrt(15n)).toBe(3n);
    expect(sqrt(16n)).toBe(4n);
    expect(sqrt(17n)).toBe(4n);
    expect(sqrt(10n ** 36n)).toBe(10n ** 18n);
  });
});

describe("SpanMathLib mirror", () => {
  it("zero portfolio", () => {
    const r = accountSnapshotUsd(0n, 0n, 0n, 0n);
    expect(r.im).toBe(0n);
    expect(r.bp).toBe(0n);
    expect(r.health).toBe(0n);
    expect(r.scenarioLosses).toEqual(new Array(16).fill(0n));
  });

  it("stock-only grid", () => {
    const r = accountSnapshotUsd(f(1_000), 0n, 0n, 0n);
    expect(r.im).toBe(f(300));
    expect(r.bp).toBe(f(440));
    expect(r.scenarioLosses[0]).toBe(f(200));
    expect(r.scenarioLosses[1]).toBe(f(300));
  });

  it("LP-only grid", () => {
    const r = accountSnapshotUsd(0n, f(1_000), 0n, 0n);
    expect(r.im).toBe(244_500_000_000_000_000_000n);
    expect(r.bp).toBe(364_400_000_000_000_000_000n);
  });

  it("base two-leg grid", () => {
    const r = accountSnapshotUsd(f(1_000), f(1_000), 0n, 0n);
    expect(r.im).toBe(544_500_000_000_000_000_000n);
    expect(r.bp).toBe(804_400_000_000_000_000_000n);
  });

  it("fee credit lowers IM", () => {
    const without = accountSnapshotUsd(f(1_000), 0n, 0n, 0n);
    const withFee = accountSnapshotUsd(f(1_000), 0n, f(100), 0n);
    expect(without.im).toBe(f(300));
    expect(withFee.im).toBe(f(250));
  });

  it("full three-class portfolio", () => {
    const r = portfolioSnapshotUsd(
      f(1_000),
      f(1_000),
      f(1_000),
      f(1_000),
      0n,
      0n,
      86_400_000_000_000_000_000n,
      0n,
      false,
      true,
      25_000_000n * E18,
    );
    expect(r.lossR1Base).toBe(f(300));
    expect(r.lossR2).toBe(f(20));
    expect(r.im).toBe(1_014_500_000_000_000_000_000n);
    expect(r.cStressed).toBe(2_135_500_000_000_000_000_000n);
    expect(r.bp).toBe(1_708_400_000_000_000_000_000n);
    expect(r.eligR1).toBe(1);
    expect(r.eligR2).toBe(1);
    expect(r.unwindableNow).toBe(f(3_150));
    expect(r.earningLocked).toBe(0n);
  });

  it("segregates restricted legs without changing BP", () => {
    const r = portfolioSnapshotUsd(
      f(1_000),
      f(1_000),
      f(1_000),
      f(1_000),
      0n,
      0n,
      86_400_000_000_000_000_000n,
      0n,
      true,
      false,
      25_000_000n * E18,
    );
    expect(r.eligR1).toBe(0);
    expect(r.eligR2).toBe(0);
    expect(r.unwindableNow).toBe(f(1_550));
    expect(r.earningLocked).toBe(f(1_600));
    expect(r.bp).toBe(1_708_400_000_000_000_000_000n);
  });
});

describe("RwaStressLib mirror", () => {
  it("lossR1 with and without vol multiplier", () => {
    expect(rwaStress(f(1_000), 0n, 0n, WAD).lossR1).toBe(f(300));
    expect(rwaStress(f(1_000), 0n, 0n, 1_500_000_000_000_000_000n).lossR1).toBe(f(450));
  });

  it("lossR2", () => {
    expect(rwaStress(0n, f(1_000), 86_400_000_000_000_000_000n, WAD).lossR2).toBe(f(20));
  });

  it("coupon can bind the exit cost", () => {
    expect(rwaStress(0n, f(1_000), WAD, WAD).lossR2).toBe(f(17));
  });

  it("eligibility flags", () => {
    expect(eligibility(false, true, f(1_000), 25_000_000n * E18)).toEqual({
      eligR1: 1,
      eligR2: 1,
    });
    expect(eligibility(true, true, f(1_000), 25_000_000n * E18)).toEqual({
      eligR1: 0,
      eligR2: 1,
    });
    expect(eligibility(false, false, f(1_000), 25_000_000n * E18)).toEqual({
      eligR1: 1,
      eligR2: 0,
    });
  });

  it("eligibility cap boundary", () => {
    const cap = 25_000_000n * E18;
    const limit = cap / 4n;
    expect(eligibility(false, true, limit, cap).eligR2).toBe(1);
    expect(eligibility(false, true, limit + 1n, cap).eligR2).toBe(0);
  });

  it("segregation split", () => {
    expect(segregated(f(1_000), f(1_000), f(1_000), f(1_000), 1, 1)).toEqual({
      unwindableNow: f(3_150),
      earningLocked: 0n,
    });
    expect(segregated(f(1_000), f(1_000), f(1_000), f(1_000), 0, 0)).toEqual({
      unwindableNow: f(1_550),
      earningLocked: f(1_600),
    });
  });
});

describe("FeeMathLib mirror", () => {
  const flat = (daily: bigint): bigint[] => new Array(7).fill(daily);

  it("taker floor", () => {
    expect(feeCreditFees(flat(f(100)), 4n)).toBe(0n);
    expect(feeCreditFees(flat(f(100)), 5n)).toBe(f(75));
  });

  it("flat fee credit", () => {
    expect(feeCreditFees(flat(f(100)), 10n)).toBe(f(150));
    expect(feeCreditFees(flat(f(100)), 20n)).toBe(f(300));
  });

  it("score gating and rounding", () => {
    expect(strategyScore(flat(f(100)), 10n, 7n)).toBe(100);
    expect(strategyScore(flat(f(100)), 4n, 7n)).toBe(0);
    expect(strategyScore(flat(f(100)), 10n, 1n)).toBe(83);
  });

  it("combined credit cap", () => {
    expect(combinedCredit(f(100), f(100), f(1_000))).toBe(f(100));
    expect(combinedCredit(f(100), f(100), f(10_000))).toBe(f(200));
  });
});
