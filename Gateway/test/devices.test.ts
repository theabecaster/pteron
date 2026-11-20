import { beforeEach, describe, expect, it } from "vitest";
import { sha256Hex } from "../src/encoding";
import { MAX_SECRETS_PER_DEVICE } from "../src/limits";
import {
  type Device,
  Gateway,
  PRODUCTION_TOKEN,
  SANDBOX_TOKEN,
  T0,
  deviceRows,
  errorOf,
  reset,
  secretRows,
} from "./helpers";

let gw: Gateway;
beforeEach(async () => {
  await reset();
  gw = new Gateway();
});

const WRONG_KEY = "A".repeat(43);
const UNKNOWN_ID = "x".repeat(27);
const TODAY = T0 / 86400;

describe("POST /v1/devices", () => {
  it("returns a device id and an owner key, no push secret, and stores only the key's hash", async () => {
    const response = await gw.request("POST", "/v1/devices", {
      body: { apns_token: PRODUCTION_TOKEN, environment: "production" },
    });
    expect(response.status).toBe(201);
    const body = await response.json<Record<string, string>>();
    expect(Object.keys(body).sort()).toEqual(["device_id", "owner_key"]);
    expect(body.device_id).toMatch(/^[A-Za-z0-9_-]{26,}$/);
    expect(body.owner_key).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const rows = await deviceRows();
    expect(rows).toEqual([
      {
        device_id: body.device_id,
        owner_hash: await sha256Hex(body.owner_key ?? ""),
        // Hex is case-insensitive, so it is stored in one case.
        apns_token: PRODUCTION_TOKEN.toLowerCase(),
        environment: "production",
        created_at: T0,
        updated_at: T0,
        push_day: TODAY,
        push_count: 0,
        manage_day: TODAY,
        manage_count: 0,
        // The hash of the token as stored, in one case.
        token_hash: await sha256Hex(PRODUCTION_TOKEN.toLowerCase()),
        dead: 0,
      },
    ]);
    expect(JSON.stringify(rows)).not.toContain(body.owner_key);
    expect(JSON.stringify(body)).not.toContain(await sha256Hex(PRODUCTION_TOKEN.toLowerCase()));
    expect(await secretRows()).toEqual([]);
  });

  it("gives every registration its own values", async () => {
    const a = await gw.registerDevice();
    const b = await gw.registerDevice();
    expect(new Set([a.device_id, a.owner_key, b.device_id, b.owner_key]).size).toBe(4);
  });

  it.each([
    ["a short token", { apns_token: "ab".repeat(31), environment: "sandbox" }],
    ["a long token", { apns_token: "a".repeat(201), environment: "sandbox" }],
    ["a token that is not hex", { apns_token: "zz".repeat(32), environment: "sandbox" }],
    ["a token that is not a string", { apns_token: 12, environment: "sandbox" }],
    ["no token", { environment: "sandbox" }],
    ["an unknown environment", { apns_token: SANDBOX_TOKEN, environment: "development" }],
    ["no environment", { apns_token: SANDBOX_TOKEN }],
    ["an array", [SANDBOX_TOKEN]],
    ["null", null],
  ])("answers 400 for %s", async (_name, body) => {
    const response = await gw.request("POST", "/v1/devices", { body });
    expect(response.status).toBe(400);
    expect((await errorOf(response)).error).toBe("invalid_request");
    expect(await deviceRows()).toEqual([]);
  });

  it("answers 400 for a body that is not JSON", async () => {
    const response = await gw.request("POST", "/v1/devices", { raw: "{not json" });
    expect(response.status).toBe(400);
    expect((await errorOf(response)).error).toBe("invalid_request");
  });
});

