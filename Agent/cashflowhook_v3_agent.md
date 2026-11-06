# AGENT.md — CashflowHook v3 (human-cosigned agent credit line with an RWA collateral class)

**Status:** GATED. Do not start gate-dependent sections until G-G1, G-G2, G-G3 and **G-RWA-1** are signed (§0.7). All gates have named fallbacks; this file remains executable with every fallback fired.
**Supersedes:** `cashflowhook_v2_agent.md` (v3 adds the RWA collateral class + segregated margin; v2 is kept for history only — build from this file).
**Focus/sponsors (exactly 3 partner prizes, max allowed):** 1inch "Build an Aqua App" $5,000 · Uniswap Foundation "Build with Uniswap" $10,000 · World "World ID Agent Pass" $5,000 (open track, NOT the $2,500 Continuity track) [verified: ethglobal.com/events/mumbai/prizes, 2026-11-05]. Entered prize total: $20,000.
**Team/time:** 2 people, ~34–40 build hours. Eng A: Solidity/Foundry. Eng B: TypeScript/Next.js.
**Chain/stack:** Demo runs against a **local Anvil fork of Base mainnet** (1inch prize rules allow local forks for the onchain-transfer proof [verified 2026-11-05]); RWA treasury NAV signal is **read from Ethereum mainnet** (OUSG/USDY state, view calls only, no bridge, no custody); CreditEngine/FeeStreamOracle/StrategyBureau additionally deploy to **Base mainnet** if gas is available (BR1). Web: Next.js. Indexer: TypeScript node service.
**Honest mean:** 8.7/10 (Tech 9.5, Orig 9, Pract 7.5, Use 8, WOW 9.5). Band 8.4–8.9 with band-raisers; **7.2–7.6 if G-RWA-1 fails and the leg ships marks-only** (coupon engine cut). Usability dropped 0.5 vs v2 on purpose: three collateral classes + locked/liquidatable segregation is harder to explain — that cost is real, not modesty.
**Finalist probability:** HIGH conditional on all four gates; ~4–8× the 4.10% 2026-IRL base rate (39/951, dataset pull 2026-11-02). Joint ≥1-prize probability ≈ 70–85% [inference; per-track applicant counts unknown].
**The one strategic fact this file is built around (dataset pull 2026-11-05):** 2026 ETHGlobal projects mentioning RWA + lending/credit/collateral: **44 projects, 0 finalists (0.00%)** — including sponsor-prize winners (Rialto, ClosingBell-Hook, Bailiff, ArcAsset, tokenize-it) that still never finalized. Therefore v3 is **a cross-margin engine with an RWA collateral class**, never pitched as an "RWA lending project". RWA-mention alone is lane-neutral (288 projects, 6 finalists, 2.08% vs 2.20% base); the lift comes from the margin/risk lane (9.1% finalist rate, 4/44 IRL lending-lane projects).

---

## 0. Rules for the building model

0.1 This file is the single source of truth. If this file and your intuition disagree, this file wins. If this file is ambiguous, pick the simplest option that satisfies the acceptance criteria in §7 and log the choice in `DECISIONS.md` (one commit per decision).
0.2 **Never invent.** No invented addresses, SDK names, event signatures, URLs, or numbers. `[verified: …]` has a source; `[assumption]` must be re-checked by the listed verify-first checklist before first use; `[to verify]` is behind an adapter and listed in §16.2.
0.3 **Adapter rule.** Every external call (Aqua, v4 PoolManager/PositionManager, World Agent Pass backend, OUSG/USDY NAV reads, stock-token marks, x402 endpoint) goes through the adapter interfaces in §6/§8. A wrong external-name guess must break exactly one adapter file.
0.4 **Determinism.** Portfolio math exists twice (Solidity `SpanMathLib` + `RwaStressLib`, TS mirror) and must produce byte-identical outputs on ≥1,000 golden vectors. Rounding is defined in §4.6 and is part of the vectors.
0.5 **Banned words** (CI grep, whole-word, case-insensitive, in `README.md`, `web/**` user-visible copy, `demo/storyboard.md`): "risk-free", "guaranteed", "unhackable", "can't lose", "certainly profitable", "little/no risk", "yield guaranteed". A hit fails CI. This is a credit product — the words are legally and credibility-sensitive.
0.6 **Definition of done** for any task: code + tests green (`forge test`, `pnpm -r test`) + `pnpm lint` clean + a `DECISIONS.md` line for any choice not written here.
0.7 **Gates (sign in `DECISIONS.md` at the stated hours):**
   - **G-G1 (1inch/opcode, hour 0–2).** Build `1inch/swap-vm` (release/1.1) locally; demonstrate added opcode `0xf1` executing on the Base mainnet fork with official Aqua contracts. Prize page explicitly permits modified-SwapVM redeploys, custom instructions, local forks [verified 2026-11-05]. Fail → Fallback Mode (unmodified SwapVM; unwind via `CreditEngine.unwindNettedFallback`). Never hold the build hostage to the opcode.
   - **G-G2 (Uniswap hook, by hour 18).** With debt > 0 on the forked v4 pool, `beforeModifyLiquidity`/`beforeRemoveLiquidity` reverts `SpanMarginBreach()`; after full repay the removal succeeds. Fail → LP-escrow lock.
   - **G-G3 (World, by hour 18).** Agent Pass happy path + denied/expired path working with World's currently **mocked** proofs; server-side validation [verified 2026-11-05]. Fail → IDKit sign-in + server-side step-up; worst case submit 2 sponsor entries.
   - **G-RWA-1 (RWA leg, by hour 8 — the new v3 gate).** BOTH real inputs live on the fork: (a) a real Base tokenized-stock token with a working mark + a transfer path from a fresh wallet; (b) a real OUSG/USDY NAV/accrual read from Ethereum mainnet via public RPC. Fail → **marks-only fallback**: `couponPerDay = 0`, gate modeling kept, README/video pitch becomes "RWA-ready engine, equity class demonstrated" — **never ship a half-built coupon engine** (that is the 44-project graveyard failure mode).

0.8 Ask a human only if a required fact is missing AND neither the file nor the verify-first checklist can resolve it.

---

## 1. What it is (and is not)

**What it is.** CashflowHook v3 is a **non-custodial, cross-margined credit line for an AI agent, underwritten by verifiable third-party cashflow — across three collateral classes: a tokenized-equity position (real tokenized stock on Base), a locked Uniswap v4 LP position (guarded by `PortfolioMarginHook`), and a tokenized-treasury NAV position (OUSG/USDY signal read from Ethereum mainnet).** One 16-scenario SPAN grid (8 price shocks × 2 vol states) plus a closed-form RWA stress term prices all three legs together. Trailing fee earnings from the LP strategy (distinct third-party takers only, borrower excluded, haircut by earnings volatility and drawdown) and **daily NAV accrual from the treasury leg** both add earnings credit to borrowing power. Crucially, the engine **segregates margin**: RWA legs that cannot exit instantly — because redemption is permissioned/capped (OUSG instant caps: $25M/investor, $50M/all per 24h [verified via Ondo docs coverage]) or the token is transfer-restricted — count as **"earning but locked"** and never back an unwind. The line itself is drawn as a **1inch Aqua virtual balance** (no token custody transfers). An autonomous deterministic-policy agent draws within caps and pays exactly one external bill via x402 with receipts. Raising its cap — or authorizing an unwind that exceeds liquidatable backing — requires a **World ID Agent Pass** proof: a verified human tapped approval, with the human explicitly accepting locked-leg liquidity risk. In a crash the account is not liquidated piecemeal: the `0xf1 spanNetUnwind` instruction (or fallback EVM path) nets the liquidatable legs atomically with **zero bad debt**, while a split-screen shows an identical isolated account liquidated.

**One-line pitch.** "The first credit line where the borrower is an AI agent, the cosigner is a verified human, and the collateral spans tokenized equity, LP cashflow, and a treasury NAV — with margin segregated by what can actually be unwound."

**What it is NOT.** Not an RWA-lending protocol (44 such projects hit ETHGlobal in 2026; zero finalized — we are a risk engine with an RWA class). Not a perp exchange. Not a custody product (one approved Unwinder operator only). Not a production lending market (demand-side demo; supply side honestly out of scope). Not ML. Not a zk/TEE product. **Not a tokenizer** — we issue nothing; we underwrite assets that already exist.

---

## 2. Final claims — exact wording

**Use on stage / README, verbatim:**
1. "Non-custodial: borrowed liquidity lives as an Aqua virtual balance; your tokens never move to the protocol."
2. "Three collateral classes, one grid: tokenized equity, a locked v4 LP position, and a treasury NAV signal — cross-margined, not isolated."
3. "Cashflow underwriting: the line grows with verifiable earnings — LP fees from distinct third-party takers (borrower excluded) and daily treasury NAV accrual — both hash-pinned and disclosed."
4. "Segregated margin: assets that cannot exit instantly are marked 'earning but locked' and never back an unwind. OUSG instant redemption is capped at $25M per investor per 24h; our engine prices that reality."
5. "Atomic unwind: the net dual-leg instruction rests only on the SPAN calculations shown; in fork fuzzing it left zero bad debt in 10,000 paths."
6. "Human-cosigned autonomy: the agent cannot raise its own limit or unwind beyond liquidatable backing; both require a World ID Agent Pass verification validated on our backend, with the human explicitly accepting locked-liquidity risk."
7. All margin numbers displayed are **computed at runtime** by `CreditEngine.marginBreakdown()` with their inputs visible; no savings percentage is read from a slide.

