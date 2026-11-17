import { beforeEach, describe, expect, it } from "vitest";
import { type ApnsConfig, dropProviderToken, providerToken } from "../src/apns";
import { Gateway, T0, appleError, reset, testKey } from "./helpers";

let gw: Gateway;
beforeEach(async () => {
  await reset();
  gw = new Gateway();
});

const config: ApnsConfig = { keyId: "5G2D4URHAC", teamId: "R2PVQ496X7", topic: "t", keyPem: testKey.pem };

function decode(part: string): Uint8Array {
  const base64 = part.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

function json(part: string): unknown {
  return JSON.parse(new TextDecoder().decode(decode(part)));
}

/** The JWT the gateway sent to Apple on its nth call. */
function sentToken(gateway: Gateway, n: number): string {
  return (gateway.calls[n]?.headers.authorization ?? "").replace(/^bearer /, "");
}

describe("the provider JWT", () => {
  it("is an ES256 JWT with the key id, the team and a signature the public key verifies", async () => {
    const device = await gw.register();
    gw.now = T0 + 1234;
    await gw.push(device.push_secret);

    const token = sentToken(gw, 0);
    const parts = token.split(".");
    expect(parts).toHaveLength(3);
    for (const part of parts) expect(part).toMatch(/^[A-Za-z0-9_-]+$/);
    const [header = "", claims = "", signature = ""] = parts;
    expect(json(header)).toEqual({ alg: "ES256", kid: "5G2D4URHAC" });
    // iat is the start of the 30-minute bucket, not the time of the request.
    expect(json(claims)).toEqual({ iss: "R2PVQ496X7", iat: T0 });

    const raw = decode(signature);
    expect(raw.byteLength).toBe(64);
    const data = new TextEncoder().encode(`${header}.${claims}`);
    const algorithm = { name: "ECDSA", hash: "SHA-256" };
    expect(await crypto.subtle.verify(algorithm, testKey.publicKey, raw, data)).toBe(true);
    const tampered = new TextEncoder().encode(`${header}.${claims}x`);
    expect(await crypto.subtle.verify(algorithm, testKey.publicKey, raw, tampered)).toBe(false);
  });

  it("is reused inside a 30-minute bucket and signed again in the next", async () => {
    const device = await gw.register();
    for (const at of [T0, T0 + 61, T0 + 1799, T0 + 1800, T0 + 1861, T0 + 3600]) {
      gw.now = at;
      expect((await gw.push(device.push_secret)).status).toBe(200);
    }
    const tokens = gw.calls.map((_, i) => sentToken(gw, i));
    expect(tokens[1]).toBe(tokens[0]);
    expect(tokens[2]).toBe(tokens[0]);
    expect(tokens[3]).not.toBe(tokens[0]);
    expect(tokens[4]).toBe(tokens[3]);
    expect(tokens[5]).not.toBe(tokens[3]);
    expect(tokens.map((t) => (json(t.split(".")[1] ?? "") as { iat: number }).iat)).toEqual([
      T0,
      T0,
      T0,
      T0 + 1800,
      T0 + 1800,
      T0 + 3600,
    ]);
  });

  it("is signed once for requests that arrive together", async () => {
    const [a, b] = await Promise.all([providerToken(config, T0), providerToken(config, T0 + 5)]);
    expect(a).toBe(b);
  });

  it.each(["ExpiredProviderToken", "InvalidProviderToken"])(
    "is dropped after 403 %s, so the next push signs a new one",
    async (reason) => {
      const device = await gw.register();
      await gw.push(device.push_secret);
      gw.apple = appleError(403, reason);
      const refused = await gw.push(device.push_secret);
      expect(refused.status).toBe(502);
      expect(await refused.json()).toMatchObject({ error: "apns_error", status: 403, reason });
      gw.apple = () => new Response(null, { status: 200 });
      await gw.push(device.push_secret);

      expect(sentToken(gw, 1)).toBe(sentToken(gw, 0));
      // Same bucket, so the same claims, but a new signature.
      expect(sentToken(gw, 2)).not.toBe(sentToken(gw, 0));
      expect(sentToken(gw, 2).split(".")[1]).toBe(sentToken(gw, 0).split(".")[1]);
    },
  );

  it("is kept after other errors", async () => {
    const device = await gw.register();
    gw.apple = appleError(403, "BadCertificateEnvironment");
    await gw.push(device.push_secret);
    gw.apple = appleError(500, "InternalServerError");
    await gw.push(device.push_secret);
    await gw.push(device.push_secret);
    expect(new Set(gw.calls.map((_, i) => sentToken(gw, i))).size).toBe(1);
  });

  it("can be dropped by hand", async () => {
    const first = await providerToken(config, T0);
    dropProviderToken();
    expect(await providerToken(config, T0)).not.toBe(first);
  });

  it("fails on a key that is not a P-256 PKCS#8 key, and works again with a good one", async () => {
    const bad = { ...config, keyPem: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n" };
    await expect(providerToken(bad, T0)).rejects.toThrow();
    expect(await providerToken(config, T0)).toMatch(/^[\w-]+\.[\w-]+\.[\w-]+$/);
  });
});