describe("GET /v1/devices/{id}", () => {
  it("answers the environment and the secrets, oldest first, without any credential", async () => {
    const device = await gw.registerDevice(PRODUCTION_TOKEN, "production");
    const empty = await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key });
    expect(empty.status).toBe(200);
    expect(await empty.json()).toEqual({ environment: "production", secrets: [] });

    gw.now = T0 + 10;
    const first = await gw.mint(device, "studio");
    gw.now = T0 + 20;
    const second = await gw.mint(device, "Abe's MacBook Pro 🦖");
    const response = await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key });
    expect(response.status).toBe(200);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({
      environment: "production",
      secrets: [
        { secret_id: first.secret_id, label: "studio", created_at: T0 + 10 },
        { secret_id: second.secret_id, label: "Abe's MacBook Pro 🦖", created_at: T0 + 20 },
      ],
    });
    for (const secret of [first.push_secret, second.push_secret, device.owner_key, PRODUCTION_TOKEN.toLowerCase()]) {
      expect(text).not.toContain(secret);
    }
    expect(text).not.toContain(await sha256Hex(first.push_secret));
  });

  it("shows only the caller's own device", async () => {
    const device = await gw.register();
    const other = await gw.register(PRODUCTION_TOKEN, "production");
    const response = await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key });
    const body = await response.json<{ secrets: { secret_id: string }[] }>();
    expect(body.secrets.map((s) => s.secret_id)).toEqual([device.secret_id]);
    expect(JSON.stringify(body)).not.toContain(other.secret_id);
  });
});

