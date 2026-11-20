import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { sha256Hex } from "../src/encoding";
import { LIMITS } from "../src/limits";
import { purge } from "../src/purge";
import { Gateway, SANDBOX_TOKEN, T0, appleError, reset } from "./helpers";

/**
 * Migrations after 0003 only add. This file puts the database where a deployed one stands
 * at 0003, with a registration in it, applies what comes after, and uses the rows.
 */

const DAY = 86400;
const TODAY = T0 / DAY;
const OWNER_KEY = "o".repeat(43);
const PUSH_SECRET = "p".repeat(43);
const OTHER_KEY = "k".repeat(43);
const OTHER_SECRET = "s".repeat(43);

function migration(prefix: string): string[] {
  const found = env.TEST_MIGRATIONS.find((m) => m.name.startsWith(prefix));
  if (!found) throw new Error(`no migration ${prefix}`);
  return found.queries;
}

async function run(queries: string[]): Promise<void> {
  await env.DB.batch(queries.map((query) => env.DB.prepare(query)));
}

/** The migrations after 0003, in order. */
function later(): { name: string; queries: string[] }[] {
  return env.TEST_MIGRATIONS.filter((m) => m.name >= "0004").sort((a, b) => a.name.localeCompare(b.name));
}

/** The schema of 0003 with two phones in it, written with the columns 0003 has. */
async function databaseAt0003(): Promise<void> {
  // 0003 makes its three tables anew, which also takes away what later migrations added.
  await run(migration("0003_"));
  const device = env.DB.prepare(
    `INSERT INTO devices
       (device_id, owner_hash, apns_token, environment, created_at, updated_at, push_day, push_count, manage_day, manage_count)
     VALUES (?1, ?2, ?3, 'sandbox', ?4, ?4, ?5, ?6, ?5, ?7)`,
  );
  const secret = env.DB.prepare(
    "INSERT INTO secrets (secret_hash, device_id, secret_id, label, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
  );
  await env.DB.batch([
    device.bind("phone-one", await sha256Hex(OWNER_KEY), SANDBOX_TOKEN, T0 - 30 * DAY, TODAY, 7, 2),
    device.bind("phone-two", await sha256Hex(OTHER_KEY), SANDBOX_TOKEN, T0 - 20 * DAY, TODAY - 1, 40, 0),
    secret.bind(await sha256Hex(PUSH_SECRET), "phone-one", "secret-one", "studio", T0 - 30 * DAY),
    secret.bind(await sha256Hex(OTHER_SECRET), "phone-two", "secret-two", "laptop", T0 - 20 * DAY),
    env.DB.prepare("INSERT INTO counters (key, count, expires_at) VALUES ('sends', 47, ?1)").bind(T0 + DAY),
  ]);
}

async function table(name: string): Promise<Record<string, unknown>[]> {
  return (await env.DB.prepare(`SELECT * FROM ${name} ORDER BY 1`).all()).results;
}

let gw: Gateway;
beforeEach(async () => {
  await reset();
  gw = new Gateway();
});

