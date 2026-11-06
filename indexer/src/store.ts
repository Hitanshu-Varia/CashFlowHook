import { createRequire } from "node:module";
import type { DatabaseSync } from "node:sqlite";
import type { Address, Hex } from "viem";
import type { NavRecord, StoredNavRecord, StoredStreamRecord, StreamRecord } from "./types.js";

const require = createRequire(import.meta.url);

export interface Store {
  saveStreamRecord(record: StreamRecord, txHash: Hex, postedAt: number): void;
  latestStreamRecord(strategyPosId: Hex): StoredStreamRecord | null;
  saveNavRecord(record: NavRecord, txHash: Hex, postedAt: number): void;
  latestNavRecord(asset: Address): StoredNavRecord | null;
  close(): void;
}

export class SqliteStore implements Store {
  private readonly db: DatabaseSync;

  constructor(path: string) {
    // Loaded lazily so bundlers/tests that only use MemoryStore never resolve the builtin.
    const { DatabaseSync } = require("node:sqlite") as typeof import("node:sqlite");
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS stream_records (
        strategy_pos_id TEXT PRIMARY KEY,
        window_start_ts TEXT NOT NULL,
        daily_fees TEXT NOT NULL,
        distinct_takers TEXT NOT NULL,
        excluded_owner TEXT NOT NULL,
        root_hash TEXT NOT NULL,
        tx_hash TEXT NOT NULL,
        posted_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS nav_records (
        asset TEXT PRIMARY KEY,
        nav_per_share_wad TEXT NOT NULL,
        accrual_per_second_wad TEXT NOT NULL,
        observed_at TEXT NOT NULL,
        gate_open INTEGER NOT NULL,
        source_tx_hash TEXT NOT NULL,
        tx_hash TEXT NOT NULL,
        posted_at INTEGER NOT NULL
      );
    `);
  }

  saveStreamRecord(record: StreamRecord, txHash: Hex, postedAt: number): void {
    this.db
      .prepare(
        `INSERT INTO stream_records
          (strategy_pos_id, window_start_ts, daily_fees, distinct_takers, excluded_owner,
           root_hash, tx_hash, posted_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(strategy_pos_id) DO UPDATE SET
           window_start_ts=excluded.window_start_ts,
           daily_fees=excluded.daily_fees,
           distinct_takers=excluded.distinct_takers,
           excluded_owner=excluded.excluded_owner,
           root_hash=excluded.root_hash,
           tx_hash=excluded.tx_hash,
           posted_at=excluded.posted_at`,
      )
      .run(
        record.strategyPosId,
        record.windowStartTs.toString(),
        record.dailyFees.map(String).join(","),
        record.distinctTakers.toString(),
        record.excludedOwner,
        record.rootHash,
        txHash,
        postedAt,
      );
  }

  latestStreamRecord(strategyPosId: Hex): StoredStreamRecord | null {
    const row = this.db
      .prepare("SELECT * FROM stream_records WHERE strategy_pos_id = ?")
      .get(strategyPosId) as Record<string, unknown> | undefined;
    if (!row) return null;

    const dailyFees = String(row.daily_fees).split(",").map(BigInt);
    const record: StreamRecord = {
      strategyPosId: row.strategy_pos_id as Hex,
      windowStartTs: BigInt(String(row.window_start_ts)),
      dailyFees: dailyFees as StreamRecord["dailyFees"],
      distinctTakers: BigInt(String(row.distinct_takers)),
      excludedOwner: row.excluded_owner as Address,
      rootHash: row.root_hash as Hex,
    };
    return {
      strategyPosId: record.strategyPosId,
      windowStartTs: record.windowStartTs,
      rootHash: record.rootHash,
      txHash: row.tx_hash as Hex,
      postedAt: Number(row.posted_at),
      record,
    };
  }

  saveNavRecord(record: NavRecord, txHash: Hex, postedAt: number): void {
    this.db
      .prepare(
        `INSERT INTO nav_records
          (asset, nav_per_share_wad, accrual_per_second_wad, observed_at, gate_open,
           source_tx_hash, tx_hash, posted_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(asset) DO UPDATE SET
           nav_per_share_wad=excluded.nav_per_share_wad,
           accrual_per_second_wad=excluded.accrual_per_second_wad,
           observed_at=excluded.observed_at,
           gate_open=excluded.gate_open,
           source_tx_hash=excluded.source_tx_hash,
           tx_hash=excluded.tx_hash,
           posted_at=excluded.posted_at`,
      )
      .run(
        record.asset,
        record.navPerShareWad.toString(),
        record.accrualPerSecondWad.toString(),
        record.observedAt.toString(),
        record.gateOpen ? 1 : 0,
        record.sourceTxHash,
        txHash,
        postedAt,
      );
  }

  latestNavRecord(asset: Address): StoredNavRecord | null {
    const row = this.db
      .prepare("SELECT * FROM nav_records WHERE asset = ?")
      .get(asset) as Record<string, unknown> | undefined;
    if (!row) return null;
    return {
      asset: row.asset as Address,
      navPerShareWad: BigInt(String(row.nav_per_share_wad)),
      accrualPerSecondWad: BigInt(String(row.accrual_per_second_wad)),
      observedAt: BigInt(String(row.observed_at)),
      gateOpen: Number(row.gate_open) === 1,
      sourceTxHash: row.source_tx_hash as Hex,
      txHash: row.tx_hash as Hex,
      postedAt: Number(row.posted_at),
    };
  }

  close(): void {
    this.db.close();
  }
}

/** In-memory implementation used by tests and by `INDEXER_STORE=memory`. */
export class MemoryStore implements Store {
  private readonly streams = new Map<string, StoredStreamRecord>();
  private readonly nav = new Map<string, StoredNavRecord>();

  saveStreamRecord(record: StreamRecord, txHash: Hex, postedAt: number): void {
    this.streams.set(record.strategyPosId, {
      strategyPosId: record.strategyPosId,
      windowStartTs: record.windowStartTs,
      rootHash: record.rootHash,
      txHash,
      postedAt,
      record,
    });
  }

  latestStreamRecord(strategyPosId: Hex): StoredStreamRecord | null {
    return this.streams.get(strategyPosId) ?? null;
  }

  saveNavRecord(record: NavRecord, txHash: Hex, postedAt: number): void {
    this.nav.set(record.asset, { ...record, txHash, postedAt });
  }

  latestNavRecord(asset: Address): StoredNavRecord | null {
    return this.nav.get(asset) ?? null;
  }

  close(): void {}
}
