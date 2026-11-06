import { createHash } from "node:crypto";
import { encodeAbiParameters, getAddress, isAddress, keccak256, pad } from "viem";
import type { Address, Hex } from "viem";
import type { FeeSnapshot, StreamRecord } from "./types.js";

export const MAX_TAKER_SAMPLE = 64;
export const DAY_SECONDS = 86_400;
export const FEE_WINDOW_DAYS = 7;

export class OwnerInSampleError extends Error {
  constructor() {
    super("sampled taker equals the account owner");
    this.name = "OwnerInSampleError";
  }
}

export function normalizeAddress(value: string): Address {
  // External feeds may use any casing; be strict about the shape, not the checksum.
  if (!isAddress(value, { strict: false })) throw new Error(`invalid address: ${value}`);
  return getAddress(value.toLowerCase());
}

/** Unique, checksummed, sorted, and owner-excluded. Deterministic across runs. */
export function eligibleTakers(raw: readonly string[], exclude: Address): Address[] {
  const owner = normalizeAddress(exclude).toLowerCase();
  const seen = new Set<string>();
  for (const value of raw) {
    const address = normalizeAddress(value);
    const key = address.toLowerCase();
    if (key === owner || seen.has(key)) continue;
    seen.add(key);
  }
  return [...seen]
    .sort()
    .map((key) => getAddress(key));
}

export function sampleTakers(takers: readonly Address[], limit = MAX_TAKER_SAMPLE): Address[] {
  return takers.slice(0, limit);
}

export function takerCsv(takers: readonly Address[]): string {
  return ["taker", ...takers].join("\n") + "\n";
}

export function sha256Hex(value: string): Hex {
  return `0x${createHash("sha256").update(value, "utf8").digest("hex")}`;
}

export function takerSummary(raw: readonly string[], exclude: Address) {
  const takers = eligibleTakers(raw, exclude);
  const sample = sampleTakers(takers);
  const csv = takerCsv(takers);
  return {
    count: takers.length,
    sample,
    csvSha256: sha256Hex(csv),
  };
}

/** Solid ABI-encodes `bytes32[]`; each entry is the left-padded address. */
export function encodeTakerSample(sample: readonly Address[]): Hex {
  const words = sample.map((address) => pad(address.toLowerCase() as Hex, { size: 32 }));
  return encodeAbiParameters([{ type: "bytes32[]" }], [words]);
}

export function takerRoot(sample: readonly Address[]): Hex {
  return keccak256(encodeTakerSample(sample));
}

/**
 * Sums snapshots into seven UTC-day buckets anchored at `windowStartTs`.
 * Snapshots outside the window are ignored. The adapter defines `feesOwedWad` as the delta since
 * the previous snapshot, not a cumulative total.
 */
export function buildDailyFees(
  snapshots: readonly FeeSnapshot[],
  windowStartTs: number,
): [bigint, bigint, bigint, bigint, bigint, bigint, bigint] {
  const totals = [0n, 0n, 0n, 0n, 0n, 0n, 0n];
  for (const snapshot of snapshots) {
    const day = Math.floor((snapshot.ts - windowStartTs) / DAY_SECONDS);
    if (day < 0 || day >= FEE_WINDOW_DAYS) continue;
    if (snapshot.feesOwedWad < 0n) throw new Error("negative fee snapshot");
    totals[day] += snapshot.feesOwedWad;
  }
  return totals as [bigint, bigint, bigint, bigint, bigint, bigint, bigint];
}

export interface BuildStreamRecordInput {
  strategyPosId: Hex;
  excludedOwner: Address;
  windowStartTs: number;
  snapshots: readonly FeeSnapshot[];
  rawTakers: readonly string[];
}

export function buildStreamRecord(input: BuildStreamRecordInput): {
  record: StreamRecord;
  sample: Address[];
} {
  const takers = eligibleTakers(input.rawTakers, input.excludedOwner);
  const sample = sampleTakers(takers);
  if (sample.some((address) => address.toLowerCase() === input.excludedOwner.toLowerCase())) {
    throw new OwnerInSampleError();
  }

  const record: StreamRecord = {
    strategyPosId: input.strategyPosId,
    windowStartTs: BigInt(input.windowStartTs),
    dailyFees: buildDailyFees(input.snapshots, input.windowStartTs),
    distinctTakers: BigInt(takers.length),
    excludedOwner: normalizeAddress(input.excludedOwner),
    rootHash: takerRoot(sample),
  };
  return { record, sample };
}

/** Deterministic default: the last fully closed seven-day window. */
export function defaultWindowStart(nowSeconds: number): number {
  const today = Math.floor(nowSeconds / DAY_SECONDS) * DAY_SECONDS;
  return today - FEE_WINDOW_DAYS * DAY_SECONDS;
}
