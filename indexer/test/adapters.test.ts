import { describe, expect, it } from "vitest";
import {
  ONDO_USDY_ETHEREUM,
  oracleAfterScheduledSwitch,
  usdyAccrualPerSecondWad,
} from "../src/adapters.js";
import type { Address } from "viem";

describe("Ondo USDY NAV adapter", () => {
  it("uses the issuer-published Ethereum addresses", () => {
    expect(ONDO_USDY_ETHEREUM.asset).toBe("0x96F6eF951840721AdBF46Ac996b59E0235CB985C");
    expect(ONDO_USDY_ETHEREUM.oracleWrapper).toBe("0x87b126e5518b6a1Bb8465779b4607C45C643DF90");
  });

  it("converts a continuous yearly rate into the engine's USD-per-share-per-second unit", () => {
    const price = 1_080_000_000_000_000_000n;
    const yearlyRate = 50_000_000_000n; // 5% continuously compounded, 1e12 precision.
    expect(usdyAccrualPerSecondWad(price, yearlyRate)).toBe(
      (price * yearlyRate) / 1_000_000_000_000n / 31_536_000n,
    );
  });

  it("does not create coupon credit when the issuer rate is frozen", () => {
    expect(usdyAccrualPerSecondWad(1_080_000_000_000_000_000n, 0n)).toBe(0n);
  });

  it("follows a scheduled issuer-oracle migration at its effective timestamp", () => {
    const oldOracle = "0x00000000000000000000000000000000000000a1" as Address;
    const newOracle = "0x00000000000000000000000000000000000000b2" as Address;
    expect(oracleAfterScheduledSwitch(99n, oldOracle, newOracle, 100n).toLowerCase()).toBe(oldOracle.toLowerCase());
    expect(oracleAfterScheduledSwitch(100n, oldOracle, newOracle, 100n).toLowerCase()).toBe(newOracle.toLowerCase());
  });

  it("rejects malformed negative oracle values", () => {
    expect(() => usdyAccrualPerSecondWad(-1n, 1n)).toThrow("negative");
    expect(() => usdyAccrualPerSecondWad(1n, -1n)).toThrow("negative");
  });
});
