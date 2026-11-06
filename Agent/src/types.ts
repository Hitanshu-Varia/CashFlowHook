/// @notice Shared types for the CashflowHook v3 agent package.
/// The policy engine, x402 client, and World step-up client all reference these.

export type Wad = bigint;

/** Outcome of a policy evaluation. */
export interface PolicyDecision {
  /** Whether the requested action is allowed under current policy. */
  allowed: boolean;
  /** Human-readable reason when denied. */
  reason: string | null;
  /** Maximum draw amount permitted right now, in USD-WAD. */
  maxDrawWad: Wad;
  /** Draws remaining in the current window. */
  drawsRemaining: number;
  /** Unix seconds when the current window resets. */
  windowResetAt: number;
}

/** Configuration for the deterministic policy engine. */
export interface PolicyConfig {
  /** Per-draw cap as a fraction of borrowing power (WAD-scaled, e.g. 0.02e18 = 2%). */
  perDrawCapWad: Wad;
  /** Maximum draws allowed per window. */
  maxDrawsPerWindow: number;
  /** Window length in seconds (e.g. 12 hours = 43200). */
  windowSeconds: number;
}

/** Mutable policy state tracked per account. */
export interface PolicyState {
  accountId: number;
  debtWad: Wad;
  /** Unix seconds of the last draw in the current window. */
  lastDrawAt: number;
  /** Number of draws in the current window. */
  drawsInWindow: number;
  /** Step-up accepted at this timestamp (0 = none). Expires after 24 h. */
  stepUpAcceptedAt: number;
  /** Contract-synchronised signal that pauses autonomous drawing. */
  needsStepUp: boolean;
  /** Whether locked-liquidity risk has been accepted via step-up. */
  lockedRiskAccepted: boolean;
}

/** Result of a draw attempt evaluation. */
export interface DrawEvaluation {
  allowed: boolean;
  reason: string | null;
  maxDrawWad: Wad;
  proposedDrawWad: Wad;
}

/** Result of an unwind authorization evaluation. */
export interface UnwindEvaluation {
  allowed: boolean;
  reason: string | null;
  /** Debt that can be unwound without step-up (liquidatable backing). */
  unwindableWad: Wad;
  /** Step-up required to unwind the excess. */
  excessWad: Wad;
}

/** An x402 payment header set returned by a bill endpoint. */
export interface X402PaymentHeaders {
  /** The x402 payment scheme, e.g. "x402-usdc". */
  scheme: string;
  /** The x402 payment address (payee). */
  payee: string;
  /** The amount due, in the smallest unit of the payment token. */
  amount: string;
  /** Optional resource/identifier being paid for. */
  resource?: string;
  /** Optional network/chain ID. */
  network?: string;
}

/** Result of submitting an x402 payment. */
export interface X402PaymentResult {
  ok: boolean;
  txHash?: string;
  error?: string;
}

/** Result of a World step-up verification. */
export interface StepUpResult {
  ok: boolean;
  /** Whether the human completed verification. */
  verified: boolean;
  /** Whether the result was denied/expired/cancelled. */
  denied: boolean;
  /** Cap tier granted (0 = none, 1 = standard, 2 = high). */
  capTier: number;
  /** Expiry in Unix seconds (0 = none). */
  expiry: number;
  /** Error message when not ok. */
  error?: string;
}

/** Configuration for the World step-up client. */
export interface WorldConfig {
  /** World App ID from the developer portal. */
  appId: string;
  /** Backend endpoint that validates Agent Pass proofs. */
  backendEndpoint: string;
  /** When true, skips live network and returns mocked results. */
  mockMode: boolean;
}

/** Configuration for the x402 client. */
export interface X402Config {
  /** The x402 bill endpoint URL. */
  billUrl: string;
  /** Optional payment token address. */
  tokenAddress?: string;
}
