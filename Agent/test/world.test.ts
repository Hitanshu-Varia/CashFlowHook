import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  requestStepUp,
  validateProof,
  worldConfigFromEnv,
} from "../src/world.js";
import type { WorldConfig } from "../src/types.js";

const BACKEND = "http://127.0.0.1:8787/world";

const CONFIG: WorldConfig = {
  appId: "app_123",
  backendEndpoint: BACKEND,
  mockMode: false,
};

beforeEach(() => {
  vi.stubGlobal("fetch", vi.fn());
  // Clear env vars for deterministic config tests
  delete process.env.WORLD_APP_ID;
  delete process.env.WORLD_BACKEND_ENDPOINT;
  delete process.env.WORLD_MOCK_MODE;
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("World step-up client", () => {
  describe("requestStepUp", () => {
    it("returns happy-path result in mock mode", async () => {
      const mockConfig: WorldConfig = { ...CONFIG, mockMode: true };
      const result = await requestStepUp(mockConfig, "0xabc");

      expect(result.ok).toBe(true);
      expect(result.verified).toBe(true);
      expect(result.denied).toBe(false);
      expect(result.capTier).toBe(1);
      expect(result.expiry).toBeGreaterThan(Date.now() / 1000);
    });

    it("validates a successful backend response", async () => {
      const fetchMock = vi.mocked(fetch);
      fetchMock.mockResolvedValueOnce(
        new Response(
          JSON.stringify({ verified: true, capTier: 2, expiry: 1_800_000_000 }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      );

      const result = await requestStepUp(CONFIG, "0xabc");

      expect(result.ok).toBe(true);
      expect(result.verified).toBe(true);
      expect(result.denied).toBe(false);
      expect(result.capTier).toBe(2);
      expect(result.expiry).toBe(1_800_000_000);
      expect(fetchMock).toHaveBeenCalledWith(
        expect.stringContaining("/agent-pass/verify"),
        expect.anything(),
      );
    });

    it("returns denied when backend returns denied status", async () => {
      const fetchMock = vi.mocked(fetch);
      fetchMock.mockResolvedValueOnce(
        new Response(
          JSON.stringify({ status: "denied", error: "proof expired" }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      );

      const result = await requestStepUp(CONFIG, "0xabc");

      expect(result.ok).toBe(false);
      expect(result.denied).toBe(true);
      expect(result.error).toContain("denied");
    });

    it("returns denied on non-ok backend response", async () => {
      const fetchMock = vi.mocked(fetch);
      fetchMock.mockResolvedValueOnce(
        new Response("error", { status: 500 }),
      );

      const result = await requestStepUp(CONFIG, "0xabc");

      expect(result.ok).toBe(false);
      expect(result.denied).toBe(true);
      expect(result.error).toContain("500");
    });

    it("returns denied on network timeout", async () => {
      const fetchMock = vi.mocked(fetch);
      fetchMock.mockRejectedValueOnce(new Error("timeout"));

      const result = await requestStepUp(CONFIG, "0xabc");

      expect(result.ok).toBe(false);
      expect(result.denied).toBe(true);
    });

    it("includes appId and account in the request URL", async () => {
      const fetchMock = vi.mocked(fetch);
      fetchMock.mockResolvedValueOnce(
        new Response(JSON.stringify({ verified: true }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      );

      await requestStepUp(CONFIG, "0xabc123");

      const url = fetchMock.mock.calls[0][0] as string;
      expect(url).toContain("appId=app_123");
      expect(url).toContain("account=0xabc123");
    });
  });

  describe("validateProof", () => {
    it("returns valid result in mock mode", async () => {
      const mockConfig: WorldConfig = { ...CONFIG, mockMode: true };
      const result = await validateProof(mockConfig, "0xproof");

      expect(result.ok).toBe(true);
      expect(result.capTier).toBe(1);
    });

    it("validates a successful proof", async () => {
      const fetchMock = vi.mocked(fetch);
      fetchMock.mockResolvedValueOnce(
        new Response(
          JSON.stringify({ ok: true, capTier: 1, expiry: 1_800_000_000 }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      );

      const result = await validateProof(CONFIG, "0xproof");

      expect(result.ok).toBe(true);
      expect(result.capTier).toBe(1);
      expect(result.expiry).toBe(1_800_000_000);
      expect(fetchMock).toHaveBeenCalledWith(
        expect.stringContaining("/agent-pass/validate"),
        expect.objectContaining({ method: "POST" }),
      );
    });

    it("returns invalid on failed validation", async () => {
      const fetchMock = vi.mocked(fetch);
      fetchMock.mockResolvedValueOnce(
        new Response(
          JSON.stringify({ ok: false, error: "invalid proof" }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      );

      const result = await validateProof(CONFIG, "0xproof");

      expect(result.ok).toBe(false);
      expect(result.error).toContain("invalid proof");
    });
  });

  describe("worldConfigFromEnv", () => {
    it("reads appId and endpoint from env", () => {
      process.env.WORLD_APP_ID = "env_app";
      process.env.WORLD_BACKEND_ENDPOINT = "http://env.backend";

      const config = worldConfigFromEnv();
      expect(config.appId).toBe("env_app");
      expect(config.backendEndpoint).toBe("http://env.backend");
      expect(config.mockMode).toBe(false);
    });

    it("enables mock mode when WORLD_MOCK_MODE is set", () => {
      process.env.WORLD_MOCK_MODE = "1";
      const config = worldConfigFromEnv();
      expect(config.mockMode).toBe(true);
    });

    it("returns empty strings when env is unset", () => {
      const config = worldConfigFromEnv();
      expect(config.appId).toBe("");
      expect(config.backendEndpoint).toBe("");
    });
  });
});
