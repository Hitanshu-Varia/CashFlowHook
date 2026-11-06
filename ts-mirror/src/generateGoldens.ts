import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { DAILY_CAP_PER_INVESTOR, accountSnapshotUsd, portfolioSnapshotUsd } from "./spanMath";

const E18 = 10n ** 18n;
const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(here, "../../test-golden");

type Rng = () => number;

/** Deterministic 32-bit LCG. The generator never uses Math.random. */
function makeRng(seed: number): Rng {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1_664_525) + 1_013_904_223) >>> 0;
    return state;
  };
}

function randBig(rng: Rng, maxExclusive: bigint): bigint {
  if (maxExclusive <= 0n) return 0n;
  let value = 0n;
  for (let i = 0; i < 8; i++) {
    value = (value << 32n) | BigInt(rng());
  }
  return value % maxExclusive;
}

function pick<T>(rng: Rng, values: readonly T[]): T {
  return values[rng() % values.length];
}

/** JSON serializer that renders bigint as an unquoted decimal number. */
function stringifyWithBigInts(value: unknown): string {
  const marker = "__CFH_BIGINT__";
  const raw = JSON.stringify(
    value,
    (_key, item) => (typeof item === "bigint" ? `${marker}${item.toString()}` : item),
    2,
  );
  return raw.replace(new RegExp(`"${marker}(-?\\d+)"`, "g"), "$1");
}

interface SpanVectorJson {
  stockUsd: bigint;
  lpUsd: bigint;
  feeCreditBase: bigint;
  debt: bigint;
  im: bigint;
  bp: bigint;
  health: bigint;
  [key: string]: unknown;
}

interface RwaVectorJson {
  stockUsd: bigint;
  lpUsd: bigint;
  equityRwaUsd: bigint;
  navUsd: bigint;
  feeCreditFees: bigint;
  navAccrualCredit: bigint;
  dailyCoupon: bigint;
  debt: bigint;
  transferRestricted: boolean;
  gateOpen: boolean;
  dailyCap: bigint;
  lossR1Base: bigint;
  lossR2: bigint;
  eligR1: number;
  eligR2: number;
  feeCreditBase: bigint;
  im: bigint;
  bp: bigint;
  health: bigint;
  cStressed: bigint;
  unwindableNow: bigint;
  earningLocked: bigint;
  [key: string]: unknown;
}

function lossFields(losses: readonly bigint[]): Record<string, bigint> {
  const out: Record<string, bigint> = {};
  losses.forEach((value, index) => {
    out[`l${index}`] = value;
  });
  return out;
}

function generateSpanVectors(count: number): SpanVectorJson[] {
  const rng = makeRng(0xc0ffee);
  const vectors: SpanVectorJson[] = [];

  for (let i = 0; i < count; i++) {
    let stockUsd: bigint;
    let lpUsd: bigint;
    let feeCreditBase: bigint;
    let debt: bigint;

    if (i === 0) {
      stockUsd = 0n;
      lpUsd = 0n;
      feeCreditBase = 0n;
      debt = 0n;
    } else if (i === 1) {
      stockUsd = 1_000n * E18;
      lpUsd = 0n;
      feeCreditBase = 0n;
      debt = 0n;
    } else if (i === 2) {
      stockUsd = 0n;
      lpUsd = 1_000n * E18;
      feeCreditBase = 0n;
      debt = 0n;
    } else if (i === 3) {
      stockUsd = 1_000n * E18;
      lpUsd = 1_000n * E18;
      feeCreditBase = 100n * E18;
      debt = 500n * E18;
    } else {
      stockUsd = randBig(rng, 5_000_000n * E18);
      lpUsd = randBig(rng, 5_000_000n * E18);
      feeCreditBase = randBig(rng, 500_000n * E18);
      debt = randBig(rng, 5_000_000n * E18);
    }

    const r = accountSnapshotUsd(stockUsd, lpUsd, feeCreditBase, debt);
    vectors.push({
      stockUsd,
      lpUsd,
      feeCreditBase,
      debt,
      im: r.im,
      bp: r.bp,
      health: r.health,
      ...lossFields(r.scenarioLosses),
    });
  }

  return vectors;
}

function generateRwaVectors(count: number): RwaVectorJson[] {
  const rng = makeRng(0x5eed5);
  const vectors: RwaVectorJson[] = [];

  for (let i = 0; i < count; i++) {
    let stockUsd = randBig(rng, 5_000_000n * E18);
    let lpUsd = randBig(rng, 5_000_000n * E18);
    let equityRwaUsd = randBig(rng, 5_000_000n * E18);
    let navUsd = randBig(rng, 5_000_000n * E18);
    const feeCreditFees = randBig(rng, 500_000n * E18);
    const navAccrualCredit = randBig(rng, 500_000n * E18);
    const dailyCoupon = randBig(rng, 100_000n * E18);
    const debt = randBig(rng, 5_000_000n * E18);

    let transferRestricted = rng() % 2 === 0;
    let gateOpen = rng() % 2 === 0;

    let dailyCap: bigint;
    if (i % 10 === 0) {
      // Exact cap boundary: navUsd == 25% of dailyCap passes, one more wei fails.
      navUsd = DAILY_CAP_PER_INVESTOR / 4n;
      dailyCap = DAILY_CAP_PER_INVESTOR;
    } else if (i % 10 === 1) {
      navUsd = DAILY_CAP_PER_INVESTOR / 4n + 1n;
      dailyCap = DAILY_CAP_PER_INVESTOR;
    } else if (i % 10 === 2) {
      navUsd = 0n;
      dailyCap = 0n;
    } else {
      dailyCap = pick(rng, [
        DAILY_CAP_PER_INVESTOR,
        navUsd * 4n,
        navUsd * 4n + 1n,
        navUsd * 4n > 0n ? navUsd * 4n - 1n : 0n,
        0n,
      ]);
    }

    if (i % 17 === 0) transferRestricted = true;
    if (i % 19 === 0) gateOpen = false;

    const r = portfolioSnapshotUsd(
      stockUsd,
      lpUsd,
      equityRwaUsd,
      navUsd,
      feeCreditFees,
      navAccrualCredit,
      dailyCoupon,
      debt,
      transferRestricted,
      gateOpen,
      dailyCap,
    );

    vectors.push({
      stockUsd,
      lpUsd,
      equityRwaUsd,
      navUsd,
      feeCreditFees,
      navAccrualCredit,
      dailyCoupon,
      debt,
      transferRestricted,
      gateOpen,
      dailyCap,
      lossR1Base: r.lossR1Base,
      lossR2: r.lossR2,
      eligR1: r.eligR1,
      eligR2: r.eligR2,
      feeCreditBase: r.feeCreditBase,
      im: r.im,
      bp: r.bp,
      health: r.health,
      cStressed: r.cStressed,
      unwindableNow: r.unwindableNow,
      earningLocked: r.earningLocked,
      ...lossFields(r.scenarioLosses),
    });
  }

  return vectors;
}

function main(): void {
  mkdirSync(outDir, { recursive: true });

  const span = generateSpanVectors(1_000);
  const rwa = generateRwaVectors(300);

  writeFileSync(
    resolve(outDir, "span_golden.json"),
    `${stringifyWithBigInts({ count: span.length, vectors: span })}\n`,
  );
  writeFileSync(
    resolve(outDir, "rwa_golden.json"),
    `${stringifyWithBigInts({ count: rwa.length, vectors: rwa })}\n`,
  );

  console.log(`wrote ${span.length} span vectors and ${rwa.length} RWA vectors to ${outDir}`);
}

main();
