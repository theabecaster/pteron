import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { addressKey } from "../src/address";
import { sha256Hex } from "../src/encoding";
import {
  LIMITS,
  MAX_DEVICES_PER_TOKEN,
  MAX_SECRETS_PER_DEVICE,
  ROWS,
  WORST_DAY_ROWS,
  allowedBy,
  counterKey,
  hit,
  utcDay,
  windowEnd,
} from "../src/limits";
import wranglerToml from "../wrangler.toml?raw";
import {
  FakeLimiter,
  Gateway,
  PAYLOAD,
  PRODUCTION_TOKEN,
  type Secret,
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

let gw: Gateway;
beforeEach(async () => {
  await reset();
  gw = new Gateway();
});

const DAY = 86400;

async function expectLimited(response: Response, retryAfter: number): Promise<void> {
  expect(response.status).toBe(429);
  expect(response.headers.get("retry-after")).toBe(String(retryAfter));
  expect((await errorOf(response)).error).toBe("rate_limited");
}

const TODAY = T0 / DAY;

/** `[push_day, push_count]` of one device. */
async function pushCount(deviceId: string): Promise<[number, number] | null> {
  const row = await env.DB.prepare("SELECT push_day, push_count FROM devices WHERE device_id = ?1")
    .bind(deviceId)
    .first<{ push_day: number; push_count: number }>();
  return row ? [row.push_day, row.push_count] : null;
}

/** `[manage_day, manage_count]` of one device. */
async function manageCount(deviceId: string): Promise<[number, number] | null> {
  const row = await env.DB.prepare("SELECT manage_day, manage_count FROM devices WHERE device_id = ?1")
    .bind(deviceId)
    .first<{ manage_day: number; manage_count: number }>();
  return row ? [row.manage_day, row.manage_count] : null;
}

const TOKEN_CHANGE = { apns_token: PRODUCTION_TOKEN, environment: "production" };

describe("the limits", () => {
  it("are the contract's", () => {
    expect(LIMITS).toEqual({
      addressPerMinute: { max: 120, windowSeconds: 60 },
      secretPerMinute: { max: 30, windowSeconds: 60 },
      allPerMinute: { max: 3000, windowSeconds: 60 },
      registerPerAddressPerHour: { max: 10, windowSeconds: 3600 },
      registerPerAddressPerDay: { max: 20, windowSeconds: DAY },
      registerPerWideAddressPerHour: { max: 30, windowSeconds: 3600 },
      registerPerWideAddressPerDay: { max: 60, windowSeconds: DAY },
      registerPerDay: { max: 1000, windowSeconds: DAY },
      managePerDevicePerDay: { max: 60, windowSeconds: DAY },
      managePerAddressPerDay: { max: 120, windowSeconds: DAY },
      managePerWideAddressPerDay: { max: 240, windowSeconds: DAY },
      managePerDay: { max: 1000, windowSeconds: DAY },
      deletesPerDay: { max: 600, windowSeconds: DAY },
      pushPerTokenPerDay: { max: 1500, windowSeconds: DAY },
      pushPerDay: { max: 30000, windowSeconds: DAY },
    });
    expect(MAX_SECRETS_PER_DEVICE).toBe(10);
    expect(MAX_DEVICES_PER_TOKEN).toBe(3);
  });

  it("fit the daily budget of 100,000 rows written to D1, by the arithmetic in src/limits.ts", () => {
    expect(ROWS).toEqual({ push: 2, registration: 7, manage: 7, delete: 23, purge: 4900 });
    expect(WORST_DAY_ROWS).toBe(60_000 + 7_000 + 7_000 + 13_800 + 4_900);
    expect(WORST_DAY_ROWS).toBe(92_700);
    expect(WORST_DAY_ROWS).toBeLessThan(100_000);
  });

  it("give one token, one device and one address a fixed share of the global budgets", () => {
    expect(LIMITS.pushPerTokenPerDay.max / LIMITS.pushPerDay.max).toBe(0.05);
    expect(LIMITS.registerPerAddressPerDay.max / LIMITS.registerPerDay.max).toBe(0.02);
    expect(LIMITS.registerPerWideAddressPerDay.max / LIMITS.registerPerDay.max).toBe(0.06);
    expect(LIMITS.managePerDevicePerDay.max / LIMITS.managePerDay.max).toBe(0.06);
    expect(LIMITS.managePerAddressPerDay.max / LIMITS.managePerDay.max).toBe(0.12);
    expect(LIMITS.managePerWideAddressPerDay.max / LIMITS.managePerDay.max).toBe(0.24);
    expect(LIMITS.managePerDevicePerDay.max / LIMITS.deletesPerDay.max).toBe(0.1);
  });

  it("give a /48 more than a /64, in every window", () => {
    expect(LIMITS.registerPerWideAddressPerHour.max).toBeGreaterThan(LIMITS.registerPerAddressPerHour.max);
    expect(LIMITS.registerPerWideAddressPerDay.max).toBeGreaterThan(LIMITS.registerPerAddressPerDay.max);
    expect(LIMITS.managePerWideAddressPerDay.max).toBeGreaterThan(LIMITS.managePerAddressPerDay.max);
  });

  it("match the Rate Limiting bindings in wrangler.toml", () => {
    const bindings = [...wranglerToml.matchAll(/name = "(RL_\w+)"\s+namespace_id = "(\d+)"\s+\[ratelimits\.simple\]\s+limit = (\d+)\s+period = (\d+)/g)];
    expect(bindings.map((m) => [m[1], Number(m[3]), Number(m[4])])).toEqual([
      ["RL_ADDRESS", LIMITS.addressPerMinute.max, LIMITS.addressPerMinute.windowSeconds],
      ["RL_SECRET", LIMITS.secretPerMinute.max, LIMITS.secretPerMinute.windowSeconds],
      ["RL_GLOBAL", LIMITS.allPerMinute.max, LIMITS.allPerMinute.windowSeconds],
    ]);
    // Bindings that share a namespace share their counters.
    expect(new Set(bindings.map((m) => m[2])).size).toBe(3);
    expect(wranglerToml).toMatch(/\[triggers\]\s+crons = \["17 3 \* \* \*"\]/);
  });
});

describe("hit", () => {
  const limit = { max: 3, windowSeconds: 60 };

  it("allows up to the limit in a window, then refuses with the time to the window's end", async () => {
    for (let i = 0; i < 3; i++) expect(await hit(env.DB, "k", limit, T0 + i)).toEqual({ allowed: true });
    expect(await hit(env.DB, "k", limit, T0 + 10)).toEqual({ allowed: false, retryAfter: 50 });
    expect(await hit(env.DB, "k", limit, T0 + 59)).toEqual({ allowed: false, retryAfter: 1 });
    // A refusal writes nothing.
    expect(await counter("k")).toEqual({ count: 3, expires_at: T0 + 60 });
  });

  it("starts again in the next window, reusing the row", async () => {
    for (let i = 0; i < 4; i++) await hit(env.DB, "k", limit, T0);
    expect(await hit(env.DB, "k", limit, T0 + 60)).toEqual({ allowed: true });
    expect(await counter("k")).toEqual({ count: 1, expires_at: T0 + 120 });
    const rows = await env.DB.prepare("SELECT COUNT(*) AS n FROM counters").first<{ n: number }>();
    expect(rows?.n).toBe(1);
  });

  it("keeps keys apart", async () => {
    for (let i = 0; i < 3; i++) await hit(env.DB, "a", limit, T0);
    expect((await hit(env.DB, "a", limit, T0)).allowed).toBe(false);
    expect((await hit(env.DB, "b", limit, T0)).allowed).toBe(true);
  });

  it("aligns day windows to the UTC day", () => {
    expect(windowEnd(LIMITS.pushPerDay, T0)).toBe(T0 + DAY);
    expect(windowEnd(LIMITS.pushPerDay, T0 + DAY - 1)).toBe(T0 + DAY);
    expect(windowEnd(LIMITS.pushPerDay, T0 - 1)).toBe(T0);
    expect(utcDay(T0 - 1)).toBe(utcDay(T0) - 1);
    expect(utcDay(T0 + DAY - 1)).toBe(utcDay(T0));
  });
});

describe("the Rate Limiting bindings", () => {
  let address: FakeLimiter;
  let secret: FakeLimiter;
  let all: FakeLimiter;
  beforeEach(() => {
    address = new FakeLimiter();
    secret = new FakeLimiter();
    all = new FakeLimiter();
  });
  const withLimiters = (): void => {
    gw.env = { ...testEnv, RL_ADDRESS: address, RL_SECRET: secret, RL_GLOBAL: all };
  };

  it("are asked on every request, with hashes as keys, and let an allowed request through", async () => {
    const device = await gw.register();
    withLimiters();
    const statuses = [
      (await gw.request("GET", "/v1/health")).status,
      (await gw.request("GET", "/nope")).status,
      (await gw.request("PATCH", "/v1/push")).status,
      (await gw.request("POST", "/v1/push", { auth: "nope" })).status,
      (await gw.request("POST", "/v1/devices", { raw: "{" })).status,
      (await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key })).status,
      (await gw.push(device.push_secret)).status,
    ];
    expect(statuses).toEqual([200, 404, 405, 401, 400, 200, 200]);

    const addressHash = await sha256Hex("203.0.113.7");
    expect(address.keys).toEqual(new Array(7).fill(addressHash));
    expect(all.keys).toEqual(new Array(7).fill("all"));
    // Only a well-formed push reaches the per-secret limiter.
    expect(secret.keys).toEqual([await sha256Hex(device.push_secret)]);
    const keys = [...address.keys, ...all.keys, ...secret.keys].join();
    expect(keys).not.toContain(device.push_secret);
    expect(keys).not.toContain("203.0.113.7");
  });

  it("answer 429 with Retry-After for an address over its limit, on any route, without D1 or the shared brake", async () => {
    const device = await gw.register();
    const { db, log } = spyOnDb(env.DB);
    withLimiters();
    gw.env = { ...gw.env, DB: db };
    const noisy = await sha256Hex("198.51.100.9");
    address.refuse = (key) => key === noisy;

    const attempts: [string, string, Parameters<Gateway["request"]>[2]][] = [
      ["GET", "/v1/health", {}],
      ["GET", "/nope", {}],
      ["POST", "/v1/devices", { body: { apns_token: PRODUCTION_TOKEN, environment: "production" } }],
      ["POST", "/v1/push", { auth: device.push_secret, body: { payload: PAYLOAD } }],
      ["DELETE", `/v1/devices/${device.device_id}`, { auth: device.owner_key }],
    ];
    for (const [method, path, options] of attempts) {
      await expectLimited(await gw.request(method, path, { ...options, ip: "198.51.100.9" }), 60);
    }
    expect(log.statements).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(all.keys).toEqual([]);
    expect(secret.keys).toEqual([]);
    expect(gw.calls).toHaveLength(0);

    // Another address is not affected.
    expect((await gw.push(device.push_secret)).status).toBe(200);
    expect(await deviceRows()).toHaveLength(1);
  });

  it("answer 429 with Retry-After when the global brake is on, without D1", async () => {
    const device = await gw.register();
    const { db, log } = spyOnDb(env.DB);
    withLimiters();
    gw.env = { ...gw.env, DB: db };
    all.refuse = () => true;
    await expectLimited(await gw.push(device.push_secret), 60);
    await expectLimited(await gw.request("GET", "/v1/health"), 60);
    await expectLimited(await gw.request("POST", "/v1/devices", { body: {} }), 60);
    expect(log.statements).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(gw.calls).toHaveLength(0);
  });

  it("answer 429 with Retry-After for a secret over its limit, without D1, and leave other secrets alone", async () => {
    const device = await gw.register();
    const second = await gw.mint(device, "laptop");
    const { db, log } = spyOnDb(env.DB);
    withLimiters();
    gw.env = { ...gw.env, DB: db };
    const noisy = await sha256Hex(device.push_secret);
    secret.refuse = (key) => key === noisy;

    for (let i = 0; i < 3; i++) await expectLimited(await gw.push(device.push_secret), 60);
    expect(log.statements).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(gw.calls).toHaveLength(0);

    expect((await gw.push(second.push_secret)).status).toBe(200);
    expect(gw.calls).toHaveLength(1);
    // A push the limiter refused took nothing from the daily caps.
    expect(await pushCount(device.device_id)).toEqual([TODAY, 1]);
    expect((await counter(counterKey.sends()))?.count).toBe(1);
  });

  it("do not count a push the gateway rejects before it looks the secret up", async () => {
    const device = await gw.register();
    withLimiters();
    await gw.request("POST", "/v1/push", { auth: "malformed", body: { payload: PAYLOAD } });
    await gw.request("POST", "/v1/push", { auth: device.push_secret, raw: "{nope" });
    await gw.push(device.push_secret, { payload: PAYLOAD, push_type: "voip" });
    expect(secret.keys).toEqual([]);
  });

  it("key IPv6 clients by their /64 and IPv4 clients by their address", async () => {
    withLimiters();
    const ips = [
      "2001:db8:1:2:aaaa:bbbb:cccc:dddd",
      "2001:db8:1:2::1",
      "2001:0DB8:0001:0002:ffff:ffff:ffff:ffff",
      "2001:db8:1:3::1",
      "::ffff:203.0.113.7",
      "203.0.113.7",
      "203.0.113.8",
    ];
    for (const ip of ips) await gw.request("GET", "/v1/health", { ip });
    const [a, b, c, next, mapped, v4, otherV4] = address.keys;
    expect(a).toBe(await sha256Hex("2001:db8:1:2::/64"));
    expect(b).toBe(a);
    expect(c).toBe(a);
    expect(next).not.toBe(a);
    expect(mapped).toBe(v4);
    expect(otherV4).not.toBe(v4);
    for (const key of address.keys) expect(key).toMatch(/^[0-9a-f]{64}$/);

    // One refusal for the /64 stops every address in it.
    address.refuse = (key) => key === a;
    await expectLimited(await gw.request("GET", "/v1/health", { ip: "2001:db8:1:2:1234::9" }), 60);
    expect((await gw.request("GET", "/v1/health", { ip: "2001:db8:1:3::9" })).status).toBe(200);
  });

  it("put every request without a usable address in one bucket", async () => {
    withLimiters();
    for (const ip of ["garbage", "999.1.1.1", ""]) await gw.request("GET", "/v1/health", { ip });
    expect(new Set(address.keys)).toEqual(new Set([await sha256Hex(addressKey("garbage"))]));
  });

  it("are optional: without them, or with one that fails, requests are allowed", async () => {
    expect(await allowedBy(undefined, "k")).toBe(true);
    const failing: RateLimit = {
      limit: () => Promise.reject(new Error("limiter down")),
    };
    expect(await allowedBy(failing, "k")).toBe(true);

    // `gw.env` has none by default, which is how every other test runs.
    expect([gw.env.RL_ADDRESS, gw.env.RL_SECRET, gw.env.RL_GLOBAL]).toEqual([undefined, undefined, undefined]);
    const device = await gw.register();
    expect((await gw.push(device.push_secret)).status).toBe(200);

    gw.env = { ...testEnv, RL_ADDRESS: failing, RL_SECRET: failing, RL_GLOBAL: failing };
    expect((await gw.push(device.push_secret)).status).toBe(200);
    expect((await gw.request("GET", "/v1/health")).status).toBe(200);
  });
});

