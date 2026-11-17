import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { sha256Hex } from "../src/encoding";
import { IDLE_SECONDS, LIMITS, MAX_DEVICES_PER_TOKEN, counterKey } from "../src/limits";
import { purge } from "../src/purge";
import {
  type Device,
  Gateway,
  PRODUCTION_TOKEN,
  type Registered,
  SANDBOX_TOKEN,
  T0,
  appleError,
  counter,
  deviceRows,
  errorOf,
  reset,
  secretRows,
  seedCounter,
  spyOnDb,
  testEnv,
  tokenNumber,
} from "./helpers";

/**
 * What the gateway keeps per APNs token: how many devices may hold one, the pushes they
 * have between them in a day, and what happens once Apple no longer accepts it.
 */

let gw: Gateway;
beforeEach(async () => {
  await reset();
  gw = new Gateway();
});

const DAY = 86400;
const TOKEN = "5a".repeat(32);

async function deviceRow(deviceId: string): Promise<Record<string, unknown>> {
  const row = await env.DB.prepare("SELECT * FROM devices WHERE device_id = ?1").bind(deviceId).first();
  if (!row) throw new Error("no such device");
  return row;
}

const registration = (token: string, ip?: string): Promise<Response> =>
  gw.request("POST", "/v1/devices", {
    body: { apns_token: token, environment: "sandbox" },
    ...(ip === undefined ? {} : { ip }),
  });

const changeToken = (device: Device, token: string): Promise<Response> =>
  gw.request("PUT", `/v1/devices/${device.device_id}`, {
    auth: device.owner_key,
    body: { apns_token: token, environment: "sandbox" },
  });

async function expectTooManyDevices(response: Response): Promise<void> {
  expect(response.status).toBe(409);
  const text = await response.clone().text();
  expect((await errorOf(response)).error).toBe("too_many_devices");
  // The answer names no device, token or hash.
  expect(Object.keys(JSON.parse(text) as object).sort()).toEqual(["error", "message"]);
  expect(text).not.toMatch(/[0-9a-f]{32}/i);
}

describe("devices per token", () => {
  it("is three", () => {
    expect(MAX_DEVICES_PER_TOKEN).toBe(3);
  });

  it("lets three registrations hold one token and answers 409 too_many_devices to the fourth, with nothing written", async () => {
    for (let i = 0; i < 3; i++) expect((await registration(TOKEN)).status).toBe(201);

    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    await expectTooManyDevices(await registration(TOKEN));
    // The same token in another case is the same token, from any address.
    await expectTooManyDevices(await registration(TOKEN.toUpperCase(), "198.51.100.9"));
    expect(log.statements).toHaveLength(2);
    expect(log.rowsWritten).toBe(0);
    expect(log.otherCalls).toBe(0);
    gw.env = testEnv;

    expect(await deviceRows()).toHaveLength(3);
    // A refused registration took nothing from the registration caps.
    expect((await counter(counterKey.registrations()))?.count).toBe(3);
    expect(await counter(counterKey.register(await sha256Hex("198.51.100.9")))).toBeNull();

    // Another token registers as before.
    expect((await registration(PRODUCTION_TOKEN)).status).toBe(201);
  });

  it("frees a place when a device is deleted or moves to another token", async () => {
    const devices: Device[] = [];
    for (let i = 0; i < 3; i++) devices.push(await gw.registerDevice(TOKEN));
    await expectTooManyDevices(await registration(TOKEN));

    const [first, second] = devices;
    if (!first || !second) throw new Error("three devices were registered");
    expect((await gw.request("DELETE", `/v1/devices/${first.device_id}`, { auth: first.owner_key })).status).toBe(204);
    expect((await registration(TOKEN)).status).toBe(201);
    await expectTooManyDevices(await registration(TOKEN));

    expect((await changeToken(second, PRODUCTION_TOKEN)).status).toBe(200);
    expect((await registration(TOKEN)).status).toBe(201);
    await expectTooManyDevices(await registration(TOKEN));
  });

  it("answers 409 too_many_devices to a token change onto a token that has three, with nothing written", async () => {
    for (let i = 0; i < 3; i++) await gw.registerDevice(TOKEN);
    const mover = await gw.register(PRODUCTION_TOKEN);
    const before = await deviceRow(mover.device_id);

    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    await expectTooManyDevices(await changeToken(mover, TOKEN));
    expect(log.statements).toHaveLength(1);
    expect(log.rowsWritten).toBe(0);
    expect(log.otherCalls).toBe(0);
    gw.env = testEnv;

    // The device is as it was, the refused change was not counted, and it still pushes.
    expect(await deviceRow(mover.device_id)).toEqual(before);
    expect((await gw.push(mover.push_secret)).status).toBe(200);
    expect(gw.calls[0]?.url).toContain(PRODUCTION_TOKEN.toLowerCase());

    // A token with a place left takes it.
    expect((await changeToken(mover, tokenNumber(77))).status).toBe(200);
  });

  it("lets a device of a full token send its own token again", async () => {
    const devices: Device[] = [];
    for (let i = 0; i < 3; i++) devices.push(await gw.registerDevice(TOKEN));
    const one = devices[0];
    if (!one) throw new Error("three devices were registered");
    expect((await changeToken(one, TOKEN)).status).toBe(200);
    expect(await deviceRows()).toHaveLength(3);
  });

  it("never answers the token's hash", async () => {
    const hash = await sha256Hex(TOKEN);
    const device = await gw.register(TOKEN);
    const answers = [
      await registration(TOKEN),
      await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key }),
      await changeToken(device, TOKEN),
      await gw.push(device.push_secret),
      await registration(TOKEN),
      await registration(TOKEN),
    ];
    expect(answers.map((r) => r.status)).toEqual([201, 200, 200, 200, 201, 409]);
    for (const answer of answers) expect(await answer.text()).not.toContain(hash);
    expect((await deviceRow(device.device_id)).token_hash).toBe(hash);
  });
});

