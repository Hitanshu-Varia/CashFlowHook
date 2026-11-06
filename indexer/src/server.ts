import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { loadEnvFile } from "node:process";
import { getAddress, isAddress } from "viem";
import type { Address, Hex } from "viem";
import {
  FileSnapshotSource,
  FileTakerSource,
  OndoUsdyNavSource,
  StaticNavSource,
  UnconfiguredNavSource,
} from "./adapters.js";
import type { NavSource, SnapshotSource, TakerSource } from "./adapters.js";
import { buildStreamRecord, defaultWindowStart, OwnerInSampleError, takerSummary } from "./events.js";
import type { NavOracleClient, StreamOracleClient } from "./oracle.js";
import { Eip712Signer } from "./signer.js";
import { MemoryStore, SqliteStore } from "./store.js";
import type { Store } from "./store.js";
import type { NavRecord, StreamRecord } from "./types.js";

export interface AppDeps {
  store: Store;
  clock?: () => number;
  snapshotSource?: SnapshotSource;
  takerSource?: TakerSource;
  navSource?: NavSource;
  streamSigner?: { signStream(record: StreamRecord): Promise<Hex> };
  streamOracle?: StreamOracleClient;
  navSigner?: { signNav(record: NavRecord): Promise<Hex> };
  navOracle?: NavOracleClient;
}

const ZERO_ADDRESS: Address = "0x0000000000000000000000000000000000000000";
const DAY = 86_400;

function json(res: ServerResponse, status: number, body: unknown): void {
  const text = JSON.stringify(body, (_key, value) =>
    typeof value === "bigint" ? value.toString() : value,
  );
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type",
  });
  res.end(text);
}

async function body(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buffer = Buffer.from(chunk);
    size += buffer.length;
    if (size > 1_000_000) throw new Error("body too large");
    chunks.push(buffer);
  }
  if (chunks.length === 0) return {};
  const value = JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("body must be a JSON object");
  }
  return value as Record<string, unknown>;
}

function requireAddress(value: unknown, field: string): Address {
  if (typeof value !== "string" || !isAddress(value, { strict: false })) {
    throw new Error(`invalid ${field}`);
  }
  return getAddress(value.toLowerCase());
}

function parseInteger(value: string | null, fallback: number): number {
  if (value === null) return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) throw new Error("invalid integer");
  return parsed;
}