describe("registration caps", () => {
  let next = 1000;
  /** A registration with a token of its own, so only the address caps decide. */
  const registerFrom = (ip?: string): Promise<Response> =>
    gw.request("POST", "/v1/devices", {
      body: { apns_token: tokenNumber(next++), environment: "production" },
      ...(ip === undefined ? {} : { ip }),
    });
  const hourly = (key: string): Promise<{ count: number; expires_at: number } | null> =>
    sha256Hex(key).then((hash) => counter(counterKey.register(hash)));
  const daily = (key: string): Promise<{ count: number; expires_at: number } | null> =>
    sha256Hex(key).then((hash) => counter(counterKey.registerDay(hash)));

  it("allow 10 an hour per client address", async () => {
    for (let i = 0; i < 10; i++) expect((await registerFrom()).status).toBe(201);
    gw.now = T0 + 600;
    await expectLimited(await registerFrom(), 3000);
    expect(await deviceRows()).toHaveLength(10);

    // Another address has its own allowance.
    expect((await registerFrom("198.51.100.9")).status).toBe(201);
    gw.now = T0 + 3600;
    expect((await registerFrom()).status).toBe(201);
  });

  it("allow 20 per UTC day per client address", async () => {
    expect(LIMITS.registerPerAddressPerDay.max).toBe(20);
    for (const hour of [0, 1]) {
      gw.now = T0 + hour * 3600;
      for (let i = 0; i < 10; i++) expect((await registerFrom()).status).toBe(201);
    }
    // A new hour has room, the day has none.
    gw.now = T0 + 2 * 3600;
    await expectLimited(await registerFrom(), DAY - 2 * 3600);
    expect(await deviceRows()).toHaveLength(20);
    expect(await daily("203.0.113.7")).toEqual({ count: 20, expires_at: T0 + DAY });
    expect((await hourly("203.0.113.7"))?.count).toBe(10);

    expect((await registerFrom("198.51.100.9")).status).toBe(201);
    gw.now = T0 + DAY;
    expect((await registerFrom()).status).toBe(201);
  });

  it("count an IPv6 client by its /64, per hour and per day", async () => {
    for (let i = 0; i < 10; i++) {
      expect((await registerFrom(`2001:db8:1:2:${i + 1}::${i + 7}`)).status).toBe(201);
    }
    await expectLimited(await registerFrom("2001:db8:1:2:ffff::1"), 3600);
    expect((await registerFrom("2001:db8:1:3::1")).status).toBe(201);
    expect((await hourly("2001:db8:1:2::/64"))?.count).toBe(10);

    gw.now = T0 + 3600;
    for (let i = 0; i < 10; i++) expect((await registerFrom("2001:db8:1:2::1")).status).toBe(201);
    gw.now = T0 + 7200;
    await expectLimited(await registerFrom("2001:db8:1:2::2"), DAY - 7200);
    expect((await daily("2001:db8:1:2::/64"))?.count).toBe(20);
    expect((await registerFrom("2001:db8:1:3::1")).status).toBe(201);
  });

  it("count an IPv6 client by its /48 as well: 30 an hour over all its /64s", async () => {
    expect(LIMITS.registerPerWideAddressPerHour.max).toBe(30);
    // Three /64s of one /48, each within its own ten.
    for (const subnet of ["a", "b", "c"]) {
      for (let i = 0; i < 10; i++) expect((await registerFrom(`2001:db8:1:${subnet}::${i + 1}`)).status).toBe(201);
    }
    expect((await hourly("2001:db8:1::/48"))?.count).toBe(30);

    // A fourth /64 of that /48 has room of its own, and the /48 has none.
    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    gw.now = T0 + 60;
    await expectLimited(await registerFrom("2001:db8:1:d::1"), 3540);
    await expectLimited(await registerFrom("2001:db8:1:ffff:1:2:3:4"), 3540);
    expect(log.statements).toHaveLength(2);
    expect(log.rowsWritten).toBe(0);
    expect(log.otherCalls).toBe(0);
    gw.env = testEnv;
    expect(await hourly("2001:db8:1:d::/64")).toBeNull();
    expect(await deviceRows()).toHaveLength(30);

    // Another /48 is not affected, and neither is an IPv4 client.
    expect((await registerFrom("2001:db8:2:a::1")).status).toBe(201);
    expect((await registerFrom("203.0.113.7")).status).toBe(201);
    expect((await hourly("2001:db8:2::/48"))?.count).toBe(1);
  });

  it("count an IPv6 client by its /48 as well: 60 per UTC day over all its /64s", async () => {
    expect(LIMITS.registerPerWideAddressPerDay.max).toBe(60);
    // Six /64s of one /48 over two hours: every hourly cap and every /64's day has room.
    for (const hour of [0, 1]) {
      gw.now = T0 + hour * 3600;
      for (const subnet of ["a", "b", "c"]) {
        for (let i = 0; i < 10; i++) {
          expect((await registerFrom(`2001:db8:1:${subnet}${hour}::${i + 1}`)).status).toBe(201);
        }
      }
    }
    expect((await daily("2001:db8:1::/48"))?.count).toBe(60);
    expect((await daily("2001:db8:1:a0::/64"))?.count).toBe(10);

    gw.now = T0 + 2 * 3600;
    await expectLimited(await registerFrom("2001:db8:1:a0::1"), DAY - 2 * 3600);
    await expectLimited(await registerFrom("2001:db8:1:eeee::1"), DAY - 2 * 3600);
    expect(await deviceRows()).toHaveLength(60);

    expect((await registerFrom("2001:db8:2:a0::1")).status).toBe(201);
    gw.now = T0 + DAY;
    expect((await registerFrom("2001:db8:1:eeee::1")).status).toBe(201);
  });

  it("do not count requests the gateway rejects, and do not store the address", async () => {
    for (let i = 0; i < 20; i++) {
      await gw.request("POST", "/v1/devices", { body: { apns_token: "bad", environment: "sandbox" } });
    }
    await gw.registerDevice();
    await gw.registerDevice(undefined, "sandbox", "2001:db8:1:2::9");
    const keys = (await env.DB.prepare("SELECT key FROM counters ORDER BY key").all<{ key: string }>()).results.map(
      (r) => r.key,
    );
    const v4 = await sha256Hex("203.0.113.7");
    const v6 = await sha256Hex("2001:db8:1:2::/64");
    const wide = await sha256Hex("2001:db8:1::/48");
    expect(keys).toEqual(
      [
        counterKey.register(v4),
        counterKey.registerDay(v4),
        counterKey.register(v6),
        counterKey.registerDay(v6),
        counterKey.register(wide),
        counterKey.registerDay(wide),
        counterKey.registrations(),
      ].sort(),
    );
    expect(keys.join()).not.toContain("203.0.113.7");
    expect(keys.join()).not.toContain("2001");
    for (const key of keys) expect((await counter(key))?.count).toBe(key === counterKey.registrations() ? 2 : 1);
  });

  it("cap registrations from everyone at 1000 per UTC day, and write nothing past the cap", async () => {
    expect(LIMITS.registerPerDay.max).toBe(1000);
    await seedCounter(counterKey.registrations(), LIMITS.registerPerDay.max - 1, T0 + DAY);
    gw.now = T0 + 7200;
    expect((await registerFrom()).status).toBe(201);

    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    // Addresses that never registered are refused too, and cost reads only.
    for (const ip of ["203.0.113.7", "198.51.100.1", "198.51.100.2", "2001:db8::1"]) {
      await expectLimited(await registerFrom(ip), DAY - 7200);
    }
    expect(log.statements).toHaveLength(4);
    for (const sql of log.statements) expect(sql).toMatch(/^\s*SELECT/);
    expect(log.otherCalls).toBe(0);
    expect(await deviceRows()).toHaveLength(1);
    expect((await counter(counterKey.registrations()))?.count).toBe(LIMITS.registerPerDay.max);
    const counters = await env.DB.prepare("SELECT COUNT(*) AS n FROM counters").first<{ n: number }>();
    expect(counters?.n).toBe(3);

    gw.env = testEnv;
    gw.now = T0 + DAY;
    expect((await registerFrom("198.51.100.1")).status).toBe(201);
  });

  it("write five rows for a registration from an IPv4 client and seven from an IPv6 client", async () => {
    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    expect((await registerFrom()).status).toBe(201);
    expect(log.batchRowsWritten).toEqual([3]);
    expect(log.rowsWritten).toBe(5);
    expect((await registerFrom("2001:db8:1:2::1")).status).toBe(201);
    expect(log.batchRowsWritten).toEqual([3, 5]);
    expect(log.rowsWritten).toBe(5 + ROWS.registration);
    expect(log.statements.filter((sql) => /^\s*INSERT INTO devices/.test(sql))).toHaveLength(2);
  });
});

