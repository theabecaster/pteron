import { createScheduledController, env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { handleScheduled } from "../src/index";
import { IDLE_SECONDS, PURGE_COUNTERS_PER_RUN, PURGE_DEVICES_PER_RUN } from "../src/limits";
import { purge } from "../src/purge";
import { Gateway, T0, counter, deviceRows, reset, secretRows, seedCounter, testEnv } from "./helpers";

let gw: Gateway;
let logged: string[];
beforeEach(async () => {
  await reset();
  gw = new Gateway();
  logged = [];
  vi.spyOn(console, "log").mockImplementation((...args: unknown[]) => {
    logged.push(args.map(String).join(" "));
  });
});
afterEach(() => {
  vi.restoreAllMocks();
});

const DAY = 86400;

describe("the daily purge", () => {
  it("is 180 days, and bounded", () => {
    expect(IDLE_SECONDS).toBe(180 * DAY);
    expect(PURGE_DEVICES_PER_RUN).toBeLessThanOrEqual(200);
    expect(PURGE_COUNTERS_PER_RUN).toBeLessThanOrEqual(500);
  });

  it("deletes a device idle for 180 days with all its secrets, and keeps a recent one", async () => {
    const old = await gw.registerDevice();
    const oldSecrets = [await gw.mint(old, "studio"), await gw.mint(old, "laptop")];
    const neverPaired = await gw.registerDevice();

    gw.now = T0 + 30 * DAY;
    const recent = await gw.register();

    // One second short of 180 days after the old ones: nothing goes yet.
    expect(await purge(env.DB, T0 + IDLE_SECONDS)).toEqual({ devices: 0, counters: expect.any(Number) });
    expect(await deviceRows()).toHaveLength(3);

    const result = await purge(env.DB, T0 + IDLE_SECONDS + DAY);
    expect(result.devices).toBe(2);
    expect(await deviceRows()).toMatchObject([{ device_id: recent.device_id }]);
    expect(await secretRows()).toMatchObject([{ secret_id: recent.secret_id }]);

    gw.now = T0 + IDLE_SECONDS + DAY;
    for (const secret of oldSecrets) expect((await gw.push(secret.push_secret)).status).toBe(401);
    for (const device of [old, neverPaired]) {
      expect((await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key })).status).toBe(401);
    }
    expect((await gw.push(recent.push_secret)).status).toBe(200);
  });

  it("keeps an old device that is still pushed to, through any one of its secrets", async () => {
    const device = await gw.register();
    const quiet = await gw.mint(device, "laptop");
    gw.now = T0 + 100 * DAY;
    expect((await gw.push(device.push_secret)).status).toBe(200);

    expect((await purge(env.DB, T0 + 250 * DAY)).devices).toBe(0);
    expect(await secretRows()).toHaveLength(2);
    // 180 days after that last push it goes, with the secret that never pushed.
    expect((await purge(env.DB, T0 + 282 * DAY)).devices).toBe(1);
    expect(await deviceRows()).toEqual([]);
    expect(await secretRows()).toEqual([]);
    gw.now = T0 + 282 * DAY;
    expect((await gw.push(quiet.push_secret)).status).toBe(401);
  });

  it("keeps an old device whose token was updated or that paired a helper lately", async () => {
    const updated = await gw.registerDevice();
    const paired = await gw.registerDevice();
    gw.now = T0 + 100 * DAY;
    await gw.request("PUT", `/v1/devices/${updated.device_id}`, {
      auth: updated.owner_key,
      body: { apns_token: "12".repeat(32), environment: "sandbox" },
    });
    await gw.mint(paired, "new laptop");

    expect((await purge(env.DB, T0 + 250 * DAY)).devices).toBe(0);
    expect(await deviceRows()).toHaveLength(2);
    expect((await purge(env.DB, T0 + 282 * DAY)).devices).toBe(2);
  });

  it("deletes counters whose window has ended and keeps the live ones", async () => {
    await seedCounter("old-a", 3, T0 - 100);
    await seedCounter("old-b", 9, T0);
    await seedCounter("live", 5, T0 + 1);
    expect((await purge(env.DB, T0)).counters).toBe(2);
    expect(await counter("old-a")).toBeNull();
    expect(await counter("old-b")).toBeNull();
    expect(await counter("live")).toEqual({ count: 5, expires_at: T0 + 1 });
  });

  it("does a bounded amount of work per run and finishes on the next ones", async () => {
    const devices = PURGE_DEVICES_PER_RUN + 5;
    const counters = PURGE_COUNTERS_PER_RUN + 5;
    const insertDevice = env.DB.prepare(
      `INSERT INTO devices (device_id, owner_hash, apns_token, environment, created_at, updated_at, push_day, manage_day)
       VALUES (?1, 'h', 't', 'sandbox', ?2, ?2, ?3, ?3)`,
    );
    const insertSecret = env.DB.prepare(
      `INSERT INTO secrets (secret_hash, device_id, secret_id, label, created_at)
       VALUES (?1, ?2, ?1, 'l', ?3)`,
    );
    const insertCounter = env.DB.prepare("INSERT INTO counters (key, count, expires_at) VALUES (?1, 1, ?2)");
    const statements: D1PreparedStatement[] = [];
    for (let i = 0; i < devices; i++) {
      statements.push(insertDevice.bind(`d${i}`, T0, T0 / DAY), insertSecret.bind(`s${i}`, `d${i}`, T0));
    }
    for (let i = 0; i < counters; i++) statements.push(insertCounter.bind(`c${i}`, T0));
    await env.DB.batch(statements);

    const now = T0 + 200 * DAY;
    expect(await purge(env.DB, now)).toEqual({ devices: PURGE_DEVICES_PER_RUN, counters: PURGE_COUNTERS_PER_RUN });
    expect(await deviceRows()).toHaveLength(5);
    expect(await secretRows()).toHaveLength(5);
    expect(await purge(env.DB, now)).toEqual({ devices: 5, counters: 5 });
    expect(await purge(env.DB, now)).toEqual({ devices: 0, counters: 0 });
    expect(await secretRows()).toEqual([]);
  });

  it("runs from the Worker's scheduled handler", async () => {
    const stale = await gw.register();
    await seedCounter("old", 1, T0 - 1);
    await handleScheduled(testEnv, T0 + 181 * DAY);
    expect(await deviceRows()).toEqual([]);
    expect(await secretRows()).toEqual([]);
    expect(await counter("old")).toBeNull();
    expect(stale.device_id).not.toBe("");

    // The exported handler uses the real clock, by which a device registered just now is new.
    const realNow = Math.floor(Date.now() / 1000);
    gw.now = realNow;
    const fresh = await gw.register();
    await seedCounter("ended", 1, realNow - 10);
    await worker.scheduled(createScheduledController({ cron: "17 3 * * *" }), testEnv);
    expect(await deviceRows()).toMatchObject([{ device_id: fresh.device_id }]);
    expect(await counter("ended")).toBeNull();
  });

  it("logs a failure by name only and lets Cloudflare see it", async () => {
    const failing = {
      prepare: () => {
        throw new TypeError("near 'a value from the database': syntax error");
      },
    } as unknown as D1Database;
    await expect(handleScheduled({ ...testEnv, DB: failing }, T0)).rejects.toThrow(TypeError);
    expect(logged).toEqual([JSON.stringify({ task: "purge", failed: "TypeError" })]);
  });
});
