import { readFile } from "node:fs/promises";
import { createPublicClient, getAddress, http, parseAbi, parseAbiItem } from "viem";
import type { AbiEvent, Address, Hex, PublicClient } from "viem";
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
 * Official Ethereum addresses from Ondo's contract-address documentation, retrieved 2026-11-06.
 * The wrapper is deliberately used as the stable entry point, while the implementation address
 * is checked on every read before its rate state is consumed.
 */
export const ONDO_USDY_ETHEREUM = {
  asset: getAddress("0x96F6eF951840721AdBF46Ac996b59E0235CB985C"),
  instantManager: getAddress("0xa42613C243b67BF6194Ac327795b926B4b491f15"),
  oracleWrapper: getAddress("0x87b126e5518b6a1Bb8465779b4607C45C643DF90"),
  continuousOracleAsListedByOndo: getAddress("0xbAEC2b9fE27cD054e1c0C2B720aF117d9D7eC871"),
} as const;

const USDY_ORACLE_WRAPPER_ABI = parseAbi([
  "function getPriceData() view returns (uint256 price, uint256 timestamp)",
  "function rwaOracle() view returns (address)",
]);

const CONTINUOUS_PRICE_ORACLE_ABI = parseAbi([
  "function currentYearlyRate() view returns (uint64)",
  "function nextRateStart() view returns (uint64)",
  "function nextYearlyRate() view returns (uint64)",
  "function lastPriceChangeTimestamp() view returns (uint64)",
  "function lastRateChangeTimestamp() view returns (uint64)",
]);

const USDY_INSTANT_MANAGER_ABI = parseAbi(["function redeemPaused() view returns (bool)"]);

const SCHEDULED_ORACLE_SWITCH_ABI = parseAbi([
  "function oldOracle() view returns (address)",
  "function newOracle() view returns (address)",
  "function switchTimestamp() view returns (uint64)",
]);

const PRICE_SET_EVENT = parseAbiItem("event PriceSet(uint256 indexed price, uint64 timestamp)");
const CURRENT_YEARLY_RATE_SET_EVENT = parseAbiItem(
  "event CurrentYearlyRateSet(uint64 indexed yearlyRate, uint64 timestamp)",
);
const NEXT_YEARLY_RATE_SET_EVENT = parseAbiItem(
  "event NextYearlyRateSet(uint64 indexed yearlyRate, uint64 startTime)",
);

const RATE_PRECISION = 1_000_000_000_000n;
const SECONDS_PER_YEAR = 31_536_000n;

/**
 * Converts Ondo's continuously-compounded yearly rate into a USD-WAD increase per USDY per
 * second. The result has the exact units consumed by CreditEngine's `accrualPerSecondWad`.
 */
export function usdyAccrualPerSecondWad(
  navPerShareWad: bigint,
  yearlyRate: bigint,
): bigint {
  if (navPerShareWad < 0n || yearlyRate < 0n) {
    throw new Error("USDY oracle returned a negative value");
  }
  return (navPerShareWad * yearlyRate) / RATE_PRECISION / SECONDS_PER_YEAR;
}

export function oracleAfterScheduledSwitch(
  observedAt: bigint,
  oldOracle: Address,
  newOracle: Address,
  switchTimestamp: bigint,
): Address {
  return observedAt >= switchTimestamp ? getAddress(newOracle) : getAddress(oldOracle);
}

export interface OndoUsdyNavSourceOptions {
  rpcUrl: string;
  asset?: Address;
  instantManager?: Address;
  oracleWrapper?: Address;
  /** Optional migration guard. If supplied, a wrapper upgrade fails closed until reviewed. */
  continuousOracle?: Address;
}

/**
 * Read-only adapter for the issuer-published USDY price. No asset, user credential, or private
 * key is used. It pins the transaction that last changed the active price/rate state, which
 * lets the on-chain NavSignalOracle record evidence a judge can independently inspect.
 */
export class OndoUsdyNavSource implements NavSource {
  private readonly asset: Address;
  private readonly instantManager: Address;
  private readonly oracleWrapper: Address;
  private readonly expectedContinuousOracle?: Address;
  private readonly client: PublicClient;