export function createApp(deps: AppDeps): Server {
  const clock = deps.clock ?? (() => Math.floor(Date.now() / 1000));

  return createServer(async (req, res) => {
    if (req.method === "OPTIONS") {
      json(res, 204, {});
      return;
    }
    const url = new URL(req.url ?? "/", "http://localhost");
    const parts = url.pathname.split("/").filter(Boolean).map(decodeURIComponent);

    try {
      if (req.method === "GET" && parts.length === 1 && parts[0] === "health") {
        json(res, 200, { ok: true });
        return;
      }

      if (req.method === "GET" && parts[0] === "snapshots" && parts.length === 2) {
        if (!deps.snapshotSource) return json(res, 503, { error: "snapshot source not configured" });
        const snapshots = await deps.snapshotSource.snapshots(parts[1] as Hex);
        return json(
          res,
          200,
          snapshots.map((row) => ({ ts: row.ts, feesOwedWad: row.feesOwedWad.toString() })),
        );
      }

      if (req.method === "GET" && parts[0] === "takers" && parts.length === 2) {
        if (!deps.takerSource) return json(res, 503, { error: "taker source not configured" });
        const exclude = requireAddress(url.searchParams.get("exclude") ?? ZERO_ADDRESS, "exclude");
        const from = parseInteger(url.searchParams.get("from"), 0);
        const to = parseInteger(url.searchParams.get("to"), clock());
        if (to < from) return json(res, 400, { error: "to must be >= from" });
        const raw = await deps.takerSource.takers({
          poolKey: parts[1],
          from,
          to,
          exclude,
        });
        return json(res, 200, takerSummary(raw, exclude));
      }

      if (req.method === "POST" && parts[0] === "records" && parts.length === 2) {
        if (!deps.snapshotSource || !deps.takerSource || !deps.streamSigner || !deps.streamOracle) {
          return json(res, 503, { error: "record posting is not configured" });
        }
        const input = await body(req);
        const owner = requireAddress(input.owner, "owner");
        const windowStartTs =
          input.windowStartTs === undefined
            ? defaultWindowStart(clock())
            : Number(input.windowStartTs);
        if (!Number.isSafeInteger(windowStartTs) || windowStartTs < 0) {
          return json(res, 400, { error: "invalid windowStartTs" });
        }
        const posId = parts[1] as Hex;
        const poolKey =
          typeof input.poolKey === "string" && input.poolKey.length > 0 ? input.poolKey : posId;

        const snapshots = await deps.snapshotSource.snapshots(posId);
        const rawTakers = await deps.takerSource.takers({
          poolKey,
          from: windowStartTs,
          to: windowStartTs + 7 * DAY - 1,
          exclude: owner,
        });
        const built = buildStreamRecord({
          strategyPosId: posId,
          excludedOwner: owner,
          windowStartTs,
          snapshots,
          rawTakers,
        });
        const signature = await deps.streamSigner.signStream(built.record);
        const txHash = await deps.streamOracle.postRecord(signature, built.record, built.sample);
        const postedAt = clock();
        deps.store.saveStreamRecord(built.record, txHash, postedAt);
        return json(res, 200, {
          txHash,
          rootHash: built.record.rootHash,
          distinctTakers: built.record.distinctTakers.toString(),
          windowStartTs: built.record.windowStartTs.toString(),
        });
      }

      if (req.method === "GET" && parts[0] === "nav" && parts.length === 2) {
        const asset = requireAddress(parts[1], "asset");
        const record = deps.store.latestNavRecord(asset);
        if (!record) return json(res, 404, { error: "no posted NAV record" });
        return json(res, 200, record);
      }

      if (req.method === "GET" && parts[0] === "nav" && parts[1] === "source" && parts.length === 3) {
        if (!deps.navSource) return json(res, 503, { error: "NAV source not configured" });
        const asset = requireAddress(parts[2], "asset");
        const record = await deps.navSource.read(asset);
        if (record.asset.toLowerCase() !== asset.toLowerCase()) {
          return json(res, 502, { error: "NAV source returned a different asset" });
        }
        return json(res, 200, record);
      }

      if (req.method === "POST" && parts[0] === "nav" && parts.length === 2) {
        if (!deps.navSource || !deps.navSigner || !deps.navOracle) {
          return json(res, 503, { error: "NAV posting is not configured" });
        }
        const requested = requireAddress(parts[1], "asset");
        const record = await deps.navSource.read(requested);
        if (record.asset.toLowerCase() !== requested.toLowerCase()) {
          return json(res, 400, { error: "NAV source returned a different asset" });
        }
        // Canonicalize the casing so the stored key matches later reads.
        const normalized: NavRecord = { ...record, asset: requested };
        const signature = await deps.navSigner.signNav(normalized);
        const txHash = await deps.navOracle.postNav(signature, normalized);
        deps.store.saveNavRecord(normalized, txHash, clock());
        return json(res, 200, { txHash, sourceTxHash: normalized.sourceTxHash });
      }

      json(res, 404, { error: "not found" });
    } catch (error) {
      if (error instanceof OwnerInSampleError) {
        json(res, 409, { error: error.message });
        return;
      }
      const message = error instanceof Error ? error.message : "unexpected error";
      const status = message.startsWith("invalid") ? 400 : 500;
      json(res, status, { error: message });
    }
  });
}

interface StaticNavFile {
  [asset: string]: {
    navPerShareWad: string;
    accrualPerSecondWad: string;
    observedAt: number | string;
    gateOpen: boolean;
    sourceTxHash: string;
  };
}

async function loadStaticNav(path: string): Promise<NavSource> {
  const { readFile } = await import("node:fs/promises");
  const raw = JSON.parse(await readFile(path, "utf8")) as StaticNavFile;
  const records = new Map<string, NavRecord>();
  for (const [asset, value] of Object.entries(raw)) {
    if (!isAddress(asset)) throw new Error(`invalid static NAV asset: ${asset}`);
    records.set(getAddress(asset).toLowerCase(), {
      asset: getAddress(asset),
      navPerShareWad: BigInt(value.navPerShareWad),
      accrualPerSecondWad: BigInt(value.accrualPerSecondWad),
      observedAt: BigInt(value.observedAt),
      gateOpen: value.gateOpen,
      sourceTxHash: value.sourceTxHash as Hex,
    });
  }
  return new StaticNavSource(records);
}

function env(name: string): string | undefined {
  const value = process.env[name];
  return value && value.length > 0 ? value : undefined;
}

