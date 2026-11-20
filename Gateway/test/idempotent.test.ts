import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { deviceIdFor, isKey, sha256Hex } from "../src/encoding";
import { LIMITS, MAX_DEVICES_PER_TOKEN, MAX_SECRETS_PER_DEVICE, ROWS, counterKey } from "../src/limits";
import {
  type DbLog,
  type Device,
  Gateway,
  PRODUCTION_TOKEN,
  SANDBOX_TOKEN,
  type Secret,
  T0,
  appleError,
  chosenDevice,
  chosenKey,
  chosenSecretId,
  counter,
  deviceIdOf,
  deviceRows,
  errorOf,
  isWrite,
  reset,
  secretRows,
  seedCounter,
  spyOnDb,
  testEnv,
  tokenNumber,
} from "./helpers";

/*
 * The two routes a phone can send again: `PUT /v1/devices/{id}` and
 * `PUT /v1/devices/{id}/secrets/{secret_id}`, with an owner key, a device id, a secret id
 * and a push secret the phone chose. The same request twice leaves one device or one secret.
 */

let gw: Gateway;
beforeEach(async () => {
  await reset();
  gw = new Gateway();
});

const DAY = 86400;
const TODAY = T0 / DAY;
const ADDRESS = "203.0.113.7";
const IPV6 = "2001:db8:1:2::1";

/** Watches D1 from here on. */
function watch(): DbLog {
  const { db, log } = spyOnDb(env.DB);
  gw.env = { ...testEnv, DB: db };
  return log;
}

const writes = (log: DbLog): string[] => log.statements.filter(isWrite);

/** Every counter, by key. */
async function counters(): Promise<Record<string, number>> {
  const rows = await env.DB.prepare("SELECT key, count FROM counters ORDER BY key").all<{ key: string; count: number }>();
  return Object.fromEntries(rows.results.map((row) => [row.key, row.count]));
}

/** Everything the database holds. */
async function everything(): Promise<unknown> {
  return [await deviceRows(), await secretRows(), await counters()];
}

async function expectLimited(response: Response, retryAfter: number): Promise<void> {
  expect(response.status).toBe(429);
  expect(response.headers.get("retry-after")).toBe(String(retryAfter));
  expect((await errorOf(response)).error).toBe("rate_limited");
}

/** A device made through `PUT`, with a token of its own unless one is given. */
let made = 0;
async function makeDevice(token = tokenNumber(5000 + made++), environment = "sandbox", ip?: string): Promise<Device> {
  const device = await chosenDevice();
  const response = await gw.putDevice(device, token, environment, ip);
  if (response.status !== 201) throw new Error(`PUT of a new device answered ${response.status}`);
  return device;
}

function newSecret(): Secret {
  return { secret_id: chosenSecretId(), push_secret: chosenKey() };
}

/** A secret stored through `PUT`. */
async function makeSecret(device: Device, label = "studio"): Promise<Secret> {
  const secret = newSecret();
  const response = await gw.putSecret(device, secret, label);
  if (response.status !== 201) throw new Error(`PUT of a new secret answered ${response.status}`);
  return secret;
}

