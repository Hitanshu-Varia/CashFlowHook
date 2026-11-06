# Base Sepolia

The test deployment target is Base Sepolia, chain ID `84532`. Oracle data is read from Ethereum mainnet through `RPC_ETH_MAINNET`, while CashflowHook contracts and signed NAV posts use `RPC_BASE_SEPOLIA`.

The current official Uniswap v4 deployments on Base Sepolia are:

- PoolManager: `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`
- PositionManager: `0x4b2c77d209d3405f41a037ec6c77f7f5b8e2ca80`

Source: [Uniswap v4 deployments](https://developers.uniswap.org/docs/protocols/v4/deployments), retrieved 2026-11-06.

## Local setup

1. Copy `.env.example` to `.env`.
2. Set `RPC_BASE_SEPOLIA` to a Base Sepolia RPC endpoint.
3. Set `DEPLOYER_KEY` to a disposable testnet-only wallet key and fund that address with Base Sepolia ETH. Keep the value in the local, gitignored `.env` file.
4. Set `CHAIN_ID=84532` and keep the v4 addresses above.
5. Deploy with Foundry after installing it. The deploy script uses the deployer as the NAV signer by default; set a separate `NAV_SIGNER` and `NAV_SIGNER_KEY` only if desired.

No mainnet asset custody or transaction is part of this testnet flow.
