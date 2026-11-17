import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { LIMITS, MAX_SECRETS_PER_DEVICE, PURGE_COUNTERS_PER_RUN, PURGE_DEVICES_PER_RUN, ROWS } from "../src/limits";
import { purge } from "../src/purge";
import {
  type DbLog,
  Gateway,
  PAYLOAD,
  PRODUCTION_TOKEN,
  type Registered,
  SANDBOX_TOKEN,
  T0,
  appleError,
  isWrite,
  reset,
  spyOnDb,
  testEnv,
} from "./helpers";

/**
 * The gateway keeps to a daily budget of rows written to D1, so these tests watch the
 * binding itself: what a request that fails a cheap check costs (nothing), and what a push
 * costs (two rows).
 */

let gw: Gateway;
let device: Registered;
let log: DbLog;
let spied: D1Database;
beforeEach(async () => {
  await reset();
  gw = new Gateway();
  device = await gw.register();
  const spy = spyOnDb(env.DB);
  spied = spy.db;
  gw.env = { ...testEnv, DB: spied };
  log = spy.log;
});

const PUSH = { payload: PAYLOAD, push_type: "alert" };
const REGISTRATION = { apns_token: PRODUCTION_TOKEN, environment: "production" };

/** A body the bounded read must stop, with no Content-Length to refuse it early. */
function endlessBody(): ReadableStream<Uint8Array> {
  const chunk = new TextEncoder().encode("x".repeat(3000));
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      controller.enqueue(chunk);
    },
  });
}

