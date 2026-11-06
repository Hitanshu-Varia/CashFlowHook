# RWA source ledger

Retrieved 2026-11-06. This ledger records only sources used by the live adapters; values stay behind adapter configuration rather than scattered through application logic.

## Treasury NAV: USDY on Ethereum

- [Ondo smart-contract addresses](https://docs.ondo.finance/addresses) identifies the Ethereum USDY token as `0x96F6eF951840721AdBF46Ac996b59E0235CB985C`, the USDY Instant Manager as `0xa42613C243b67BF6194Ac327795b926B4b491f15`, the Oracle Wrapper as `0x87b126e5518b6a1Bb8465779b4607C45C643DF90`, and the current ContinuousPriceOracle as `0xbAEC2b9fE27cD054e1c0C2B720aF117d9D7eC871`.
- [Ondo's USDY integration guide](https://docs.ondo.finance/developer-guides/usdy-instant-manager-integration) documents `getPrice()` / `getPriceData()`, 18-decimal USD prices, the wrapper as the stable integration point, and the issuer's redemption-pause status.
- [Ondo's continuous-pricing announcement](https://ondo.finance/blog/usdy-continuous-pricing) explains that price accrues on every read and directs integrations to the Oracle Wrapper.
- The adapter reads at one Ethereum block, follows the wrapper's current on-chain target (with an optional explicit implementation pin), resolves Ondo's published `ScheduledOracleSwitch` when one is present, derives the exact USD-per-share-per-second rate from the issuer's continuously compounded yearly rate, and pins the transaction emitting the active price/rate update. If any check cannot be reproduced, it fails closed and no NAV record is signed.
- The indexer exposes this record through the read-only `GET /nav/source/:asset` route. Posting the record to a CashflowHook deployment remains a separate signed transaction path.

## Equity RWA: pending G-RWA-1 verification

The Base tokenized-equity adapter remains unconfigured. It will not accept a token address until the contract, Chainlink mark path, decimals, and a fresh-wallet transfer on a local Base fork have all been reproduced and recorded here.