/** The APNs token a push with this secret went to, from the request the fake Apple got. */
async function pushedTo(pushSecret: string): Promise<string[]> {
  const before = gw.calls.length;
  expect((await gw.push(pushSecret)).status).toBe(200);
  return gw.calls.slice(before).map((call) => call.url.replace(/^.*\/3\/device\//, ""));
}

describe("the device id of an owner key", () => {
  it("is the first 22 characters of base64url(SHA-256(\"rexduo-device-v1\\n\" + owner_key))", async () => {
    // A fixed pair, so the derivation can't change without this test.
    const key = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    expect(await deviceIdFor(key)).toBe(await deviceIdOf(key));
    expect(await deviceIdFor(key)).toMatch(/^[A-Za-z0-9_-]{22}$/);
    const other = chosenKey();
    expect(await deviceIdFor(other)).toBe(await deviceIdOf(other));
    expect(await deviceIdFor(other)).not.toBe(await deviceIdFor(key));
  });

  it("takes a key of exactly 32 bytes: 43 characters with no bits to spare in the last", () => {
    for (let i = 0; i < 50; i++) expect(isKey(chosenKey())).toBe(true);
    expect(isKey("A".repeat(43))).toBe(true);
    for (const last of "BCDFGHJKLNOPRSTVWXZabdefhijlmnpqrtuvxyz1235679-_") expect(isKey("A".repeat(42) + last)).toBe(false);
    expect(isKey("A".repeat(42))).toBe(false);
    expect(isKey("A".repeat(44))).toBe(false);
    expect(isKey(`${"A".repeat(42)}=`)).toBe(false);
    expect(isKey(`${"A".repeat(41)}+A`)).toBe(false);
  });
});

describe("PUT /v1/devices/{id} with an id the phone chose", () => {
  it("makes the device, answers 201 with its id only, and stores only the key's hash", async () => {
    const device = await chosenDevice();
    const response = await gw.putDevice(device, PRODUCTION_TOKEN, "production");
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ device_id: device.device_id });
    const rows = await deviceRows();
    expect(rows).toEqual([
      {
        device_id: device.device_id,
        owner_hash: await sha256Hex(device.owner_key),
        apns_token: PRODUCTION_TOKEN.toLowerCase(),
        environment: "production",
        created_at: T0,
        updated_at: T0,
        push_day: TODAY,
        push_count: 0,
        manage_day: TODAY,
        manage_count: 0,
        token_hash: await sha256Hex(PRODUCTION_TOKEN.toLowerCase()),
        dead: 0,
      },
    ]);
    expect(JSON.stringify(rows)).not.toContain(device.owner_key);
  });

  it("answers 200 to the same request again: one device, one read, nothing written and nothing counted", async () => {
    const device = await chosenDevice();
    expect((await gw.putDevice(device)).status).toBe(201);
    const before = await everything();

    const log = watch();
    gw.now = T0 + 50;
    for (let i = 0; i < 3; i++) {
      const again = await gw.putDevice(device);
      expect(again.status).toBe(200);
      expect(await again.json()).toEqual({});
    }
    expect(log.statements).toHaveLength(3);
    for (const sql of log.statements) expect(sql).toMatch(/^\s*SELECT/);
    expect(log.otherCalls).toBe(0);
    expect(log.rowsWritten).toBe(0);
    expect(await everything()).toEqual(before);
    expect(await deviceRows()).toHaveLength(1);
  });

  it("takes the token in either case as the same token", async () => {
    const device = await chosenDevice();
    expect((await gw.putDevice(device, PRODUCTION_TOKEN.toLowerCase(), "production")).status).toBe(201);
    const log = watch();
    expect((await gw.putDevice(device, PRODUCTION_TOKEN, "production")).status).toBe(200);
    expect(log.rowsWritten).toBe(0);
  });

  it("updates the device when the same request carries another token: one management write, the secrets stay", async () => {
    const device = await makeDevice(SANDBOX_TOKEN);
    const secret = await makeSecret(device);
    const before = await counters();

    gw.now = T0 + 50;
    const response = await gw.putDevice(device, PRODUCTION_TOKEN, "production");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({});
    expect(await deviceRows()).toMatchObject([
      {
        device_id: device.device_id,
        apns_token: PRODUCTION_TOKEN.toLowerCase(),
        token_hash: await sha256Hex(PRODUCTION_TOKEN.toLowerCase()),
        environment: "production",
        created_at: T0,
        updated_at: T0 + 50,
        // The secret and the token change.
        manage_count: 2,
      },
    ]);
    const manage = counterKey.manage();
    const fromAddress = counterKey.manageFrom(await sha256Hex(ADDRESS));
    expect(await counters()).toEqual({
      ...before,
      [manage]: (before[manage] ?? 0) + 1,
      [fromAddress]: (before[fromAddress] ?? 0) + 1,
    });
    expect(await pushedTo(secret.push_secret)).toEqual([PRODUCTION_TOKEN.toLowerCase()]);

    // And that request again is a repeat.
    const log = watch();
    expect((await gw.putDevice(device, PRODUCTION_TOKEN, "production")).status).toBe(200);
    expect(log.rowsWritten).toBe(0);
  });

  it("updates the device when only the environment is another", async () => {
    const device = await makeDevice(SANDBOX_TOKEN, "sandbox");
    expect((await gw.putDevice(device, SANDBOX_TOKEN, "production")).status).toBe(200);
    expect(await deviceRows()).toMatchObject([{ environment: "production", manage_count: 1 }]);
  });

  it("makes a device marked dead live again, also with the token it holds, as a token change does", async () => {
    const device = await makeDevice(SANDBOX_TOKEN);
    const secret = await makeSecret(device);
    gw.apple = appleError(410, "Unregistered");
    expect((await gw.push(secret.push_secret)).status).toBe(410);
    expect(await deviceRows()).toMatchObject([{ dead: 1 }]);
    gw.apple = () => new Response(null, { status: 200 });

    expect((await gw.putDevice(device, SANDBOX_TOKEN)).status).toBe(200);
    expect(await deviceRows()).toMatchObject([{ dead: 0, apns_token: SANDBOX_TOKEN, manage_count: 2 }]);
    expect(await pushedTo(secret.push_secret)).toEqual([SANDBOX_TOKEN]);

    // Live with this token: the next one is a repeat.
    const log = watch();
    expect((await gw.putDevice(device, SANDBOX_TOKEN)).status).toBe(200);
    expect(log.rowsWritten).toBe(0);
  });

  it("answers 400 for an id that is not its key's, from the request alone", async () => {
    const device = await chosenDevice();
    const other = await chosenDevice();
    const log = watch();
    const answers = [
      await gw.putDevice({ device_id: other.device_id, owner_key: device.owner_key }),
      await gw.putDevice({ device_id: "x".repeat(22), owner_key: device.owner_key }),
      // The right id but for its last character.
      await gw.putDevice({ device_id: `${device.device_id.slice(0, 21)}${device.device_id.endsWith("A") ? "B" : "A"}`, owner_key: device.owner_key }),
    ];
    for (const response of answers) {
      expect(response.status).toBe(400);
      expect((await errorOf(response)).error).toBe("invalid_request");
    }
    expect(log.statements).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(await deviceRows()).toEqual([]);
  });

  it("answers 400 to another owner key on a device that exists, without a D1 call, and the device stays as it is", async () => {
    const device = await makeDevice(SANDBOX_TOKEN);
    const other = await makeDevice();
    const before = await everything();

    const log = watch();
    for (const key of [other.owner_key, chosenKey(), "A".repeat(43)]) {
      const response = await gw.putDevice({ device_id: device.device_id, owner_key: key }, PRODUCTION_TOKEN, "production");
      expect(response.status).toBe(400);
      expect((await errorOf(response)).error).toBe("invalid_request");
    }
    // The same answer as for an id no device has.
    const absent = await chosenDevice();
    const forAbsent = await gw.putDevice({ device_id: absent.device_id, owner_key: other.owner_key });
    const forPresent = await gw.putDevice({ device_id: device.device_id, owner_key: other.owner_key });
    expect(await forPresent.text()).toBe(await forAbsent.text());
    expect(forPresent.status).toBe(forAbsent.status);

    expect(log.statements).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(await everything()).toEqual(before);
  });

  it("answers 401 for a key that is not 32 bytes, without a D1 call", async () => {
    const device = await makeDevice();
    const log = watch();
    for (const key of ["B".repeat(43), `${device.owner_key.slice(0, 42)}_`]) {
      const response = await gw.putDevice({ device_id: device.device_id, owner_key: key });
      expect(response.status).toBe(401);
      expect((await errorOf(response)).error).toBe("unauthorized");
    }
    expect(log.statements).toEqual([]);
    expect(log.otherCalls).toBe(0);
  });

  it("keeps today's answers for an id of any other length: 401 for one no device has, with one read and no write", async () => {
    const owner = chosenKey();
    const id = await deviceIdOf(owner);
    const log = watch();
    for (const deviceId of [id.slice(0, 21), `${id}A`, "x".repeat(27), "x"]) {
      const response = await gw.putDevice({ device_id: deviceId, owner_key: owner });
      expect(response.status).toBe(401);
      expect(await response.text()).toBe('{"error":"unauthorized","message":"Missing or invalid credentials."}');
    }
    expect(log.statements).toHaveLength(4);
    expect(writes(log)).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(await deviceRows()).toEqual([]);
  });

  it("keeps today's token change for a device registered with POST: the same token again is a management write", async () => {
    const device = await gw.registerDevice(SANDBOX_TOKEN);
    expect(device.device_id).toHaveLength(27);
    for (let i = 1; i <= 2; i++) {
      expect((await gw.putDevice(device, SANDBOX_TOKEN)).status).toBe(200);
      expect(await deviceRows()).toMatchObject([{ manage_count: i }]);
    }
  });

  it.each([
    ["a bad token", { apns_token: "nope", environment: "sandbox" }],
    ["no environment", { apns_token: SANDBOX_TOKEN }],
    ["an array", [SANDBOX_TOKEN]],
  ])("answers 400 for %s, without a D1 call", async (_name, body) => {
    const device = await chosenDevice();
    const log = watch();
    const response = await gw.request("PUT", `/v1/devices/${device.device_id}`, { auth: device.owner_key, body });
    expect(response.status).toBe(400);
    expect((await errorOf(response)).error).toBe("invalid_request");
    expect(log.statements).toEqual([]);
  });

  it("is reached by the other owner-key routes like any device, and a wrong key gets their 401 with nothing written", async () => {
    const device = await makeDevice(SANDBOX_TOKEN);
    const secret = await makeSecret(device);
    const base = `/v1/devices/${device.device_id}`;
    const shown = await gw.request("GET", base, { auth: device.owner_key });
    expect(await shown.json()).toMatchObject({ environment: "sandbox", secrets: [{ secret_id: secret.secret_id, label: "studio" }] });
    const minted = await gw.mint(device, "laptop");
    expect(await pushedTo(minted.push_secret)).toEqual([SANDBOX_TOKEN]);

    const before = await everything();
    const log = watch();
    const wrong = chosenKey();
    const answers = [
      await gw.request("GET", base, { auth: wrong }),
      await gw.request("DELETE", base, { auth: wrong }),
      await gw.request("POST", `${base}/secrets`, { auth: wrong, body: { label: "intruder" } }),
      await gw.putSecret({ device_id: device.device_id, owner_key: wrong }, newSecret()),
      await gw.putSecret({ device_id: device.device_id, owner_key: wrong }, secret),
      await gw.request("DELETE", `${base}/secrets/${secret.secret_id}`, { auth: wrong }),
    ];
    for (const response of answers) {
      expect(response.status).toBe(401);
      expect(await response.text()).toBe('{"error":"unauthorized","message":"Missing or invalid credentials."}');
    }
    expect(log.statements).toHaveLength(answers.length);
    expect(writes(log)).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(await everything()).toEqual(before);

    gw.env = testEnv;
    expect((await gw.request("DELETE", base, { auth: device.owner_key })).status).toBe(204);
    expect(await deviceRows()).toEqual([]);
    // The same request makes the device again, under the same id.
    expect((await gw.putDevice(device)).status).toBe(201);
  });
});