describe("requests that make no D1 call", () => {
  type Options = Parameters<Gateway["request"]>[2];
  const cases: [string, number, () => [string, string, Options]][] = [
    ["health", 200, () => ["GET", "/v1/health", {}]],
    ["an unknown route", 404, () => ["GET", "/v1/nope", {}]],
    ["an unknown route with a real credential", 404, () => ["POST", "/v1/pushes", { auth: device.push_secret, body: PUSH }]],
    ["the removed rotate route", 404, () => ["POST", `/v1/devices/${device.device_id}/rotate`, { auth: device.owner_key }]],
    ["a wrong method on push", 405, () => ["GET", "/v1/push", { auth: device.push_secret }]],
    ["a wrong method on devices", 405, () => ["PUT", "/v1/devices", { body: REGISTRATION }]],
    ["a wrong method on a device", 405, () => ["POST", `/v1/devices/${device.device_id}`, { auth: device.owner_key }]],
    ["a wrong method on secrets", 405, () => ["GET", `/v1/devices/${device.device_id}/secrets`, { auth: device.owner_key }]],
    ["a wrong method on a secret", 405, () => ["GET", `/v1/devices/${device.device_id}/secrets/${device.secret_id}`, { auth: device.owner_key }]],

    ["a push without a bearer", 401, () => ["POST", "/v1/push", { body: PUSH }]],
    ["a push with a short bearer", 401, () => ["POST", "/v1/push", { auth: "short", body: PUSH }]],
    ["a push with a 44-character bearer", 401, () => ["POST", "/v1/push", { auth: "A".repeat(44), body: PUSH }]],
    ["a push with a bearer that is not url-safe", 401, () => ["POST", "/v1/push", { auth: `${"A".repeat(42)}+`, body: PUSH }]],
    ["a push with Basic auth", 401, () => ["POST", "/v1/push", { headers: { authorization: `Basic ${device.push_secret}` }, body: PUSH }]],
    ["GET device with a malformed bearer", 401, () => ["GET", `/v1/devices/${device.device_id}`, { auth: "nope" }]],
    ["GET device without a bearer", 401, () => ["GET", `/v1/devices/${device.device_id}`, {}]],
    ["PUT device with a malformed bearer", 401, () => ["PUT", `/v1/devices/${device.device_id}`, { auth: "nope", body: REGISTRATION }]],
    ["DELETE device with a malformed bearer", 401, () => ["DELETE", `/v1/devices/${device.device_id}`, { auth: "nope" }]],
    ["POST secrets with a malformed bearer", 401, () => ["POST", `/v1/devices/${device.device_id}/secrets`, { auth: "nope", body: { label: "x" } }]],
    ["DELETE secret with a malformed bearer", 401, () => ["DELETE", `/v1/devices/${device.device_id}/secrets/${device.secret_id}`, { auth: "nope" }]],

    ["a push whose Content-Length is over the limit", 413, () => ["POST", "/v1/push", { auth: device.push_secret, raw: "{}", headers: { "content-length": "8193" } }]],
    ["a push whose streamed body is over the limit", 413, () => ["POST", "/v1/push", { auth: device.push_secret, raw: endlessBody() }]],
    ["a push whose payload is over 4096 bytes", 413, () => ["POST", "/v1/push", { auth: device.push_secret, body: { payload: { ...PAYLOAD, server: "x".repeat(4200) } } }]],
    ["a registration with an oversized body", 413, () => ["POST", "/v1/devices", { raw: endlessBody() }]],
    ["a token change with an oversized body", 413, () => ["PUT", `/v1/devices/${device.device_id}`, { auth: device.owner_key, raw: endlessBody() }]],
    ["a secret with an oversized body", 413, () => ["POST", `/v1/devices/${device.device_id}/secrets`, { auth: device.owner_key, raw: endlessBody() }]],

    ["a push that is not JSON", 400, () => ["POST", "/v1/push", { auth: device.push_secret, raw: "{nope" }]],
    ["a push without a body", 400, () => ["POST", "/v1/push", { auth: device.push_secret }]],
    ["a push that is not UTF-8", 400, () => ["POST", "/v1/push", { auth: device.push_secret, raw: new Uint8Array([0x7b, 0xff, 0x7d]) }]],
    ["a push of an unsupported type", 400, () => ["POST", "/v1/push", { auth: device.push_secret, body: { payload: PAYLOAD, push_type: "voip" } }]],
    ["a push whose payload has no alert", 400, () => ["POST", "/v1/push", { auth: device.push_secret, body: { payload: { aps: { sound: "default" } } } }]],
    ["a push whose payload holds another top-level field", 400, () => ["POST", "/v1/push", { auth: device.push_secret, body: { payload: { ...PAYLOAD, extra: "x" } } }]],
    ["a push whose aps holds another field", 400, () => ["POST", "/v1/push", { auth: device.push_secret, body: { payload: { ...PAYLOAD, aps: { ...PAYLOAD.aps, badge: 1 } } } }]],
    ["a push with another category", 400, () => ["POST", "/v1/push", { auth: device.push_secret, body: { payload: { ...PAYLOAD, aps: { ...PAYLOAD.aps, category: "OTHER" } } } }]],
    ["a push with a title that is too long", 400, () => ["POST", "/v1/push", { auth: device.push_secret, body: { payload: { ...PAYLOAD, aps: { ...PAYLOAD.aps, alert: { title: "t".repeat(121), body: "b" } } } } }]],
    ["a registration that is not JSON", 400, () => ["POST", "/v1/devices", { raw: "{nope" }]],
    ["a registration with a bad token", 400, () => ["POST", "/v1/devices", { body: { apns_token: "bad", environment: "sandbox" } }]],
    ["a token change that is not JSON", 400, () => ["PUT", `/v1/devices/${device.device_id}`, { auth: device.owner_key, raw: "{nope" }]],
    ["a token change with a bad token", 400, () => ["PUT", `/v1/devices/${device.device_id}`, { auth: device.owner_key, body: { apns_token: "bad" } }]],
    ["a secret that is not JSON", 400, () => ["POST", `/v1/devices/${device.device_id}/secrets`, { auth: device.owner_key, raw: "{nope" }]],
    ["a secret with a bad label", 400, () => ["POST", `/v1/devices/${device.device_id}/secrets`, { auth: device.owner_key, body: { label: "" } }]],
  ];

  it.each(cases)("%s answers %i", async (_name, status, build) => {
    const [method, path, options] = build();
    const response = await gw.request(method, path, options);
    expect(response.status).toBe(status);
    expect(log.statements).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(gw.calls).toHaveLength(0);
  });

  it("the spy does see a request that reaches D1", async () => {
    expect((await gw.request("GET", `/v1/devices/${device.device_id}`, { auth: device.owner_key })).status).toBe(200);
    expect(log.statements.length).toBeGreaterThan(0);
  });
});

