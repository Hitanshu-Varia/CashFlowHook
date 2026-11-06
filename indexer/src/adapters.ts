import { readFile } from "node:fs/promises";
import { getAddress } from "viem";
import type { Address, Hex } from "viem";
import type { FeeSnapshot, NavRecord, TakerQuery } from "./types.js";

/** Adapter boundary: the only place that knows a v4 PositionManager event shape. */
export interface SnapshotSource {
  snapshots(strategyPosId: Hex): Promise<FeeSnapshot[]>;
}

/** Adapter boundary: the only place that knows a v4 Swap event shape. */
export interface TakerSource {
  takers(query: TakerQuery): Promise<string[]>;
}

/** Adapter boundary: the only place that knows OUSG/USDY NAV mechanics. */
export interface NavSource {
  read(asset: Address): Promise<NavRecord>;
}

interface SnapshotFile {
  [posId: string]: Array<{ ts: number; feesOwedWad: string }>;
}

interface TakerFile {
  [poolKey: string]: Array<{ sender: string; ts: number }>;
}

export class FileSnapshotSource implements SnapshotSource {
  constructor(private readonly path: string) {}

  async snapshots(strategyPosId: Hex): Promise<FeeSnapshot[]> {
    const raw = JSON.parse(await readFile(this.path, "utf8")) as SnapshotFile;
    const rows = raw[strategyPosId] ?? raw[strategyPosId.toLowerCase()] ?? [];
    return rows
      .map((row) => ({ ts: Number(row.ts), feesOwedWad: BigInt(row.feesOwedWad) }))
      .sort((a, b) => a.ts - b.ts);
  }
}

export class FileTakerSource implements TakerSource {
  constructor(private readonly path: string) {}

  async takers(query: TakerQuery): Promise<string[]> {
    const raw = JSON.parse(await readFile(this.path, "utf8")) as TakerFile;
    const rows = raw[query.poolKey] ?? raw[query.poolKey.toLowerCase()] ?? [];
    return rows
      .filter((row) => row.ts >= query.from && row.ts <= query.to)
      .map((row) => row.sender);
  }
}

export class StaticNavSource implements NavSource {
  constructor(private readonly records: Map<string, NavRecord>) {}

  async read(asset: Address): Promise<NavRecord> {
    const record = this.records.get(getAddress(asset.toLowerCase()).toLowerCase());
    if (!record) throw new Error(`no static NAV record for ${asset}`);
    return record;
  }
}

/**
 * Live NAV reads are deliberately not guessed. The contract-level schema is stable; the
 * OUSG/USDY read path is isolated here and must be implemented against verified issuer state
 * (see docs/rwa-sources.md and Agent/cashflowhook_v3_agent.md §16.2).
 */
export class UnconfiguredNavSource implements NavSource {
  async read(): Promise<NavRecord> {
    throw new Error(
      "live NAV reads are not configured; set NAV_READ_MODE=static or implement the verified issuer adapter",
    );
  }
}