describe("pushes per token", () => {
  const LEFT = 6;

  /** Three devices on one token, one on another, and the shared token six pushes from its cap. */
  async function nearTheCap(): Promise<{ sharing: Registered[]; other: Registered }> {
    const sharing = [await gw.register(TOKEN), await gw.register(TOKEN), await gw.register(TOKEN)];
    const other = await gw.register(PRODUCTION_TOKEN);
    await env.DB.prepare("UPDATE devices SET push_count = ?1 WHERE device_id = ?2")
      .bind(LIMITS.pushPerTokenPerDay.max - LEFT, sharing[0]?.device_id)
      .run();
    return { sharing, other };
  }

  it("stop at the token's cap across the devices that share it, while another token still pushes", async () => {
    const { sharing, other } = await nearTheCap();
    gw.now = T0 + 3600;

    // The six pushes left go out through any of the three devices.
    for (let i = 0; i < LEFT; i++) {
      expect((await gw.push(sharing[i % 3]?.push_secret ?? "")).status).toBe(200);
    }
    expect(gw.calls).toHaveLength(LEFT);

    // Now none of the three has a push, though two of them sent two each.
    for (const device of sharing) {
      const response = await gw.push(device.push_secret);
      expect(response.status).toBe(429);
      expect(response.headers.get("retry-after")).toBe(String(DAY - 3600));
    }
    expect(gw.calls).toHaveLength(LEFT);
    const counts = await Promise.all(sharing.map(async (d) => (await deviceRow(d.device_id)).push_count));
    expect(counts).toEqual([LIMITS.pushPerTokenPerDay.max - LEFT + 2, 2, 2]);
    expect((counts as number[]).reduce((sum, n) => sum + n, 0)).toBe(LIMITS.pushPerTokenPerDay.max);

    // A device with another token is not affected.
    for (let i = 0; i < 3; i++) expect((await gw.push(other.push_secret)).status).toBe(200);
    expect((await deviceRow(other.device_id)).push_count).toBe(3);

    // A refused push took nothing from the global budget.
    expect((await counter(counterKey.sends()))?.count).toBe(LEFT + 3);

    gw.now = T0 + DAY;
    for (const device of sharing) expect((await gw.push(device.push_secret)).status).toBe(200);
  });

  it("give three devices on one token exactly what one device alone has", async () => {
    const sharing = [await gw.register(TOKEN), await gw.register(TOKEN), await gw.register(TOKEN)];
    const alone = await gw.register(PRODUCTION_TOKEN);
    const sent = async (devices: Registered[]): Promise<number> => {
      const before = gw.calls.length;
      for (let i = 0; i < LIMITS.pushPerTokenPerDay.max + 30; i++) {
        await gw.push(devices[i % devices.length]?.push_secret ?? "");
      }
      return gw.calls.length - before;
    };
    expect(await sent(sharing)).toBe(LIMITS.pushPerTokenPerDay.max);
    expect(await sent([alone])).toBe(LIMITS.pushPerTokenPerDay.max);
  });

  it("refuse a push past the token's cap with one read and no write, through every device of the token", async () => {
    const { sharing } = await nearTheCap();
    await env.DB.prepare("UPDATE devices SET push_count = ?1 WHERE device_id = ?2")
      .bind(LIMITS.pushPerTokenPerDay.max, sharing[0]?.device_id)
      .run();
    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    for (const device of sharing) expect((await gw.push(device.push_secret)).status).toBe(429);
    expect(log.statements).toHaveLength(3);
    expect(log.rowsWritten).toBe(0);
    expect(log.otherCalls).toBe(0);
    expect(gw.calls).toHaveLength(0);
  });

  it("follow the device to its new token", async () => {
    const { sharing } = await nearTheCap();
    const [busy, quiet] = sharing;
    if (!busy || !quiet) throw new Error("three devices were registered");
    // The device that sent most of the day's pushes moves to a token of its own: it brings
    // its count along, and the token it left has the day's pushes of the devices that stay.
    expect((await changeToken(busy, tokenNumber(5))).status).toBe(200);
    for (let i = 0; i < LEFT; i++) expect((await gw.push(busy.push_secret)).status).toBe(200);
    expect((await gw.push(busy.push_secret)).status).toBe(429);
    expect((await gw.push(quiet.push_secret)).status).toBe(200);
  });

  it("count a device whose row has no token hash on its own, and with its token once the hash is filled in", async () => {
    const legacy = await gw.register(TOKEN);
    const second = await gw.register(TOKEN);
    await env.DB.prepare("UPDATE devices SET token_hash = NULL, push_count = ?1 WHERE device_id = ?2")
      .bind(LIMITS.pushPerTokenPerDay.max - 1, legacy.device_id)
      .run();

    // Its own count decides for it, and the other device's count does not include it.
    expect((await gw.push(legacy.push_secret)).status).toBe(200);
    expect((await gw.push(legacy.push_secret)).status).toBe(429);
    expect((await gw.push(second.push_secret)).status).toBe(200);
    // A push does not write the hash.
    expect((await deviceRow(legacy.device_id)).token_hash).toBeNull();

    // Its next management write does, and from then on the two share the token's count.
    await gw.mint(legacy, "laptop");
    expect((await deviceRow(legacy.device_id)).token_hash).toBe(await sha256Hex(TOKEN));
    expect((await gw.push(second.push_secret)).status).toBe(429);
  });
});