describe("management caps", () => {
  const mintAt = (device: { device_id: string; owner_key: string }, ip?: string): Promise<Response> =>
    gw.request("POST", `/v1/devices/${device.device_id}/secrets`, {
      auth: device.owner_key,
      body: { label: "laptop" },
      ...(ip === undefined ? {} : { ip }),
    });
  const deleteAt = (device: { device_id: string; owner_key: string }, secretId: string, ip?: string): Promise<Response> =>
    gw.request("DELETE", `/v1/devices/${device.device_id}/secrets/${secretId}`, {
      auth: device.owner_key,
      ...(ip === undefined ? {} : { ip }),
    });

  it("cap a device at 60 management writes per UTC day: a mint and delete loop ends in 429, and other devices still mint", async () => {
    const device = await gw.registerDevice();
    const other = await gw.registerDevice();
    gw.now = T0 + 3600;

    let writes = 0;
    let refused: Response | null = null;
    while (!refused && writes < 200) {
      const minted = await mintAt(device);
      if (minted.status !== 201) {
        refused = minted;
        break;
      }
      writes++;
      const deleted = await deleteAt(device, (await minted.json<Secret>()).secret_id);
      if (deleted.status !== 204) refused = deleted;
      else writes++;
    }
    expect(writes).toBe(LIMITS.managePerDevicePerDay.max);
    expect(writes).toBe(60);
    if (!refused) throw new Error("the loop was never refused");
    await expectLimited(refused, DAY - 3600);

    // Every kind of management write is refused for this device, and nothing more is counted.
    const path = `/v1/devices/${device.device_id}`;
    await expectLimited(await mintAt(device), DAY - 3600);
    await expectLimited(await deleteAt(device, "anything"), DAY - 3600);
    await expectLimited(await gw.request("PUT", path, { auth: device.owner_key, body: TOKEN_CHANGE }), DAY - 3600);
    expect(await manageCount(device.device_id)).toEqual([TODAY, 60]);
    // Thirty mints on the management budget, thirty deletes on the budget for deletes.
    expect((await counter(counterKey.manage()))?.count).toBe(30);
    expect((await counter(counterKey.deletes()))?.count).toBe(30);
    // Reading it still works.
    expect((await gw.request("GET", path, { auth: device.owner_key })).status).toBe(200);

    // Another device, from the same address, has its own allowance.
    const secret = await gw.mint(other);
    expect((await gw.push(secret.push_secret)).status).toBe(200);
    expect(await manageCount(other.device_id)).toEqual([TODAY, 1]);

    gw.now = T0 + DAY;
    expect((await mintAt(device)).status).toBe(201);
    expect(await manageCount(device.device_id)).toEqual([TODAY + 1, 1]);
  });

  it("lets a device at its cap delete itself, which turns its secrets off", async () => {
    const device = await gw.register();
    const secret = await gw.mint(device);
    await env.DB.prepare("UPDATE devices SET manage_count = ?1 WHERE device_id = ?2")
      .bind(LIMITS.managePerDevicePerDay.max, device.device_id)
      .run();
    const path = `/v1/devices/${device.device_id}`;
    expect((await gw.request("DELETE", path, { auth: device.owner_key })).status).toBe(204);
    expect((await gw.push(secret.push_secret)).status).toBe(401);
    expect((await gw.request("GET", path, { auth: device.owner_key })).status).toBe(401);
  });

  it("count every kind of management write on the device, mints and token changes on the address, and deletes on their own budget", async () => {
    const device = await gw.registerDevice();
    const address = counterKey.manageFrom(await sha256Hex("203.0.113.7"));
    const path = `/v1/devices/${device.device_id}`;
    /** The device's count, the address's, the management budget's and the budget for deletes. */
    const counts = async (): Promise<(number | undefined)[]> => [
      (await manageCount(device.device_id))?.[1],
      (await counter(address))?.count,
      (await counter(counterKey.manage()))?.count,
      (await counter(counterKey.deletes()))?.count,
    ];

    const secret = await gw.mint(device);
    expect(await counts()).toEqual([1, 1, 1, undefined]);
    expect((await gw.request("PUT", path, { auth: device.owner_key, body: TOKEN_CHANGE })).status).toBe(200);
    expect(await counts()).toEqual([2, 2, 2, undefined]);
    expect((await deleteAt(device, secret.secret_id)).status).toBe(204);
    // A delete counts on the device and on the budget for deletes, not on the address.
    expect(await counts()).toEqual([3, 2, 2, 1]);
    // Deleting a secret that is already gone is a delete like any other.
    expect((await deleteAt(device, secret.secret_id)).status).toBe(204);
    expect(await counts()).toEqual([4, 2, 2, 2]);
    // Reading is not a management write.
    expect((await gw.request("GET", path, { auth: device.owner_key })).status).toBe(200);
    expect(await counts()).toEqual([4, 2, 2, 2]);

    expect((await gw.request("DELETE", path, { auth: device.owner_key })).status).toBe(204);
    expect(await counts()).toEqual([undefined, 2, 2, 3]);
    expect((await counter(address))?.expires_at).toBe(T0 + DAY);
    expect((await counter(counterKey.deletes()))?.expires_at).toBe(T0 + DAY);
  });

  it("cap a client address at 120 mints and token changes per UTC day, an IPv6 client by its /64, and leave its deletes alone", async () => {
    const devices = [];
    for (let i = 0; i < 6; i++) devices.push(await gw.registerDevice());
    const spare = await gw.registerDevice();
    gw.now = T0 + 600;
    // Forty writes for each device, under its own cap, from 240 addresses of one /64. The
    // twenty mints of each count for the /64; the deletes do not.
    let n = 0;
    for (const device of devices) {
      for (let i = 0; i < 20; i++) {
        const minted = await mintAt(device, `2001:db8:1:2:${(++n).toString(16)}::1`);
        expect(minted.status).toBe(201);
        const deleted = await deleteAt(device, (await minted.json<Secret>()).secret_id, `2001:db8:1:2::${(++n).toString(16)}`);
        expect(deleted.status).toBe(204);
      }
    }
    expect(n).toBe(2 * LIMITS.managePerAddressPerDay.max);
    const key = counterKey.manageFrom(await sha256Hex("2001:db8:1:2::/64"));
    expect((await counter(key))?.count).toBe(120);

    // The /64 is spent for every address in it and every device, also one that wrote nothing today.
    await expectLimited(await mintAt(spare, "2001:db8:1:2:ffff:ffff:ffff:ffff"), DAY - 600);
    await expectLimited(await mintAt(devices[0] ?? spare, "2001:0DB8:0001:0002::9"), DAY - 600);
    await expectLimited(
      await gw.request("PUT", `/v1/devices/${spare.device_id}`, { auth: spare.owner_key, body: TOKEN_CHANGE, ip: "2001:db8:1:2::1" }),
      DAY - 600,
    );
    expect((await counter(key))?.count).toBe(120);
    expect(await manageCount(spare.device_id)).toEqual([TODAY, 0]);
    expect((await counter(counterKey.manage()))?.count).toBe(120);
    expect((await counter(counterKey.deletes()))?.count).toBe(120);
    // A delete from the spent /64 goes through: a phone there can still turn a helper or
    // itself off.
    const last = devices[5] ?? spare;
    expect((await deleteAt(last, "anything", "2001:db8:1:2::1")).status).toBe(204);
    expect(
      (await gw.request("DELETE", `/v1/devices/${last.device_id}`, { auth: last.owner_key, ip: "2001:db8:1:2::1" })).status,
    ).toBe(204);
    expect((await counter(key))?.count).toBe(120);
    expect((await counter(counterKey.deletes()))?.count).toBe(122);
    // The /48 counted the same writes and has room left.
    expect((await counter(counterKey.manageFrom(await sha256Hex("2001:db8:1::/48"))))?.count).toBe(120);

    // The next /64 and an IPv4 address have their own.
    expect((await mintAt(spare, "2001:db8:1:3::1")).status).toBe(201);
    expect((await mintAt(spare)).status).toBe(201);
    // The stored key is a hash, not the address.
    const keys = (await env.DB.prepare("SELECT key FROM counters").all<{ key: string }>()).results.map((r) => r.key);
    expect(keys.join()).not.toContain("2001");

    gw.now = T0 + DAY;
    expect((await mintAt(spare, "2001:db8:1:2::1")).status).toBe(201);
  });

  it("cap an IPv6 /48 at 240 management writes per UTC day, over all its /64s", async () => {
    expect(LIMITS.managePerWideAddressPerDay.max).toBe(240);
    const device = await gw.registerDevice();
    const wide = counterKey.manageFrom(await sha256Hex("2001:db8:1::/48"));
    const narrow = async (subnet: string): Promise<number | undefined> =>
      (await counter(counterKey.manageFrom(await sha256Hex(`2001:db8:1:${subnet}::/64`))))?.count;
    // The /48 has two writes left. Its /64s have written far less than their own 120.
    await seedCounter(wide, LIMITS.managePerWideAddressPerDay.max - 2, T0 + DAY);
    gw.now = T0 + 600;

    expect((await mintAt(device, "2001:db8:1:a::1")).status).toBe(201);
    const minted = await mintAt(device, "2001:db8:1:b::1");
    expect(minted.status).toBe(201);
    expect((await counter(wide))?.count).toBe(240);
    expect([await narrow("a"), await narrow("b")]).toEqual([1, 1]);

    // Two /64s spent what the /48 had: every /64 of it is refused a mint or a token change
    // now, and nothing is counted.
    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    const path = `/v1/devices/${device.device_id}`;
    await expectLimited(await mintAt(device, "2001:db8:1:a::2"), DAY - 600);
    await expectLimited(await mintAt(device, "2001:db8:1:c::1"), DAY - 600);
    await expectLimited(
      await gw.request("PUT", path, { auth: device.owner_key, body: TOKEN_CHANGE, ip: "2001:db8:1:d::1" }),
      DAY - 600,
    );
    expect(log.statements).toHaveLength(3);
    expect(log.rowsWritten).toBe(0);
    expect(log.otherCalls).toBe(0);
    gw.env = testEnv;
    // Deletes are not held back by the /48, and count on no address.
    expect((await deleteAt(device, (await minted.json<Secret>()).secret_id, "2001:db8:1:c::1")).status).toBe(204);
    expect((await counter(wide))?.count).toBe(240);
    expect(await narrow("c")).toBeUndefined();
    expect(await manageCount(device.device_id)).toEqual([TODAY, 3]);

    // Another /48 and an IPv4 client are not affected.
    expect((await mintAt(device, "2001:db8:2:a::1")).status).toBe(201);
    expect((await mintAt(device)).status).toBe(201);
    expect((await counter(counterKey.manageFrom(await sha256Hex("2001:db8:2::/48"))))?.count).toBe(1);

    gw.now = T0 + DAY;
    expect((await mintAt(device, "2001:db8:1:c::1")).status).toBe(201);
  });

  it("cap mints and token changes from everyone at 1000 per UTC day, and write nothing past the cap", async () => {
    expect(LIMITS.managePerDay.max).toBe(1000);
    const device = await gw.register();
    const other = await gw.register(undefined, "sandbox", "198.51.100.20");
    await env.DB.prepare("UPDATE counters SET count = ?2 WHERE key = ?1")
      .bind(counterKey.manage(), LIMITS.managePerDay.max - 1)
      .run();

    gw.now = T0 + 3600;
    const path = `/v1/devices/${device.device_id}`;
    expect((await gw.request("PUT", path, { auth: device.owner_key, body: TOKEN_CHANGE })).status).toBe(200);

    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    // Devices and addresses with room of their own are refused too, and cost reads only.
    await expectLimited(await gw.request("PUT", path, { auth: device.owner_key, body: TOKEN_CHANGE }), DAY - 3600);
    await expectLimited(await mintAt(device), DAY - 3600);
    await expectLimited(await mintAt(other, "198.51.100.21"), DAY - 3600);
    await expectLimited(await mintAt(other, "2001:db8::1"), DAY - 3600);
    expect(log.statements).toHaveLength(4);
    for (const sql of log.statements) expect(sql).toMatch(/^\s*SELECT/);
    expect(log.otherCalls).toBe(0);
    expect(log.rowsWritten).toBe(0);
    gw.env = testEnv;
    expect(await secretRows()).toHaveLength(2);
    expect((await counter(counterKey.manage()))?.count).toBe(LIMITS.managePerDay.max);

    gw.now = T0 + DAY;
    expect((await mintAt(device)).status).toBe(201);
    expect((await counter(counterKey.manage()))?.count).toBe(1);
  });

  it("let a phone delete a secret and itself on a day when the management budget is spent", async () => {
    const device = await gw.register();
    const laptop = await gw.mint(device, "laptop");
    const other = await gw.register(undefined, "sandbox", "2001:db8:7:1::1");
    await env.DB.prepare("UPDATE counters SET count = ?2 WHERE key = ?1")
      .bind(counterKey.manage(), LIMITS.managePerDay.max)
      .run();
    gw.now = T0 + 3600;
    const path = `/v1/devices/${device.device_id}`;

    // Nothing that adds or changes goes through.
    await expectLimited(await mintAt(device), DAY - 3600);
    await expectLimited(await gw.request("PUT", path, { auth: device.owner_key, body: TOKEN_CHANGE }), DAY - 3600);
    await expectLimited(await mintAt(other, "2001:db8:7:1::1"), DAY - 3600);

    // Everything that turns notifications off does.
    expect((await deleteAt(device, laptop.secret_id)).status).toBe(204);
    expect((await gw.push(laptop.push_secret)).status).toBe(401);
    expect((await gw.push(device.push_secret)).status).toBe(200);
    expect((await gw.request("DELETE", path, { auth: device.owner_key })).status).toBe(204);
    expect((await gw.push(device.push_secret)).status).toBe(401);
    expect(
      (await gw.request("DELETE", `/v1/devices/${other.device_id}`, { auth: other.owner_key, ip: "2001:db8:7:1::1" })).status,
    ).toBe(204);
    expect(await deviceRows()).toEqual([]);
    expect(await secretRows()).toEqual([]);

    expect((await counter(counterKey.manage()))?.count).toBe(LIMITS.managePerDay.max);
    expect((await counter(counterKey.deletes()))?.count).toBe(3);
  });

  it("cap deletes from everyone at 600 per UTC day, and write nothing past the cap", async () => {
    expect(LIMITS.deletesPerDay.max).toBe(600);
    const device = await gw.register();
    const other = await gw.register(undefined, "sandbox", "198.51.100.20");
    await seedCounter(counterKey.deletes(), LIMITS.deletesPerDay.max - 1, T0 + DAY);
    gw.now = T0 + 3600;
    expect((await deleteAt(device, device.secret_id)).status).toBe(204);

    const { db, log } = spyOnDb(env.DB);
    gw.env = { ...testEnv, DB: db };
    await expectLimited(await deleteAt(device, "anything"), DAY - 3600);
    await expectLimited(await deleteAt(other, other.secret_id, "198.51.100.21"), DAY - 3600);
    await expectLimited(
      await gw.request("DELETE", `/v1/devices/${other.device_id}`, { auth: other.owner_key, ip: "2001:db8::1" }),
      DAY - 3600,
    );
    expect(log.statements).toHaveLength(3);
    for (const sql of log.statements) expect(sql).toMatch(/^\s*SELECT/);
    expect(log.otherCalls).toBe(0);
    expect(log.rowsWritten).toBe(0);
    gw.env = testEnv;
    expect(await deviceRows()).toHaveLength(2);
    expect(await secretRows()).toHaveLength(1);
    expect((await counter(counterKey.deletes()))?.count).toBe(LIMITS.deletesPerDay.max);

    // Minting draws on the other budget and goes on.
    expect((await mintAt(device)).status).toBe(201);

    gw.now = T0 + DAY;
    expect((await deleteAt(other, other.secret_id)).status).toBe(204);
    expect((await counter(counterKey.deletes()))?.count).toBe(1);
  });

  it("are not spent by a caller without the owner key, or by a malformed request", async () => {
    const device = await gw.registerDevice();
    const path = `/v1/devices/${device.device_id}`;
    for (let i = 0; i < 5; i++) {
      await gw.request("POST", `${path}/secrets`, { auth: "A".repeat(43), body: { label: "x" } });
      await gw.request("PUT", path, { auth: "A".repeat(43), body: { apns_token: PRODUCTION_TOKEN, environment: "sandbox" } });
      await gw.request("DELETE", `${path}/secrets/any`, { auth: "A".repeat(43) });
      await gw.request("DELETE", path, { auth: "A".repeat(43) });
      await gw.request("POST", `${path}/secrets`, { auth: device.owner_key, body: { label: "" } });
      await gw.request("PUT", path, { auth: device.owner_key, body: { apns_token: "bad" } });
    }
    expect(await counter(counterKey.manage())).toBeNull();
    expect(await counter(counterKey.deletes())).toBeNull();
    expect(await counter(counterKey.manageFrom(await sha256Hex("203.0.113.7")))).toBeNull();
    expect(await manageCount(device.device_id)).toEqual([TODAY, 0]);
  });
});

