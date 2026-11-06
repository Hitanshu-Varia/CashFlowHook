/// @notice Deterministic policy engine for the CashflowHook v3 agent.
///
/// The engine enforces:
///   - A per-draw cap (fraction of borrowing power, USD-WAD).
///   - A per-window draw count limit.
///   - A step-up requirement when CreditEngine pauses autonomy after a
///     margin-state change.
///   - Unwind authorization: debt ≤ unwindableNow is always allowed;
///     unwinding beyond liquidatable backing requires a step-up that
///     accepts locked-liquidity risk (expires after 24 h).
///
/// All math is pure and deterministic. No external calls.

import type {
  DrawEvaluation,
  PolicyConfig,
  PolicyDecision,
  PolicyState,
  UnwindEvaluation,
  Wad,
} from "./types.js";

const WAD = 10n ** 18n;

const DEFAULT_CONFIG: PolicyConfig = {
  perDrawCapWad: (2n * WAD) / 100n,
  maxDrawsPerWindow: 3,
  windowSeconds: 12 * 60 * 60,
};

const STEP_UP_EXPIRY_SECONDS = 24 * 60 * 60; // 24 hours

/**
 * Returns a default policy config. Callers may override individual fields.
 */
export function defaultConfig(): PolicyConfig {
  return { ...DEFAULT_CONFIG };
}

/**
 * Returns the initial policy state for a new account.
 */
export function initialState(accountId: number): PolicyState {
  return {
    accountId,
    debtWad: 0n,
    lastDrawAt: 0,
    drawsInWindow: 0,
    stepUpAcceptedAt: 0,
    needsStepUp: false,
    lockedRiskAccepted: false,
  };
}

/**
 * Advances the policy state's window if enough time has elapsed since the
 * last draw. Returns a new state object (immutable update).
 */
function advanceWindow(
  state: PolicyState,
  windowSeconds: number,
  nowSeconds: number,
): PolicyState {
  if (state.lastDrawAt === 0) {
    return state; // no draws yet, window is open
  }
  const elapsed = nowSeconds - state.lastDrawAt;
  if (elapsed < windowSeconds) {
    return state; // still inside the current window
  }
  // Window has rolled over: reset draw counter.
  return { ...state, drawsInWindow: 0, lastDrawAt: nowSeconds };
}

/**
 * Evaluates whether a proposed draw is allowed under current policy.
 *
 * Returns a DrawEvaluation. The caller applies the draw (updates debt,
 * draw counter, timestamp) only when `allowed` is true.
 */
export function evaluateDraw(
  state: PolicyState,
  config: PolicyConfig,
  borrowingPowerWad: Wad,
  proposedDrawWad: Wad,
  nowSeconds: number,
): DrawEvaluation {
  const advanced = advanceWindow(state, config.windowSeconds, nowSeconds);

  // Per-draw cap: draw ≤ perDrawCapWad × borrowing power / WAD.
  const drawCapWad = (borrowingPowerWad * config.perDrawCapWad) / WAD;

  if (proposedDrawWad <= 0n) {
    return {
      allowed: false,
      reason: "draw amount must be positive",
      maxDrawWad: drawCapWad,
      proposedDrawWad,
    };
  }

  if (proposedDrawWad > drawCapWad) {
    return {
      allowed: false,
      reason: `draw ${proposedDrawWad.toString()} exceeds per-draw cap ${drawCapWad.toString()}`,
      maxDrawWad: drawCapWad,
      proposedDrawWad,
    };
  }

  // Per-window draw count.
  if (advanced.drawsInWindow >= config.maxDrawsPerWindow) {
    return {
      allowed: false,
      reason: `draw count ${advanced.drawsInWindow} ≥ max ${config.maxDrawsPerWindow} in window`,
      maxDrawWad: drawCapWad,
      proposedDrawWad,
    };
  }

  if (advanced.needsStepUp && !stepUpIsValid(advanced, nowSeconds)) {
    return {
      allowed: false,
      reason:
        "autonomy is paused; World Agent Pass step-up required",
      maxDrawWad: drawCapWad,
      proposedDrawWad,
    };
  }

  return {
    allowed: true,
    reason: null,
    maxDrawWad: drawCapWad,
    proposedDrawWad,
  };
}

/**
 * Evaluates whether an unwind of `debtWad` is authorized.
 *
 * Debt up to `unwindableWad` can always be unwound. The excess requires a
 * currently-valid step-up that accepted locked-liquidity risk.
 */
export function evaluateUnwind(
  state: PolicyState,
  config: PolicyConfig,
  unwindableWad: Wad,
  debtWad: Wad,
  nowSeconds: number,
): UnwindEvaluation {
  const excessWad = debtWad > unwindableWad ? debtWad - unwindableWad : 0n;

  if (excessWad === 0n) {
    return { allowed: true, reason: null, unwindableWad, excessWad: 0n };
  }

  const stepUpValid = state.lockedRiskAccepted && stepUpIsValid(state, nowSeconds);

  if (!stepUpValid) {
    return {
      allowed: false,
      reason: `excess ${excessWad.toString()} beyond unwindable ${unwindableWad.toString()} requires step-up`,
      unwindableWad,
      excessWad,
    };
  }

  return { allowed: true, reason: null, unwindableWad, excessWad };
}

/**
 * Applies a successful draw to the policy state, returning a new state.
 */
export function applyDraw(
  state: PolicyState,
  drawWad: Wad,
  nowSeconds: number,
): PolicyState {
  return {
    ...state,
    debtWad: state.debtWad + drawWad,
    drawsInWindow: state.drawsInWindow + 1,
    lastDrawAt: nowSeconds,
  };
}

/**
 * Records an accepted step-up in the policy state.
 */
export function acceptStepUp(
  state: PolicyState,
  capTier: number,
  lockedRiskAccepted: boolean,
  nowSeconds: number,
): PolicyState {
  void capTier;
  return {
    ...state,
    stepUpAcceptedAt: nowSeconds,
    needsStepUp: false,
    lockedRiskAccepted,
  };
}

/**
 * Checks whether a previously accepted step-up is still valid.
 */
export function stepUpIsValid(
  state: PolicyState,
  nowSeconds: number,
): boolean {
  return (
    state.stepUpAcceptedAt > 0 &&
    nowSeconds >= state.stepUpAcceptedAt &&
    nowSeconds - state.stepUpAcceptedAt <= STEP_UP_EXPIRY_SECONDS
  );
}

/**
 * Computes a full PolicyDecision for a draw request. Convenience wrapper
 * around evaluateDraw.
 */
export function decideDraw(
  state: PolicyState,
  config: PolicyConfig,
  borrowingPowerWad: Wad,
  proposedDrawWad: Wad,
  nowSeconds: number,
): PolicyDecision {
  const ev = evaluateDraw(state, config, borrowingPowerWad, proposedDrawWad, nowSeconds);
  const advanced = advanceWindow(state, config.windowSeconds, nowSeconds);
  return {
    allowed: ev.allowed,
    reason: ev.reason,
    maxDrawWad: ev.maxDrawWad,
    drawsRemaining: Math.max(
      0,
      config.maxDrawsPerWindow - advanced.drawsInWindow - (ev.allowed ? 1 : 0),
    ),
    windowResetAt:
      advanced.lastDrawAt === 0
        ? nowSeconds + config.windowSeconds
        : advanced.lastDrawAt + config.windowSeconds,
  };
}