describe("registration caps on a device made through PUT", () => {
  const hourly = (): Promise<{ count: number; expires_at: number } | null> =>
    sha256Hex(ADDRESS).then((hash) => counter(counterKey.register(hash)));

  it("allow 10 an hour per client address, POST and PUT together, and none of them counts a repeat", async () => {
    const devices: Device[] = [];
    for (let i = 0; i < 5; i++) devices.push(await makeDevice());
    for (let i = 0; i < 5; i++) await gw.registerDevice(tokenNumber(7000 + i));
    expect((await hourly())?.count).toBe(10);

    gw.now = T0 + 600;
    const refused = await chosenDevice();
    await expectLimited(await gw.putDevice(refused, tokenNumber(7100)), 3000);
    expect(await deviceRows()).toHaveLength(10);

    // A device that is there sends its request again, whatever the address did.
    const log = watch();
    for (const [index, device] of devices.entries()) {
      expect((await gw.putDevice(device, tokenNumber(5000 + made - 5 + index))).status).toBe(200);
    }
    expect(log.rowsWritten).toBe(0);
    gw.env = testEnv;
    expect((await hourly())?.count).toBe(10);

    // Another address has its own allowance, and so has the next hour.
    expect((await gw.putDevice(await chosenDevice(), tokenNumber(7101), "sandbox", "198.51.100.9")).status).toBe(201);
    gw.now = T0 + 3600;
    expect((await gw.putDevice(refused, tokenNumber(7100))).status).toBe(201);
  });

  it("allow 20 per UTC day per client address", async () => {
    for (const hour of [0, 1]) {
      gw.now = T0 + hour * 3600;
      for (let i = 0; i < 10; i++) await makeDevice();
    }
    gw.now = T0 + 2 * 3600;
    await expectLimited(await gw.putDevice(await chosenDevice(), tokenNumber(7200)), DAY - 2 * 3600);
    expect(await deviceRows()).toHaveLength(20);
  });

  it("count an IPv6 client by its /64 and by its /48", async () => {
    await makeDevice(undefined, "sandbox", IPV6);
    const keys = Object.keys(await counters());
    expect(keys.sort()).toEqual(
      [
        counterKey.register(await sha256Hex("2001:db8:1:2::/64")),
        counterKey.registerDay(await sha256Hex("2001:db8:1:2::/64")),
        counterKey.register(await sha256Hex("2001:db8:1::/48")),
        counterKey.registerDay(await sha256Hex("2001:db8:1::/48")),
        counterKey.registrations(),
      ].sort(),
    );
  });

  it(`let ${MAX_DEVICES_PER_TOKEN} devices hold one token and answer 409 too_many_devices to the next, with nothing written`, async () => {
    const token = "5a".repeat(32);
    await gw.registerDevice(token);
    const second = await makeDevice(token);
    await makeDevice(token);
    const elsewhere = await makeDevice();
    const before = await everything();

    const log = watch();
    const fourth = await gw.putDevice(await chosenDevice(), token);
    expect(fourth.status).toBe(409);
    expect((await errorOf(fourth)).error).toBe("too_many_devices");
    // A device on another token can't move onto the full one either.
    const moved = await gw.putDevice(elsewhere, token);
    expect(moved.status).toBe(409);
    expect((await errorOf(moved)).error).toBe("too_many_devices");
    expect(writes(log)).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(await everything()).toEqual(before);

    // A device of the full token sends its request again.
    expect((await gw.putDevice(second, token)).status).toBe(200);
    expect(log.rowsWritten).toBe(0);
  });

  it("cap registrations from everyone at 1000 per UTC day, write nothing past the cap, and leave repeats alone", async () => {
    await seedCounter(counterKey.registrations(), LIMITS.registerPerDay.max - 1, T0 + DAY);
    gw.now = T0 + 7200;
    const last = await makeDevice(SANDBOX_TOKEN);

    const log = watch();
    for (const ip of [ADDRESS, "198.51.100.1", "2001:db8::1"]) {
      await expectLimited(await gw.putDevice(await chosenDevice(), tokenNumber(7300), "sandbox", ip), DAY - 7200);
    }
    // The device's own read finds nothing, and the registration's read finds the cap.
    expect(log.statements).toHaveLength(6);
    for (const sql of log.statements) expect(sql).toMatch(/^\s*SELECT/);
    expect(log.otherCalls).toBe(0);
    expect(await deviceRows()).toHaveLength(1);
    expect((await counter(counterKey.registrations()))?.count).toBe(LIMITS.registerPerDay.max);

    // The device that is there: a repeat, and a token change, which is not a registration.
    expect((await gw.putDevice(last, SANDBOX_TOKEN)).status).toBe(200);
    expect(log.rowsWritten).toBe(0);
    expect((await gw.putDevice(last, PRODUCTION_TOKEN, "production")).status).toBe(200);
  });
});

