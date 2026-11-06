# Decisions

- 2026-11-06 — The TypeScript policy adapter now mirrors `CreditEngine` autonomy semantics: its default per-draw cap is 2% of borrowing power and its 12-hour window allows three draws. A World step-up is required only when the contract-synchronised `needsStepUp` flag is set; locked-liquidity consent remains separately required for an excess unwind. This resolves the earlier adapter's unsourced fixed debt threshold and keeps the on-chain contract as the authority.