function envAddress(name: string): Address | undefined {
  const value = env(name);
  if (!value) return undefined;
  if (!isAddress(value, { strict: false })) throw new Error(`invalid ${name}`);
  return getAddress(value);
}

export async function startFromEnv(): Promise<Server> {
  const projectEnvFile = resolve(dirname(fileURLToPath(import.meta.url)), "../../.env");
  if (existsSync(projectEnvFile)) loadEnvFile(projectEnvFile);

  const port = Number(env("INDEXER_PORT") ?? 8787);
  const chainId = Number(env("CHAIN_ID") ?? 8453);

  let store: Store;
  if (env("INDEXER_STORE") === "memory") {
    store = new MemoryStore();
  } else {
    const dbPath = resolve(env("INDEXER_DB") ?? "indexer.sqlite");
    mkdirSync(dirname(dbPath), { recursive: true });
    store = new SqliteStore(dbPath);
  }

  const snapshotPath = env("INDEXER_SNAPSHOTS_FILE");
  const takerPath = env("INDEXER_TAKERS_FILE");
  const navPath = env("INDEXER_NAV_STATIC_FILE");
  const navMode = env("NAV_READ_MODE") ?? (navPath ? "static" : "unconfigured");

  const streamKey = (env("ORACLE_SIGNER_KEY") ?? env("ORACLE_PK")) as Hex | undefined;
  const navKey = (env("NAV_SIGNER_KEY") ?? env("NAV_PK")) as Hex | undefined;
  const rpcUrl = chainId === 84532 ? env("RPC_BASE_SEPOLIA") : env("RPC_FORK_URL");
  const feeOracleAddress = env("FEE_STREAM_ORACLE_ADDR") as Address | undefined;
  const navOracleAddress = env("NAV_SIGNAL_ORACLE_ADDR") as Address | undefined;

  const { ViemNavOracleClient, ViemStreamOracleClient } = await import("./oracle.js");

  let navSource: NavSource;
  if (navPath) {
    navSource = await loadStaticNav(navPath);
  } else if (navMode === "ondo-usdy") {
    const ethRpcUrl = env("RPC_ETH_MAINNET");
    if (!ethRpcUrl) throw new Error("RPC_ETH_MAINNET is required when NAV_READ_MODE=ondo-usdy");
    navSource = new OndoUsdyNavSource({
      rpcUrl: ethRpcUrl,
      asset: envAddress("USDY_ADDR_ETH"),
      instantManager: envAddress("USDY_INSTANT_MANAGER_ETH"),
      oracleWrapper: envAddress("USDY_ORACLE_WRAPPER_ETH"),
      // Supply this only to pin a reviewed implementation during an issuer migration.
      continuousOracle: envAddress("USDY_CONTINUOUS_ORACLE_ETH"),
    });
  } else if (navMode === "unconfigured" || navMode === "static") {
    navSource = new UnconfiguredNavSource();
  } else {
    throw new Error(`unsupported NAV_READ_MODE: ${navMode}`);
  }

  const deps: AppDeps = {
    store,
    snapshotSource: snapshotPath ? new FileSnapshotSource(snapshotPath) : undefined,
    takerSource: takerPath ? new FileTakerSource(takerPath) : undefined,
    navSource,
    streamSigner:
      streamKey && feeOracleAddress
        ? new Eip712Signer(streamKey, chainId, feeOracleAddress)
        : undefined,
    navSigner:
      navKey && navOracleAddress ? new Eip712Signer(navKey, chainId, navOracleAddress) : undefined,
  };

  if (rpcUrl && streamKey && feeOracleAddress) {
    deps.streamOracle = new ViemStreamOracleClient({
      rpcUrl,
      privateKey: streamKey,
      chainId,
      oracleAddress: feeOracleAddress,
    });
  }
  if (rpcUrl && navKey && navOracleAddress) {
    deps.navOracle = new ViemNavOracleClient({
      rpcUrl,
      privateKey: navKey,
      chainId,
      oracleAddress: navOracleAddress,
    });
  }

  const server = createApp(deps);
  await new Promise<void>((resolveListen) => server.listen(port, resolveListen));
  console.log(`cashflowhook indexer listening on :${port}`);
  return server;
}

const isMain = process.argv[1] ? import.meta.url === pathToFileURL(process.argv[1]).href : false;
if (isMain) {
  startFromEnv().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