describe("management caps on a token update through PUT", () => {
  let device: Device;
  beforeEach(async () => {
    device = await makeDevice(SANDBOX_TOKEN);
    gw.now = T0 + 7200;
  });

  /** A token update is refused with nothing written, and the same token still answers 200. */
  async function expectCapped(): Promise<void> {
    const before = await everything();
    const log = watch();
    await expectLimited(await gw.putDevice(device, PRODUCTION_TOKEN, "production"), DAY - 7200);
    expect(log.statements).toHaveLength(1);
    expect(writes(log)).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(await everything()).toEqual(before);

    expect((await gw.putDevice(device, SANDBOX_TOKEN)).status).toBe(200);
    expect(log.rowsWritten).toBe(0);
    expect(await deviceRows()).toMatchObject([{ apns_token: SANDBOX_TOKEN, environment: "sandbox" }]);
  }

  it("the device's 60 a day", async () => {
    await env.DB.prepare("UPDATE devices SET manage_count = ?1").bind(LIMITS.managePerDevicePerDay.max).run();
    await expectCapped();
  });

  it("the client address's 120 a day", async () => {
    const key = counterKey.manageFrom(await sha256Hex(ADDRESS));
    await seedCounter(key, LIMITS.managePerAddressPerDay.max, T0 + DAY);
    await expectCapped();
  });

  it("the /48's 240 a day", async () => {
    await seedCounter(counterKey.manageFrom(await sha256Hex("2001:db8:1::/48")), LIMITS.managePerWideAddressPerDay.max, T0 + DAY);
    const before = await everything();
    await expectLimited(await gw.putDevice(device, PRODUCTION_TOKEN, "production", IPV6), DAY - 7200);
    expect(await everything()).toEqual(before);
    expect((await gw.putDevice(device, SANDBOX_TOKEN, "sandbox", IPV6)).status).toBe(200);
  });

  it("everyone's 1000 a day", async () => {
    await seedCounter(counterKey.manage(), LIMITS.managePerDay.max, T0 + DAY);
    await expectCapped();
  });

  it("counts exactly one management write when there is room", async () => {
    expect((await gw.putDevice(device, PRODUCTION_TOKEN, "production")).status).toBe(200);
    expect(await deviceRows()).toMatchObject([{ manage_count: 1 }]);
    expect(await counters()).toMatchObject({
      [counterKey.manage()]: 1,
      [counterKey.manageFrom(await sha256Hex(ADDRESS))]: 1,
    });
  });
});

