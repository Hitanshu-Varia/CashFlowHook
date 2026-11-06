import { privateKeyToAccount } from "viem/accounts";
import type { Address, Hex } from "viem";
import type { NavRecord, StreamRecord } from "./types.js";

export const DOMAIN_NAME = "CashflowHook";
export const DOMAIN_VERSION = "1";

export const STREAM_TYPES = {
  StreamRecord: [
    { name: "strategyPosId", type: "bytes32" },
    { name: "windowStartTs", type: "uint64" },
    { name: "dailyFees", type: "uint256[7]" },
    { name: "distinctTakers", type: "uint256" },
    { name: "excludedOwner", type: "address" },
    { name: "rootHash", type: "bytes32" },
  ],
} as const;

export const NAV_TYPES = {
  NavRecord: [
    { name: "asset", type: "address" },
    { name: "navPerShareWad", type: "uint256" },
    { name: "accrualPerSecondWad", type: "uint256" },
    { name: "observedAt", type: "uint64" },
    { name: "gateOpen", type: "bool" },
    { name: "sourceTxHash", type: "bytes32" },
  ],
} as const;

export class Eip712Signer {
  private readonly account;
  private readonly chainId: number;
  private readonly verifyingContract: Address;

  constructor(privateKey: Hex, chainId: number, verifyingContract: Address) {
    this.account = privateKeyToAccount(privateKey);
    this.chainId = chainId;
    this.verifyingContract = verifyingContract;
  }

  get address(): Address {
    return this.account.address;
  }

  private domain() {
    return {
      name: DOMAIN_NAME,
      version: DOMAIN_VERSION,
      chainId: this.chainId,
      verifyingContract: this.verifyingContract,
    } as const;
  }

  async signStream(record: StreamRecord): Promise<Hex> {
    return this.account.signTypedData({
      domain: this.domain(),
      types: STREAM_TYPES,
      primaryType: "StreamRecord",
      message: record,
    });
  }

  async signNav(record: NavRecord): Promise<Hex> {
    return this.account.signTypedData({
      domain: this.domain(),
      types: NAV_TYPES,
      primaryType: "NavRecord",
      message: record,
    });
  }
}
