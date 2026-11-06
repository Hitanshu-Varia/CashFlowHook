/// @notice Public API for the CashflowHook v3 agent package.

export type {
  DrawEvaluation,
  PolicyConfig,
  PolicyDecision,
  PolicyState,
  StepUpResult,
  UnwindEvaluation,
  Wad,
  WorldConfig,
  X402Config,
  X402PaymentHeaders,
  X402PaymentResult,
} from "./types.js";

export {
  defaultConfig,
  evaluateDraw,
  evaluateUnwind,
  applyDraw,
  acceptStepUp,
  stepUpIsValid,
  decideDraw,
  initialState,
} from "./policy.js";

export {
  fetchPaymentHeaders,
  submitPayment,
  payBill,
} from "./x402.js";

export {
  requestStepUp,
  validateProof,
  worldConfigFromEnv,
} from "./world.js";