describe("PUT /v1/devices/{id}/secrets/{secret_id}", () => {
  it("stores the secret, answers 201 with its id only, and keeps only the secret's hash", async () => {
    const device = await makeDevice(SANDBOX_TOKEN);
    const secret = newSecret();
    gw.now = T0 + 7;
    const response = await gw.putSecret(device, secret, "Abe's MacBook Pro 🦖");
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ secret_id: secret.secret_id });
    const rows = await secretRows();
    expect(rows).toEqual([
      {
        secret_hash: await sha256Hex(secret.push_secret),
        device_id: device.device_id,
        secret_id: secret.secret_id,
        label: "Abe's MacBook Pro 🦖",
        created_at: T0 + 7,
        presence: 0,
      },
    ]);
    expect(JSON.stringify(rows)).not.toContain(secret.push_secret);
    expect(await deviceRows()).toMatchObject([{ manage_count: 1 }]);
  });

  it("makes a secret that pushes, and such a push writes two rows", async () => {
    const device = await makeDevice(SANDBOX_TOKEN);
    const secret = await makeSecret(device);
    const log = watch();
    for (let i = 0; i < 3; i++) expect(await pushedTo(secret.push_secret)).toEqual([SANDBOX_TOKEN]);
    expect(log.batchRowsWritten).toEqual([ROWS.push, ROWS.push, ROWS.push]);
    expect(log.rowsWritten).toBe(3 * ROWS.push);
    expect(log.statements).toHaveLength(9);
    expect(await deviceRows()).toMatchObject([{ push_count: 3 }]);
  });

  it("answers 200 to the same request again: one secret, one read, nothing written and nothing counted", async () => {
    const device = await makeDevice();
    const secret = await makeSecret(device);
    const before = await everything();

    const log = watch();
    gw.now = T0 + 50;
    for (let i = 0; i < 3; i++) {
      const again = await gw.putSecret(device, secret);
      expect(again.status).toBe(200);
      expect(await again.json()).toEqual({ secret_id: secret.secret_id });
    }
    expect(log.statements).toHaveLength(3);
    for (const sql of log.statements) expect(sql).toMatch(/^\s*SELECT/);
    expect(log.otherCalls).toBe(0);
    expect(log.rowsWritten).toBe(0);
    expect(await everything()).toEqual(before);
  });

  it("replaces the secret under an id with another: one management write, the first no longer pushes and the second does", async () => {
    const device = await makeDevice(SANDBOX_TOKEN);
    const first = await makeSecret(device, "studio");
    const kept = await makeSecret(device, "laptop");
    expect(await pushedTo(first.push_secret)).toEqual([SANDBOX_TOKEN]);
    const before = await counters();

    gw.now = T0 + 90;
    const second: Secret = { secret_id: first.secret_id, push_secret: chosenKey() };
    const response = await gw.putSecret(device, second, "studio, again");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ secret_id: first.secret_id });

    expect((await gw.push(first.push_secret)).status).toBe(401);
    expect(await pushedTo(second.push_secret)).toEqual([SANDBOX_TOKEN]);
    expect(await pushedTo(kept.push_secret)).toEqual([SANDBOX_TOKEN]);
    expect(await secretRows()).toEqual([
      expect.objectContaining({ secret_id: kept.secret_id, label: "laptop", created_at: T0 }),
      {
        secret_hash: await sha256Hex(second.push_secret),
        device_id: device.device_id,
        secret_id: first.secret_id,
        label: "studio, again",
        created_at: T0 + 90,
        presence: 0,
      },
    ]);
    // Two secrets stored and one replaced.
    expect(await deviceRows()).toMatchObject([{ manage_count: 3 }]);
    const manage = counterKey.manage();
    const fromAddress = counterKey.manageFrom(await sha256Hex(ADDRESS));
    expect(await counters()).toMatchObject({ [manage]: (before[manage] ?? 0) + 1, [fromAddress]: (before[fromAddress] ?? 0) + 1 });

    // The replacement again is a repeat.
    const log = watch();
    expect((await gw.putSecret(device, second, "studio, again")).status).toBe(200);
    expect(log.rowsWritten).toBe(0);
  });

  it(`holds ${MAX_SECRETS_PER_DEVICE} secrets a device, counted by id and not by request`, async () => {
    const device = await makeDevice();
    const other = await makeDevice();
    const secrets: Secret[] = [];
    for (let i = 0; i < MAX_SECRETS_PER_DEVICE; i++) secrets.push(await makeSecret(device, `helper ${i}`));

    // Each of the ten again, and one of them replaced: still ten.
    for (const secret of secrets) expect((await gw.putSecret(device, secret)).status).toBe(200);
    const replaced: Secret = { secret_id: secrets[4]?.secret_id ?? "", push_secret: chosenKey() };
    expect((await gw.putSecret(device, replaced)).status).toBe(200);
    expect(await secretRows()).toHaveLength(MAX_SECRETS_PER_DEVICE);

    const full = await gw.putSecret(device, newSecret());
    expect(full.status).toBe(409);
    expect((await errorOf(full)).error).toBe("too_many_secrets");
    const minted = await gw.request("POST", `/v1/devices/${device.device_id}/secrets`, { auth: device.owner_key, body: { label: "one more" } });
    expect(minted.status).toBe(409);
    expect(await secretRows()).toHaveLength(MAX_SECRETS_PER_DEVICE);

    // Another phone has its own ten, and a deleted secret frees a place.
    await makeSecret(other);
    const gone = secrets[0];
    await gw.request("DELETE", `/v1/devices/${device.device_id}/secrets/${gone?.secret_id}`, { auth: device.owner_key });
    expect((await gw.putSecret(device, newSecret())).status).toBe(201);
    expect((await gw.putSecret(device, newSecret())).status).toBe(409);
  });

  it("answers the same 409 conflict for a push secret that is in another row, of this device or another, and writes nothing", async () => {
    const device = await makeDevice();
    const other = await makeDevice();
    const mine = await makeSecret(device);
    const second = await makeSecret(device, "laptop");
    const theirs = await makeSecret(other);
    const minted = await gw.mint(other, "minted");
    const before = await everything();

    const log = watch();
    const answers = [
      // Under a new id of the same device.
      await gw.putSecret(device, { secret_id: chosenSecretId(), push_secret: mine.push_secret }),
      // In the place of another secret of the same device.
      await gw.putSecret(device, { secret_id: second.secret_id, push_secret: mine.push_secret }),
      // Another device's, under a new id and under its own id.
      await gw.putSecret(device, { secret_id: chosenSecretId(), push_secret: theirs.push_secret }),
      await gw.putSecret(device, { secret_id: theirs.secret_id, push_secret: theirs.push_secret }),
      await gw.putSecret(device, { secret_id: mine.secret_id, push_secret: theirs.push_secret }),
      // One the gateway minted.
      await gw.putSecret(device, { secret_id: chosenSecretId(), push_secret: minted.push_secret }),
    ];
    const bodies = new Set<string>();
    for (const response of answers) {
      expect(response.status).toBe(409);
      bodies.add(await response.text());
    }
    expect([...bodies]).toEqual(['{"error":"conflict","message":"This push secret is already in use."}']);
    expect(log.statements).toHaveLength(answers.length);
    expect(writes(log)).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(await everything()).toEqual(before);
  });

  it("works for a device registered with POST, beside the secrets it minted", async () => {
    const device = await gw.register(SANDBOX_TOKEN);
    const secret = await makeSecret(device, "laptop");
    expect(await pushedTo(secret.push_secret)).toEqual([SANDBOX_TOKEN]);
    expect(await pushedTo(device.push_secret)).toEqual([SANDBOX_TOKEN]);
    const shown = await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key });
    const body = await shown.json<{ secrets: { secret_id: string }[] }>();
    expect(body.secrets.map((s) => s.secret_id).sort()).toEqual([device.secret_id, secret.secret_id].sort());
    expect((await gw.request("DELETE", `/v1/devices/${device.device_id}/secrets/${secret.secret_id}`, { auth: device.owner_key })).status).toBe(204);
    expect((await gw.push(secret.push_secret)).status).toBe(401);
    // Deleted, the same request stores it again.
    expect((await gw.putSecret(device, secret, "laptop")).status).toBe(201);
  });

  it("answers the uniform 401 for a wrong key and for an unknown device, with one read and nothing written", async () => {
    const device = await makeDevice();
    const secret = await makeSecret(device);
    const absent = await chosenDevice();
    const before = await everything();
    const log = watch();
    const answers = [
      await gw.putSecret({ device_id: device.device_id, owner_key: chosenKey() }, secret),
      await gw.putSecret({ device_id: device.device_id, owner_key: chosenKey() }, newSecret()),
      await gw.putSecret(absent, newSecret()),
      await gw.putSecret({ device_id: "x".repeat(27), owner_key: device.owner_key }, newSecret()),
    ];
    for (const response of answers) {
      expect(response.status).toBe(401);
      expect(await response.text()).toBe('{"error":"unauthorized","message":"Missing or invalid credentials."}');
    }
    expect(log.statements).toHaveLength(answers.length);
    expect(writes(log)).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(await everything()).toEqual(before);
  });

  it("is under the management caps when it stores or replaces, and a repeat is not", async () => {
    const device = await makeDevice();
    const secret = await makeSecret(device);
    gw.now = T0 + 7200;
    const fromAddress = counterKey.manageFrom(await sha256Hex(ADDRESS));
    const caps: [string, () => Promise<unknown>, () => Promise<unknown>][] = [
      [
        "the device's",
        () => env.DB.prepare("UPDATE devices SET manage_count = ?1").bind(LIMITS.managePerDevicePerDay.max).run(),
        () => env.DB.prepare("UPDATE devices SET manage_count = 1").run(),
      ],
      [
        "the address's",
        () => env.DB.prepare("UPDATE counters SET count = ?2 WHERE key = ?1").bind(fromAddress, LIMITS.managePerAddressPerDay.max).run(),
        () => env.DB.prepare("UPDATE counters SET count = 1 WHERE key = ?1").bind(fromAddress).run(),
      ],
      [
        "everyone's",
        () => env.DB.prepare("UPDATE counters SET count = ?2 WHERE key = ?1").bind(counterKey.manage(), LIMITS.managePerDay.max).run(),
        () => env.DB.prepare("UPDATE counters SET count = 1 WHERE key = ?1").bind(counterKey.manage()).run(),
      ],
    ];
    for (const [, spend, restore] of caps) {
      await spend();
      const before = await everything();
      const log = watch();
      await expectLimited(await gw.putSecret(device, newSecret()), DAY - 7200);
      await expectLimited(await gw.putSecret(device, { secret_id: secret.secret_id, push_secret: chosenKey() }), DAY - 7200);
      expect((await gw.putSecret(device, secret)).status).toBe(200);
      expect(log.statements).toHaveLength(3);
      expect(writes(log)).toEqual([]);
      expect(log.otherCalls).toBe(0);
      expect(await everything()).toEqual(before);
      gw.env = testEnv;
      await restore();
    }
    expect((await gw.putSecret(device, newSecret())).status).toBe(201);
  });
});