describe("the migrations after 0003", () => {
  it("only add: no statement drops a table or deletes rows", () => {
    const migrations = later();
    expect(migrations.map((m) => m.name)).toEqual(["0004_token_hash_and_dead.sql", "0005_secret_presence.sql"]);
    for (const { queries } of migrations) {
      for (const query of queries) {
        // A file of one statement comes back with its comments, which are not SQL.
        const statement = query.replace(/^\s*--.*$/gm, "");
        expect(statement).toMatch(/^\s*(ALTER TABLE \w+ ADD COLUMN|CREATE TABLE IF NOT EXISTS|CREATE (UNIQUE )?INDEX IF NOT EXISTS|UPDATE)\b/i);
        expect(statement).not.toMatch(/DROP|DELETE/i);
      }
    }
  });

  it("keep every row of a database at 0003, with the new columns at their starting values", async () => {
    await databaseAt0003();
    const before = { devices: await table("devices"), secrets: await table("secrets"), counters: await table("counters") };
    expect(before.devices).toHaveLength(2);
    expect(Object.keys(before.devices[0] ?? {})).not.toContain("token_hash");

    for (const { queries } of later()) await run(queries);

    expect(await table("secrets")).toEqual(before.secrets.map((row) => ({ ...row, presence: 0 })));
    expect(await table("counters")).toEqual(before.counters);
    expect(await table("devices")).toEqual(before.devices.map((row) => ({ ...row, token_hash: null, dead: 0 })));
  });

  it("leave the rows usable: the phone pushes, reads, mints, changes its token and deletes as before", async () => {
    await databaseAt0003();
    for (const { queries } of later()) await run(queries);

    // The secret minted before the migration pushes, and the day's count goes on from 7.
    expect((await gw.push(PUSH_SECRET)).status).toBe(200);
    expect(gw.calls[0]?.url).toContain(SANDBOX_TOKEN);
    const pushed = await env.DB.prepare("SELECT push_count, token_hash FROM devices WHERE device_id = 'phone-one'").first();
    expect(pushed).toEqual({ push_count: 8, token_hash: null });
    expect((await env.DB.prepare("SELECT count FROM counters WHERE key = 'sends'").first<{ count: number }>())?.count).toBe(48);

    // The owner key from before reads the device and its secret.
    const shown = await gw.request("GET", "/v1/devices/phone-one", { auth: OWNER_KEY });
    expect(shown.status).toBe(200);
    expect(await shown.json()).toEqual({
      environment: "sandbox",
      secrets: [{ secret_id: "secret-one", label: "studio", created_at: T0 - 30 * DAY }],
    });

    // The first management write fills the token's hash in and counts on from 2.
    const minted = await gw.request("POST", "/v1/devices/phone-one/secrets", { auth: OWNER_KEY, body: { label: "laptop" } });
    expect(minted.status).toBe(201);
    expect(await env.DB.prepare("SELECT manage_count, token_hash, dead FROM devices WHERE device_id = 'phone-one'").first()).toEqual({
      manage_count: 3,
      token_hash: await sha256Hex(SANDBOX_TOKEN),
      dead: 0,
    });
    expect((await gw.push((await minted.json<{ push_secret: string }>()).push_secret)).status).toBe(200);

    // The other phone, on a new day, with a token change and a delete.
    gw.now = T0 + DAY;
    expect((await gw.push(OTHER_SECRET)).status).toBe(200);
    const change = { apns_token: "7c".repeat(32), environment: "production" };
    expect((await gw.request("PUT", "/v1/devices/phone-two", { auth: OTHER_KEY, body: change })).status).toBe(200);
    expect(await env.DB.prepare("SELECT token_hash, environment FROM devices WHERE device_id = 'phone-two'").first()).toEqual({
      token_hash: await sha256Hex("7c".repeat(32)),
      environment: "production",
    });
    expect((await gw.request("DELETE", "/v1/devices/phone-two/secrets/secret-two", { auth: OTHER_KEY })).status).toBe(204);
    expect((await gw.push(OTHER_SECRET)).status).toBe(401);
    expect((await gw.request("DELETE", "/v1/devices/phone-two", { auth: OTHER_KEY })).status).toBe(204);
    expect((await table("devices")).map((row) => row.device_id)).toEqual(["phone-one"]);
  });

  it("leave the rows under the limits: the token's cap, a dead token and the purge", async () => {
    await databaseAt0003();
    for (const { queries } of later()) await run(queries);

    // A row without a hash is capped on its own count.
    await env.DB.prepare("UPDATE devices SET push_count = ?1 WHERE device_id = 'phone-one'")
      .bind(LIMITS.pushPerTokenPerDay.max)
      .run();
    expect((await gw.push(PUSH_SECRET)).status).toBe(429);

    // It is marked dead like any other, and purged.
    gw.apple = appleError(410, "Unregistered");
    expect((await gw.push(OTHER_SECRET)).status).toBe(410);
    expect((await gw.push(OTHER_SECRET)).status).toBe(410);
    expect(gw.calls).toHaveLength(1);
    expect((await purge(env.DB, T0 + 60)).devices).toBe(1);
    expect((await table("devices")).map((row) => row.device_id)).toEqual(["phone-one"]);
    expect((await table("secrets")).map((row) => row.secret_id)).toEqual(["secret-one"]);
  });

  it("can be applied to a database that has them: the test database is at the last one", async () => {
    const columns = (await env.DB.prepare("SELECT name FROM pragma_table_info('devices')").all<{ name: string }>()).results.map(
      (r) => r.name,
    );
    expect(columns).toEqual(expect.arrayContaining(["token_hash", "dead"]));
    const secretColumns = (await env.DB.prepare("SELECT name FROM pragma_table_info('secrets')").all<{ name: string }>()).results;
    expect(secretColumns.map((r) => r.name)).toContain("presence");
    const index = await env.DB.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'devices_token'").first();
    expect(index).not.toBeNull();
  });
});
