import { afterEach, describe, expect, it } from "vitest";
import type { AddressInfo } from "node:net";
import { keccak256, recoverTypedDataAddress, toHex } from "viem";
import type { Address, Hex } from "viem";
import { createApp } from "../src/server.js";
import type { SnapshotSource, TakerSource } from "../src/adapters.js";
import { StaticNavSource } from "../src/adapters.js";
import type { NavOracleClient, StreamOracleClient } from "../src/oracle.js";
import { Eip712Signer, STREAM_TYPES } from "../src/signer.js";
import { MemoryStore } from "../src/store.js";
import type { NavRecord, StreamRecord, TakerQuery } from "../src/types.js";

const OWNER: Address = "0x0000000000000000000000000000000000000b0b";
const A: Address = "0x0000000000000000000000000000000000000a01";
const B: Address = "0x0000000000000000000000000000000000000a02";
const FEE_ORACLE: Address = "0x000000000000000000000000000000000000F00D";
const NAV_ORACLE: Address = "0x0000000000000000000000000000000000000a11";
const POS: Hex = keccak256(toHex("position-1"));
const ASSET: Address = "0x0000000000000000000000000000000000000e02";
const NOW = 1_800_000_000;
const CHAIN_ID = 8453;

class FakeSnapshots implements SnapshotSource {
  async snapshots() {
    return [
      { ts: NOW - 7 * 86_400, feesOwedWad: 10n },
      { ts: NOW - 6 * 86_400, feesOwedWad: 20n },
    ];
  }
}

class FakeTakers implements TakerSource {
  queries: TakerQuery[] = [];
  async takers(query: TakerQuery) {
    this.queries.push(query);
    return [A, B, OWNER];
  }
}

class FakeStreamOracle implements StreamOracleClient {
  last: { signature: Hex; record: StreamRecord; sample: readonly Address[] } | null = null;
  async postRecord(signature: Hex, record: StreamRecord, sample: readonly Address[]) {
    this.last = { signature, record, sample };
    return keccak256(toHex("fee-tx")) as Hex;
  }
}

class FakeNavOracle implements NavOracleClient {
  last: { signature: Hex; record: NavRecord } | null = null;
  async postNav(signature: Hex, record: NavRecord) {
    this.last = { signature, record };
    return keccak256(toHex("nav-tx")) as Hex;
  }
}

function navRecord(asset: Address): NavRecord {
  return {
    asset,
    navPerShareWad: 1_020_000_000_000_000_000n,
    accrualPerSecondWad: 1_000_000_000_000n,
    observedAt: BigInt(NOW - 60),
    gateOpen: true,
    sourceTxHash: keccak256(toHex("nav-source")),
  };
}

function setup() {
  const store = new MemoryStore();
  const snapshots = new FakeSnapshots();
  const takers = new FakeTakers();
  const streamOracle = new FakeStreamOracle();
  const navOracle = new FakeNavOracle();
  const signer = new Eip712Signer(`0x${"11".repeat(32)}`, CHAIN_ID, FEE_ORACLE);
  const navSigner = new Eip712Signer(`0x${"22".repeat(32)}`, CHAIN_ID, NAV_ORACLE);
  const nav = navRecord(ASSET);
  const server = createApp({
    store,
    clock: () => NOW,
    snapshotSource: snapshots,
    takerSource: takers,
    navSource: new StaticNavSource(new Map([[ASSET.toLowerCase(), nav]])),
    streamSigner: signer,
    streamOracle,
    navSigner,
    navOracle,
  });
  return { store, takers, streamOracle, navOracle, signer, nav, server };
}

const servers: ReturnType<typeof createApp>[] = [];

async function listen(server: ReturnType<typeof createApp>): Promise<string> {
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const port = (server.address() as AddressInfo).port;
  return `http://127.0.0.1:${port}`;
}

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map(
      (server) => new Promise<void>((resolve) => server.close(() => resolve())),
    ),
  );
});