  constructor(options: OndoUsdyNavSourceOptions) {
    this.asset = options.asset ?? ONDO_USDY_ETHEREUM.asset;
    this.instantManager = options.instantManager ?? ONDO_USDY_ETHEREUM.instantManager;
    this.oracleWrapper = options.oracleWrapper ?? ONDO_USDY_ETHEREUM.oracleWrapper;
    this.expectedContinuousOracle = options.continuousOracle;
    this.client = createPublicClient({ transport: http(options.rpcUrl) });
  }

  async read(asset: Address): Promise<NavRecord> {
    const requested = getAddress(asset);
    if (requested.toLowerCase() !== this.asset.toLowerCase()) {
      throw new Error(`USDY adapter does not support asset ${asset}`);
    }

    const head = await this.client.getBlock();
    if (head.number === null) throw new Error("Ethereum RPC returned a pending block");

    const blockNumber = head.number;
    const [chainId, wrapperOracle, priceData, redeemPaused] = await Promise.all([
      this.client.getChainId(),
      this.client.readContract({
        address: this.oracleWrapper,
        abi: USDY_ORACLE_WRAPPER_ABI,
        functionName: "rwaOracle",
        blockNumber,
      }),
      this.client.readContract({
        address: this.oracleWrapper,
        abi: USDY_ORACLE_WRAPPER_ABI,
        functionName: "getPriceData",
        blockNumber,
      }),
      this.client.readContract({
        address: this.instantManager,
        abi: USDY_INSTANT_MANAGER_ABI,
        functionName: "redeemPaused",
        blockNumber,
      }),
    ]);

    if (chainId !== 1) throw new Error(`USDY adapter requires Ethereum mainnet, got chain ${chainId}`);
    const activeContinuousOracle = await this.resolveContinuousOracle(
      getAddress(wrapperOracle),
      priceData[1],
      blockNumber,
    );
    if (
      this.expectedContinuousOracle &&
      activeContinuousOracle.toLowerCase() !== this.expectedContinuousOracle.toLowerCase()
    ) {
      throw new Error("USDY Oracle Wrapper no longer points to the explicitly configured oracle");
    }

    const [currentYearlyRate, nextRateStart, nextYearlyRate, lastPriceChangeTimestamp,
      lastRateChangeTimestamp] = await Promise.all([
      this.client.readContract({
        address: activeContinuousOracle,
        abi: CONTINUOUS_PRICE_ORACLE_ABI,
        functionName: "currentYearlyRate",
        blockNumber,
      }),
      this.client.readContract({
        address: activeContinuousOracle,
        abi: CONTINUOUS_PRICE_ORACLE_ABI,
        functionName: "nextRateStart",
        blockNumber,
      }),
      this.client.readContract({
        address: activeContinuousOracle,
        abi: CONTINUOUS_PRICE_ORACLE_ABI,
        functionName: "nextYearlyRate",
        blockNumber,
      }),
      this.client.readContract({
        address: activeContinuousOracle,
        abi: CONTINUOUS_PRICE_ORACLE_ABI,
        functionName: "lastPriceChangeTimestamp",
        blockNumber,
      }),
      this.client.readContract({
        address: activeContinuousOracle,
        abi: CONTINUOUS_PRICE_ORACLE_ABI,
        functionName: "lastRateChangeTimestamp",
        blockNumber,
      }),
    ]);

    const [navPerShareWad, observedAt] = priceData;
    if (navPerShareWad === 0n || observedAt === 0n || observedAt > head.timestamp) {
      throw new Error("USDY oracle returned an invalid price or timestamp");
    }

    const usingScheduledRate = observedAt >= nextRateStart;
    const activeYearlyRate = usingScheduledRate ? nextYearlyRate : currentYearlyRate;
    const sourceIsPrice = lastPriceChangeTimestamp >= lastRateChangeTimestamp;
    const sourceEvent = sourceIsPrice
      ? PRICE_SET_EVENT
      : usingScheduledRate
        ? NEXT_YEARLY_RATE_SET_EVENT
        : CURRENT_YEARLY_RATE_SET_EVENT;
    const sourceTimestamp = sourceIsPrice ? lastPriceChangeTimestamp : lastRateChangeTimestamp;
    const sourceEventMatch = sourceIsPrice
      ? { timeField: "timestamp", eventTime: sourceTimestamp, valueField: "price", value: navPerShareWad }
      : usingScheduledRate
        ? { timeField: "startTime", eventTime: nextRateStart, valueField: "yearlyRate", value: nextYearlyRate }
        : { timeField: "timestamp", eventTime: sourceTimestamp, valueField: "yearlyRate", value: currentYearlyRate };

    return {
      asset: this.asset,
      navPerShareWad,
      accrualPerSecondWad: usdyAccrualPerSecondWad(navPerShareWad, activeYearlyRate),
      observedAt,
      // This reports the issuer's public redemption pause only. Individual KYC/eligibility
      // remains outside public state and is intentionally not inferred as an approval.
      gateOpen: !redeemPaused,
      sourceTxHash: await this.transactionForEvent(
        activeContinuousOracle,
        sourceEvent,
        sourceTimestamp,
        sourceEventMatch,
        blockNumber,
      ),
    };
  }

