import { WAD, divWad, max, mulWad } from "./wad";
import { eligibility, rwaStress, segregated } from "./rwaStress";

export const HC_STOCK = 850_000_000_000_000_000n;
export const HC_LP = 700_000_000_000_000_000n;
export const HC_R1 = 750_000_000_000_000_000n;
export const HC_R2 = 850_000_000_000_000_000n;
export const LTV_MAX = 800_000_000_000_000_000n;
export const MAINT = 850_000_000_000_000_000n;
export const LP_BETA = 800_000_000_000_000_000n;
export const LP_CONVEX = 50_000_000_000_000_000n;
export const FEE_CREDIT_CAP = 100_000_000_000_000_000n;
export const HALF = 500_000_000_000_000_000n;
export const DAILY_CAP_PER_INVESTOR = 25_000_000_000_000_000_000_000_000n;

export const SHOCKS: readonly bigint[] = [
  -200_000_000_000_000_000n,
  -100_000_000_000_000_000n,
  -50_000_000_000_000_000n,
  -20_000_000_000_000_000n,
  20_000_000_000_000_000n,
  50_000_000_000_000_000n,
  100_000_000_000_000_000n,
  200_000_000_000_000_000n,
];

export const VOLS: readonly bigint[] = [1_000_000_000_000_000_000n, 1_500_000_000_000_000_000n];

export interface AccountSnapshot {
  im: bigint;
  bp: bigint;
  health: bigint;
  scenarioLosses: bigint[];
}

export interface PortfolioSnapshot {
  im: bigint;
  bp: bigint;
  health: bigint;
  cStressed: bigint;
  unwindableNow: bigint;
  earningLocked: bigint;
  feeCreditBase: bigint;
  lossR1Base: bigint;
  lossR2: bigint;
  eligR1: number;
  eligR2: number;
  scenarioLosses: bigint[];
}

/** Mirror of SpanMathLib.accountSnapshotUsd. */
export function accountSnapshotUsd(
  stockUsd: bigint,
  lpUsd: bigint,
  feeCreditBase: bigint,
  debt: bigint,
): AccountSnapshot {
  let maxIm = 0n;
  const scenarioLosses: bigint[] = [];

  for (let i = 0; i < SHOCKS.length; i++) {
    for (let j = 0; j < VOLS.length; j++) {
      const sh = (SHOCKS[i] * VOLS[j]) / WAD;
      const absSh = sh < 0n ? -sh : sh;

      const lossStock = sh < 0n ? mulWad(-sh, stockUsd) : 0n;
      const beta = mulWad(LP_BETA, absSh) + mulWad(LP_CONVEX, mulWad(absSh, absSh));
      const lossLp = mulWad(lpUsd, beta);
      const gross = lossStock + lossLp;
      const feeCred = sh < 0n ? mulWad(feeCreditBase, HALF) : feeCreditBase;
      const required = gross > feeCred ? gross - feeCred : 0n;

      scenarioLosses.push(gross);
      if (required > maxIm) maxIm = required;
    }
  }

  const collateral = mulWad(stockUsd, HC_STOCK) + mulWad(lpUsd, HC_LP);
  const cStressed = collateral > maxIm ? collateral - maxIm : 0n;
  const bp = mulWad(cStressed, LTV_MAX);
  const denom = debt > 1_000_000_000_000n ? debt : 1_000_000_000_000n;
  const health = divWad(cStressed, denom);

  return { im: maxIm, bp, health, scenarioLosses };
}

/** Mirror of SpanMathLib.portfolioSnapshotUsd. */
export function portfolioSnapshotUsd(
  stockUsd: bigint,
  lpUsd: bigint,
  equityRwaUsd: bigint,
  navUsd: bigint,
  feeCreditFees: bigint,
  navAccrualCredit: bigint,
  dailyCoupon: bigint,
  debt: bigint,
  transferRestricted: boolean,
  gateOpen: boolean,
  dailyCap: bigint,
): PortfolioSnapshot {
  const totalCollateral = stockUsd + lpUsd + equityRwaUsd + navUsd;
  const feeCap = mulWad(totalCollateral, FEE_CREDIT_CAP);
  const combinedCredit = feeCreditFees + navAccrualCredit;
  const feeCreditBase = combinedCredit < feeCap ? combinedCredit : feeCap;

  const { eligR1, eligR2 } = eligibility(transferRestricted, gateOpen, navUsd, dailyCap);
  const { lossR1: lossR1Base, lossR2 } = rwaStress(equityRwaUsd, navUsd, dailyCoupon, WAD);

  let maxIm = 0n;
  const scenarioLosses: bigint[] = [];

  for (let i = 0; i < SHOCKS.length; i++) {
    for (let j = 0; j < VOLS.length; j++) {
      const sh = (SHOCKS[i] * VOLS[j]) / WAD;
      const absSh = sh < 0n ? -sh : sh;

      const lossStock = sh < 0n ? mulWad(-sh, stockUsd) : 0n;
      const beta = mulWad(LP_BETA, absSh) + mulWad(LP_CONVEX, mulWad(absSh, absSh));
      const lossLp = mulWad(lpUsd, beta);
      const lossR1 = mulWad(lossR1Base, VOLS[j]);
      const gross = lossStock + lossLp + lossR1 + lossR2;
      const feeCred = sh < 0n ? mulWad(feeCreditBase, HALF) : feeCreditBase;
      const required = gross > feeCred ? gross - feeCred : 0n;

      scenarioLosses.push(gross);
      if (required > maxIm) maxIm = required;
    }
  }

  const collateral = mulWad(stockUsd, HC_STOCK) + mulWad(lpUsd, HC_LP)
    + mulWad(equityRwaUsd, HC_R1) + mulWad(navUsd, HC_R2);
  const cStressed = collateral > maxIm ? collateral - maxIm : 0n;
  const bp = mulWad(cStressed, LTV_MAX);
  const denom = debt > 1_000_000_000_000n ? debt : 1_000_000_000_000n;
  const health = divWad(cStressed, denom);

  const { unwindableNow, earningLocked } =
    segregated(stockUsd, lpUsd, equityRwaUsd, navUsd, eligR1, eligR2);

  return {
    im: maxIm,
    bp,
    health,
    cStressed,
    unwindableNow,
    earningLocked,
    feeCreditBase,
    lossR1Base,
    lossR2,
    eligR1,
    eligR2,
    scenarioLosses,
  };
}

/** Keep max imported: useful for asserts in tests and mirrors Solidity WadMath.max. */
export { WAD, divWad, max, mulWad };