describe("indexer HTTP surface", () => {
  it("serves fee snapshots as decimal strings", async () => {
    const { server } = setup();
    const base = await listen(server);
    const response = await fetch(`${base}/snapshots/${POS}`);
    expect(response.status).toBe(200);
    const rows = (await response.json()) as Array<{ ts: number; feesOwedWad: string }>;
    expect(rows).toEqual([
      { ts: NOW - 7 * 86_400, feesOwedWad: "10" },
      { ts: NOW - 6 * 86_400, feesOwedWad: "20" },
    ]);
  });

  it("returns an owner-excluded taker summary", async () => {
    const { server } = setup();
    const base = await listen(server);
    const response = await fetch(`${base}/takers/pool-1?from=0&to=${NOW}&exclude=${OWNER}`);
    expect(response.status).toBe(200);
    const summary = (await response.json()) as {
      count: number;
      sample: string[];
      csvSha256: string;
    };
    expect(summary.count).toBe(2);
    expect(summary.sample.map((s) => s.toLowerCase())).toEqual([A.toLowerCase(), B.toLowerCase()]);
    expect(summary.csvSha256).toMatch(/^0x[0-9a-f]{64}$/);
  });

  it("builds, signs, and posts a stream record", async () => {
    const { server, store, streamOracle, signer } = setup();
    const base = await listen(server);
    const response = await fetch(`${base}/records/${POS}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ owner: OWNER }),
    });
    expect(response.status).toBe(200);
    const result = (await response.json()) as {
      txHash: string;
      rootHash: string;
      distinctTakers: string;
      windowStartTs: string;
    };
    expect(result.distinctTakers).toBe("2");
    expect(result.windowStartTs).toBe(String(1799366400));
    expect(store.latestStreamRecord(POS)?.rootHash).toBe(result.rootHash);

    const signed = streamOracle.last!;
    const recovered = await recoverTypedDataAddress({
      domain: {
        name: "CashflowHook",
        version: "1",
        chainId: CHAIN_ID,
        verifyingContract: FEE_ORACLE,
      },
      types: STREAM_TYPES,
      primaryType: "StreamRecord",
      message: signed.record,
      signature: signed.signature,
    });
    expect(recovered).toBe(signer.address);
    expect(signed.sample.map((s) => s.toLowerCase())).toEqual([
      A.toLowerCase(),
      B.toLowerCase(),
    ]);
  });

  it("rejects a record request without an owner", async () => {
    const { server } = setup();
    const base = await listen(server);
    const response = await fetch(`${base}/records/${POS}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(response.status).toBe(400);
  });

  it("posts and reads a NAV record", async () => {
    const { server, navOracle, nav } = setup();
    const base = await listen(server);
    const post = await fetch(`${base}/nav/${ASSET}`, { method: "POST" });
    expect(post.status).toBe(200);
    expect(await post.json()).toEqual({
      txHash: keccak256(toHex("nav-tx")),
      sourceTxHash: nav.sourceTxHash,
    });
    expect(navOracle.last?.record.asset).toBe(ASSET);

    const read = await fetch(`${base}/nav/${ASSET}`);
    expect(read.status).toBe(200);
    const stored = (await read.json()) as { navPerShareWad: string; gateOpen: boolean };
    expect(stored.navPerShareWad).toBe("1020000000000000000");
    expect(stored.gateOpen).toBe(true);
  });

  it("returns 404 for an unposted NAV asset", async () => {
    const { server } = setup();
    const base = await listen(server);
    const response = await fetch(`${base}/nav/${"0x00000000000000000000000000000000000000ff"}`);
    expect(response.status).toBe(404);
  });

  it("returns 503 when record posting is not configured", async () => {
    const server = createApp({ store: new MemoryStore(), clock: () => NOW });
    const base = await listen(server);
    const response = await fetch(`${base}/records/${POS}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ owner: OWNER }),
    });
    expect(response.status).toBe(503);
  });
});
