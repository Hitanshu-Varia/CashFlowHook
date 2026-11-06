import { WAD, divWad, min, mulWad } from "./wad";

export const HC_R1 = 750_000_000_000_000_000n;
export const HC_R2 = 850_000_000_000_000_000n;
export const GAP_PREMIUM = 500_000_000_000_000_000n;
export const PERM_LIQ_HC = 15_000_000_000_000_000n;
export const EXIT_COST_NAV = 5_000_000_000_000_000n;
export const GATE_DAYS = 2n;
export const CAP_FRACTION = 250_000_000_000_000_000n;
export const SHOCK_20 = 200_000_000_000_000_000n;

export interface RwaStressResult {
  lossR1: bigint;
  lossR2: bigint;
}

export interface EligibilityResult {
  eligR1: number;
  eligR2: number;
}

export interface SegregationResult {
  unwindableNow: bigint;
  earningLocked: bigint;
}

/** Mirror of RwaStressLib.rwaStress. */
export function rwaStress(
  equityRwaUsd: bigint,
  navUsd: bigint,
  dailyCoupon: bigint,
  volMul: bigint,
): RwaStressResult {
  let lossR1 = mulWad(equityRwaUsd, SHOCK_20);
  lossR1 = mulWad(lossR1, WAD + GAP_PREMIUM);
  lossR1 = mulWad(lossR1, volMul);

  const perm = mulWad(navUsd, PERM_LIQ_HC);
  const exitCost = mulWad(navUsd, EXIT_COST_NAV);
  const couponCost = dailyCoupon * GATE_DAYS;
  const lossR2 = perm + min(exitCost, couponCost);

  return { lossR1, lossR2 };
}

/** Mirror of RwaStressLib.eligibility. */
export function eligibility(
  transferRestricted: boolean,
  gateOpen: boolean,
  navUsd: bigint,
  dailyCap: bigint,
): EligibilityResult {
  const eligR1 = transferRestricted ? 0 : 1;
  const capLimit = mulWad(dailyCap, CAP_FRACTION);
  const eligR2 = gateOpen && navUsd <= capLimit ? 1 : 0;
  return { eligR1, eligR2 };
}

/** Mirror of RwaStressLib.segregated. */
export function segregated(
  stockUsd: bigint,
  lpUsd: bigint,
  equityRwaUsd: bigint,
  navUsd: bigint,
  eligR1: number,
  eligR2: number,
): SegregationResult {
  const stockHc = mulWad(stockUsd, 850_000_000_000_000_000n);
  const lpHc = mulWad(lpUsd, 700_000_000_000_000_000n);
  const r1Hc = mulWad(equityRwaUsd, HC_R1);
  const r2Hc = mulWad(navUsd, HC_R2);

  let unwindableNow = stockHc + lpHc;
  if (eligR1 === 1) unwindableNow += r1Hc;
  if (eligR2 === 1) unwindableNow += r2Hc;

  const earningLocked = stockHc + lpHc + r1Hc + r2Hc - unwindableNow;
  return { unwindableNow, earningLocked };
}

/** Explicit re-export keeps the module surface easy to audit. */
export { WAD, divWad, min, mulWad };