describe("PUT /v1/devices/{id}", () => {
  it("replaces the token and environment and keeps the secrets", async () => {
    const device = await gw.register();
    gw.now = T0 + 50;
    const response = await gw.request("PUT", `/v1/devices/${device.device_id}`, {
      auth: device.owner_key,
      body: { apns_token: PRODUCTION_TOKEN, environment: "production" },
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({});
    expect(await deviceRows()).toMatchObject([
      {
        apns_token: PRODUCTION_TOKEN.toLowerCase(),
        token_hash: await sha256Hex(PRODUCTION_TOKEN.toLowerCase()),
        environment: "production",
        created_at: T0,
        updated_at: T0 + 50,
      },
    ]);

    expect((await gw.push(device.push_secret)).status).toBe(200);
    expect(gw.calls[0]?.url).toBe(`https://api.push.apple.com/3/device/${PRODUCTION_TOKEN.toLowerCase()}`);
  });

  it("answers 400 for a bad token", async () => {
    const device = await gw.register();
    const response = await gw.request("PUT", `/v1/devices/${device.device_id}`, {
      auth: device.owner_key,
      body: { apns_token: "nope", environment: "sandbox" },
    });
    expect(response.status).toBe(400);
  });
});

describe("POST /v1/devices/{id}/secrets", () => {
  it("returns a secret id and a push secret, and stores only the secret's hash", async () => {
    const device = await gw.registerDevice();
    gw.now = T0 + 7;
    const response = await gw.request("POST", `/v1/devices/${device.device_id}/secrets`, {
      auth: device.owner_key,
      body: { label: "studio" },
    });
    expect(response.status).toBe(201);
    const body = await response.json<Record<string, string>>();
    expect(Object.keys(body).sort()).toEqual(["push_secret", "secret_id"]);
    expect(body.secret_id).toMatch(/^[A-Za-z0-9_-]{16,}$/);
    expect(body.push_secret).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(body.push_secret).not.toBe(device.owner_key);

    const rows = await secretRows();
    expect(rows).toEqual([
      {
        secret_hash: await sha256Hex(body.push_secret ?? ""),
        device_id: device.device_id,
        secret_id: body.secret_id,
        label: "studio",
        created_at: T0 + 7,
        presence: 0,
      },
    ]);
    expect(JSON.stringify(rows)).not.toContain(body.push_secret);
    expect((await gw.push(body.push_secret ?? "")).status).toBe(200);
  });

  it("gives every secret its own values, also for the same label", async () => {
    const device = await gw.registerDevice();
    const a = await gw.mint(device, "mac");
    const b = await gw.mint(device, "mac");
    expect(new Set([a.secret_id, a.push_secret, b.secret_id, b.push_secret]).size).toBe(4);
  });

  it(`answers 409 too_many_secrets at ${MAX_SECRETS_PER_DEVICE}, per device, and frees a place on delete`, async () => {
    expect(MAX_SECRETS_PER_DEVICE).toBe(10);
    const device = await gw.registerDevice();
    const other = await gw.registerDevice();
    const minted = [];
    for (let i = 0; i < 10; i++) minted.push(await gw.mint(device, `helper ${i}`));

    const path = `/v1/devices/${device.device_id}/secrets`;
    const full = await gw.request("POST", path, { auth: device.owner_key, body: { label: "one more" } });
    expect(full.status).toBe(409);
    expect((await errorOf(full)).error).toBe("too_many_secrets");
    expect(await secretRows()).toHaveLength(10);

    // Another phone has its own ten.
    await gw.mint(other);

    const gone = minted[3];
    await gw.request("DELETE", `${path}/${gone?.secret_id}`, { auth: device.owner_key });
    expect((await gw.request("POST", path, { auth: device.owner_key, body: { label: "one more" } })).status).toBe(201);
    expect((await gw.request("POST", path, { auth: device.owner_key, body: { label: "again" } })).status).toBe(409);
  });

  it.each([
    ["no label", {}],
    ["an empty label", { label: "" }],
    ["a label of spaces", { label: "   " }],
    ["a label of 65 characters", { label: "a".repeat(65) }],
    ["a label that is not a string", { label: 7 }],
    ["a label with a line break", { label: "work\ndesk" }],
    ["a label with a tab", { label: "work\tdesk" }],
    ["a label with a NUL", { label: "work\u0000desk" }],
    ["a label with an escape", { label: "work\u001b[31mdesk" }],
    ["a label with a line separator", { label: "work desk" }],
    ["a label with a lone surrogate", { label: "work\ud83ddesk" }],
    ["an array", ["studio"]],
    ["null", null],
  ])("answers 400 for %s", async (_name, body) => {
    const device = await gw.registerDevice();
    const response = await gw.request("POST", `/v1/devices/${device.device_id}/secrets`, {
      auth: device.owner_key,
      body,
    });
    expect(response.status).toBe(400);
    expect((await errorOf(response)).error).toBe("invalid_request");
    expect(await secretRows()).toEqual([]);
  });

  it("accepts a label of 64 characters, counted as characters and not as bytes", async () => {
    const device = await gw.registerDevice();
    await gw.mint(device, "a".repeat(64));
    await gw.mint(device, "🦖".repeat(64));
    await gw.mint(device, "Büro – Küche (2)");
    expect(await secretRows()).toHaveLength(3);
  });
});

describe("DELETE /v1/devices/{id}/secrets/{secret_id}", () => {
  it("removes that secret at once and leaves the device's other secrets working", async () => {
    const device = await gw.registerDevice();
    const a = await gw.mint(device, "studio");
    const b = await gw.mint(device, "laptop");
    expect((await gw.push(a.push_secret)).status).toBe(200);
    expect((await gw.push(b.push_secret)).status).toBe(200);

    const response = await gw.request("DELETE", `/v1/devices/${device.device_id}/secrets/${a.secret_id}`, {
      auth: device.owner_key,
    });
    expect(response.status).toBe(204);
    expect(await response.text()).toBe("");

    expect((await gw.push(a.push_secret)).status).toBe(401);
    expect((await gw.push(b.push_secret)).status).toBe(200);
    expect(gw.calls).toHaveLength(3);
    expect(await secretRows()).toMatchObject([{ secret_id: b.secret_id }]);
    expect(await deviceRows()).toHaveLength(1);
  });

  it("answers 204 again when the secret is already gone, or never was", async () => {
    const device = await gw.register();
    const path = `/v1/devices/${device.device_id}/secrets`;
    for (let i = 0; i < 2; i++) {
      expect((await gw.request("DELETE", `${path}/${device.secret_id}`, { auth: device.owner_key })).status).toBe(204);
    }
    expect((await gw.request("DELETE", `${path}/neverMintedSecret0`, { auth: device.owner_key })).status).toBe(204);
  });

  it("does not remove another device's secret", async () => {
    const device = await gw.register();
    const other = await gw.register();
    const response = await gw.request("DELETE", `/v1/devices/${device.device_id}/secrets/${other.secret_id}`, {
      auth: device.owner_key,
    });
    // The device and key are right and that device has no such secret: nothing to do.
    expect(response.status).toBe(204);
    expect((await gw.push(other.push_secret)).status).toBe(200);
    expect(await secretRows()).toHaveLength(2);
  });
});

describe("DELETE /v1/devices/{id}", () => {
  it("removes the device and all its secrets, and nothing of another device", async () => {
    const device = await gw.registerDevice();
    const a = await gw.mint(device, "studio");
    const b = await gw.mint(device, "laptop");
    const other = await gw.register(PRODUCTION_TOKEN, "production");

    const response = await gw.request("DELETE", `/v1/devices/${device.device_id}`, { auth: device.owner_key });
    expect(response.status).toBe(204);
    expect(await response.text()).toBe("");

    expect((await gw.push(a.push_secret)).status).toBe(401);
    expect((await gw.push(b.push_secret)).status).toBe(401);
    expect(await deviceRows()).toMatchObject([{ device_id: other.device_id }]);
    expect(await secretRows()).toMatchObject([{ secret_id: other.secret_id, device_id: other.device_id }]);
    expect((await gw.push(other.push_secret)).status).toBe(200);
  });

  it("answers 401 once the device is gone, as for any unknown device", async () => {
    const device = await gw.register();
    const path = `/v1/devices/${device.device_id}`;
    expect((await gw.request("DELETE", path, { auth: device.owner_key })).status).toBe(204);
    expect((await gw.request("DELETE", path, { auth: device.owner_key })).status).toBe(401);
    expect((await gw.request("GET", path, { auth: device.owner_key })).status).toBe(401);
  });
});

describe("the owner key", () => {
  type Attempt = (device: Device, id: string, key: string | undefined) => Promise<Response>;
  const send =
    (method: string, suffix: string, body?: unknown): Attempt =>
    (_device, id, key) =>
      gw.request(method, `/v1/devices/${id}${suffix}`, {
        ...(key === undefined ? {} : { auth: key }),
        ...(body === undefined ? {} : { body }),
      });
  const routes: [string, Attempt][] = [
    ["GET /v1/devices/{id}", send("GET", "")],
    ["PUT /v1/devices/{id}", send("PUT", "", { apns_token: PRODUCTION_TOKEN, environment: "production" })],
    ["DELETE /v1/devices/{id}", send("DELETE", "")],
    ["POST /v1/devices/{id}/secrets", send("POST", "/secrets", { label: "intruder" })],
    ["DELETE /v1/devices/{id}/secrets/{secret_id}", send("DELETE", "/secrets/someSecretId0000")],
  ];

  /** Status, headers and body bytes, so two answers can be compared as a client sees them. */
  async function wire(response: Response): Promise<string> {
    const headers = [...response.headers].map(([name, value]) => `${name}: ${value}`).sort();
    return [response.status, ...headers, await response.text()].join("\n");
  }

  it.each(routes)(
    "%s answers a byte-identical 401 for an unknown device and for a wrong key",
    async (_name, attempt) => {
      const device = await gw.register();
      const other = await gw.register();
      const before = [await deviceRows(), await secretRows()];

      const unknownDevice = await wire(await attempt(device, UNKNOWN_ID, device.owner_key));
      const answers = [
        await wire(await attempt(device, device.device_id, WRONG_KEY)),
        // Another device's real key is still the wrong key.
        await wire(await attempt(device, device.device_id, other.owner_key)),
        // The push secret is not the owner key.
        await wire(await attempt(device, device.device_id, device.push_secret)),
        await wire(await attempt(device, device.device_id, undefined)),
        await wire(await attempt(device, device.device_id, "short")),
        await wire(await attempt(device, UNKNOWN_ID, WRONG_KEY)),
      ];
      for (const answer of answers) expect(answer).toBe(unknownDevice);

      const [status, ...rest] = unknownDevice.split("\n");
      expect(status).toBe("401");
      // Exactly these two fields, so a client can tell this 401 from a proxy's.
      expect(rest.at(-1)).toBe('{"error":"unauthorized","message":"Missing or invalid credentials."}');

      expect([await deviceRows(), await secretRows()]).toEqual(before);
      expect((await gw.push(device.push_secret)).status).toBe(200);
    },
  );

  it("answers the same 401 body on every owner-key route and on push", async () => {
    const device = await gw.register();
    const bodies = new Set<string>();
    for (const [, attempt] of routes) bodies.add(await (await attempt(device, device.device_id, WRONG_KEY)).text());
    bodies.add(await (await gw.push("B".repeat(43))).text());
    expect(bodies.size).toBe(1);
  });

  it("has no rotate route any more", async () => {
    const device = await gw.register();
    const response = await gw.request("POST", `/v1/devices/${device.device_id}/rotate`, { auth: device.owner_key });
    expect(response.status).toBe(404);
    expect((await gw.push(device.push_secret)).status).toBe(200);
  });
});