describe("what a request costs D1", () => {
  const writes = (): string[] => log.statements.filter(isWrite);

  it("a successful push: one read and two rows written", async () => {
    for (let i = 1; i <= 3; i++) {
      gw.now = T0 + i * 4000;
      expect((await gw.push(device.push_secret)).status).toBe(200);
      expect(log.statements).toHaveLength(3 * i);
      expect(writes().length).toBeLessThanOrEqual(2 * i);
    }
    expect(writes()).toHaveLength(6);
    // The two writes go in one batch, and D1 itself reports two rows for each.
    expect(log.batchRowsWritten).toEqual([2, 2, 2]);
    expect(log.otherCalls).toBe(3);
    expect(writes().filter((sql) => /UPDATE devices/.test(sql))).toHaveLength(3);
    expect(writes().filter((sql) => /INSERT INTO counters/.test(sql))).toHaveLength(3);
    // The secret's row is not written by a push.
    expect(writes().filter((sql) => /secrets/.test(sql))).toEqual([]);
    expect(log.rowsWritten).toBe(6);
    expect(ROWS.push).toBe(2);
  });

  it("a successful push through each of ten secrets: two rows each", async () => {
    gw.env = testEnv;
    const secrets = [device.push_secret];
    while (secrets.length < MAX_SECRETS_PER_DEVICE) secrets.push((await gw.mint(device, "helper")).push_secret);
    gw.env = { ...testEnv, DB: spied };
    for (const secret of secrets) expect((await gw.push(secret)).status).toBe(200);
    expect(log.batchRowsWritten).toEqual(new Array(10).fill(2));
    expect(writes()).toHaveLength(20);
  });

  it("a push on a new UTC day: still two rows", async () => {
    expect((await gw.push(device.push_secret)).status).toBe(200);
    gw.now = T0 + 86400 + 5;
    expect((await gw.push(device.push_secret)).status).toBe(200);
    expect(log.batchRowsWritten).toEqual([2, 2]);
  });

  it("a push Apple refuses with an error: the same two rows", async () => {
    gw.apple = appleError(503, "ServiceUnavailable");
    expect((await gw.push(device.push_secret)).status).toBe(502);
    expect(writes()).toHaveLength(2);
    expect(log.batchRowsWritten).toEqual([2]);
  });

  it("a push with an unknown secret: one read, nothing written", async () => {
    for (let i = 0; i < 5; i++) expect((await gw.push("B".repeat(43))).status).toBe(401);
    expect(log.statements).toHaveLength(5);
    expect(writes()).toEqual([]);
    expect(log.otherCalls).toBe(0);
  });

  it("a push past its token's daily cap: one read, nothing written", async () => {
    await env.DB.prepare("UPDATE devices SET push_count = ?1").bind(LIMITS.pushPerTokenPerDay.max).run();
    for (let i = 0; i < 5; i++) expect((await gw.push(device.push_secret)).status).toBe(429);
    expect(log.statements).toHaveLength(5);
    expect(writes()).toEqual([]);
    expect(log.otherCalls).toBe(0);
  });

  it("a push past the global daily cap: one read, nothing written", async () => {
    await env.DB.prepare("INSERT INTO counters (key, count, expires_at) VALUES ('sends', ?1, ?2)")
      .bind(LIMITS.pushPerDay.max, T0 + 86400)
      .run();
    for (let i = 0; i < 5; i++) expect((await gw.push(device.push_secret)).status).toBe(429);
    expect(log.statements).toHaveLength(5);
    expect(writes()).toEqual([]);
    expect(log.otherCalls).toBe(0);
  });

  it("a push to a token Apple no longer accepts: the same two rows, which also mark the device", async () => {
    gw.apple = appleError(410, "Unregistered");
    expect((await gw.push(device.push_secret)).status).toBe(410);
    expect(log.statements).toHaveLength(3);
    expect(writes()).toHaveLength(2);
    expect(log.batchRowsWritten).toEqual([2]);
    expect(log.rowsWritten).toBe(2);
  });

  it("a push for a device marked dead: one read, nothing written, Apple not asked", async () => {
    await env.DB.prepare("UPDATE devices SET dead = 1").run();
    for (let i = 0; i < 5; i++) expect((await gw.push(device.push_secret)).status).toBe(410);
    expect(log.statements).toHaveLength(5);
    expect(writes()).toEqual([]);
    expect(log.otherCalls).toBe(0);
    expect(log.rowsWritten).toBe(0);
    expect(gw.calls).toHaveLength(0);
  });

  it("a successful push to a token three devices share: two rows", async () => {
    gw.env = testEnv;
    const sharing = [device, await gw.register(SANDBOX_TOKEN), await gw.register(SANDBOX_TOKEN)];
    gw.env = { ...testEnv, DB: spied };
    for (const one of sharing) expect((await gw.push(one.push_secret)).status).toBe(200);
    expect(log.batchRowsWritten).toEqual([2, 2, 2]);
    expect(log.rowsWritten).toBe(6);
    expect(log.statements).toHaveLength(9);
  });

  it("a management write: one read, its counts in one batch, then the change", async () => {
    const base = `/v1/devices/${device.device_id}`;
    const minted = await gw.request("POST", `${base}/secrets`, { auth: device.owner_key, body: { label: "laptop" } });
    expect(minted.status).toBe(201);
    expect(log.statements).toHaveLength(5);
    expect(log.batchRowsWritten).toEqual([3]);
    expect(writes().filter((sql) => /INSERT INTO secrets/.test(sql))).toHaveLength(1);

    const { secret_id: secretId } = await minted.json<{ secret_id: string }>();
    expect((await gw.request("DELETE", `${base}/secrets/${secretId}`, { auth: device.owner_key })).status).toBe(204);
    expect((await gw.request("PUT", base, { auth: device.owner_key, body: REGISTRATION })).status).toBe(200);
    // The mint and the token change count on the device, the address and their budget; the
    // delete on the device and the budget for deletes.
    expect(log.batchRowsWritten).toEqual([3, 2, 3]);

    // Deleting the device counts on the budget for deletes only: its row goes.
    expect((await gw.request("DELETE", base, { auth: device.owner_key })).status).toBe(204);
    expect(log.batchRowsWritten).toEqual([3, 2, 3, 1]);
    // A mint or a token change: a read, three counts and the change. A delete: one count fewer.
    expect(log.statements).toHaveLength(5 * 2 + 4 + 3);
  });

  it("a management write past the device's daily cap: one read, nothing written", async () => {
    await env.DB.prepare("UPDATE devices SET manage_count = ?1").bind(LIMITS.managePerDevicePerDay.max).run();
    const base = `/v1/devices/${device.device_id}`;
    const answers = [
      await gw.request("POST", `${base}/secrets`, { auth: device.owner_key, body: { label: "laptop" } }),
      await gw.request("DELETE", `${base}/secrets/${device.secret_id}`, { auth: device.owner_key }),
      await gw.request("PUT", base, { auth: device.owner_key, body: REGISTRATION }),
    ];
    expect(answers.map((r) => r.status)).toEqual([429, 429, 429]);
    expect(log.statements).toHaveLength(3);
    expect(writes()).toEqual([]);
    expect(log.otherCalls).toBe(0);
    // Deleting the device is not held back by its own count: its owner can always turn it off.
    expect((await gw.request("DELETE", base, { auth: device.owner_key })).status).toBe(204);
  });

  it("a wrong owner key: one read, nothing written, on every owner-key route", async () => {
    const wrong = "A".repeat(43);
    const base = `/v1/devices/${device.device_id}`;
    await gw.request("GET", base, { auth: wrong });
    await gw.request("PUT", base, { auth: wrong, body: { apns_token: SANDBOX_TOKEN, environment: "sandbox" } });
    await gw.request("POST", `${base}/secrets`, { auth: wrong, body: { label: "x" } });
    await gw.request("DELETE", `${base}/secrets/${device.secret_id}`, { auth: wrong });
    await gw.request("DELETE", base, { auth: wrong });
    expect(log.statements).toHaveLength(5);
    expect(writes()).toEqual([]);
    expect(log.otherCalls).toBe(0);
  });

  /*
   * The dearest of each kind, as D1 itself counts the rows: an IPv6 client, which has two
   * address counters, and a device that holds the most secrets. These are the figures the
   * arithmetic in src/limits.ts multiplies the budgets by.
   */
  describe("at its dearest, by D1's own count of rows written", () => {
    const ip = "2001:db8:1:2::1";
    const written = async (run: () => Promise<Response>, status: number): Promise<number> => {
      const before = log.rowsWritten;
      expect((await run()).status).toBe(status);
      return log.rowsWritten - before;
    };

    it("a registration writes ROWS.registration", async () => {
      const rows = await written(
        () => gw.request("POST", "/v1/devices", { body: REGISTRATION, ip }),
        201,
      );
      expect(rows).toBe(ROWS.registration);
    });

    it("minting a secret and a token change write 6 rows, and ROWS.manage when the write fills the token's hash in", async () => {
      const base = `/v1/devices/${device.device_id}`;
      const mint = await written(
        () => gw.request("POST", `${base}/secrets`, { auth: device.owner_key, body: { label: "laptop" }, ip }),
        201,
      );
      const change = await written(() => gw.request("PUT", base, { auth: device.owner_key, body: REGISTRATION, ip }), 200);
      expect(mint).toBe(6);
      expect(change).toBe(6);

      // A row from before `token_hash` gets its hash with its first management write.
      await env.DB.prepare("UPDATE devices SET token_hash = NULL").run();
      const filling = await written(
        () => gw.request("POST", `${base}/secrets`, { auth: device.owner_key, body: { label: "studio 2" }, ip }),
        201,
      );
      expect(filling).toBe(ROWS.manage);
      expect(ROWS.manage).toBe(7);
    });

    it("deleting a secret writes at most 4 rows, and deleting a device with ten secrets at most ROWS.delete", async () => {
      gw.env = testEnv;
      const secrets = [device.secret_id];
      while (secrets.length < MAX_SECRETS_PER_DEVICE) secrets.push((await gw.mint(device, "helper")).secret_id);
      const spare = await gw.mint(await gw.registerDevice(), "spare");
      gw.env = { ...testEnv, DB: spied };

      const base = `/v1/devices/${device.device_id}`;
      expect(await written(() => gw.request("DELETE", `${base}/secrets/${secrets[0]}`, { auth: device.owner_key, ip }), 204)).toBeLessThanOrEqual(4);
      gw.env = testEnv;
      await gw.mint(device, "helper");
      gw.env = { ...testEnv, DB: spied };
      const deleted = await written(() => gw.request("DELETE", base, { auth: device.owner_key, ip }), 204);
      // One counter, the device and its ten secrets; the arithmetic also counts every index entry.
      expect(deleted).toBeGreaterThanOrEqual(12);
      expect(deleted).toBeLessThanOrEqual(ROWS.delete);
      expect(ROWS.delete).toBe(23);
      expect(spare.secret_id).not.toBe("");
    });

    it("the purge writes at most 22 rows for a device", async () => {
      gw.env = testEnv;
      while ((await env.DB.prepare("SELECT COUNT(*) AS n FROM secrets").first<{ n: number }>())?.n !== MAX_SECRETS_PER_DEVICE) {
        await gw.mint(device, "helper");
      }
      const before = log.rowsWritten;
      expect(await purge(spied, T0 + 400 * 86400)).toMatchObject({ devices: 1 });
      // Besides the device, the purge took the counters of its registration and its mints.
      expect(log.rowsWritten - before).toBeGreaterThanOrEqual(11);
      expect(log.rowsWritten - before).toBeLessThanOrEqual(22 + PURGE_COUNTERS_PER_RUN);
      expect(ROWS.purge).toBe(PURGE_DEVICES_PER_RUN * 22 + PURGE_COUNTERS_PER_RUN);
    });
  });
});
