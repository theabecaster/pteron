import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import type { Env } from "../src/env";
import { HELD_RETRY_SECONDS, HOLD_TIMEOUT_MS, deskHolds } from "../src/index";
import { ROWS, counterKey } from "../src/limits";
import { MAX_LEASE_SECONDS, type Presence } from "../src/presence";
import { MAX_HOLD_TAGS } from "../src/validate";
import {
  type Device,
  FakeLimiter,
  Gateway,
  PAYLOAD,
  type Secret,
  T0,
  appleError,
  chosenDevice,
  chosenKey,
  chosenSecretId,
  counter,
  deviceRows,
  errorOf,
  reset,
  secretRows,
  spyOnDb,
  testEnv,
} from "./helpers";

/*
 * Desk presence at the gateway: `PUT /v1/presence`, `hold_if_desk` on a push, the
 * `presence` flag on a secret's PUT, and lease clearing. The Beacon and app
 * sides are stand-ins here: a test sends what they will send.
 */

/** A desk's tag, as a computer makes one: 22 url-safe characters. */
const DESK = "deskMacBook0000000000a";
const OTHER_DESK = "deskMacdesk0000000000b";


let gw: Gateway;
let device: Device;
/** The secret of the computer at the desk (the MacBook), flagged as the phone's own. */
let desk: Secret;
/** The secret of the computer the agents run on (workdesk), flagged as the phone's own. */
let agents: Secret;

beforeEach(async () => {
  await reset();
  gw = new Gateway();
  device = await chosenDevice();
  expect((await gw.putDevice(device)).status).toBe(201);
  desk = await own(device, "MacBook");
  agents = await own(device, "workdesk");
});

/** A secret the phone stores with `presence: true`, or the flag given; null sends none. */
async function own(of: Device, label: string, presence: boolean | null = true): Promise<Secret> {
  const secret = { secret_id: chosenSecretId(), push_secret: chosenKey() };
  const response = await putSecret(of, secret, label, presence ?? undefined);
  expect(response.status).toBe(201);
  return secret;
}

function putSecret(of: Device, secret: Secret, label: string, presence?: unknown): Promise<Response> {
  return gw.request("PUT", `/v1/devices/${of.device_id}/secrets/${secret.secret_id}`, {
    auth: of.owner_key,
    body: { label, push_secret: secret.push_secret, ...(presence === undefined ? {} : { presence }) },
  });
}

function lease(secret: string, body: unknown = { desk: DESK, ttl: 600 }): Promise<Response> {
  return gw.request("PUT", "/v1/presence", { auth: secret, body });
}

function held(secret: string, holdIfDesk: unknown = [DESK]): Promise<Response> {
  return gw.push(secret, { payload: PAYLOAD, push_type: "alert", hold_if_desk: holdIfDesk });
}

/** A namespace that stands in for PRESENCE_DO and records each use. */
function fakePresence(stub: Partial<Pick<Presence, "holds" | "lease" | "clear">>): {
  namespace: NonNullable<Env["PRESENCE_DO"]>;
  names: string[];
} {
  const names: string[] = [];
  const namespace = {
    idFromName(name: string) {
      names.push(name);
      return name;
    },
    get() {
      return stub;
    },
  } as unknown as NonNullable<Env["PRESENCE_DO"]>;
  return { namespace, names };
}

async function pushCount(): Promise<number> {
  const [row] = await deviceRows();
  return Number(row?.push_count);
}

