import { env } from "cloudflare:test";
import { dropProviderToken } from "../src/apns";
import type { Env } from "../src/env";
import { handleRequest } from "../src/index";

/** 2027-01-16 00:00:00 UTC: the start of a day, an hour, a 30-minute bucket and a minute. */
export const T0 = 1_800_057_600;

export const SANDBOX_TOKEN = "ab".repeat(32);
export const PRODUCTION_TOKEN = "CD".repeat(40);

/** A well-formed APNs token of its own for every `n`. */
export function tokenNumber(n: number): string {
  return n.toString(16).padStart(64, "0");
}

/** A throwaway P-256 key made for this test run. Never a real APNs key. */
async function makeKey(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const base64 = btoa(String.fromCharCode(...der));
  const lines = base64.match(/.{1,64}/g) ?? [];
  return {
    pem: `-----BEGIN PRIVATE KEY-----\n${lines.join("\n")}\n-----END PRIVATE KEY-----\n`,
    publicKey: pair.publicKey,
  };
}

export const testKey = await makeKey();

/**
 * Without the Rate Limiting bindings: the local ones count in real time, and these tests set
 * their own clock. A test that wants a limiter gives the gateway a fake one.
 */
export const testEnv: Env = {
  ...env,
  APNS_KEY_P8: testKey.pem,
  RL_ADDRESS: undefined,
  RL_SECRET: undefined,
  RL_GLOBAL: undefined,
};

/** A Rate Limiting binding that records the keys it is asked about and refuses on demand. */
export class FakeLimiter implements RateLimit {
  keys: string[] = [];
  refuse: (key: string) => boolean = () => false;

  async limit(options: RateLimitOptions): Promise<RateLimitOutcome> {
    this.keys.push(options.key);
    return { success: !this.refuse(options.key) };
  }
}

/** What a test saw the Worker do with D1. */
export interface DbLog {
  /** The text of every statement prepared, in order. */
  statements: string[];
  /** Calls to `batch`, `exec` and `dump`. */
  otherCalls: number;
  /** `rows_written` as D1 reported it for each batch. */
  batchRowsWritten: number[];
  /** `rows_written` as D1 reported it, summed over every batch, `run` and `all`. */
  rowsWritten: number;
}

export function isWrite(sql: string): boolean {
  return /^\s*(INSERT|UPDATE|DELETE|REPLACE)\b/i.test(sql);
}

/** The real local D1 behind a wrapper that records every use of the binding. */
export function spyOnDb(db: D1Database): { db: D1Database; log: DbLog } {
  const log: DbLog = { statements: [], otherCalls: 0, batchRowsWritten: [], rowsWritten: 0 };
  // `batch` needs D1's own statements, so each wrapper remembers the one it stands for.
  const real = new WeakMap<object, D1PreparedStatement>();
  const watch = (statement: D1PreparedStatement): D1PreparedStatement => {
    const wrapper = new Proxy(statement, {
      get(target, property) {
        const value: unknown = Reflect.get(target, property, target);
        if (typeof value !== "function") return value;
        if (property === "bind") return (...values: unknown[]) => watch(target.bind(...values));
        if (property === "run" || property === "all") {
          return async (...args: unknown[]) => {
            const result = (await (value as (...a: unknown[]) => unknown).apply(target, args)) as D1Result;
            log.rowsWritten += result.meta.rows_written;
            return result;
          };
        }
        return (...args: unknown[]) => (value as (...a: unknown[]) => unknown).apply(target, args);
      },
    });
    real.set(wrapper, statement);
    return wrapper;
  };
  const spy = new Proxy(db, {
    get(target, property) {
      if (property === "prepare") {
        return (sql: string) => {
          log.statements.push(sql);
          return watch(target.prepare(sql));
        };
      }
      if (property === "batch") {
        return async (statements: D1PreparedStatement[]) => {
          log.otherCalls++;
          const results = await target.batch(statements.map((statement) => real.get(statement) ?? statement));
          const written = results.reduce((sum, r) => sum + r.meta.rows_written, 0);
          log.batchRowsWritten.push(written);
          log.rowsWritten += written;
          return results;
        };
      }
      const value: unknown = Reflect.get(target, property, target);
      if (typeof value !== "function") return value;
      return (...args: unknown[]) => {
        log.otherCalls++;
        return (value as (...a: unknown[]) => unknown).apply(target, args);
      };
    },
  });
  return { db: spy, log };
}

export interface AppleCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string;
}

export interface Device {
  device_id: string;
  owner_key: string;
}

export interface Secret {
  secret_id: string;
  push_secret: string;
}

/** A phone that registered and minted one secret for a helper. */
export type Registered = Device & Secret;

interface Options {
  auth?: string;
  /** Sent as JSON. */
  body?: unknown;
  /** Sent as is, instead of `body`. */
  raw?: BodyInit;
  headers?: Record<string, string>;
  ip?: string;
}