**Never say:** "we're the only…" (name competitors; no superlatives), "bank-grade", "compliance-safe", "we'll get a license", "solves liquidations" (say "avoids isolated liquidation in tested paths"), "yield" without "accrual", anything implying we hold OUSG or that KYC'd assets are available to the demo user (we read public NAV state only), "tokenized stocks pay dividends" (dividend treatment unverified — coupon = 0 for R1, disclosed).

---

## 3. Band-raising conditions table

| ID | Lever | Criteria moved | Acceptance test | Failure mode | Type |
|---|---|---|---|---|---|
| BR1 | Deploy `CreditEngine`, `FeeStreamOracle`, `StrategyBureau`, `NavSignalOracle` to **Base mainnet** (~$0.5–2 gas) and cite real Basescan URLs | Practicality 7.5→8 | Basescan URLs resolve; a `cast call` from a fresh wallet reproduces the displayed fee credit within ±1% | No mainnet ETH → fork-only demo | grind |
| BR2 | **Real LP fee stream**: hash-pinned 30-day fees of a real mainnet v4 position | Practicality +0.25; kills the "simulated history" attack | Recomputing from pinned raw events matches the displayed credit | Archive RPC limits → live 6h accumulation + 30d CSV, still hash-pinned | luck-bound, do first |
| BR3 | **Real treasury NAV accrual on screen**: coupon ticker fed by real OUSG/USDY accrual reads; the accrual amount is verifiable from the source tx | Practicality +0.25, WOW +0.25 | UI shows accrual + the source tx hash; an independent read reproduces it | G-RWA-1 (b) fails → marks-only fallback | luck-bound, do first |
| BR4 | **Live human step-up on stage** (World tap) | WOW 9.5→10 nominally | Tap < 20s; denied path shown first | Network friction → recorded tap, disclosed once | luck-bound, rehearse 5× |
| BR5 | **Real crash replay** (Aug 2024 / Feb 2025 / Oct 2026) showing isolated vs cross-margined on identical books, with the RWA weekend-gap term visible | WOW +0.25 | Replay prints per-scenario losses; inputs visible | Archive block unreachable → hash-pinned CSV replay | grind |
| BR6 | Bureau shows ≥3 registered strategy scores (demo + 2 labeled fixtures) | Originality +0.25 | Bureau page lists them; fixtures labeled | n/a | grind |

Conjunctive: BR2 is prerequisite for BR5's headline claim; BR3 is prerequisite for the RWA coupon claim; BR4 is required for the §11 climax. Do BR1+BR2+BR3 in hours 0–8, BR4 rehearsal immediately after.

---

## 4. Product definition — exact semantics

### 4.1 Objects
- **Account**: legs + debt + autonomy + unwinder approval; one owner.
- **Leg ST (stock leg)**: token, amount (WAD), mark price, haircut input.
- **Leg LP (strategy leg)**: v4 `tokenId` + `poolKey` + `liquidityOwner`; hook-locked while debt > 0.
- **Leg R1 (RWA equity)**: Base tokenized-stock token, amount, mark, `transferRestricted(bool)`; **coupon = 0** (dividend treatment unverified — disclosed).
- **Leg R2 (RWA treasury)**: asset id (OUSG/USDY), `navPerShareWad`, `accrualPerSecondWad`, amount, `gateOpen(bool)`, `lastAccrualTs`, `sourceTxHash`, `navTs`.
- **Fee stream**: 7-day daily fee schedule + `distinctTakers` + excluded owner, oracle-posted.
- **Line**: Aqua virtual balance; `debt(account)`.
- **Autonomy cap**: per-draw cap, per-window draw count; raising = Agent Pass step-up.
- **Margin segregation**: `unwindableNow` vs `earningLocked` (§4.3).