describe("PUT /v1/presence", () => {
  it("stores a lease from a secret flagged as the phone's own", async () => {
    const response = await lease(desk.push_secret);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ stored: true });
  });

  it("stores nothing for a secret that is not flagged, and says so", async () => {
    const plain = await own(device, "tagged server", null);
    const response = await lease(plain.push_secret);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ stored: false });
    // The phone's own computers are not held by it.
    expect((await held(agents.push_secret)).status).toBe(200);
  });

  it("answers the one 401 to a missing, malformed or unknown secret", async () => {
    const missing = await gw.request("PUT", "/v1/presence", { body: { desk: DESK, ttl: 600 } });
    const malformed = await gw.request("PUT", "/v1/presence", {
      headers: { authorization: "Bearer short" },
      body: { desk: DESK, ttl: 600 },
    });
    const unknown = await lease(chosenKey());
    for (const response of [missing, malformed, unknown]) {
      expect(response.status).toBe(401);
      expect(await errorOf(response)).toMatchObject({ error: "unauthorized" });
    }
  });

  it.each([
    ["no desk", { ttl: 600 }],
    ["a desk that is not a tag", { desk: "MacBook", ttl: 600 }],
    ["a desk of 23 characters", { desk: `${DESK}x`, ttl: 600 }],
    ["no ttl", { desk: DESK }],
    ["a negative ttl", { desk: DESK, ttl: -1 }],
    ["a ttl over the longest lease", { desk: DESK, ttl: MAX_LEASE_SECONDS + 1 }],
    ["a ttl that is not whole", { desk: DESK, ttl: 1.5 }],
    ["a ttl that is text", { desk: DESK, ttl: "600" }],
    ["a body that is not an object", [DESK, 600]],
  ])("refuses %s with 400, before D1", async (_name, body) => {
    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    const response = await lease(desk.push_secret, body);
    expect(response.status).toBe(400);
    expect(log.statements).toEqual([]);
  });

  it("removes only its own desk with ttl 0", async () => {
    await lease(desk.push_secret, { desk: DESK, ttl: 600 });
    await lease(desk.push_secret, { desk: OTHER_DESK, ttl: 600 });
    expect(await (await lease(desk.push_secret, { desk: DESK, ttl: 0 })).json()).toEqual({ stored: true });
    expect((await held(agents.push_secret, [DESK])).status).toBe(200);
    expect((await held(agents.push_secret, [OTHER_DESK])).status).toBe(202);
  });

  it("answers 410 for a device whose token is dead, as a push does", async () => {
    gw.apple = appleError(410, "Unregistered");
    expect((await gw.push(agents.push_secret)).status).toBe(410);
    expect((await lease(desk.push_secret)).status).toBe(410);
  });

  it("uses the secret's limiter under a key of its own, so leases take no push's place", async () => {
    const limiter = new FakeLimiter();
    gw.env = { ...testEnv, RL_SECRET: limiter };
    await lease(desk.push_secret);
    await gw.push(desk.push_secret);
    expect(limiter.keys).toHaveLength(2);
    expect(limiter.keys[0]).toBe(`presence:${limiter.keys[1]}`);

    limiter.refuse = (key) => key.startsWith("presence:");
    const refused = await lease(desk.push_secret);
    expect(refused.status).toBe(429);
    expect((await gw.push(desk.push_secret)).status).toBe(200);
  });

  it("answers 429 with the store's wait when the phone's leases for the day are spent", async () => {
    const { namespace } = fakePresence({ lease: async () => ({ stored: false, retryAfter: 1234 }) });
    gw.env = { ...testEnv, PRESENCE_DO: namespace };
    const response = await lease(desk.push_secret);
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("1234");
  });

  it("answers 503 when the store fails, and the push still goes", async () => {
    const { namespace } = fakePresence({
      lease: async () => {
        throw new Error("storage");
      },
      holds: async () => {
        throw new Error("storage");
      },
    });
    gw.env = { ...testEnv, PRESENCE_DO: namespace };
    const response = await lease(desk.push_secret);
    expect(response.status).toBe(503);
    expect(await errorOf(response)).toMatchObject({ error: "presence_unavailable" });
    expect((await held(agents.push_secret)).status).toBe(200);
  });

  it("writes no D1 row", async () => {
    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    expect((await lease(desk.push_secret)).status).toBe(200);
    expect((await lease(desk.push_secret, { desk: DESK, ttl: 0 })).status).toBe(200);
    expect(log.rowsWritten).toBe(0);
  });

  it("takes only PUT", async () => {
    const response = await gw.request("POST", "/v1/presence", { auth: desk.push_secret, body: { desk: DESK, ttl: 600 } });
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("PUT");
  });
});

