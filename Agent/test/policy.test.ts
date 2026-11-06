import { describe, expect, it } from "vitest";
import {
  acceptStepUp,
  applyDraw,
  decideDraw,
  defaultConfig,
  evaluateDraw,
  evaluateUnwind,
  initialState,
  stepUpIsValid,
} from "../src/policy.js";
import type { PolicyState } from "../src/types.js";

const WAD = 10n ** 18n;
const NOW = 1_700_000_000;
const BORROWING_POWER = 1_000n * WAD;

function makeState(overrides: Partial<PolicyState> = {}): PolicyState {
  return {
    accountId: 1,
    debtWad: 0n,
    lastDrawAt: 0,
    drawsInWindow: 0,
    stepUpAcceptedAt: 0,
    needsStepUp: false,
    lockedRiskAccepted: false,
    ...overrides,
  };
}

describe("policy engine", () => {
  const config = defaultConfig();

  describe("defaults and state", () => {
    it("uses CreditEngine's 2% cap and three-draw, 12-hour window", () => {
      expect(config.perDrawCapWad).toBe((2n * WAD) / 100n);
      expect(config.maxDrawsPerWindow).toBe(3);
      expect(config.windowSeconds).toBe(12 * 60 * 60);
    });

    it("initialises an unpaused account", () => {
      expect(initialState(42)).toEqual({
        accountId: 42,
        debtWad: 0n,
        lastDrawAt: 0,
        drawsInWindow: 0,
        stepUpAcceptedAt: 0,
        needsStepUp: false,
        lockedRiskAccepted: false,
      });
    });
  });

  describe("evaluateDraw", () => {
    it("allows a draw at or below the 2% cap", () => {
      const evaluation = evaluateDraw(makeState(), config, BORROWING_POWER, 20n * WAD, NOW);

      expect(evaluation.allowed).toBe(true);
      expect(evaluation.maxDrawWad).toBe(20n * WAD);
    });

    it("rejects a draw above the cap before any other evaluation", () => {
      const evaluation = evaluateDraw(
        makeState({ needsStepUp: true }),
        config,
        BORROWING_POWER,
        20n * WAD + 1n,
        NOW,
      );

      expect(evaluation.allowed).toBe(false);
      expect(evaluation.reason).toContain("exceeds per-draw cap");
    });

    it("rejects zero and negative draw amounts", () => {
      expect(evaluateDraw(makeState(), config, BORROWING_POWER, 0n, NOW).reason).toContain("positive");
      expect(evaluateDraw(makeState(), config, BORROWING_POWER, -1n, NOW).reason).toContain("positive");
    });

    it("enforces and rolls over the draw-count window", () => {
      const fullWindow = makeState({ drawsInWindow: 3, lastDrawAt: NOW });
      expect(evaluateDraw(fullWindow, config, BORROWING_POWER, WAD, NOW + 1).allowed).toBe(false);
      expect(
        evaluateDraw(
          makeState({ drawsInWindow: 3, lastDrawAt: NOW - config.windowSeconds }),
          config,
          BORROWING_POWER,
          WAD,
          NOW,
        ).allowed,
      ).toBe(true);
    });

    it("does not reset the window when the local clock moves backwards", () => {
      const evaluation = evaluateDraw(
        makeState({ drawsInWindow: 3, lastDrawAt: NOW }),
        config,
        BORROWING_POWER,
        WAD,
        NOW - 1,
      );

      expect(evaluation.allowed).toBe(false);
      expect(evaluation.reason).toContain("draw count");
    });

    it("requires a valid human step-up only when the engine has paused autonomy", () => {
      const paused = makeState({ needsStepUp: true });
      expect(evaluateDraw(paused, config, BORROWING_POWER, WAD, NOW).reason).toContain("step-up");

      const approved = makeState({ needsStepUp: true, stepUpAcceptedAt: NOW });
      expect(evaluateDraw(approved, config, BORROWING_POWER, WAD, NOW + 1).allowed).toBe(true);
    });
  });

  describe("step-up and unwind", () => {
    it("keeps regular proof validity separate from locked-risk consent", () => {
      const standard = makeState({ stepUpAcceptedAt: NOW, lockedRiskAccepted: false });
      expect(stepUpIsValid(standard, NOW)).toBe(true);
      expect(evaluateUnwind(standard, config, 100n * WAD, 150n * WAD, NOW).allowed).toBe(false);

      const lockedRisk = { ...standard, lockedRiskAccepted: true };
      expect(evaluateUnwind(lockedRisk, config, 100n * WAD, 150n * WAD, NOW).allowed).toBe(true);
    });

    it("expires proofs after 24 hours and refuses future timestamps", () => {
      expect(stepUpIsValid(makeState({ stepUpAcceptedAt: NOW - 86_401 }), NOW)).toBe(false);
      expect(stepUpIsValid(makeState({ stepUpAcceptedAt: NOW + 1 }), NOW)).toBe(false);
    });

    it("clears the pause when a World step-up is accepted", () => {
      const accepted = acceptStepUp(makeState({ needsStepUp: true }), 1, false, NOW);
      expect(accepted.needsStepUp).toBe(false);
      expect(accepted.lockedRiskAccepted).toBe(false);
      expect(accepted.stepUpAcceptedAt).toBe(NOW);
    });
  });

  describe("state transitions", () => {
    it("records a successful draw immutably", () => {
      const before = makeState({ debtWad: 10n * WAD, drawsInWindow: 1 });
      const after = applyDraw(before, 20n * WAD, NOW);

      expect(after).toMatchObject({
        debtWad: 30n * WAD,
        drawsInWindow: 2,
        lastDrawAt: NOW,
      });
      expect(before.drawsInWindow).toBe(1);
    });

    it("reports the remaining draw budget without mutating state", () => {
      const decision = decideDraw(
        makeState({ drawsInWindow: 1, lastDrawAt: NOW }),
        config,
        BORROWING_POWER,
        WAD,
        NOW + 1,
      );

      expect(decision.allowed).toBe(true);
      expect(decision.drawsRemaining).toBe(1);
      expect(decision.windowResetAt).toBe(NOW + config.windowSeconds);
    });
  });
});
