/**
 * WAD (1e18) helpers that match the Solidity library exactly.
 * Solidity `Math.mulDiv` floors; BigInt division truncates toward zero.
 * Every value in this project is non-negative, so floor and truncation coincide.
 */

export const WAD = 10n ** 18n;
export const MAX_GRID_VALUE = 10n ** 40n;

export function mulWad(a: bigint, b: bigint): bigint {
  return (a * b) / WAD;
}

export function divWad(a: bigint, b: bigint): bigint {
  if (b === 0n) return 0n;
  return (a * WAD) / b;
}

export function min(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
}

export function max(a: bigint, b: bigint): bigint {
  return a > b ? a : b;
}

export function abs(a: bigint): bigint {
  return a < 0n ? -a : a;
}

/** Floor square root, matching OpenZeppelin Math.sqrt. */
export function sqrt(value: bigint): bigint {
  if (value < 0n) throw new Error("sqrt of negative");
  if (value < 2n) return value;
  let z = value;
  let x = value / 2n + 1n;
  while (x < z) {
    z = x;
    x = (value / x + x) / 2n;
  }
  return z;
}

export function checkGrid(value: bigint): bigint {
  if (value > MAX_GRID_VALUE) throw new Error("GridOverflow");
  return value;
}

export function toWadString(value: bigint): string {
  return value.toString();
}