describe("POST /v1/push with hold_if_desk", () => {
  it("holds a push while a named desk has a lease: 202, nothing to Apple, nothing counted", async () => {
    await lease(desk.push_secret);
    const before = await pushCount();
    const response = await held(agents.push_secret);
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ held: true, retry_after: HELD_RETRY_SECONDS });
    expect(gw.calls).toEqual([]);
    expect(await pushCount()).toBe(before);
    expect(await counter(counterKey.sends())).toBeNull();
  });

  it("holds a push from the desk's own computer too", async () => {
    await lease(desk.push_secret);
    expect((await held(desk.push_secret)).status).toBe(202);
  });

  it("sends once the lease has ended", async () => {
    await lease(desk.push_secret, { desk: DESK, ttl: 600 });
    gw.now = T0 + 600;
    expect((await held(agents.push_secret)).status).toBe(200);
    expect(gw.calls).toHaveLength(1);
  });

  it("sends when no named desk has a lease", async () => {
    await lease(desk.push_secret, { desk: OTHER_DESK, ttl: 600 });
    expect((await held(agents.push_secret, [DESK])).status).toBe(200);
  });

  it("passes the payload on as before: the field never reaches Apple", async () => {
    expect((await held(agents.push_secret)).status).toBe(200);
    expect(gw.calls[0]?.body).toBe(JSON.stringify(PAYLOAD));
  });

  it.each([
    ["text", DESK],
    ["an empty list", []],
    ["a tag that is too short", ["desk"]],
    ["a tag that is not text", [42]],
    ["a list with one bad tag", [DESK, "no!"]],
    [`more than ${MAX_HOLD_TAGS} tags`, Array.from({ length: MAX_HOLD_TAGS + 1 }, () => DESK)],
    ["an object", { desk: DESK }],
    ["null", null],
  ])("ignores a malformed field (%s) and sends, without asking the store", async (_name, field) => {
    await lease(desk.push_secret);
    const { namespace, names } = fakePresence({ holds: async () => true });
    gw.env = { ...testEnv, PRESENCE_DO: namespace };
    expect((await held(agents.push_secret, field)).status).toBe(200);
    expect(names).toEqual([]);
  });

  it(`accepts up to ${MAX_HOLD_TAGS} tags`, async () => {
    await lease(desk.push_secret);
    const tags = [...Array.from({ length: MAX_HOLD_TAGS - 1 }, () => OTHER_DESK), DESK];
    expect((await held(agents.push_secret, tags)).status).toBe(202);
  });

  it("ignores the field from a secret that is not flagged, without asking the store", async () => {
    await lease(desk.push_secret);
    const plain = await own(device, "tagged server", false);
    const { namespace, names } = fakePresence({ holds: async () => true });
    gw.env = { ...testEnv, PRESENCE_DO: namespace };
    expect((await held(plain.push_secret)).status).toBe(200);
    expect(names).toEqual([]);
  });

  it("asks the store only for a push that carries the field", async () => {
    const { namespace, names } = fakePresence({ holds: async () => true });
    gw.env = { ...testEnv, PRESENCE_DO: namespace };
    expect((await gw.push(agents.push_secret)).status).toBe(200);
    expect(names).toEqual([]);
    expect((await held(agents.push_secret)).status).toBe(202);
    expect(names).toEqual([`phone:${device.device_id}`]);
  });

  it("asks the store only for a push that would go to Apple: a dead token or a spent cap answers first", async () => {
    const { namespace, names } = fakePresence({ holds: async () => true });
    gw.env = { ...testEnv, PRESENCE_DO: namespace };
    gw.apple = appleError(410, "Unregistered");
    expect((await gw.push(agents.push_secret)).status).toBe(410);
    expect((await held(agents.push_secret)).status).toBe(410);
    expect(names).toEqual([]);
  });

  it("sends when the store fails", async () => {
    const { namespace } = fakePresence({
      holds: async () => {
        throw new Error("storage");
      },
    });
    gw.env = { ...testEnv, PRESENCE_DO: namespace };
    expect((await held(agents.push_secret)).status).toBe(200);
  });

  it("sends when the store answers anything but true", async () => {
    const { namespace } = fakePresence({ holds: async () => "yes" as unknown as boolean });
    gw.env = { ...testEnv, PRESENCE_DO: namespace };
    expect((await held(agents.push_secret)).status).toBe(200);
  });

  it("sends within about a second when the store never answers", async () => {
    const { namespace } = fakePresence({ holds: () => new Promise<boolean>(() => {}) });
    gw.env = { ...testEnv, PRESENCE_DO: namespace };
    const started = Date.now();
    const response = await held(agents.push_secret);
    const waited = Date.now() - started;
    expect(response.status).toBe(200);
    expect(gw.calls).toHaveLength(1);
    expect(waited).toBeGreaterThanOrEqual(HOLD_TIMEOUT_MS - 50);
    expect(waited).toBeLessThan(HOLD_TIMEOUT_MS + 1000);
  });

  it("deskHolds is false with no binding, and with a store that throws at once", async () => {
    expect(await deskHolds(undefined, "d", [DESK], T0)).toBe(false);
    const throwing = {
      idFromName() {
        throw new Error("bad");
      },
    } as unknown as NonNullable<Env["PRESENCE_DO"]>;
    expect(await deskHolds(throwing, "d", [DESK], T0)).toBe(false);
  });

  it("keeps one phone's leases from another's pushes", async () => {
    await lease(desk.push_secret);
    const other = await chosenDevice();
    expect((await gw.putDevice(other, "ef".repeat(32))).status).toBe(201);
    const theirs = await own(other, "workdesk");
    expect((await held(theirs.push_secret)).status).toBe(200);
  });
});

