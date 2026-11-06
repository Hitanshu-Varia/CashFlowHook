/// @notice World ID Agent Pass step-up client for CashflowHook v3.
///
/// The World step-up client orchestrates the Agent Pass verification journey:
///   1. Request step-up (client asks the human to verify via World App).
///   2. Poll/validate the proof via a secure backend endpoint.
///   3. Return a StepUpResult indicating ok/denied/capTier/expiry.
///
/// Security notes from the spec (§8.3, §9):
///   - A client-asserted result is NEVER authorization. Validation happens
///     server-side at `WORLD_BACKEND_ENDPOINT`.
///   - Proofs are currently mocked (fake identities, not for production).
///   - The denied/expired/cancelled path must be implemented explicitly.
///
/// All network calls go through `fetch`; no World SDK is imported (adapter
/// rule: a wrong external-name guess breaks exactly this file).

import type { StepUpResult, WorldConfig } from "./types.js";

const DEFAULT_TIMEOUT_MS = 15_000;
const STEP_UP_PATH = "/agent-pass/verify";

/**
 * Requests a World Agent Pass step-up verification.
 *
 * Returns a StepUpResult. When `mockMode` is true, returns a simulated
 * happy-path result without network calls (for offline/dev use only —
 * disclosed in docs/limits.md).
 */
export async function requestStepUp(
  config: WorldConfig,
  accountAddress: string,
  init?: RequestInit,
): Promise<StepUpResult> {
  if (config.mockMode) {
    return {
      ok: true,
      verified: true,
      denied: false,
      capTier: 1,
      expiry: Date.now() / 1000 + 24 * 60 * 60,
    };
  }

  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(),
    (init?.signal ? 0 : DEFAULT_TIMEOUT_MS),
  );

  try {
    const response = await fetch(
      `${config.backendEndpoint}${STEP_UP_PATH}?account=${encodeURIComponent(accountAddress)}&appId=${encodeURIComponent(config.appId)}`,
      {
        ...init,
        signal: controller.signal,
        headers: {
          accept: "application/json",
          ...(init?.headers ?? {}),
        },
      },
    );

    clearTimeout(timeout);

    if (!response.ok) {
      return {
        ok: false,
        verified: false,
        denied: true,
        capTier: 0,
        expiry: 0,
        error: `World backend returned ${response.status} ${response.statusText}`,
      };
    }

    const body = (await response.json().catch(() => ({}))) as Record<
      string,
      unknown
    >;

    const denied =
      body.denied === true ||
      body.status === "denied" ||
      body.status === "expired" ||
      body.status === "cancelled";

    return {
      ok: !denied,
      verified: body.verified === true && !denied,
      denied,
      capTier:
        typeof body.capTier === "number"
          ? body.capTier
          : typeof body.capTier === "string"
            ? Number(body.capTier)
            : 0,
      expiry:
        typeof body.expiry === "number"
          ? body.expiry
          : typeof body.expiry === "string"
            ? Number(body.expiry)
            : 0,
      error: denied
        ? typeof body.error === "string"
          ? body.status === "denied"
            ? `denied: ${body.error}`
            : body.error
          : "step-up denied"
        : undefined,
    };
  } catch (error) {
    clearTimeout(timeout);
    if (error instanceof Error && error.name === "AbortError") {
      return {
        ok: false,
        verified: false,
        denied: true,
        capTier: 0,
        expiry: 0,
        error: `World backend timed out: ${config.backendEndpoint}`,
      };
    }
    return {
      ok: false,
      verified: false,
      denied: true,
      capTier: 0,
      expiry: 0,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

/**
 * Validates an Agent Pass proof hash via the backend.
 *
 * Called after the human completes verification in the World App. The
 * `proofHash` is the onchain commitment (submitted to AgentPassVerifier).
 * Returns whether the backend validated it.
 */
export async function validateProof(
  config: WorldConfig,
  proofHash: string,
  init?: RequestInit,
): Promise<{ ok: boolean; capTier: number; expiry: number; error?: string }> {
  if (config.mockMode) {
    return { ok: true, capTier: 1, expiry: Date.now() / 1000 + 24 * 60 * 60 };
  }

  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(),
    (init?.signal ? 0 : DEFAULT_TIMEOUT_MS),
  );

  try {
    const response = await fetch(`${config.backendEndpoint}/agent-pass/validate`, {
      method: "POST",
      ...init,
      signal: controller.signal,
      headers: {
        "content-type": "application/json",
        ...(init?.headers ?? {}),
      },
      body: JSON.stringify({ proofHash, appId: config.appId }),
    });

    clearTimeout(timeout);

    if (!response.ok) {
      return {
        ok: false,
        capTier: 0,
        expiry: 0,
        error: `validation returned ${response.status}`,
      };
    }

    const body = (await response.json().catch(() => ({}))) as Record<
      string,
      unknown
    >;
    return {
      ok: body.ok === true,
      capTier:
        typeof body.capTier === "number"
          ? body.capTier
          : typeof body.capTier === "string"
            ? Number(body.capTier)
            : 0,
      expiry:
        typeof body.expiry === "number"
          ? body.expiry
          : typeof body.expiry === "string"
            ? Number(body.expiry)
            : 0,
      error: body.ok === true ? undefined : String(body.error ?? "validation failed"),
    };
  } catch (error) {
    clearTimeout(timeout);
    if (error instanceof Error && error.name === "AbortError") {
      return {
        ok: false,
        capTier: 0,
        expiry: 0,
        error: `validation timed out`,
      };
    }
    return {
      ok: false,
      capTier: 0,
      expiry: 0,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

/**
 * Creates a default World config from environment variables.
 */
export function worldConfigFromEnv(): WorldConfig {
  return {
    appId: process.env.WORLD_APP_ID ?? "",
    backendEndpoint: process.env.WORLD_BACKEND_ENDPOINT ?? "",
    mockMode:
      process.env.WORLD_MOCK_MODE === "1" ||
      process.env.WORLD_MOCK_MODE === "true",
  };
}