describe("push caps", () => {
  it("keep the per-minute limit out of D1", async () => {
    const device = await gw.register();
    gw.now = T0 + 5;
    for (let i = 0; i < 40; i++) expect((await gw.push(device.push_secret)).status).toBe(200);
    const address = await sha256Hex("203.0.113.7");
    const keys = (await env.DB.prepare("SELECT key FROM counters").all<{ key: string }>()).results.map((r) => r.key);
    expect(keys.sort()).toEqual(
      [
        counterKey.manage(),
        counterKey.manageFrom(address),
        counterKey.register(address),
        counterKey.registerDay(address),
        counterKey.registrations(),
        counterKey.sends(),
      ].sort(),
    );
    expect((await counter(counterKey.sends()))?.count).toBe(40);
  });

  it("do not count pushes the gateway rejects as invalid", async () => {
    const device = await gw.register();
    for (let i = 0; i < 40; i++) {
      expect((await gw.push(device.push_secret, { payload: {}, push_type: "alert" })).status).toBe(400);
    }
    expect((await gw.push(device.push_secret)).status).toBe(200);
    expect((await counter(counterKey.sends()))?.count).toBe(1);
    expect(await pushCount(device.device_id)).toEqual([TODAY, 1]);
  });

  it("count a push Apple refused", async () => {
    const device = await gw.register();
    gw.apple = appleError(503, "ServiceUnavailable");
    for (let i = 0; i < 3; i++) expect((await gw.push(device.push_secret)).status).toBe(502);
    expect(await pushCount(device.device_id)).toEqual([TODAY, 3]);
    expect((await counter(counterKey.sends()))?.count).toBe(3);
  });

  it("cap a token at 1500 pushes per UTC day across its device's 10 secrets, and let other tokens push", async () => {
    expect(LIMITS.pushPerTokenPerDay.max).toBe(1500);
    const device = await gw.registerDevice();
    const secrets: Secret[] = [];
    for (let i = 0; i < MAX_SECRETS_PER_DEVICE; i++) secrets.push(await gw.mint(device, `helper ${i}`));
    const other = await gw.register();

    // Every secret pushes its tenth of the token's allowance.
    gw.now = T0 + 3600;
    const each = LIMITS.pushPerTokenPerDay.max / secrets.length;
    for (const secret of secrets) {
      for (let i = 0; i < each; i++) {
        const response = await gw.push(secret.push_secret);
        if (response.status !== 200) throw new Error(`push ${i} of a secret answered ${response.status}`);
      }
    }
    expect(gw.calls).toHaveLength(1500);
    expect(await pushCount(device.device_id)).toEqual([TODAY, 1500]);

    // Not one of them has a push left, in this minute or a later one of the same day.
    for (const secret of secrets) await expectLimited(await gw.push(secret.push_secret), DAY - 3600);
    gw.now = T0 + DAY - 1;
    for (const secret of secrets) await expectLimited(await gw.push(secret.push_secret), 1);
    expect(gw.calls).toHaveLength(1500);
    expect(await pushCount(device.device_id)).toEqual([TODAY, 1500]);
    // A refused push took nothing from the shared budget.
    expect((await counter(counterKey.sends()))?.count).toBe(1500);

    // Other tokens still push, and the device still manages its secrets.
    expect((await gw.push(other.push_secret)).status).toBe(200);
    expect(await pushCount(other.device_id)).toEqual([TODAY, 1]);
    expect((await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key })).status).toBe(200);

    gw.now = T0 + DAY;
    expect((await gw.push(secrets[0]?.push_secret ?? "")).status).toBe(200);
    expect(await pushCount(device.device_id)).toEqual([TODAY + 1, 1]);
    expect(await pushCount(other.device_id)).toEqual([TODAY, 1]);
  });

  it("cap all sends at 30000 per UTC day", async () => {
    expect(LIMITS.pushPerDay.max).toBe(30000);
    const device = await gw.register();
    const other = await gw.register();
    await seedCounter(counterKey.sends(), LIMITS.pushPerDay.max - 1, T0 + DAY);

    gw.now = T0 + 7200;
    expect((await gw.push(device.push_secret)).status).toBe(200);
    await expectLimited(await gw.push(device.push_secret), DAY - 7200);
    await expectLimited(await gw.push(other.push_secret), DAY - 7200);
    expect(gw.calls).toHaveLength(1);
    // A push refused by the shared budget is not counted against its device.
    expect(await pushCount(device.device_id)).toEqual([TODAY, 1]);
    expect(await pushCount(other.device_id)).toEqual([TODAY, 0]);
    expect((await counter(counterKey.sends()))?.count).toBe(LIMITS.pushPerDay.max);

    gw.now = T0 + DAY;
    expect((await gw.push(device.push_secret)).status).toBe(200);
    expect((await counter(counterKey.sends()))?.count).toBe(1);
  });

});