describe("the binding", () => {
  it("is in wrangler.toml", () => {
    expect(env.PRESENCE_DO).toBeDefined();
  });

  it("missing, the lease route answers 404 as an older gateway does, and every push is sent", async () => {
    await lease(desk.push_secret);
    gw.env = { ...testEnv, PRESENCE_DO: undefined };
    const response = await lease(desk.push_secret);
    expect(response.status).toBe(404);
    expect(await errorOf(response)).toMatchObject({ error: "not_found" });
    expect((await held(agents.push_secret)).status).toBe(200);
  });
});

describe("trust taken back clears the phone's leases", () => {
  it("when a secret's flag is cleared", async () => {
    await lease(desk.push_secret);
    expect((await held(agents.push_secret)).status).toBe(202);
    expect((await putSecret(device, desk, "MacBook", false)).status).toBe(200);
    expect((await held(agents.push_secret)).status).toBe(200);
  });

  it("when another secret takes the id's place with the flag cleared", async () => {
    await lease(desk.push_secret);
    const replaced = { secret_id: desk.secret_id, push_secret: chosenKey() };
    expect((await putSecret(device, replaced, "MacBook", false)).status).toBe(200);
    expect((await held(agents.push_secret)).status).toBe(200);
  });

  it("when a flagged secret is deleted", async () => {
    await lease(desk.push_secret);
    const deleted = await gw.request("DELETE", `/v1/devices/${device.device_id}/secrets/${desk.secret_id}`, {
      auth: device.owner_key,
    });
    expect(deleted.status).toBe(204);
    expect((await held(agents.push_secret)).status).toBe(200);
  });

  it("not when an unflagged secret is deleted, or a flag is set or kept", async () => {
    const plain = await own(device, "plain", false);
    const { namespace, names } = fakePresence({ clear: async () => {} });
    gw.env = { ...testEnv, PRESENCE_DO: namespace };
    await gw.request("DELETE", `/v1/devices/${device.device_id}/secrets/${plain.secret_id}`, { auth: device.owner_key });
    await putSecret(device, desk, "MacBook", true);
    await putSecret(device, desk, "MacBook");
    await own(device, "new", true);
    expect(names).toEqual([]);
  });

  it("answers as before when the store fails or never answers, and asks once", async () => {
    let calls = 0;
    const { namespace } = fakePresence({
      clear: () => {
        calls++;
        return new Promise<void>(() => {});
      },
    });
    gw.env = { ...testEnv, PRESENCE_DO: namespace };
    const started = Date.now();
    expect((await putSecret(device, desk, "MacBook", false)).status).toBe(200);
    expect(Date.now() - started).toBeLessThan(HOLD_TIMEOUT_MS + 1000);
    const failing = fakePresence({
      clear: async () => {
        calls++;
        throw new Error("storage");
      },
    });
    gw.env = { ...testEnv, PRESENCE_DO: failing.namespace };
    const deleted = await gw.request("DELETE", `/v1/devices/${device.device_id}/secrets/${agents.secret_id}`, {
      auth: device.owner_key,
    });
    expect(deleted.status).toBe(204);
    expect(calls).toBe(2);
  });
});


