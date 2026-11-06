/// @notice x402 payment client for CashflowHook v3.
///
/// The x402 client fetches a payment bill from a configured endpoint and
/// submits payment. It does not hold keys or sign transactions itself —
/// the wallet-side signing is delegated to the web UI or a signing adapter.
/// All network calls go through `fetch`; no external SDKs are imported.

import type { X402Config, X402PaymentHeaders, X402PaymentResult } from "./types.js";

const DEFAULT_TIMEOUT_MS = 10_000;

/**
 * Fetches x402 payment headers from the bill endpoint.
 *
 * The endpoint returns an `X-Payment` header (or JSON body) describing the
 * payment required: scheme, payee, amount, and optional resource/network.
 */
export async function fetchPaymentHeaders(
  config: X402Config,
  init?: RequestInit,
): Promise<X402PaymentHeaders> {
  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(),
    (init?.signal ? 0 : DEFAULT_TIMEOUT_MS),
  );

  try {
    const response = await fetch(config.billUrl, {
      ...init,
      signal: controller.signal,
      headers: {
        accept: "application/json",
        ...(init?.headers ?? {}),
      },
    });

    clearTimeout(timeout);

    if (!response.ok) {
      throw new Error(
        `x402 bill endpoint returned ${response.status} ${response.statusText}`,
      );
    }

    // Prefer the X-Payment header; fall back to JSON body.
    const paymentHeader = response.headers.get("x-payment");
    if (paymentHeader) {
      return parsePaymentHeader(paymentHeader);
    }

    const body = (await response.json()) as Record<string, unknown>;
    return {
      scheme: String(body.scheme ?? "x402-usdc"),
      payee: String(body.payee ?? ""),
      amount: String(body.amount ?? "0"),
      resource: typeof body.resource === "string" ? body.resource : undefined,
      network:
        typeof body.network === "string" ? body.network : undefined,
    };
  } catch (error) {
    clearTimeout(timeout);
    if (error instanceof Error && error.name === "AbortError") {
      throw new Error(`x402 bill endpoint timed out: ${config.billUrl}`);
    }
    throw error;
  }
}

/**
 * Submits an x402 payment to the bill endpoint.
 *
 * The `payment` payload is the signed x402 payment (produced client-side by
 * the wallet/signing adapter). Returns `{ ok: true, txHash }` on success.
 */
export async function submitPayment(
  config: X402Config,
  payment: Record<string, unknown>,
  init?: RequestInit,
): Promise<X402PaymentResult> {
  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(),
    (init?.signal ? 0 : DEFAULT_TIMEOUT_MS),
  );

  try {
    const response = await fetch(`${config.billUrl}/pay`, {
      method: "POST",
      ...init,
      signal: controller.signal,
      headers: {
        "content-type": "application/json",
        ...(init?.headers ?? {}),
      },
      body: JSON.stringify(payment),
    });

    clearTimeout(timeout);

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      return {
        ok: false,
        error: `x402 payment returned ${response.status}: ${text}`,
      };
    }

    const body = (await response.json().catch(() => ({}))) as Record<
      string,
      unknown
    >;
    return {
      ok: true,
      txHash: typeof body.txHash === "string" ? body.txHash : undefined,
    };
  } catch (error) {
    clearTimeout(timeout);
    if (error instanceof Error && error.name === "AbortError") {
      return { ok: false, error: `x402 payment timed out` };
    }
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

/**
 * Parses an `X-Payment` header value into structured headers.
 *
 * Header format: `x402-usdc:0xpayee:1000000:resource:network`
 */
function parsePaymentHeader(value: string): X402PaymentHeaders {
  const parts = value.split(":");
  return {
    scheme: parts[0] ?? "x402-usdc",
    payee: parts[1] ?? "",
    amount: parts[2] ?? "0",
    resource: parts[3] || undefined,
    network: parts[4] || undefined,
  };
}

/**
 * Convenience: fetch headers then submit payment in one call.
 */
export async function payBill(
  config: X402Config,
  payment: Record<string, unknown>,
  init?: RequestInit,
): Promise<X402PaymentResult> {
  await fetchPaymentHeaders(config, init);
  return submitPayment(config, payment, init);
}