### 4.2 Defaults (units; no placeholders)
| Parameter | Default | Unit | Notes |
|---|---|---|---|
| Grid shocks `S[]` | `−0.20, −0.10, −0.05, −0.02, +0.02, +0.05, +0.10, +0.20` | WAD | 8 values |
| Vol states `V[]` | `1.0, 1.5` | multiplier | ×8 = 16 scenarios |
| LP beta / convexity | `0.8` / `0.05` | fraction / fraction² | value stated here (carried from v2) |
| Stock haircut `HC_STOCK` | `0.85` | WAD | |
| LP haircut `HC_LP` | `0.70` | WAD | |
| R1 haircut `HC_R1` | `0.75` | WAD | [assumption — ours, not Aave's] |
| R2 haircut `HC_R2` | `0.85` | WAD | [assumption] |
| Initial LTV vs stressed collateral | `0.80` | WAD | draw cap |
| Maintenance health | `0.85` | WAD | below → unwind eligible |
| Earnings window | `7` days | calendar | rolling |
| Earnings credit multiplier | `3 × avgDailyFees` | USD-WAD | trailing 3d avg |
| Fee-credit cap | `0.10 × totalCollateralUsd`, applied to the **combined** `feeCreditFees + navAccrualCredit` | WAD | hard cap |
| Distinct takers floor | `5` | count | below → fee credit 0 |
| Sybil / vol / drawdown penalties | `min(1, takers/20)` / `1 − 0.5·σn` / `1 − 0.3·ddn` | fraction | value stated here (carried from v2) |
| Autonomy cap default | `2%` of BP per draw, `3` draws / 12h | WAD / count | |
| Mark staleness (ST/LP) | `1800` s | seconds | else STALE_MARK revert |
| **R1 gap premium `GAP_PREMIUM`** | `0.5` | multiplier on shock loss | weekend/overnight gap: tokenized stocks trade 24/7 while the underlying trades market hours [verified: Robinhood disclosures via eco.com, 2026-10-08]; magnitude is [assumption] |
| **R2 permissioned-liquidity haircut `PERM_LIQ_HC`** | `0.015` (1.5% of NAV) | WAD | [assumption] |
| **R2 exit-cost term** | `min(navUsd·0.005, dailyCoupon·gateDays)` | USD-WAD | 0.5% NAV cap [assumption] |
| **`gateDays`** | `2` | days | [assumption — conservative] |
| **`dailyCapPerInvestor`** (OUSG instant-redeem cap) | `25,000,000` per investor per 24h (`50,000,000` all investors) | USD | [verified: Ondo docs coverage via eco.com/altstreet, 2026] |
| **`capFraction`** | `0.25` of daily per-investor cap | fraction | R2 unwind-eligibility threshold [assumption] |
| Coupon period | `86400` s | seconds | daily accrual |
| `dailyCoupon` (derived) | `accrualPerSecondWad · navAmt · 86400` | USD-WAD | NAV accrual per day for the held amount |
| `navAccrualCredit` (derived) | `accrualPerSecondWad · navAmt · min(heldSeconds, 604800)` | USD-WAD | `heldSeconds = now − lastAccrualTs` (I12) |
| Min holding for accrual credit | `1` coupon period (`86400` s) | seconds | I12 |
| NAV staleness (R2) | `93600` s (26h) | seconds | daily NAV + slack; stale → R2 eligibility 0 |
| TWAP interval (marks) | `30` min | s | |

### 4.3 Formulas (canonical — defined once; mirrored in TS)
Scenario index `s = i·2 + j`, `i ∈ [0..7]` shock, `j ∈ [0..1]` vol; `sh_i = S[i]·V[j]`:
```
lossStock_i = max(0, −sh_i) · stockLegUsd
β_i         = 0.8·|sh_i| + 0.05·sh_i²
lossLP_i    = lpLegUsd · β_i
// RWA closed-form terms (not looped 16× for gas)
lossR1      = equityRwaUsd · max(0, −sh_20) · (1 + GAP_PREMIUM)          // worst shock ±0.20, vol-scaled below
lossR2      = navUsd · PERM_LIQ_HC + min(navUsd·0.005, dailyCoupon·gateDays)
feeCred_i   = feeCreditBase · (sh_i < 0 ? 0.5 : 1.0)
IM_i        = max(0, lossStock_i + lossLP_i + lossR1·V[j] + lossR2 − feeCred_i)
IM          = max over the 16 scenarios
C_stressed  = stockLegUsd·HC_STOCK + lpLegUsd·HC_LP + equityRwaUsd·HC_R1 + navUsd·HC_R2 − IM
BP          = floor(C_stressed · 0.80)
health      = C_stressed / max(debt, 1e12)                                // < 0.85 → unwind eligible
// Segregated margin (v3 core)
eligR1      = transferRestricted ? 0 : 1
eligR2      = (gateOpen && navUsd ≤ dailyCapPerInvestor·capFraction) ? 1 : 0   // dailyCapPerInvestor = 25,000,000 USD (OUSG, verified); capFraction = 0.25
unwindableNow = stockLegUsd·HC_STOCK + lpLegUsd·HC_LP + equityRwaUsd·HC_R1·eligR1 + navUsd·HC_R2·eligR2
earningLocked = (stockLegUsd·HC_STOCK + lpLegUsd·HC_LP + equityRwaUsd·HC_R1 + navUsd·HC_R2) − unwindableNow
feeCreditFees    = 3·avg7dFees · min(1, takers/20) · (1 − 0.5·σn) · (1 − 0.3·ddn)
navAccrualCredit = accrualPerSecondWad · navAmt · min(heldSeconds, 604800)     // heldSeconds = now − lastAccrualTs
feeCreditBase    = min(feeCreditFees + navAccrualCredit, 0.10 · totalCollateralUsd)   // combined 10% cap
```
StrategyScore (computed and stored by `StrategyBureau`, §6.6):
```
score = min(100, round(100·(0.5·(1 − min(1,σ/μ)) + 0.3·(1 − maxWeeklyDDfrac) + 0.2·min(1, ageDays/7)))) gated by takers ≥5
```

### 4.4 State machine (account)
`EMPTY → PRICED(debt=0) → ACTIVE(debt>0) → STRESSED(health<0.85 or debt>unwindableNow·0.80) → UNWINDING → PRICED`. Gate events: `GateShut(asset)` → recompute `eligR2=0` in the same block, emit `SegregationChanged(unwindableNow, earningLocked)`; if debt > `unwindableNow·0.80`, the agent is capped and a step-up (human accepts locked-leg risk) is the only unlock. Terminal `INSOLVENT` must be unreachable (I3).

### 4.5 Invariants (all 13 stated in full — this file is standalone)
- **I1 Non-custody**: no contract in this repo holds ST/LP/RWA tokens except the Unwinder's transient pull-and-swap inside one transaction; end-of-tx token balances return to the account wallet.
- **I2 Cap**: `debt ≤ BP` after any state change (draw, fee/mark/NAV update, accrual).
- **I3 Zero bad debt**: any completed unwind leaves `debt = 0` with all repo tokens surfaced to the wallet; otherwise it reverts `BadDebtProjection`.
- **I4 Hook lock**: with `debt > 0`, any liquidity decrease/removal on a locked LP position reverts `SpanMarginBreach`.
- **I5 Determinism**: Solidity (`SpanMathLib` + `RwaStressLib`) and the TS mirror produce identical `IM, BP, feeCreditBase, unwindableNow, earningLocked` on every golden vector (exact WAD match).
- **I6 Taker floor**: fee earnings credit is 0 whenever `distinctTakers < 5`.
- **I7 Step-up needs human**: no call path raises the autonomy cap or accepts locked-liquidity risk without an accepted Agent Pass proof validated server-side and posted to `AgentPassVerifier` (nonce-bound, replay-guarded).
- **I8 Receipts**: every agent spend emits `AgentSpent(account, to, amount, memo, ts)`; the demo shows ≥ 1 receipt.
- **I9 Staleness safety**: stale ST/LP marks (> 1800 s) revert `STALE_MARK`; stale NAV (> 26 h) sets R2 eligibility to 0 and flags the UI; never price silently off stale data.
- **I10 Bureau immutability**: `StrategyScore` history is append-only; changes require a fresh oracle record with strictly increasing timestamps.
- **I11** Transfer-restricted RWA never counts toward `unwindableNow` (`eligR1 = 0` by construction).
- **I12** NAV accrual credit requires held ≥ 1 coupon period; accrual is `accrualPerSecondWad × heldSeconds`, inside the combined 10% cap.
- **I13** Any unwind instruction requires `debt ≤ unwindableNow` at entry, else reverts `InsufficientUnwindable`; the only override is a human Agent Pass acceptance of locked-liquidity risk (emits `LockedRiskAccepted`, expires in 24 h).

### 4.6 Rounding
WAD (1e18) fixed-point; intermediates at 1e36; floor divisions for collateral/health/accrual; ceil for debt; StrategyScore rounds half-up at 16-bit; any intermediate > 1e40 reverts `GridOverflow`.

### 4.7 Edge cases
R2 gate shut mid-block (oracle posts `gateOpen=false`) → `SegregationChanged` in same tx; R1 transfer-restricted discovered post-onboard → `eligR1=0`, UI badge flips, no silent margin; NAV stale > 26h → R2 marked at 0 eligibility until refreshed; coupon accrual with `heldSeconds` from `lastAccrualTs` (monotonic); negative fee week → feeCreditBase clamps 0; R2 position > daily cap → `eligR2=0` with UI explanation; zero RWA legs → the engine reduces to the two-leg case (formulas unchanged, RWA terms evaluate to 0); concurrent gate-shut + draw → draw wins on BP, segregation applies in the same block.

---

## 5. Architecture & repo layout

```
cashflow-hook/
 ├ README.md · AGENT.md (this file) · FEEDBACK.md · DECISIONS.md
 ├ docs/{sponsor-map.md, limits.md, agent-debrief.md, claims.md, rwa-sources.md}
 ├ contracts/
 │  ├ src/{CreditEngine.sol, SpanMathLib.sol, RwaStressLib.sol, PortfolioMarginHook.sol,
 │  │        AquaCreditLine.sol, SpanVMRouter.sol, FeeStreamOracle.sol, StrategyBureau.sol,
 │  │        RwaCollateralAdapter.sol, NavSignalOracle.sol, AgentPassVerifier.sol, ReceiptsRegistry.sol}
 │  ├ script/{Deploy.s.sol, DeployFork.s.sol, Configure.s.sol, MineHook.s.sol}
 │  └ test/{Unit.t.sol, Fuzz.t.sol, Invariants.t.sol, Fork.t.sol, Hook.t.sol, Rwa.t.sol}
 ├ ts-mirror/  (spanMath.ts + rwaStress.ts + golden runner)
 ├ indexer/    (Node/TS: fee snapshots, taker diversity, NAV signal poster)
 ├ agent/      (policy engine, x402 bill client, World step-up client)
 ├ web/        (Next.js Credit Desk)
 ├ demo/       {fork.sh, storyboard.md, crash-data/*.csv + *.sha, video/}
 └ .github/workflows/ci.yml
```

```
v4 PoolManager events ─▶ indexer ─▶ FeeStreamOracle.postRecord ─▶ StrategyBureau
OUSG/USDY state (ETH mainnet, view-only) ─▶ NavSignalOracle.postNav ─┐
stock token marks (Base) ─▶ MarkFeed ───────────────────────────────┤
                                                                     ▼
CreditEngine.marginBreakdown() → { BP, unwindableNow, earningLocked, health }  → web
World Agent Pass ─▶ backend validates ─▶ AgentPassVerifier.onchain allow ─▶ step-up / locked-risk acceptance
agent policy ─▶ AquaCreditLine.draw() ─▶ AQUA ship/pull ─▶ x402 bill / ReceiptsRegistry
crash / gate-shut ─▶ SpanVMRouter (0xf1 spanNetUnwind or fallback) ─▶ atomic unwind, badDebt=0
```

---

## 6. Detailed component specs

### 6.1 `SpanMathLib.sol` (pure math; no storage, no external calls)
- `struct Legs { uint256 stockAmt; uint256 stockMark; uint256 lpAmt; uint256 lpMark; uint256 feeCreditBase; uint256 debt; bool nonEmpty; }`
- `function accountSnapshot(Legs memory l) internal pure returns (uint256 im, uint256 bp, uint256 health, uint256[16] scenarioLosses)` — implements §4.3 base-leg terms exactly.
- Constants defined here once: `SHOCKS_8_WAD = [-0.20e18, -0.10e18, -0.05e18, -0.02e18, 0.02e18, 0.05e18, 0.10e18, 0.20e18]`, `VOL_STATES_2 = [1.0e18, 1.5e18]`, `HC_STOCK = 0.85e18`, `HC_LP = 0.70e18`, `LTV_MAX = 0.80e18`, `MAINT = 0.85e18`, `LP_BETA = 0.8e18`, `LP_CONVEX = 0.05e18`.
- Gas target: `accountSnapshot()` ≤ 120k at 16 scenarios (`forge snapshot --check` in CI).

### 6.2 `RwaStressLib.sol` (new; pure functions)
- `function rwaStress(uint256 equityRwaUsd, uint256 navUsd, uint256 dailyCoupon, uint256 volMul) pure returns (uint256 lossR1, uint256 lossR2)` implementing §4.3 exactly; both terms WAD; `max(0, −sh_20)` is the constant `0.20e18`.
- `function eligibility(bool transferRestricted, bool gateOpen, uint256 navUsd, uint256 dailyCap) pure returns (uint8 eligR1, uint8 eligR2)` implementing §4.3 flags.
- `function segregated(uint256 stockUsd, uint256 lpUsd, uint256 equityRwaUsd, uint256 navUsd, uint8 eligR1, uint8 eligR2) pure returns (uint256 unwindableNow, uint256 earningLocked)`.
- No storage, no external calls. Gas targets: `rwaStress` ≤ 8k; `eligibility` ≤ 3k; `segregated` ≤ 6k.

### 6.3 `CreditEngine.sol`
Storage (complete — no field is defined elsewhere):
```
struct Account {
  address owner;                                            // account wallet
  uint256 stockAmt; uint256 stockMark; uint64 stockMarkTs;  // leg ST
  uint256 lpTokenId; uint256 lpUnits; bool lpLocked;         // leg LP (hook-locked while debt > 0)
  uint256 equityRwaAmt; uint256 equityRwaMark; bool r1TransferRestricted; uint64 r1MarkTs;   // leg R1
  uint256 navAmt; uint256 navPerShareWad; uint256 accrualPerSecondWad; uint64 lastAccrualTs; uint64 navTs; bool gateOpen; bytes32 rwaSourceTxHash;  // leg R2
  uint256 debtWad; uint64 lastFeeRec;                        // line + fee stream anchor
  Autonomy aut; bool unwinderOk; bool lockedRiskAccepted; uint64 lockedRiskExpiry;
}
struct Autonomy { uint128 capWad; uint16 capCountPer12h; uint16 spent; uint64 windowStart; bool needsStepUp; }
uint256 public immutable FEE_ORACLE; uint256 public immutable AGENT_VERIFIER;
uint256 public immutable RWA_ADAPTER; uint256 public immutable NAV_ORACLE; uint256 public immutable ROUTER;
mapping(uint256 accountId => Account) accounts;
mapping(bytes32 proofHash => bool used) consumedProofs;      // replay guard (mirrors AgentPassVerifier)
```
Functions (complete set):
- `onboard(accountId, stockToken, stockAmt, lpTokenId, lpUnits)` — owner-only; zeroes debt; emits `Onboarded`.
- `setRwaPosition(accountId, asset, amount)` — owner-only via `RWA_ADAPTER`; emits `RwaPositionSet`.
- `refreshMarks(accountId)` — pulls ST/LP/R1 marks (TWAP preferred, spot fallback with banner flag); reverts `STALE_MARK` if any mark older than 1800 s.
- `accrueCoupon(accountId)` — owner/agent/keeper; `navAccrualCredit += accrualPerSecondWad × (now − lastAccrualTs)` (I12); reverts `NavStale` if `navTs` older than 26 h.
- `computeBp(accountId) view returns (uint256 bp)` — via `SpanMathLib.accountSnapshot` + `RwaStressLib.rwaStress`.
- `marginBreakdown(accountId) view returns (uint256 bp, uint256 unwindableNow, uint256 earningLocked, uint256 health)` — via `RwaStressLib.segregated`; the single read the UI and demo use.
- `draw(accountId, amtWad)` — owner; checks `debt + amt ≤ bp` and autonomy cap; emits `Drew`.
- `agentDraw(accountId, amtWad)` — agent (within caps); same checks; 4th draw in a 12 h window reverts `CapExceededBlock`.
- `repay(accountId, amtWad)` — owner/agent/unwinder; emits `Repaid`.
- `stepUp(accountId, bytes32 proofHash, uint8 newCapTier)` — only `AGENT_VERIFIER`; marks `proofHash` used; 24 h high tier; emits `SteppedUp`.
- `acceptLockedRisk(accountId, bytes32 proofHash)` — only `AGENT_VERIFIER`; sets `lockedRiskAccepted` + 24 h expiry; emits `LockedRiskAccepted`.
- `registerUnwinder(accountId, address who)` — owner-only; `who` is the router (or fallback unwinder).
- `setGateState(accountId, bool open)` — `NAV_ORACLE`/keeper; emits `GateShut` + `SegregationChanged`.
- `unwind(accountId)` — unwinder-only; requires `health < 0.85` or `debt > unwindableNow·0.80`; requires `debt ≤ unwindableNow` unless valid `lockedRiskAccepted` (I13); calls router `spanNetUnwind` or `unwindNettedFallback`; emits `Unwound(repaid, badDebt)`.
Access-control table:
| fn | owner | agent | unwinder | agentPassVerifier | navOracle/rwaAdapter |
|---|---|---|---|---|---|
| onboard / setRwaPosition / draw / repay / registerUnwinder | ✓ | ✗ | ✗ | ✗ | ✗ |
| agentDraw / accrueCoupon | ✓ | ✓ | ✗ | ✗ | ✗ |
| refreshMarks | ✓ | ✓ | ✗ | ✗ | ✓ (via adapters) |
| stepUp / acceptLockedRisk | ✗ | ✗ | ✗ | ✓ | ✗ |
| setGateState | ✗ | ✗ | ✗ | ✗ | ✓ |
| unwind | ✗ | ✗ | ✓ | ✗ | ✗ |
Custom errors (complete): `STALE_MARK, NavStale, DebtExceedsBp, CapExceededBlock, NotHumanApproved, GridOverflow, InsufficientUnwindable, GateShutNoLiquidity, NotFound`.
Events (complete): `Onboarded, RwaPositionSet, Drew, Repaid, SteppedUp, LockedRiskAccepted, GateShut, SegregationChanged(unwindableNow, earningLocked), Unwound(accountId, repaid, badDebt), BadDebtProjection`.
Gas targets: draw ≤ 180k; `refreshMarks` + `computeBp` ≤ 140k; `marginBreakdown` ≤ 150k; `accrueCoupon` ≤ 90k; `stepUp` ≤ 90k.

### 6.4 `RwaCollateralAdapter.sol` (new; the only file that knows RWA token specifics)
- Storage: `mapping(address asset => RwaAsset { uint8 class; bool transferRestricted; address markSource; uint8 decimals; bool permissioned; })` — R1 (equity token) or R2 (treasury).
- `setPosition(accountId, asset, amount)` — pulls `mark` via adapter: R1 from `MarkFeed` (token price on Base); R2 from `NavSignalOracle` (posted `navPerShareWad` + `accrualPerSecondWad` + `sourceTxHash`).
- `transferRestricted(asset)` — reads the token's transfer-restriction flag via a minimal `IERC1404`-style check **[assumption — verify per token; permissioned tokens (OUSG) are never demo-held; the flag models R1-style restricted tokens]**.
- Events: `RwaPositionSet(accountId, asset, amount, class)`, `NavRefreshed(asset, navPerShareWad, accrualPerSecondWad, sourceTxHash)`.
- If a token's mark/transfer API differs from the assumption, **only this file changes** (adapter rule).

### 6.5 `NavSignalOracle.sol` (new)
- Trusted-signer MVP, disclosed in `limits.md`. `postNav(bytes sig, NavRecord {asset, navPerShareWad, accrualPerSecondWad, sourceTxHash, observedAt})` — signature by `navSigner`; `observedAt` monotonic per asset; `sourceTxHash` pinned for BR3 verification.
- Production path (README): multi-oracle + issuer-signed feeds. State the limitation; do not publish without it.
- Events: `NavPosted(asset, navPerShareWad, accrualPerSecondWad, sourceTxHash, observedAt)`.

### 6.6 Base components (full specs — nothing is defined in another file)
**`PortfolioMarginHook.sol`** — extends `BaseHook` (v4-periphery, pinned sha). Logic in `beforeModifyLiquidity` + `beforeRemoveLiquidity`: any liquidity decrease/removal for a locked position while `engine.debt(owner) > 0` reverts `SpanMarginBreach()`. Storage: `mapping(uint256 tokenId => uint256 accountId) lockedTo`. Events: `PositionLocked(tokenId, account)`, `Unlocked(tokenId)`. Address mined once via `script/MineHook.s.sol` for the exact flags needed (fewer flags = cheaper mining) **[assumption: verify against v4-periphery examples]**. Revert path ≤ 40k gas.

**`AquaCreditLine.sol`** — all Aqua calls behind `IAquaAdapter` (two impls: `RealAqua` on fork, `MockAqua` in unit tests). Expected external names **[assumption — verify in `1inch/aqua` repo; adapter isolates]**: `ship / dock / pull / push / rawBalances`. Our functions: `openAccount(accountId)`, `draw(accountId, amtWad)` (Aqua virtual balance to the user's own balance — no token custody transfer), `repay(accountId, amtWad)`, `creditLineOf(accountId) view`. Events: `LineDrawn(accountId, amt, usdcWad)`, `LineRepaid`. Invariant I1 verified by a balance-delta test.

**`SpanVMRouter.sol` + opcode `0xf1 spanNetUnwind`** — vendored `1inch/swap-vm` (release/1.1), redeployed with one new instruction. Byte layout **[assumption: verify exact ISA encoding in the repo's whitepaper/doc; the opcode table lives in one file]**:
```
0xf1 | 1 byte accountIdx (0–255 accounts in the tx batch)
     | 4 bytes maxGasHint (little-endian)
     | remainder: no inline args; operands fetched from CreditEngine storage by accountIdx
```
Semantics (pseudocode for `instructionSpanNetUnwind`):
```
1) a = accounts[accountIdx]; require(a.nonEmpty, EMPTY)
2) health = engine.computeHealth(a); require(health < 0.85, NOT_UNDERWATER)
3) burn LP via v4 modifyLiquidity (router is the registered Unwinder); collect fees + principal
4) sell entire stock + R1 legs to USDC via the Aqua path (no external AMM needed)
5) engine.repay(min(debt, usdcReceived)); any uncovered debt reverts BadDebtProjection (I3)
6) emit Unwound(accountIdx, repaid, badDebt = 0, gasUsed)
```
Fallback Mode (G-G1 fail): identical 6 steps in `CreditEngine.unwindNettedFallback(accountId)` in plain EVM, selected by a constructor flag — the opcode risk is isolated to this one file.

**`FeeStreamOracle.sol`** — trusted-signer MVP (disclosed in `limits.md`). Record: `{strategyPosId, windowStartTs, dailyFees[7] (USD-WAD), distinctTakers, excludedOwner, takerSample[≤64], rootHash}`; `postRecord(bytes sig, StreamRecord r, bytes32[] sample)`; verifies `navSigner`-analog `oracleSigner` signature, `windowStartTs > lastTs`, recomputes `rootHash` over the sample, and **reverts if any sampled taker equals the account owner** (Sybil filter enforced onchain). Events: `StreamRecorded(strategyPosId, avg, takers, score)`. Production: decentralized attestation; stated as limitation.

**`StrategyBureau.sol`** — computes + stores StrategyScore per §4.3 (uint16, 0–100); `mapping(strategyId => ScoreRecord[]) records` append-only (I10); `register(strategyId)` callable by anyone (self-registration is the two-sided onramp). Events: `ScorePosted(strategyId, score, takers, ts)`.

**`AgentPassVerifier.sol`** — off-chain backend validates the Agent Pass result (server-side only; a client-asserted result is never authorization) and calls `acceptProof(account, proofHash, capTier, expiry24h)` from the backend key. Storage: `mapping(bytes32 => bool used)` replay guard; `mapping(account => Proof[]) history`. Custom error: `ReplayedProof`. The World rubric's "denied/expired path" is demonstrated by the UI's denial flow + this contract never being called.

**`ReceiptsRegistry.sol`** — `record(account, to, amount, memo)` owner-or-agent; emits `AgentSpent(account, to, amount, memo, ts)` (I8); the x402 bill (if enabled) mirrors here via `spendObserved`.

### 6.7 Indexer service (`indexer/`, TypeScript, Node 22)
Endpoints (complete set; internal only):
- `GET /snapshots/:posId` → JSON array of `{ts, feesOwedWad}` (from the v4 PositionManager adapter).
- `GET /takers/:poolKey?from&to&exclude=0x…` → `{count, sample[≤64], csvSha256}` — Swap events filtered by sender; the excluded address is the account owner.
- `POST /records/:posId` → builds + signs `StreamRecord` (owner exclusion applied, sample hashed), submits to `FeeStreamOracle`; returns `{txHash, rootHash}`.
- `GET /nav/:asset` → latest posted `{navPerShareWad, accrualPerSecondWad, sourceTxHash, observedAt}` (cached ≥ 60 s).
- `POST /nav/:asset` → reads OUSG/USDY state from Ethereum mainnet RPC (view calls), builds + signs `NavRecord`, submits; returns `{txHash, sourceTxHash}`.
Persistence: single-node SQLite on disk (`npm run start`). Determinism: identical raw reads → identical signed record (fixed ordering, `observedAt` from data, never wall clock). Rate limits: RPC responses cached ≥ 30 s. Failure handling: upstream error → keep last record; UI flags stale feed (I9 analog).

### 6.8 Web (Next.js) — four screens, complete
1. **Onboard** — connect wallet → select demo account preset → World sign-in (or IDKit) → grant Unwinder → show granted caps. One screen.
2. **Credit Desk** — two-column book: stock leg, LP leg; live `health`, `BP`, `debt`; autonomy cap gauge; `Draw` button (agent auto-draws too); receipts history (from `ReceiptsRegistry`); StrategyScore badge with the formula shown verbatim.
3. **Stress tab** — the 16-scenario grid as a heat strip; hover shows scenario inputs; "run replay" against `CrashTimeline` (Aug 2024 / Feb 2025 / Oct 2026) printing per-scenario losses and the isolated-account comparator.
4. **Agent tab** — policy log, x402 receipt, World step-up button (phone verification → high-tier confirmation).
v3 additions: **collateral-mix bar** on the Credit Desk (three segments + `unwindableNow` vs `earningLocked` split line; locked segment carries a "earning but locked" badge + reason: "redemption capped" / "transfer restricted" / "gate shut"); **coupon ticker** ("+$X.XX borrowing power today — OUSG NAV accrual" + source tx link, BR3); **gate-shut toast** on `SegregationChanged` (locked segment animates, autonomy gauge drops, "request step-up" CTA).
Copy rules: human tone, no marketing adjectives; every number carries its unit; persistent "non-custodial — Aqua virtual balance" badge; no banned words (§0.5).

---

## 7. Requirements tables

### Functional (complete — F1–F20)
| ID | Req | Acceptance |
|---|---|---|
| F1 | Onboard account with 2 base legs | state ACTIVE; invariants hold; `Onboarded` emitted |
| F2 | Compute BP from grid | matches TS mirror on 1,000 goldens, exact match |
| F3 | Draw, repay, health, re-pricing | debt ≤ BP always; reverts recorded |
| F4 | Hook reverts un-authorized removal | reverts `SpanMarginBreach` with debt > 0; succeeds after full repay |
| F5 | AquaCreditLine has no token custody transfer | after draw + repay, wallet token balances equal before (rounded WAD); lifecycle gas < 0.01 USD on fork |
| F6 | Fee stream record posts with owner exclusion | record reverts if a sampled taker equals the account owner |
| F7 | BP grows with fee stream credit | credit = §4.3 equation; test vectors provided |
| F8 | Agent auto-draw within caps | 3 draws / 12 h max; 4th reverts `CapExceededBlock` |
| F9 | Agent Pass step-up raises cap | new cap active 24 h; replay of same proof reverts `ReplayedProof` |
| F10 | Denied Agent Pass path | expired/cancelled → no step-up; UI shows DENIED; protected action never occurs |
| F11 | Atomic unwind | ends with debt = 0; `Unwound(badDebt=0)`; I1 holds post-tx |
| F12 | Isolated comparator crash view | UI prints isolated liquidation value + cross-margined survival from identical inputs |
| F13 | x402 spend recorded | 1 receipt row + optional tx link |
| F14 | Bureau append-only | 2 records for same strategy → strictly increasing timestamps |
| F15 | RWA positions onboard (R1 + R2) with real marks | marks resolve on fork; `RwaPositionSet` emitted; no synthetic path in the demo |
| F16 | NAV accrual credit accrues daily | after `accrueCoupon`, credit increases by exactly `accrualPerSecondWad × elapsed`; I12 enforced |
| F17 | Segregated margin correct under gate shut / transfer restriction | `unwindableNow` excludes ineligible legs; `SegregationChanged` emitted; UI badge flips |
| F18 | Unwind blocked beyond liquidatable backing | `unwind` reverts `InsufficientUnwindable` when debt > unwindableNow and no valid step-up |
| F19 | Step-up can accept locked-liquidity risk | with accepted proof, unwind proceeds; `LockedRiskAccepted` emitted; expires in 24 h |
| F20 | Coupon + fee credit share the 10% cap | combined `feeCreditFees + navAccrualCredit ≤ cap`; boundary fuzz cases pass |

### Non-functional (complete — N1–N10)
| ID | N Requirement | Acceptance |
|---|---|---|
| N1 | Determinism / reproducibility | `pnpm mirror:test` goldens; any CI runner byte-identical |
| N2 | Legibility in 90s | a reviewer without video gets the mechanism from README top + Sponsor-map |
| N3 | Gas discipline | forge snapshot checked in CI; no function > 600k |
| N4 | Security posture | all external calls only through adapters; no unbounded loops; reentrancy guarded |
| N5 | Honesty | `docs/limits.md` lists trusted-oracle MVP, mocked World proofs, fork-only Aqua path, RWA source limits |
| N6 | Reproducibility of datasets | every CSV has `.sha`; `make dataset` regenerates from public RPC reads |
| N7 | Live in 1 command | `make fork && make demo` from a clean clone works on the team's machines |
| N8 | Commit hygiene | no single-commit entry; daily commits; CI blocks single-commit-only repos (1inch rule) |
| N9 | RWA honesty | README + `docs/rwa-sources.md` state: we read public OUSG/USDY state only; OUSG is KYC/qualified-purchaser; instant-redeem caps cited; R1 dividend coupon = 0 (unverified); issuer insolvency risk disclosed |
| N10 | RWA determinism | `rwaStress.ts` mirror byte-identical to `RwaStressLib` on ≥ 300 RWA golden vectors (gate shut × open, restricted × not, cap boundary) |
| ID | N Requirement | Acceptance |
|---|---|---|
| N9 | RWA honesty | README + `docs/rwa-sources.md` state: we read public OUSG/USDY state only; OUSG is KYC/qualified-purchaser; instant-redeem caps cited; R1 dividend coupon = 0 (unverified); issuer insolvency risk disclosed |
| N10 | RWA determinism | `rwaStress.ts` mirror byte-identical to `RwaStressLib` on ≥300 RWA golden vectors (gate shut × open, restricted × not, cap boundary) |

---

## 8. Sponsor integration sections

### 8.1 1inch — "Build an Aqua App" $5,000 (fit 9/10, odds High, load-bearing)
**Verified facts** [verified: ethglobal.com/events/mumbai/prizes/1inch, 2026-11-05]: prize $5,000 (1st $2,500 / 2nd $1,500 / 3rd $1,000); "Create a custom Aqua app that implements a sophisticated DeFi position"; "If you use SwapVM, you may modify SwapVM opcodes and define your own instructions"; "Projects that utilize SwapVM will be scored higher during the final judging"; official Aqua/SwapVM contracts required (redeployments of a modified SwapVM contract allowed); onchain token-transfer execution in the final demo (local forks ok); proper git history (no single-commit entries on the final day). Resources: github.com/1inch/swap-vm (release/1.1), github.com/1inch/aqua, github.com/1inch/sdks (Aqua TS SDK), whitepaper PDFs in-repo. Workshop today 17:30 IST, Workshop Room 2.
**Verify-first checklist (hour 0–2):** (1) clone both repos; confirm the instruction-dispatch extension point and the exact Aqua external function set (`ship/dock/pull/push/rawBalances` assumed — adapter isolates a wrong guess); (2) record the Base mainnet Aqua/USDC addresses from the repo's deployment docs into `docs/sponsor-map.md` with the commit hash; (3) confirm the patched-router redeploy path on the fork; (4) mentor confirmation that unmodified Aqua + patched SwapVM redeploy is in scope (prize page says yes — get the receipt anyway).
**Adapter:** `IAquaAdapter` (RealAqua on fork / MockAqua in unit tests). **Fallback:** Fallback Mode — Aqua unmodified, unwind via engine; the line still uses Aqua virtual-balance settlement (the load-bearing part).
**On-stage proof:** Aqua virtual-balance debit/credit inside the unwind transaction transcript; video names Aqua while the split-screen runs; README anchors `contracts/src/SpanVMRouter.sol` + `AquaCreditLine.sol` by line.
**Narrative upgrade (new, citable):** Robinhood's mainnet announcement lists **1inch among the spot venues in Robinhood Wallet for tokenized stock trading** [verified: robinhood.com newsroom via eco.com, 2026-10-08] — the production thesis "agent credit line drawn against tokenized equity, settled via 1inch rails" is a documented venue fact, not hand-waving.

### 8.2 Uniswap Foundation — "Build with Uniswap" $10,000 (fit 8/10, odds Medium-High, load-bearing)
**Verified facts** [verified: ethglobal.com/events/mumbai/prizes/uniswap-foundation, 2026-11-05]: $10,000 across 4 places ($4,000 / $3,000 / $2,000 / $1,000); any part of the Uniswap stack incl. new v4 hooks; **mandatory**: public repo + `FEEDBACK.md` + completed submission to `developers.uniswap.org/hackathon-feedback` including the FEEDBACK.md link; README must point to relevant contracts and lines. Workshop today 16:30 IST, Room 1.
**Verify-first checklist (hour 0–2):** pin v4 `{poolManager, positionManager, quoter, periphery}` Base addresses from official docs into `docs/sponsor-map.md`; pin the `BaseHook` version the hook subclasses; validate `script/MineHook.s.sol` address mining; confirm the hook needs only `beforeModifyLiquidity | beforeRemoveLiquidity` flags.
**On-stage proof:** video shows the exact `SpanMarginBreach` revert, then the unwind, then a successful removal after repayment; HUD toast names the hook.
**Competitive fact to pre-empt in the README:** this cycle's ETHOnline already awarded Uniswap prizes to RWA-flavored v4 hooks — **ClosingBell-Hook** (tokenized-stock swap-fee pricing) and **Bailiff** (keeper liquidation of restricted-RWA loans) [verified: showcase pages]. Delta sentence for judges: *"They priced RWA swaps or liquidated RWA loans. We guard cross-class collateral — equity + LP + treasury NAV — under one margin engine."*

### 8.3 World — "World ID Agent Pass" $5,000 (fit 8/10, odds Medium-High, load-bearing)
**Verified facts** [verified: ethglobal.com/events/mumbai/prizes/world, 2026-11-05]: open track $5,000 (1st $2,500 / 2nd $1,500 / 3rd $1,000); official Agent Pass required; complete journey (request → user completes → validated → protected action); a **denied/expired/cancelled path where the action does not occur**; results validated in a secure backend (client secrets never exposed; a client-asserted result is never authorization); integration debrief (time-to-first-success, friction, missing capability, one improvement); **proofs are currently mocked** — fake identities, not for production. Links: auth.world.org, /docs, /portal.
**Verify-first checklist (hour 0–1):** create the demo app in the portal; record app ID + scopes; complete one happy-path verification < 15 min; confirm the backend validation endpoint (record in `docs/sponsor-map.md`); implement the denied path explicitly (expiry + user-cancel), with a UI "simulate denial" only if the live path can't run.
**Adapter:** `WorldFlowClient` (backend) + `AgentPassVerifier` (onchain allow). **Fallback:** IDKit basic sign-in for onboarding + server-side step-up confirm; on-chain verifier unchanged.
**On-stage proof:** agent hits the autonomy ceiling mid-crash → denied path first (expired proof, no raise) → phone tap → step-up granted → `LockedRiskAccepted` → unwind. The gate-shut trigger makes this a "meaningful action that needs a human identity or approval layer" in the rubric's own words — the strongest answer to "not simply a login screen."

### 8.4 x402 — infrastructure garnish (one bill, one receipt)
One externally-reachable x402 endpoint [to verify at kickoff; if none reachable from the venue network, self-host and label it self-hosted in the UI]. `ReceiptsRegistry` records the spend regardless; the x402 call is the second half. Cut first under time pressure (§12).

---

## 9. Security & threat model

| Threat | Mitigation | Residual risk |
|---|---|---|
| Oracle signer key compromise (fee + NAV signers) | dedicated hot keys, separate from team signing; records windowed + fee credit capped at 10% of collateral bounds the blast radius | key loss mid-demo stops credit growth (fail-closed); stated |
| Marks manipulation (sandwich the TWAP window) | 30-min TWAP; `STALE_MARK` revert; fork demo uses real pool marks | last-block manipulation in thin windows possible; disclosed |
| Front-run of draws | one draw per account per block; `CapExceededBlock` on the second | none material |
| Reentrancy through Aqua/v4 callbacks | pull-only tokens (I1); no untrusted external calls mid-accounting; checks-effects-interactions | adapter bug in a real protocol call — fork tests |
| Treasury NAV manipulation (posted accrual inflated) | source tx pinned per record; monotonic `observedAt`; accrual capped by the 10% fee-credit cap; BR3 lets a judge verify from the source | signer compromise inflates credit within the cap; stated in limits.md |
| Weekend/overnight gap on tokenized equity | `GAP_PREMIUM` stress term; mark staleness rule | premium magnitude is an assumption; disclosed |
| Permissioned liquidity (can't exit when needed) | segregated margin; R2 never backs unwind unless gate open + under cap; I13 | locked leg still loses value in a crash; human step-up explicitly accepts that |
| Issuer insolvency (tokenized asset issuer fails) | README/limits disclose; engine treats RWA marks as oracle inputs with staleness + haircuts | holders can lose principal; demo holds no KYC'd assets |
| Borrower wash-trades to inflate fee earnings | borrower exclusion + ≥5 takers + vol/drawdown haircuts + mainnet gas friction | stranger-botnet Sybil partially gameable; stated |
| Transfer-restriction surprise post-onboard | `eligR1=0` recompute; UI badge; no silent margin | restriction flag source per token must be verified (adapter) |
| Agent key compromise | per-draw + per-window caps; raises need human; receipts visible | capped damage within window |
| Unwinder griefing | unwind only in STRESSED / backed by unwindableNow or accepted step-up | router bug could unwind healthy account — fuzz includes healthy-account attempts |
| World proof replay / mock confusion | nonce-bound `used` set; UI disclaimer once; backend logs MOCK_PROOF | revoked-after-accept edge |
| Stale NAV > 26h | R2 eligibility → 0; UI stale flag; I9 | engine stops growing credit (fail-closed) |

---

## 10. Test plan (complete)

- **Unit (forge):** `SpanMathLib` scenario bottoms + rounding edges (§4.6) + bureau score (16 fixed cases); `RwaStressLib` — lossR1/lossR2/eligibility/segregation boundary cases (cap boundary, gate shut, restricted).
- **Invariant (forge, `invariant_` handlers):** I1/I2/I3 with actor contracts (borrower, agent, unwinder, attacker); I4 hook lock; I10 bureau append-only; I11/I13 RWA segregation.
- **Fuzz (forge):** 10,000 runs including RWA legs; assert I2, I3, I11, I12, I13; accrual monotonicity; cap enforcement.
- **Golden vectors:** `test-golden/span_golden.json` (1,000) + `test-golden/rwa_golden.json` (300) — Solidity and TS byte-identical (CI).
- **Fork integration:** real Base stock token mark + transfer; real OUSG/USDY NAV read from Ethereum mainnet via public RPC recorded into `NavSignalOracle`; full lifecycle with RWA legs.
- **E2E (Playwright):** collateral-mix bar shows locked segment after gate-shut toast; coupon ticker increments; step-up CTA appears; denied path leaves gauge unchanged.
- **Negative/attack:** inflated NAV (rejected by cap), stale NAV, transfer-restricted mid-life, gate-shut + draw same block, unwind attempt beyond unwindableNow (reverts), healthy-account unwind attempt (reverts).
- **Static analysis:** solhint + `forge build` warnings-as-errors + `pnpm typecheck/lint`.

---

## 11. Demo script (stage ≤ 4 min; video 3:00–3:30, 1080p, human voiceover, no AI voiceover)

- 0:00–0:20 cold open: "44 RWA-lending projects hit ETHGlobal this cycle; zero finalized. Flux lends against one treasury in isolation. We asked: what if RWA is a *margin class* — cross-netted against LP cashflow under an agent's credit line?"
- 0:20–1:00 onboard + collateral mix bar (equity token + LP + treasury NAV); coupon ticker starts (+$X.XX borrowing power today, source tx linked).
- 1:00–1:35 the crash: isolated account margin-called vs cross-margined; R1 weekend-gap term visible in the grid strip.
- 1:35–2:35 **climax — the gate shuts**: treasury redemption gate closes (oracle posts `gateOpen=false`) → locked segment jumps → autonomy gauge drops → agent requests cap raise → **denied path first** (expired proof, no raise) → phone tap → human accepts locked-liquidity risk → `0xf1 spanNetUnwind` fires on liquidatable legs → `badDebt = 0` printed next to the isolated account's liquidation number.
- 2:35–3:05 the proof (BR2+BR3): hash-pinned fee stream root + real NAV accrual tx; Basescan links if BR1 landed.
- 3:05–3:30 close: credits, repo, limits slide (trusted oracle, mocked World proofs, fork-based Aqua, KYC'd assets not held).
Rehearsal ≥5× before recording; recorded tap backup exists. Fallbacks in order: recorded video → offline Anvil fork → marks-only RWA (no coupon beats) → pre-recorded tap.

---

## 12. Build order

**Pre-window (rule-safe):** repo scaffold, this file, storyboard, crash CSVs from public data, `docs/sponsor-map.md` + `docs/rwa-sources.md` with verified names, banned-words CI, verify checklists printed. No project code before window start.

**Hour-by-hour (window start Thu ~19:00 IST post-kickoff; internal submit target Fri 18:00 IST; official deadline Sat Nov 7 09:00 IST [verified 2026-11-05; cached pages still show Fri 19:30 — treat Fri as real]):**
| Hours | Eng A (Solidity) | Eng B (TS) |
|---|---|---|
| 0–2 | vendor 1inch/aqua + swap-vm; **G-G1 attempt**; mentor touchpoints (1inch 17:30, Uniswap 16:30 workshops) | Anvil Base fork up; indexer skeleton; World portal app |
| 2–8 | `RwaStressLib` + `RwaCollateralAdapter` + `NavSignalOracle`; **G-RWA-1 attempt** (stock mark + NAV read) | ETH-mainnet NAV reader; stock-token mark feed; goldens runner |
| 8–14 | `SpanMathLib` + `CreditEngine` core + RWA fields + `marginBreakdown` | `spanMath.ts` + `rwaStress.ts` mirrors + 1,300 goldens; parity CI |
| 14–20 | `AquaCreditLine` + `FeeStreamOracle` + `StrategyBureau` | Credit Desk screens 1–2; collateral-mix bar; coupon ticker |
| 20–26 | `PortfolioMarginHook` + mining; **G-G2**; `SpanVMRouter` opcode or fallback | Agent policy + x402 bill + denied-path tooling; README sponsor-map + rwa-sources |
| 26–32 | fallback unwind; fork E2E incl. gate-shut beat; gas tuning | Stress tab; gate-shut visuals; `docs/limits.md` + `agent-debrief.md` **written now**; record pass 1 |
| 32–36 | freeze; BR1 mainnet deploy if gas | record pass 2; FEEDBACK.md; prize selections (3); CI green; booth 1-pager |
| 36–40 | buffer | buffer; **submit — internal target Fri 18:00 IST** |

**Cut-list (first → last):** x402 live call (receipts only) → coupon engine (marks-only RWA, keep segregation + gate model) → 30d→7d fee window → bureau third fixture → historical replay (live accumulation only) → Agent Pass richness (IDKit fallback) → opcode (fallback engine drive). **Never-cut:** FeeStreamVerifier exclusion + taker floor, hook revert, SPAN grid + parity, atomic unwind semantics, **segregated-margin semantics**, non-custody invariant, `docs/limits.md` + `docs/rwa-sources.md`, no-single-commit rule.

---

## 13. Submission checklist

- [ ] README: problem, mechanism, **Sponsor Integration Map** with contract line anchors, demo + video links, **Limitations** (trusted oracle, mocked proofs, fork-based Aqua, RWA sources/limits), AI-attribution + committed spec files.
- [ ] `docs/rwa-sources.md`: every RWA fact with source + retrieval date (OUSG caps, chain list, stock token on Base, gap-risk citation, Robinhood-1inch venue citation).
- [ ] `FEEDBACK.md` in repo **and** submitted to `developers.uniswap.org/hackathon-feedback` with the link (mandatory).
- [ ] `docs/agent-debrief.md` per World rubric.
- [ ] Exactly **3 partner prizes selected**: 1inch Aqua App $5,000 (Classic), Uniswap $10,000 (Classic), World Agent Pass $5,000 (open).
- [ ] Video 3:00–3:30, ≥1080p, human voiceover, **no AI voiceover**.
- [ ] Addresses listed (fork documented; mainnet if BR1); `cast` reproduction commands in README.
- [ ] CI green (banned words incl. "yield guaranteed", lint, goldens, fork).
- [ ] Git history: multiple commits per day; no single mega-commit.
- [ ] Booth 1-pager printed ×3 (partner judging is live at booths [verified 2026-11-05]).
- [ ] `make check-submission` passes all of the above mechanically.

---

## 14. Judge / VC red-team Q&A (exact answers)

1. **"How is this different from Veilend / Folio / BorrowBot?"** — "Veilend scores simulated history; Folio is price-only with a collar; BorrowBot is price-only via Morpho. We underwrite verifiable third-party earnings — LP fees and treasury NAV accrual — cross-margin three classes, and gate agent autonomy behind a verified human."
2. **"Flux Finance already lends against tokenized treasuries."** — "Correct — single collateral, isolated, since 2023, and still small. We net a treasury NAV signal against LP cashflow and equity in one grid, segregate by liquidity, and add the agent/human layer. Flux is the proof the category is real and unclaimed at the cross-class level."
3. **"Your RWA-lending lane is 0-for-44 at ETHGlobal this year."** — "That's exactly why we're not in it. We're a margin engine with an RWA class — same reason margin projects finalize and RWA-lending projects don't."
4. **"Why read Ethereum NAV from a Base demo?"** — "Custody-free signal reading, not a bridge: public state, view calls, source tx pinned. Production is same-chain or multi-oracle — the adapter isolates the difference."
5. **"Weekend gap on tokenized equity?"** — "Documented: tokens trade 24/7 while the underlying trades market hours. That's why `GAP_PREMIUM` multiplies the equity shock loss and why the R1 haircut is 0.75."
6. **"Where does lender yield come from at demo scale?"** — "Honest: demand-side only here; supply via stablecoin vaults / Aqua reserves in production. We don't fake it on stage."
7. **"Is the NAV signal manipulable?"** — "It's issuer-published state with the source tx pinned and accrual capped at 10% of collateral; residual trust is disclosed in limits.md. Production = multi-oracle."
8. **"What breaks without 1inch / Uniswap / World?"** — "Aqua → USDC escrow line; hook → LP escrow; World → IDKit sign-in + server step-up. Named fallbacks, not decorations."
9. **"Tokenized securities are licensed-venue territory — are you a broker-dealer?"** — "We're a B2B risk kernel with an intentional path through licensed venues; retail use needs counsel. Today: traders, MMs, funds, protocols."
10. **"Regulatory risk of holding/tokenizing RWAs?"** — "We hold nothing KYC'd; we read public state and underwrite user-held positions. Issuer insolvency risk is disclosed as residual."
11. **"What one thing kills this in production?"** — "Sybil-fee gaming at scale — our answer is verifier + economics, not cryptography; if that fails, we misprice risk."
12. **The deciding question: "Why is this a prize and not a feature?"** — "Because nothing prices permissioned liquidity into margin: the segregated unwindable/locked split is the mechanism, and the Bureau's cross-asset cashflow dataset compounds with every scored strategy — the moat is data no fork copies."

---

## 15. Kill conditions

| ID | Check (time-boxed) | Action if hit |
|---|---|---|
| K1 | G-G1 within 2h | Fallback Mode; demote 1inch strength; keep everything else |
| K2 | Real v4 fee deltas readable within 6h | drop BR2; live-only accumulation; state in limits |
| K3 | World happy path < 2h + denied path available | IDKit fallback or submit 2 sponsor entries |
| K4 | Archive RPC for historical marks (30 min) | hash-pinned CSV replay |
| K5 | Mainnet gas > $5 | skip BR1; fork-only demo |
| K6 | Demo instability (>2 crashes in captures) | recorded video primary; live = single unwind beat |
| **K7** | **G-RWA-1 (hour 8): stock mark + NAV read both live** | **marks-only RWA: couponPerDay = 0, segregation + gate model kept; pitch becomes "RWA-ready engine, equity class demoed"; coupon engine cut, never half-built** |
| **K8** | **NAV mechanics differ from assumption (rebasing vs exchange-rate)** | adapter isolates the difference; accrual computed from posted `accrualPerSecondWad`; no formula change elsewhere |

---

## 16. Environment

### 16.1 Env vars
```
RPC_FORK_URL=                  # Base mainnet (public ok; archive is paid — see K4)
RPC_ETH_MAINNET=               # for OUSG/USDY NAV reads (public ok, view calls)
RPC_BASE_SEPOLIA=
DEPLOYER_KEY=                  # dev-only, burnable
ORACLE_SIGNER=                 # FeeStreamOracle
NAV_SIGNER=                    # NavSignalOracle
BACKEND_SIGNER=                # AgentPassVerifier
AQUA_ADDR=                     # 1inch/aqua deployments docs [to verify]
SWAPVM_ROUTER_VENDORED_ADDR=   # patched router address after deploy
POOL_MANAGER_BASE=             # [to verify from Uniswap docs]
POSITION_MANAGER_BASE=         # [to verify]
WORLD_APP_ID=
WORLD_BACKEND_ENDPOINT=        # Agent Pass validation URL [to verify]
AGENT_BILL_X402_URL=           # one endpoint [to verify or self-host]
STOCK_TOKEN_BASE=              # Coinbase-style tokenized stock on Base [to verify symbol/address]
OUSG_ADDR_ETH=                 # [to verify from Ondo docs]
USDY_ADDR_ETH=                 # [to verify from Ondo docs]
GATE_KEEPER_KEY=               # dev key for setGateState demo beat
```

### 16.2 [to verify] ledger (close hour 0–8)
1. OUSG/USDY contract addresses on Ethereum mainnet + NAV read mechanics (rebasing vs exchange-rate vs price()) from Ondo docs — drives `NavSignalOracle` schema.
2. Coinbase tokenized-stock token address(es) on Base + mark path + permissionless transfer from a fresh wallet (Aave collateral implies yes; verify) + decimals.
3. Robinhood mainnet announcement naming 1inch as a Wallet spot venue — cite from robinhood.com directly (we currently cite it via eco.com's coverage).
4. Aqua contract address on Base + exposed function set (`ship/dock/pull/push/rawBalances` assumed; adapter exists for this) + SwapVM instruction extension point.
5. v4 Base addresses (PoolManager/PositionManager) + `BaseHook` periphery pin + hook-address mining.
6. World Agent Pass backend validation endpoint + mock-mode scopes.
7. One reachable x402 endpoint for the single bill (else self-host and disclose).

### 16.3 Tool versions
- Node 22 LTS, pnpm 9 [assumption: confirm at kickoff; no mid-event major bumps].
- Foundry stable (no update after window start); Forge snapshot in CI.
- Next 14.x [assumption — pin at kickoff].
- Anvil 0.2.x with `--fork-url` + pinned `--fork-block-number`.

### 16.4 Make targets (defined once)
- `make setup` — foundryup + pnpm install + `.env`; fails if `RPC_FORK_URL`/`DEPLOYER_KEY` unset.
- `make fork` — Anvil fork of Base mainnet at pinned block; deploy vendored SwapVM patch + all §6 contracts (deterministic salts); write `deploy/fork-addresses.json`.
- `make nav` — one-shot NAV read from Ethereum mainnet → post to `NavSignalOracle`; writes `deploy/nav-record.json` with source tx hash.
- `make demo` — fork + nav + indexer + web + scripted sequence (onboard, coupon accrual, draw, gate-shut, step-up, unwind).
- `make mirror:test` — TS mirrors vs `span_golden.json` + `rwa_golden.json`.
- `make test` — forge + pnpm typecheck/test + goldens + solhint.
- `make e2e` — headless Playwright over the four screens incl. gate-shut toast.
- `make dataset` — regenerate crash CSVs + `.sha` from public RPC reads; identical inputs → empty git diff.
- `make check-submission` — mechanical §13 validation (banned words, ffprobe duration 3:00–3:30, FEEDBACK/agent-debrief/rwa-sources presence, multi-commit history, selections file).

---

## 17. Definition of Done

- [ ] Contracts: all §6 components compile; tests green; gas snapshot ≤ targets; fork lifecycle incl. RWA legs passes.
- [ ] TS mirror parity: 1,000 + 300 goldens byte-identical in CI.
- [ ] RWA: G-RWA-1 signed or marks-only fallback declared in DECISIONS.md; `docs/rwa-sources.md` complete.
- [ ] Demo: video 3:00–3:30 recorded + uploaded; `make demo` works from clean clone in < 2 min.
- [ ] Sponsor artifacts: FEEDBACK.md + form; agent-debrief; sponsor-map; 3 prizes selected; booth 1-pager.
- [ ] Submission hits the internal Fri-evening target.
- [ ] Honesty: limits.md + rwa-sources.md present and specific; no banned words (CI); claims match §2 exactly.

---

## 18. Bottom line

The RWA upgrade is worth +0.4 mean (8.3 → 8.7) only because it is executed as a margin class with real cashflows and permissioned-liquidity segregation — the exact thing the 44-project RWA-lending graveyard never did — and it is protected by one hard gate (G-RWA-1) with a marks-only fallback so a failed RWA leg degrades the pitch instead of sinking the build. If G-RWA-1 fails and you cannot ship the coupon story, submit anyway with segregation intact: a clean 7.6 honest engine beats a broken 8.7 Frankenstein every single time.

---

## Sources

- ethglobal.com/events/mumbai/prizes + /events/mumbai/info/start (fetched 2026-11-05): sponsor amounts and rubrics (1inch Aqua $5k incl. modified-SwapVM permission + local forks + no single-commit; Uniswap $10k/4 places + FEEDBACK.md + feedback form; World Agent Pass tracks + journey/denied-path/server-validation rubric + mocked-proofs note; Arc = Circle L1; Hedera x402 track), staking rule, deadline Sat Nov 7 09:00 IST (cached contradiction: Fri Nov 6 19:30), partner judging at booths.
- Dataset pulls (2026-11-02 / 2026-11-05): finalist base rates (4.10% 2026-IRL, 39/951; 2.20% all 2026), RWA+lending lane 44 projects / 0 finalists, RWA-mention 288/6, lending-lane 9.1%, prior-art pages opened (Veilend, Folio, BorrowBot, OddsFlow, ArcBook, Slopstock, Takarabako, ALMA, TARE; RWA-lane: Rialto, Tenor, tokenize-it, ClosingBell-Hook, Bailiff, ArcAsset, Galvanic, stockshield.eth, TrueTick, Unison, explorador.pt).
- Ondo: ondo.finance/ousg (daily yield, 24/7 instant mint/redeem, qualified purchasers); OUSG ~$650M AUM, KYC-only, $100K min, $25M/$50M per-24h instant caps, Ethereum/Polygon/Solana/XRPL deployment (eco.com OUSG deep dive, 2026-09-15); USDY permissionless trading + DeFi collateral (Ondo X post); composition 92% treasuries + 8% deposits (eco.com, Apr 2026 data).
- Flux Finance: fluxfinance.com (only collateral OUSG); Ondo SEC letter (first DEX lending protocol for permissioned tokenized securities); launch Jan 2023.
- Tokenized equities: aave.com/blog/coinbase-tokenized-stocks (7 stocks on Base, live Aug 24 2026, Aave V4 collateral); robinhood.com newsroom (Robinhood Chain mainnet Jul 1 2026; 1inch among Wallet spot venues; tokenized debt securities; security agent) via eco.com coverage (2026-10-08); weekend-gap risk disclosures (same).
- RWA.xyz pull (2026-11-02): RWA total $38.82B. Ondo blog: tokenized stocks >$3B, tripled in 8 months.
- 1inch Aqua Incubator: 1inch.network/aqua-incubator + gov.1inch.network (up to $50k/team, milestone funding, revenue share, hackathon demos "a strong signal").