describe("presence on the secret's PUT", () => {
  async function flag(of: Secret): Promise<number | undefined> {
    const rows = await secretRows();
    return rows.find((row) => row.secret_id === of.secret_id)?.presence as number | undefined;
  }
  async function manageCount(): Promise<number> {
    const [row] = await deviceRows();
    return Number(row?.manage_count);
  }

  it("stores the flag with a new secret, and 0 without one", async () => {
    expect(await flag(desk)).toBe(1);
    const plain = await own(device, "plain", null);
    expect(await flag(plain)).toBe(0);
  });

  it("a minted secret is never flagged", async () => {
    const minted = await gw.mint(device, "minted");
    expect(await flag(minted)).toBe(0);
  });

  it("writes a change of the flag alone, as one management write", async () => {
    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    const count = await manageCount();
    const response = await putSecret(device, desk, "MacBook", false);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ secret_id: desk.secret_id });
    expect(await flag(desk)).toBe(0);
    expect(await manageCount()).toBe(count + 1);
    // Three counts (an IPv4 client has one address counter) and the secret's row; its index
    // entry is not rewritten. An IPv6 client adds its /48 counter: 5.
    expect(log.rowsWritten).toBe(4);
    expect(log.rowsWritten).toBeLessThanOrEqual(ROWS.manage);
    // And back.
    expect((await putSecret(device, desk, "MacBook", true)).status).toBe(200);
    expect(await flag(desk)).toBe(1);
  });

  it("keeps the flag when the body has none, and writes nothing", async () => {
    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    const count = await manageCount();
    expect((await putSecret(device, desk, "MacBook")).status).toBe(200);
    expect((await putSecret(device, desk, "MacBook", true)).status).toBe(200);
    expect(await flag(desk)).toBe(1);
    expect(await manageCount()).toBe(count);
    expect(log.rowsWritten).toBe(0);
  });

  it("keeps the flag when another secret takes the id's place without one, and takes one that is given", async () => {
    const healed = { secret_id: desk.secret_id, push_secret: chosenKey() };
    expect((await putSecret(device, healed, "MacBook")).status).toBe(200);
    expect(await flag(desk)).toBe(1);
    // The new secret leases; the one it replaced is gone.
    expect((await lease(healed.push_secret)).status).toBe(200);
    expect((await lease(desk.push_secret)).status).toBe(401);

    const again = { secret_id: desk.secret_id, push_secret: chosenKey() };
    expect((await putSecret(device, again, "MacBook", false)).status).toBe(200);
    expect(await flag(desk)).toBe(0);
  });

  it.each([["text", "true"], ["a number", 1], ["null", null]])("refuses a flag that is %s with 400", async (_name, value) => {
    const response = await putSecret(device, desk, "MacBook", value);
    expect(response.status).toBe(400);
    expect(await flag(desk)).toBe(1);
  });

  it("leaves the device's listing as it was: the flag is not shown", async () => {
    const shown = await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key });
    // The listing is as it was: the flag is not shown.
    const body = await shown.json<{ secrets: Record<string, unknown>[] }>();
    for (const secret of body.secrets) expect(Object.keys(secret).sort()).toEqual(["created_at", "label", "secret_id"]);
  });
});
