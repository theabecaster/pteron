import { SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sha256Hex } from "../src/encoding";
import { VERSION, handleScheduled } from "../src/index";
import { FakeLimiter, Gateway, PAYLOAD, SANDBOX_TOKEN, appleError, errorOf, reset, testEnv, testKey } from "./helpers";

let gw: Gateway;
beforeEach(async () => {
  await reset();
  gw = new Gateway();
});
afterEach(() => {
  vi.restoreAllMocks();
});

describe("GET /v1/health", () => {
  it("answers ok and the version without auth", async () => {
    const response = await gw.request("GET", "/v1/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, version: VERSION });
    expect(VERSION).toMatch(/^\d+\.\d+\.\d+$/);
  });

  it("is served by the Worker's own entry point", async () => {
    const response = await SELF.fetch("https://gateway.test/v1/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, version: VERSION });
  });
});

describe("routing", () => {
  it.each([
    ["GET", "/"],
    ["GET", "/v1"],
    ["POST", "/v1/health/x"],
    ["POST", "/v2/push"],
    ["POST", "/v1/push/"],
    ["GET", "/v1/devices/abc/rotate/x"],
    ["POST", "/v1/devices/abc/rotate"],
    ["POST", "/v1/devices/abc/secrets/"],
    ["DELETE", "/v1/devices/abc/secrets/def/x"],
    ["DELETE", "/v1/devices/abc/secrets/has.dot"],
    ["GET", "/v1/devices/abc/secret"],
    ["GET", "/v1/secrets"],
    ["PUT", "/v1/devices/"],
    ["PUT", "/v1/devices/has.dot"],
    ["GET", `/v1/devices/${"a".repeat(65)}`],
  ])("answers 404 for %s %s", async (method, path) => {
    const response = await gw.request(method, path);
    expect(response.status).toBe(404);
    expect((await errorOf(response)).error).toBe("not_found");
  });

  it.each([
    ["POST", "/v1/health", "GET"],
    ["GET", "/v1/devices", "POST"],
    ["DELETE", "/v1/devices", "POST"],
    ["GET", "/v1/push", "POST"],
    ["PUT", "/v1/push", "POST"],
    ["POST", "/v1/devices/abc", "GET, PUT, DELETE"],
    ["PATCH", "/v1/devices/abc", "GET, PUT, DELETE"],
    ["GET", "/v1/devices/abc/secrets", "POST"],
    ["DELETE", "/v1/devices/abc/secrets", "POST"],
    ["GET", "/v1/devices/abc/secrets/def", "DELETE"],
    ["POST", "/v1/devices/abc/secrets/def", "DELETE"],
    ["OPTIONS", "/v1/push", "POST"],
  ])("answers 405 for %s %s", async (method, path, allow) => {
    const response = await gw.request(method, path);
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe(allow);
    expect((await errorOf(response)).error).toBe("method_not_allowed");
  });

  it("answers JSON that is never cached, and no CORS headers", async () => {
    const device = await gw.register();
    const responses = [
      await gw.request("GET", "/v1/health"),
      await gw.request("GET", "/nope"),
      await gw.request("OPTIONS", "/v1/push", { headers: { origin: "https://evil.example" } }),
      await gw.request("POST", "/v1/devices", { body: { apns_token: SANDBOX_TOKEN, environment: "sandbox" } }),
      await gw.request("POST", "/v1/push", { body: {} }),
      await gw.push(device.push_secret),
      await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key }),
      await gw.request("POST", `/v1/devices/${device.device_id}/secrets`, {
        auth: device.owner_key,
        body: { label: "laptop" },
      }),
      await gw.request("DELETE", `/v1/devices/${device.device_id}/secrets/${device.secret_id}`, {
        auth: device.owner_key,
      }),
      await gw.request("DELETE", `/v1/devices/${device.device_id}`, { auth: device.owner_key }),
    ];
    expect(responses.map((r) => r.status)).toEqual([200, 404, 405, 201, 401, 200, 200, 201, 204, 204]);
    for (const response of responses) {
      expect(response.headers.get("content-type")).toBe("application/json");
      expect(response.headers.get("cache-control")).toBe("no-store");
      for (const [name] of response.headers) expect(name).not.toMatch(/^access-control-/);
    }
  });

  it("answers 500 without details when the APNs key is unusable", async () => {
    const { handleRequest } = await import("../src/index");
    const device = await gw.register();
    const response = await handleRequest(
      new Request("https://gateway.test/v1/push", {
        method: "POST",
        headers: { authorization: `Bearer ${device.push_secret}` },
        body: JSON.stringify({ payload: PAYLOAD, push_type: "alert" }),
      }),
      { ...testEnv, APNS_KEY_P8: "not a key" },
      { now: () => gw.now, fetch: async () => new Response(null) },
    );
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "internal_error", message: "The gateway failed." });
  });
});

