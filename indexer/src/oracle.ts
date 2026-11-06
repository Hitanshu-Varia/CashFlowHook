import { createPublicClient, createWalletClient, defineChain, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { Address, Hex, PublicClient, WalletClient } from "viem";
import type { NavRecord, StreamRecord } from "./types.js";

const FEE_ORACLE_ABI = parseAbi([
  "function postRecord(bytes sig, (bytes32 strategyPosId, uint64 windowStartTs, uint256[7] dailyFees, uint256 distinctTakers, address excludedOwner, bytes32 rootHash) r, bytes32[] sample)",
]);

const NAV_ORACLE_ABI = parseAbi([
  "function postNav(bytes sig, (address asset, uint256 navPerShareWad, uint256 accrualPerSecondWad, uint64 observedAt, bool gateOpen, bytes32 sourceTxHash) r)",
]);

export interface StreamOracleClient {
  postRecord(signature: Hex, record: StreamRecord, sample: readonly Address[]): Promise<Hex>;
}

export interface NavOracleClient {
  postNav(signature: Hex, record: NavRecord): Promise<Hex>;
}

interface ViemClientOptions {
  rpcUrl: string;
  privateKey: Hex;
  chainId: number;
}

function makeClients(options: ViemClientOptions): {
  wallet: WalletClient;
  publicClient: PublicClient;
} {
  const chain = defineChain({
    id: options.chainId,
    name: "cashflowhook",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [options.rpcUrl] } },
  });
  const account = privateKeyToAccount(options.privateKey);
  return {
    wallet: createWalletClient({ account, chain, transport: http(options.rpcUrl) }),
    publicClient: createPublicClient({ chain, transport: http(options.rpcUrl) }),
  };
}

export class ViemStreamOracleClient implements StreamOracleClient {
  private readonly wallet: WalletClient;
  private readonly publicClient: PublicClient;
  private readonly address: Address;

  constructor(options: ViemClientOptions & { oracleAddress: Address }) {
    const clients = makeClients(options);
    this.wallet = clients.wallet;
    this.publicClient = clients.publicClient;
    this.address = options.oracleAddress;
  }

  async postRecord(
    signature: Hex,
    record: StreamRecord,
    sample: readonly Address[],
  ): Promise<Hex> {
    const sampleWords = sample.map(
      (address) => `0x${"0".repeat(24)}${address.toLowerCase().slice(2)}` as Hex,
    );
    const hash = await this.wallet.writeContract({
      address: this.address,
      abi: FEE_ORACLE_ABI,
      functionName: "postRecord",
      args: [signature, record, sampleWords],
      account: this.wallet.account!,
      chain: this.wallet.chain!,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }
}

export class ViemNavOracleClient implements NavOracleClient {
  private readonly wallet: WalletClient;
  private readonly publicClient: PublicClient;
  private readonly address: Address;

  constructor(options: ViemClientOptions & { oracleAddress: Address }) {
    const clients = makeClients(options);
    this.wallet = clients.wallet;
    this.publicClient = clients.publicClient;
    this.address = options.oracleAddress;
  }

  async postNav(signature: Hex, record: NavRecord): Promise<Hex> {
    const hash = await this.wallet.writeContract({
      address: this.address,
      abi: NAV_ORACLE_ABI,
      functionName: "postNav",
      args: [signature, record],
      account: this.wallet.account!,
      chain: this.wallet.chain!,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }
}