/** Runs requests through the Worker's handler with a fake Apple and a clock the test sets. */
export class Gateway {
  now = T0;
  /** The bindings the Worker gets. Replace `DB` or the limiters to watch or steer them. */
  env: Env = testEnv;
  /** Requests made through this gateway, which is also the number of log lines. */
  requests = 0;
  calls: AppleCall[] = [];
  /** What Apple answers. Replace it to fail. */
  apple: (call: AppleCall) => Response | Promise<Response> = () =>
    new Response(null, { status: 200, headers: { "apns-id": "11111111-2222-3333-4444-555555555555" } });

  request(method: string, path: string, options: Options = {}): Promise<Response> {
    const headers = new Headers(options.headers);
    headers.set("cf-connecting-ip", options.ip ?? "203.0.113.7");
    if (options.auth !== undefined) headers.set("authorization", `Bearer ${options.auth}`);
    const body = options.raw ?? (options.body === undefined ? undefined : JSON.stringify(options.body));
    this.requests++;
    return handleRequest(new Request(`https://gateway.test${path}`, { method, headers, body }), this.env, {
      now: () => this.now,
      fetch: async (url, init) => {
        const call: AppleCall = {
          url,
          method: init.method ?? "GET",
          headers: init.headers as Record<string, string>,
          body: init.body as string,
        };
        this.calls.push(call);
        return this.apple(call);
      },
    });
  }

  private registered = 0;

  /**
   * Registers a phone, without a secret. Without a token, the first phone of this gateway
   * gets `SANDBOX_TOKEN` and every later one a token of its own, as phones have.
   */
  async registerDevice(token?: string, environment = "sandbox", ip?: string): Promise<Device> {
    token ??= this.registered === 0 ? SANDBOX_TOKEN : tokenNumber(this.registered);
    this.registered++;
    const response = await this.request("POST", "/v1/devices", {
      body: { apns_token: token, environment },
      ...(ip === undefined ? {} : { ip }),
    });
    if (response.status !== 201) throw new Error(`registration answered ${response.status}`);
    return response.json();
  }

  async mint(device: Device, label = "studio"): Promise<Secret> {
    const response = await this.request("POST", `/v1/devices/${device.device_id}/secrets`, {
      auth: device.owner_key,
      body: { label },
    });
    if (response.status !== 201) throw new Error(`minting a secret answered ${response.status}`);
    return response.json();
  }

  /** Registers a phone and mints one secret, the state every push starts from. */
  async register(token?: string, environment = "sandbox", ip?: string): Promise<Registered> {
    const device = await this.registerDevice(token, environment, ip);
    return { ...device, ...(await this.mint(device)) };
  }

  push(secret: string, body: unknown = { payload: PAYLOAD, push_type: "alert" }): Promise<Response> {
    return this.request("POST", "/v1/push", { auth: secret, body });
  }
}

/** The shape the helper sends today (Relay/src/push.rs). */
export const PAYLOAD = {
  aps: {
    alert: { title: "Claude · api", body: "Which DB? ünïcödé 🦖", subtitle: "work" },
    "interruption-level": "time-sensitive",
    "thread-id": "block:01a1-b1",
    category: "AGENT_BLOCKED",
    sound: "default",
  },
  server: "https://rex.example.ts.net",
  session_id: "session:s1",
  block_id: "block:01a1-b1",
  window_id: "window:w1",
};

export function appleError(status: number, reason: string): () => Response {
  return () => new Response(JSON.stringify({ reason }), { status, headers: { "apns-id": "x" } });
}

/** Empties the database and the cached JWT, so no test sees another's rows. */
export async function reset(): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM secrets"),
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM counters"),
  ]);
  dropProviderToken();
}

export async function deviceRows(): Promise<Record<string, unknown>[]> {
  return (await env.DB.prepare("SELECT * FROM devices").all()).results;
}

export async function secretRows(): Promise<Record<string, unknown>[]> {
  return (await env.DB.prepare("SELECT * FROM secrets ORDER BY created_at, secret_id").all()).results;
}

export async function counter(key: string): Promise<{ count: number; expires_at: number } | null> {
  return env.DB.prepare("SELECT count, expires_at FROM counters WHERE key = ?1").bind(key).first();
}

export async function seedCounter(key: string, count: number, expiresAt: number): Promise<void> {
  await env.DB.prepare("INSERT INTO counters (key, count, expires_at) VALUES (?1, ?2, ?3)")
    .bind(key, count, expiresAt)
    .run();
}

export async function errorOf(response: Response): Promise<Record<string, unknown>> {
  const body = await response.json<Record<string, unknown>>();
  expectString(body.error);
  expectString(body.message);
  return body;
}

function expectString(value: unknown): void {
  if (typeof value !== "string" || value === "") throw new Error("an error body needs error and message");
}
