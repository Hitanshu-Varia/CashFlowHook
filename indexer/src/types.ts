import type { Address, Hex } from "viem";

export interface FeeSnapshot {
  /** Unix seconds of the snapshot. */
  ts: number;
  /** Fees owed by third-party takers since the previous snapshot, USD-WAD. */
  feesOwedWad: bigint;
}

export interface StreamRecord {
  strategyPosId: Hex;
  windowStartTs: bigint;
  dailyFees: [bigint, bigint, bigint, bigint, bigint, bigint, bigint];
  distinctTakers: bigint;
  excludedOwner: Address;
  rootHash: Hex;
}

export interface NavRecord {
  asset: Address;
  navPerShareWad: bigint;
  accrualPerSecondWad: bigint;
  observedAt: bigint;
  gateOpen: boolean;
  sourceTxHash: Hex;
}

export interface StoredStreamRecord {
  strategyPosId: Hex;
  windowStartTs: bigint;
  rootHash: Hex;
  txHash: Hex;
  postedAt: number;
  record: StreamRecord;
}

export interface StoredNavRecord extends NavRecord {
  txHash: Hex;
  postedAt: number;
}

export interface TakerQuery {
  poolKey: string;
  from: number;
  to: number;
  exclude: Address;
}