  private async transactionForEvent(
    oracle: Address,
    event: AbiEvent,
    timestamp: bigint,
    match: { timeField: string; eventTime: bigint; valueField: string; value: bigint },
    latestBlock: bigint,
  ): Promise<Hex> {
    if (timestamp === 0n || timestamp > (await this.client.getBlock({ blockNumber: latestBlock })).timestamp) {
      throw new Error("USDY oracle has no valid source-event timestamp");
    }
    const center = await this.blockAtOrBefore(timestamp, latestBlock);
    const logs = await this.client.getLogs({
      address: oracle,
      event,
      fromBlock: center > 2n ? center - 2n : 0n,
      toBlock: center + 2n > latestBlock ? latestBlock : center + 2n,
    });
    const matchingLog = logs.find((log) => {
      const args = log.args as Record<string, unknown>;
      return args[match.timeField] === match.eventTime && args[match.valueField] === match.value;
    });
    const txHash = matchingLog?.transactionHash;
    if (!txHash) {
      throw new Error(
        "USDY source event was not found; configure an Ethereum RPC with historical log access",
      );
    }
    return txHash;
  }

  /**
   * Ondo can insert its verified ScheduledOracleSwitch between the stable wrapper and a
   * ContinuousPriceOracle. Resolve that switch at the price's observed timestamp; any unknown
   * implementation subsequently fails on the explicit ContinuousPriceOracle reads above.
   */
  private async resolveContinuousOracle(
    wrapperTarget: Address,
    observedAt: bigint,
    blockNumber: bigint,
  ): Promise<Address> {
    try {
      const [oldOracle, newOracle, switchTimestamp] = await Promise.all([
        this.client.readContract({
          address: wrapperTarget,
          abi: SCHEDULED_ORACLE_SWITCH_ABI,
          functionName: "oldOracle",
          blockNumber,
        }),
        this.client.readContract({
          address: wrapperTarget,
          abi: SCHEDULED_ORACLE_SWITCH_ABI,
          functionName: "newOracle",
          blockNumber,
        }),
        this.client.readContract({
          address: wrapperTarget,
          abi: SCHEDULED_ORACLE_SWITCH_ABI,
          functionName: "switchTimestamp",
          blockNumber,
        }),
      ]);
      return oracleAfterScheduledSwitch(observedAt, oldOracle, newOracle, switchTimestamp);
    } catch {
      return wrapperTarget;
    }
  }

  private async blockAtOrBefore(timestamp: bigint, latestBlock: bigint): Promise<bigint> {
    let low = 0n;
    let high = latestBlock;
    let candidate = 0n;
    while (low <= high) {
      const mid = low + (high - low) / 2n;
      const block = await this.client.getBlock({ blockNumber: mid });
      if (block.timestamp <= timestamp) {
        candidate = mid;
        low = mid + 1n;
      } else {
        high = mid - 1n;
      }
    }
    return candidate;
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
      "live NAV reads are not configured; set NAV_READ_MODE=ondo-usdy or provide NAV static data",
    );
  }
}