describe("logging", () => {
  it("logs the route, the status and Apple's reason, and nothing secret", async () => {
    const spies = (["log", "info", "warn", "error", "debug"] as const).map((level) =>
      vi.spyOn(console, level).mockImplementation(() => {}),
    );

    const device = await gw.register();
    const second = await gw.register("ef".repeat(32), "production");
    await gw.push(device.push_secret, { payload: PAYLOAD, push_type: "alert", collapse_id: "collapse-me" });
    gw.apple = appleError(500, "InternalServerError");
    await gw.push(device.push_secret);
    gw.apple = () => {
      throw new Error(`could not reach ${gw.calls.at(-1)?.url}`);
    };
    await gw.push(device.push_secret);
    // Bodies the gateway refuses must not be quoted either.
    await gw.request("POST", "/v1/push", { auth: device.push_secret, raw: `{"payload": "Which DB?" oops` });
    await gw.push(device.push_secret, { payload: PAYLOAD, push_type: "voip" });
    await gw.request("POST", `/v1/devices/${device.device_id}/secrets`, {
      auth: "wrong-key-wrong-key",
      body: { label: "Kitchen iMac" },
    });
    await gw.request("POST", `/v1/devices/${device.device_id}/secrets`, {
      auth: "W".repeat(43),
      body: { label: "Kitchen iMac" },
    });
    await gw.request("POST", `/v1/devices/${device.device_id}/secrets`, {
      auth: device.owner_key,
      body: { label: "Kitchen\niMac" },
    });
    const minted = await gw.mint(device, "Kitchen iMac");
    const fresh = minted.push_secret;
    await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key });
    await gw.request("DELETE", `/v1/devices/${device.device_id}/secrets/${device.secret_id}`, {
      auth: device.owner_key,
    });
    await gw.push(device.push_secret);
    await gw.request("PUT", `/v1/devices/${second.device_id}`, {
      auth: second.owner_key,
      body: { apns_token: "12".repeat(32), environment: "sandbox" },
    });
    gw.apple = appleError(400, "BadDeviceToken");
    await gw.push(fresh);
    await gw.request("DELETE", `/v1/devices/${second.device_id}`, { auth: second.owner_key });
    await gw.request("GET", `/secret-path/${device.push_secret}`);
    // A limiter refusing, and the daily purge, log no more than the rest.
    const limiter = new FakeLimiter();
    limiter.refuse = () => true;
    gw.env = { ...testEnv, RL_ADDRESS: limiter };
    await gw.push(second.push_secret);
    gw.env = testEnv;
    const idle = await gw.register("9a".repeat(32), "sandbox", "2001:db8:5:6::77");
    await handleScheduled(testEnv, gw.now + 181 * 86400);

    const logged = spies.flatMap((spy) => spy.mock.calls.map((args) => args.map(String).join(" "))).join("\n");
    const jwt = (gw.calls[0]?.headers.authorization ?? "").replace("bearer ", "");
    const forbidden = [
      SANDBOX_TOKEN,
      "ef".repeat(32),
      "12".repeat(32),
      device.push_secret,
      device.owner_key,
      device.device_id,
      second.push_secret,
      second.owner_key,
      second.device_id,
      second.secret_id,
      device.secret_id,
      minted.secret_id,
      idle.device_id,
      idle.owner_key,
      idle.push_secret,
      idle.secret_id,
      fresh,
      "wrong-key-wrong-key",
      "W".repeat(43),
      "Kitchen",
      "studio",
      "9a".repeat(32),
      "2001:db8",
      await sha256Hex(device.push_secret),
      await sha256Hex(fresh),
      await sha256Hex(device.owner_key),
      await sha256Hex("203.0.113.7"),
      await sha256Hex("2001:db8:5:6::/64"),
      await sha256Hex("2001:db8:5::/48"),
      await sha256Hex(SANDBOX_TOKEN),
      await sha256Hex("9a".repeat(32)),
      "Which DB?",
      "Claude",
      "rex.example.ts.net",
      "session:s1",
      "collapse-me",
      jwt,
      jwt.split(".")[2] ?? "",
      testKey.pem.split("\n")[1] ?? "",
      "PRIVATE KEY",
      "api.sandbox.push.apple.com",
      "203.0.113.7",
    ];
    expect(jwt).not.toBe("");
    for (const text of forbidden) {
      expect(text.length).toBeGreaterThan(5);
      expect(logged).not.toContain(text);
    }

    const all = logged.split("\n").map((line) => JSON.parse(line) as Record<string, unknown>);
    // The purge logs how many rows it deleted, and no more.
    const purges = all.filter((line) => "task" in line);
    // Two devices: the one whose token Apple refused, and the one registered last, by then idle.
    expect(purges).toEqual([{ task: "purge", devices: 2, counters: expect.any(Number) }]);
    const lines = all.filter((line) => !("task" in line));
    // One line per request and nothing else.
    expect(lines).toHaveLength(gw.requests);
    expect(gw.requests).toBeGreaterThan(20);
    for (const line of lines) expect(Object.keys(line).sort().join()).toMatch(/^(apns_status,)?(reason,)?route,status$/);
    expect(lines).toContainEqual({ route: "POST /v1/devices", status: 201 });
    expect(lines).toContainEqual({ route: "POST /v1/push", status: 200 });
    expect(lines).toContainEqual({
      route: "POST /v1/push",
      status: 502,
      apns_status: 500,
      reason: "InternalServerError",
    });
    expect(lines).toContainEqual({ route: "POST /v1/push", status: 410, apns_status: 400, reason: "BadDeviceToken" });
    expect(lines).toContainEqual({ route: "POST /v1/devices/:id/secrets", status: 401 });
    expect(lines).toContainEqual({ route: "POST /v1/devices/:id/secrets", status: 400 });
    expect(lines).toContainEqual({ route: "POST /v1/devices/:id/secrets", status: 201 });
    expect(lines).toContainEqual({ route: "GET /v1/devices/:id", status: 200 });
    expect(lines).toContainEqual({ route: "DELETE /v1/devices/:id/secrets/:secret", status: 204 });
    expect(lines).toContainEqual({ route: "POST /v1/push", status: 401 });
    expect(lines).toContainEqual({ route: "POST /v1/push", status: 429 });
    expect(lines).toContainEqual({ route: "DELETE /v1/devices/:id", status: 204 });
    expect(lines).toContainEqual({ route: "unknown", status: 404 });
  });
});
