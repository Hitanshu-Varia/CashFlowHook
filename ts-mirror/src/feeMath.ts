import { WAD, divWad, min, mulWad, sqrt } from "./wad";

export const TAKER_FLOOR = 5n;
export const TAKER_SCALE = 20n;
export const VOL_PENALTY = 500_000_000_000_000_000n;
export const DD_PENALTY = 300_000_000_000_000_000n;
export const SCORE_WAD = 100_000_000_000_000_000_000n;
export const HALF = 500_000_000_000_000_000n;

export function avg7d(dailyFees: readonly bigint[]): bigint {
  if (dailyFees.length !== 7) throw new Error("expected 7 daily fees");
  let sum = 0n;
  for (const fee of dailyFees) sum += fee;
  return sum / 7n;
}

export function sigmaN(dailyFees: readonly bigint[], mean: bigint): bigint {
  if (mean === 0n) return 0n;
  let variance = 0n;
  for (const fee of dailyFees) {
    const diff = fee > mean ? fee - mean : mean - fee;
    variance += mulWad(diff, diff);
  }
  variance /= 7n;
  const sigma = sqrt(variance);
  const normalized = divWad(sigma, mean);
  return min(normalized, WAD);
}

export function drawdownN(dailyFees: readonly bigint[]): bigint {
  let peak = 0n;
  let maxDd = 0n;
  for (const fee of dailyFees) {
    if (fee > peak) peak = fee;
    if (peak > 0n) {
      const dd = peak > fee ? divWad(peak - fee, peak) : 0n;
      if (dd > maxDd) maxDd = dd;
    }
  }
  return min(maxDd, WAD);
}

/** Mirror of FeeMathLib.feeCreditFees (before the combined 10% cap). */
export function feeCreditFees(dailyFees: readonly bigint[], distinctTakers: bigint): bigint {
  if (distinctTakers < TAKER_FLOOR) return 0n;

  const mean = avg7d(dailyFees);
  if (mean === 0n) return 0n;

  const takerFactor = distinctTakers >= TAKER_SCALE ? WAD : divWad(distinctTakers, TAKER_SCALE);
  const volPenalty = WAD - mulWad(VOL_PENALTY, sigmaN(dailyFees, mean));
  const ddPenalty = WAD - mulWad(DD_PENALTY, drawdownN(dailyFees));

  let credit = mean * 3n;
  credit = mulWad(credit, takerFactor);
  credit = mulWad(credit, volPenalty);
  credit = mulWad(credit, ddPenalty);
  return credit;
}

/** Mirror of FeeMathLib.strategyScore. Returns a JS number in 0..100. */
export function strategyScore(
  dailyFees: readonly bigint[],
  distinctTakers: bigint,
  ageDays: bigint,
): number {
  if (distinctTakers < TAKER_FLOOR) return 0;

  const mean = avg7d(dailyFees);
  const sigma = sigmaN(dailyFees, mean);
  const dd = drawdownN(dailyFees);
  const ageFactor = ageDays >= 7n ? WAD : divWad(ageDays, 7n);

  const raw = mulWad(HALF, WAD - sigma) + mulWad(300_000_000_000_000_000n, WAD - dd)
    + mulWad(200_000_000_000_000_000n, ageFactor);
  const scoreWad = mulWad(raw, SCORE_WAD);
  const rounded = (scoreWad + HALF) / WAD;
  return Number(rounded > 100n ? 100n : rounded);
}

/** Mirror of FeeMathLib.combinedCredit. */
export function combinedCredit(
  feeCredit: bigint,
  navAccrualCredit: bigint,
  totalCollateralUsd: bigint,
): bigint {
  const cap = mulWad(totalCollateralUsd, 100_000_000_000_000_000n);
  const combined = feeCredit + navAccrualCredit;
  return min(combined, cap);
}

export { WAD, divWad, min, mulWad, sqrt };
