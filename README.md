# CashflowHook

CashflowHook is a non-custodial, cross-margined credit-line prototype for an AI agent. It models three collateral classes together: tokenized equity, a locked Uniswap v4 LP position, and a tokenized-treasury NAV signal. The product specification and acceptance criteria live in [`Agent/cashflowhook_v3_agent.md`](Agent/cashflowhook_v3_agent.md).

## Current integration status

The deterministic math, contract surfaces, TypeScript mirror, policy service, indexer boundary, and a fixture-driven dashboard are present. The live RWA adapters are intentionally not configured yet: no RPC or issuer contract settings are committed, and the application will fail closed rather than fabricate a NAV, mark, or transfer result.

The first live-data gate requires both of these read-only proofs:

- a verified Base tokenized-equity contract, with a reproducible mark and fresh-wallet transfer path;
- a verified Ethereum-mainnet OUSG or USDY issuer-state read, with its NAV/accrual mechanics and source transaction recorded.

Until that gate is signed in [`DECISIONS.md`](DECISIONS.md), the only honest fallback is marks-only RWA with treasury coupon credit set to zero.

## Local configuration

Create an untracked `.env` locally. Do not commit secrets or paste private keys into an issue, chat, or repository.
Copy `.env.example` to `.env`; the indexer loads that root file automatically when it starts.

```dotenv
# Required for the first read-only integration pass
RPC_FORK_URL=
RPC_ETH_MAINNET=

# Enables the read-only USDY issuer-oracle adapter on Ethereum mainnet.
NAV_READ_MODE=ondo-usdy

# Destination for signed oracle records. Use 84532 for Base Sepolia.
CHAIN_ID=84532
RPC_BASE_SEPOLIA=

# Verified addresses only; leave blank until their primary sources are recorded
STOCK_TOKEN_BASE=
OUSG_ADDR_ETH=
USDY_ADDR_ETH=
```

Wallet keys are needed only for local-fork deployment or explicitly authorised oracle-posting tests. The indexer accepts `ORACLE_SIGNER_KEY`/`NAV_SIGNER_KEY` and local fork contract addresses when that stage is reached.

When `NAV_READ_MODE=ondo-usdy`, the indexer uses Ondo's documented USDY Oracle Wrapper and follows its live ContinuousPriceOracle implementation before publishing a record. The optional `USDY_INSTANT_MANAGER_ETH` and `USDY_ORACLE_WRAPPER_ETH` settings are migration overrides. `USDY_CONTINUOUS_ORACLE_ETH` is an intentional implementation pin: set it only after reviewing an issuer migration, because a mismatch fails closed.

The read-only source can be checked at `GET /nav/source/:asset` (for example, `/nav/source/0x96F6eF951840721AdBF46Ac996b59E0235CB985C`). It does not need a signer or send a transaction. Posting with `POST /nav/:asset` additionally requires a NAV signer and a deployed `NavSignalOracle` address on the configured destination chain.

## Verification

Run package-local tooling to preserve the checked-in pnpm store layout:

```powershell
Push-Location Agent; .\node_modules\.bin\vitest.cmd run; .\node_modules\.bin\tsc.cmd --noEmit -p .; Pop-Location
Push-Location ts-mirror; .\node_modules\.bin\vitest.cmd run; .\node_modules\.bin\tsc.cmd --noEmit -p .; Pop-Location
Push-Location indexer; .\node_modules\.bin\vitest.cmd run; .\node_modules\.bin\tsc.cmd --noEmit -p .; Pop-Location
Push-Location web; .\node_modules\.bin\vitest.cmd run; .\node_modules\.bin\tsc.cmd --noEmit -p .; .\node_modules\.bin\eslint.cmd .; Pop-Location
```

Foundry is required for Solidity compilation, invariant tests, and fork tests. It is not bundled in this workspace.

## Safety and scope

This repository is a hackathon prototype, not a production lending service. External asset state is isolated behind adapters, signed records are monotonic, and stale data is intended to fail closed. See the v3 specification for the complete invariant and limitation set.