/*
 * The figures the arithmetic in src/limits.ts states for the two routes, as D1 itself
 * counts the rows, from an IPv6 client, which has two address counters.
 */
describe("rows written by the two PUT routes, by D1's own count", () => {
  const written = async (log: DbLog, run: () => Promise<Response>, status: number): Promise<number> => {
    const before = log.rowsWritten;
    expect((await run()).status).toBe(status);
    return log.rowsWritten - before;
  };

  it("a device made writes ROWS.registration, a token update 6, a repeat 0", async () => {
    const device = await chosenDevice();
    const log = watch();
    expect(await written(log, () => gw.putDevice(device, SANDBOX_TOKEN, "sandbox", IPV6), 201)).toBe(ROWS.registration);
    expect(await written(log, () => gw.putDevice(device, SANDBOX_TOKEN, "sandbox", IPV6), 200)).toBe(0);
    const update = await written(log, () => gw.putDevice(device, PRODUCTION_TOKEN, "production", IPV6), 200);
    expect(update).toBe(6);
    expect(update).toBeLessThanOrEqual(ROWS.manage);
    expect(await written(log, () => gw.putDevice(device, PRODUCTION_TOKEN, "production", IPV6), 200)).toBe(0);
    expect(ROWS.registration).toBe(7);
  });

  it("a secret stored and a secret replaced write 6 rows each, a repeat 0, a conflict 0", async () => {
    const device = await makeDevice();
    const other = await makeSecret(await makeDevice());
    const first = newSecret();
    const second: Secret = { secret_id: first.secret_id, push_secret: chosenKey() };
    const log = watch();
    expect(await written(log, () => gw.putSecret(device, first, "studio", IPV6), 201)).toBe(6);
    expect(await written(log, () => gw.putSecret(device, first, "studio", IPV6), 200)).toBe(0);
    expect(await written(log, () => gw.putSecret(device, second, "studio", IPV6), 200)).toBe(6);
    expect(await written(log, () => gw.putSecret(device, second, "studio", IPV6), 200)).toBe(0);
    expect(await written(log, () => gw.putSecret(device, { ...newSecret(), push_secret: other.push_secret }, "x", IPV6), 409)).toBe(0);
  });

  it("a secret stored or replaced writes ROWS.manage when the write also fills the token's hash in", async () => {
    // A row from before `token_hash` gets its hash with its first management write.
    const device = await gw.registerDevice();
    const first = newSecret();
    const log = watch();
    await env.DB.prepare("UPDATE devices SET token_hash = NULL").run();
    expect(await written(log, () => gw.putSecret(device, first, "studio", IPV6), 201)).toBe(ROWS.manage);
    await env.DB.prepare("UPDATE devices SET token_hash = NULL").run();
    const replaced = await written(
      log,
      () => gw.putSecret(device, { secret_id: first.secret_id, push_secret: chosenKey() }, "studio", IPV6),
      200,
    );
    expect(replaced).toBe(ROWS.manage);
    expect(ROWS.manage).toBe(7);
  });
});