describe("a dead token", () => {
  /** Every counter there is at or past its maximum: the device's, its address's and the global ones. */
  async function spendEverything(device: Device): Promise<void> {
    const far = T0 + 10 * DAY;
    const address = await sha256Hex("203.0.113.7");
    await env.DB.batch([
      env.DB.prepare("DELETE FROM counters"),
      env.DB.prepare("UPDATE devices SET push_count = ?1, manage_count = ?2, push_day = ?3, manage_day = ?3 WHERE device_id = ?4").bind(
        LIMITS.pushPerTokenPerDay.max,
        LIMITS.managePerDevicePerDay.max,
        Math.floor(gw.now / DAY),
        device.device_id,
      ),
    ]);
    for (const [key, limit] of [
      [counterKey.sends(), LIMITS.pushPerDay],
      [counterKey.manage(), LIMITS.managePerDay],
      [counterKey.deletes(), LIMITS.deletesPerDay],
      [counterKey.registrations(), LIMITS.registerPerDay],
      [counterKey.manageFrom(address), LIMITS.managePerAddressPerDay],
      [counterKey.register(address), LIMITS.registerPerAddressPerHour],
      [counterKey.registerDay(address), LIMITS.registerPerAddressPerDay],
    ] as const) {
      await seedCounter(key, limit.max, far);
    }
  }

  it("answers 410 on the push that learns it and marks the device in that push's two rows", async () => {
    const device = await gw.register();
    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    gw.apple = appleError(410, "Unregistered");

    const response = await gw.push(device.push_secret);
    expect(response.status).toBe(410);
    expect(await errorOf(response)).toMatchObject({ error: "unregistered", reason: "Unregistered" });
    expect(log.statements).toHaveLength(3);
    expect(log.batchRowsWritten).toEqual([2]);
    expect(log.rowsWritten).toBe(2);
    expect(await deviceRow(device.device_id)).toMatchObject({ dead: 1, push_count: 1 });
    // The device and its secret stay until the purge.
    expect(await secretRows()).toHaveLength(1);
  });

  it("answers 410 to every later push with one read, no write and no request to Apple, whatever the budgets hold", async () => {
    const device = await gw.register();
    const second = await gw.mint(device, "laptop");
    gw.apple = appleError(400, "BadDeviceToken");
    expect((await gw.push(device.push_secret)).status).toBe(410);
    expect(gw.calls).toHaveLength(1);

    await spendEverything(device);
    const countersBefore = (await env.DB.prepare("SELECT * FROM counters ORDER BY key").all()).results;
    const rowBefore = await deviceRow(device.device_id);

    // Apple would take the push now. It is not asked.
    gw.apple = () => new Response(null, { status: 200 });
    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    for (let i = 0; i < 5; i++) {
      for (const secret of [device.push_secret, second.push_secret]) {
        const response = await gw.push(secret);
        expect(response.status).toBe(410);
        expect(await response.json()).toEqual({
          error: "unregistered",
          message: "Apple no longer accepts this device's token.",
        });
        expect(response.headers.get("retry-after")).toBeNull();
      }
    }
    expect(log.statements).toHaveLength(10);
    for (const sql of log.statements) expect(sql).toMatch(/^\s*SELECT/);
    expect(log.rowsWritten).toBe(0);
    expect(log.otherCalls).toBe(0);
    expect(gw.calls).toHaveLength(1);
    expect((await env.DB.prepare("SELECT * FROM counters ORDER BY key").all()).results).toEqual(countersBefore);
    expect(await deviceRow(device.device_id)).toEqual(rowBefore);

    // On a later day too: the flag is not a daily count.
    gw.now = T0 + 3 * DAY;
    expect((await gw.push(device.push_secret)).status).toBe(410);
  });

  it("is marked also when the token's cap was reached while Apple answered", async () => {
    const device = await gw.register();
    gw.apple = async () => {
      // Another push of the same token takes the last place while this one is with Apple.
      await env.DB.prepare("UPDATE devices SET push_count = ?1").bind(LIMITS.pushPerTokenPerDay.max).run();
      return appleError(410, "Unregistered")();
    };
    expect((await gw.push(device.push_secret)).status).toBe(410);
    expect((await deviceRow(device.device_id)).dead).toBe(1);
  });

  it("is not marked by any other answer of Apple's", async () => {
    const device = await gw.register();
    for (const [status, reason] of [
      [400, "BadCollapseId"],
      [403, "ExpiredProviderToken"],
      [429, "TooManyRequests"],
      [500, "InternalServerError"],
    ] as const) {
      gw.apple = appleError(status, reason);
      expect((await gw.push(device.push_secret)).status).toBe(502);
    }
    gw.apple = () => {
      throw new TypeError("Network connection lost.");
    };
    expect((await gw.push(device.push_secret)).status).toBe(502);
    expect(await deviceRow(device.device_id)).toMatchObject({ dead: 0, push_count: 5 });
  });

  it("marks only the device that pushed, and each device of the token on its own push", async () => {
    const first = await gw.register(TOKEN);
    const second = await gw.register(TOKEN);
    gw.apple = appleError(410, "Unregistered");
    expect((await gw.push(first.push_secret)).status).toBe(410);
    expect((await deviceRow(second.device_id)).dead).toBe(0);
    expect((await gw.push(second.push_secret)).status).toBe(410);
    expect((await deviceRow(second.device_id)).dead).toBe(1);
    expect(gw.calls).toHaveLength(2);
  });

  it("leaves the device to its owner: it can be read, managed and deleted", async () => {
    const device = await gw.register();
    gw.apple = appleError(410, "Unregistered");
    expect((await gw.push(device.push_secret)).status).toBe(410);
    gw.apple = () => new Response(null, { status: 200 });

    const path = `/v1/devices/${device.device_id}`;
    const shown = await gw.request("GET", path, { auth: device.owner_key });
    expect(shown.status).toBe(200);
    expect(await shown.json()).toMatchObject({ environment: "sandbox", secrets: [{ secret_id: device.secret_id }] });

    const minted = await gw.mint(device, "laptop");
    expect((await gw.push(minted.push_secret)).status).toBe(410);
    expect((await gw.request("DELETE", `${path}/secrets/${minted.secret_id}`, { auth: device.owner_key })).status).toBe(204);
    expect((await deviceRow(device.device_id)).dead).toBe(1);

    expect((await gw.request("DELETE", path, { auth: device.owner_key })).status).toBe(204);
    expect(await deviceRows()).toEqual([]);
    expect(await secretRows()).toEqual([]);
    expect((await gw.push(device.push_secret)).status).toBe(401);
  });

  it("is live again after a token change, with the secrets it had", async () => {
    const device = await gw.register();
    gw.apple = appleError(410, "Unregistered");
    expect((await gw.push(device.push_secret)).status).toBe(410);
    gw.apple = () => new Response(null, { status: 200 });
    expect((await gw.push(device.push_secret)).status).toBe(410);

    gw.now = T0 + 60;
    expect((await changeToken(device, PRODUCTION_TOKEN)).status).toBe(200);
    expect(await deviceRow(device.device_id)).toMatchObject({
      dead: 0,
      apns_token: PRODUCTION_TOKEN.toLowerCase(),
      token_hash: await sha256Hex(PRODUCTION_TOKEN.toLowerCase()),
      updated_at: T0 + 60,
    });
    const response = await gw.push(device.push_secret);
    expect(response.status).toBe(200);
    expect(gw.calls.at(-1)?.url).toContain(PRODUCTION_TOKEN.toLowerCase());
    expect(gw.calls).toHaveLength(2);
  });

  it("can be deleted by its owner when every budget but the one for deletes is spent", async () => {
    const device = await gw.register();
    gw.apple = appleError(410, "Unregistered");
    expect((await gw.push(device.push_secret)).status).toBe(410);
    await spendEverything(device);
    await env.DB.prepare("DELETE FROM counters WHERE key IN (?1, ?2)")
      .bind(counterKey.deletes(), counterKey.manageFrom(await sha256Hex("203.0.113.7")))
      .run();
    // The device's own count is at its cap, and deleting the device does not look at it.
    expect((await gw.request("DELETE", `/v1/devices/${device.device_id}`, { auth: device.owner_key })).status).toBe(204);
    expect(await deviceRows()).toEqual([]);
  });

  it("goes with its secrets at the next purge, and live devices stay", async () => {
    const dead = await gw.register();
    await gw.mint(dead, "laptop");
    const live = await gw.register(SANDBOX_TOKEN.replace("ab", "ba"));
    gw.apple = appleError(410, "Unregistered");
    expect((await gw.push(dead.push_secret)).status).toBe(410);
    gw.apple = () => new Response(null, { status: 200 });

    // The same day: far from idle, and gone all the same.
    expect(IDLE_SECONDS).toBeGreaterThan(DAY);
    expect((await purge(env.DB, T0 + 3600)).devices).toBe(1);
    expect(await deviceRows()).toMatchObject([{ device_id: live.device_id, dead: 0 }]);
    expect(await secretRows()).toMatchObject([{ secret_id: live.secret_id }]);

    gw.now = T0 + 3600;
    expect((await gw.push(dead.push_secret)).status).toBe(401);
    expect((await gw.request("GET", `/v1/devices/${dead.device_id}`, { auth: dead.owner_key })).status).toBe(401);
    expect((await gw.push(live.push_secret)).status).toBe(200);
  });

  it("is kept by the purge once a token change made it live again", async () => {
    const device = await gw.register();
    gw.apple = appleError(410, "Unregistered");
    expect((await gw.push(device.push_secret)).status).toBe(410);
    expect((await changeToken(device, PRODUCTION_TOKEN)).status).toBe(200);
    expect((await purge(env.DB, T0 + 3600)).devices).toBe(0);
    expect(await deviceRows()).toHaveLength(1);
  });
});