describe("the global budgets are separate", () => {
  const spend = (key: string, limit: { max: number }): Promise<void> => seedCounter(key, limit.max, T0 + DAY);
  const register = (ip: string): Promise<Response> =>
    gw.request("POST", "/v1/devices", { body: TOKEN_CHANGE, ip });

  it("pushes spent: registration and management go on", async () => {
    const device = await gw.register();
    await spend(counterKey.sends(), LIMITS.pushPerDay);
    await expectLimited(await gw.push(device.push_secret), DAY);

    const path = `/v1/devices/${device.device_id}`;
    expect((await register("198.51.100.1")).status).toBe(201);
    const minted = await gw.mint(device, "laptop");
    expect((await gw.request("PUT", path, { auth: device.owner_key, body: TOKEN_CHANGE })).status).toBe(200);
    expect((await gw.request("DELETE", `${path}/secrets/${minted.secret_id}`, { auth: device.owner_key })).status).toBe(204);
    expect((await gw.request("DELETE", path, { auth: device.owner_key })).status).toBe(204);
  });

  it("management spent: pushes and registration go on", async () => {
    const device = await gw.register();
    await env.DB.prepare("UPDATE counters SET count = ?2 WHERE key = ?1")
      .bind(counterKey.manage(), LIMITS.managePerDay.max)
      .run();
    await expectLimited(
      await gw.request("POST", `/v1/devices/${device.device_id}/secrets`, { auth: device.owner_key, body: { label: "x" } }),
      DAY,
    );

    for (let i = 0; i < 3; i++) expect((await gw.push(device.push_secret)).status).toBe(200);
    expect((await register("198.51.100.1")).status).toBe(201);
    expect((await counter(counterKey.sends()))?.count).toBe(3);
    // And the phone can still take the secret back.
    expect(
      (await gw.request("DELETE", `/v1/devices/${device.device_id}/secrets/${device.secret_id}`, { auth: device.owner_key })).status,
    ).toBe(204);
  });

  it("registrations spent: phones that are registered push and manage as before", async () => {
    const device = await gw.register();
    await env.DB.prepare("UPDATE counters SET count = ?2 WHERE key = ?1")
      .bind(counterKey.registrations(), LIMITS.registerPerDay.max)
      .run();
    await expectLimited(await register("198.51.100.1"), DAY);
    await expectLimited(await register("203.0.113.7"), DAY);

    const path = `/v1/devices/${device.device_id}`;
    expect((await gw.push(device.push_secret)).status).toBe(200);
    const minted = await gw.mint(device, "laptop");
    expect((await gw.push(minted.push_secret)).status).toBe(200);
    expect((await gw.request("PUT", path, { auth: device.owner_key, body: TOKEN_CHANGE })).status).toBe(200);
    expect((await gw.request("GET", path, { auth: device.owner_key })).status).toBe(200);
    expect((await gw.request("DELETE", `${path}/secrets/${minted.secret_id}`, { auth: device.owner_key })).status).toBe(204);
    expect((await gw.push(device.push_secret)).status).toBe(200);
  });

  it("registrations and management both spent: phones that are registered still get pushes", async () => {
    const device = await gw.register();
    await env.DB.prepare("UPDATE counters SET count = ?3 WHERE key IN (?1, ?2)")
      .bind(counterKey.registrations(), counterKey.manage(), 100_000)
      .run();
    await expectLimited(await register("198.51.100.1"), DAY);
    expect((await gw.push(device.push_secret)).status).toBe(200);
  });

  it("deletes spent: pushes, registration, mints and token changes go on", async () => {
    const device = await gw.register();
    await spend(counterKey.deletes(), LIMITS.deletesPerDay);
    const path = `/v1/devices/${device.device_id}`;
    await expectLimited(await gw.request("DELETE", `${path}/secrets/${device.secret_id}`, { auth: device.owner_key }), DAY);
    await expectLimited(await gw.request("DELETE", path, { auth: device.owner_key }), DAY);

    expect((await gw.push(device.push_secret)).status).toBe(200);
    expect((await register("198.51.100.1")).status).toBe(201);
    await gw.mint(device, "laptop");
    expect((await gw.request("PUT", path, { auth: device.owner_key, body: TOKEN_CHANGE })).status).toBe(200);
  });

});