describe("a notification reaches only its own phone", () => {
  const TOKEN_A = "a1".repeat(32);
  const TOKEN_B = "b2".repeat(32);

  it("a push with a secret of one phone makes one request to Apple, for that phone's token, whichever route made the device and the secret", async () => {
    // A registered with POST, B with PUT; each holds a minted secret and a chosen one.
    const a = await gw.registerDevice(TOKEN_A);
    const b = await makeDevice(TOKEN_B);
    const secretsOfA = [await gw.mint(a, "minted"), await makeSecret(a, "chosen")];
    const secretsOfB = [await gw.mint(b, "minted"), await makeSecret(b, "chosen")];

    for (const [secrets, own, others] of [
      [secretsOfA, TOKEN_A, TOKEN_B],
      [secretsOfB, TOKEN_B, TOKEN_A],
    ] as const) {
      for (const secret of secrets) {
        const before = gw.calls.length;
        expect((await gw.push(secret.push_secret)).status).toBe(200);
        const sent = gw.calls.slice(before);
        expect(sent).toHaveLength(1);
        expect(sent[0]?.url).toBe(`https://api.sandbox.push.apple.com/3/device/${own}`);
        expect(JSON.stringify(sent)).not.toContain(others);
      }
    }
    expect(gw.calls).toHaveLength(4);
  });

  it("a token update for a phone takes that phone's owner key and no other", async () => {
    const chosenA = await makeDevice(TOKEN_A);
    const postedA = await gw.registerDevice("a3".repeat(32));
    const chosenB = await makeDevice(TOKEN_B);
    const postedB = await gw.registerDevice("b4".repeat(32));
    const before = await everything();

    const log = watch();
    for (const key of [chosenB.owner_key, postedB.owner_key]) {
      // An id the phone chose: the key is not the id's, decided before D1.
      const onChosen = await gw.putDevice({ device_id: chosenA.device_id, owner_key: key }, TOKEN_B);
      expect(onChosen.status).toBe(400);
      expect(log.statements).toEqual([]);
    }
    for (const key of [chosenB.owner_key, postedB.owner_key]) {
      // An id the gateway made: the uniform 401.
      const onPosted = await gw.putDevice({ device_id: postedA.device_id, owner_key: key }, TOKEN_B);
      expect(onPosted.status).toBe(401);
      expect(await onPosted.text()).toBe('{"error":"unauthorized","message":"Missing or invalid credentials."}');
    }
    expect(writes(log)).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(await everything()).toEqual(before);

    // Each phone's own key moves its own token.
    gw.env = testEnv;
    expect((await gw.putDevice(chosenA, "a5".repeat(32))).status).toBe(200);
    expect((await gw.putDevice(postedA, "a6".repeat(32))).status).toBe(200);
    const tokens = Object.fromEntries((await deviceRows()).map((row) => [row.device_id, row.apns_token]));
    expect(tokens).toEqual({
      [chosenA.device_id]: "a5".repeat(32),
      [postedA.device_id]: "a6".repeat(32),
      [chosenB.device_id]: TOKEN_B,
      [postedB.device_id]: "b4".repeat(32),
    });
  });

  it("a secret belongs to one phone for good: no request stores it for another, and secret ids are each phone's own", async () => {
    const a = await makeDevice(TOKEN_A);
    const b = await makeDevice(TOKEN_B);
    const secretOfA = await makeSecret(a, "studio");
    const rowOfA = await secretRows();

    // B asks for A's push secret under the id A uses: refused, and A's secret is as it was.
    const taken = await gw.putSecret(b, secretOfA);
    expect(taken.status).toBe(409);
    expect((await errorOf(taken)).error).toBe("conflict");
    expect(await secretRows()).toEqual(rowOfA);
    expect(await pushedTo(secretOfA.push_secret)).toEqual([TOKEN_A]);

    // B stores a secret of its own under that same id: ids are per device, so both exist.
    const secretOfB: Secret = { secret_id: secretOfA.secret_id, push_secret: chosenKey() };
    expect((await gw.putSecret(b, secretOfB, "laptop")).status).toBe(201);
    expect(await pushedTo(secretOfB.push_secret)).toEqual([TOKEN_B]);
    expect(await pushedTo(secretOfA.push_secret)).toEqual([TOKEN_A]);
    const rows = await secretRows();
    expect(rows).toHaveLength(2);
    expect(rows).toContainEqual(rowOfA[0]);
    expect(rows).toContainEqual(expect.objectContaining({ device_id: b.device_id, secret_id: secretOfA.secret_id, label: "laptop" }));

    // Every route B has that names a secret, aimed at A's: A's row keeps its device.
    expect((await gw.putSecret(b, { secret_id: secretOfB.secret_id, push_secret: secretOfA.push_secret })).status).toBe(409);
    expect((await gw.putSecret(b, { secret_id: chosenSecretId(), push_secret: secretOfA.push_secret })).status).toBe(409);
    expect((await gw.request("DELETE", `/v1/devices/${b.device_id}/secrets/${secretOfA.secret_id}`, { auth: b.owner_key })).status).toBe(204);
    expect((await gw.putDevice(b, "b7".repeat(32))).status).toBe(200);
    expect(await secretRows()).toEqual(rowOfA);
    expect(await pushedTo(secretOfA.push_secret)).toEqual([TOKEN_A]);
    // B's own secret under that id went with B's delete, and A's key can't reach B.
    expect((await gw.push(secretOfB.push_secret)).status).toBe(401);
    expect((await gw.putSecret({ device_id: b.device_id, owner_key: a.owner_key }, secretOfA)).status).toBe(401);
  });
});
