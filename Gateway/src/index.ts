/**
 * Rex DUO push gateway. It holds the APNs key and the phones' APNs tokens, so the helper on
 * each computer needs neither: a phone registers its token here, mints one secret per helper
 * and hands it over. A secret can push to that phone and do nothing else.
 */
import { addressKeys } from "./address";
import { type ApnsConfig, sendPush, tokenIsDead } from "./apns";
import { randomToken, sha256Hex } from "./encoding";
import type { Deps, Env } from "./env";
import { type Reply, bearer, fail, ok, rateLimited, readJson, toResponse, unauthorized } from "./http";
import {
  type Client,
  LIMITS,
  MAX_DEVICES_PER_TOKEN,
  type ManageKind,
  type Verdict,
  allowedBy,
  countPush,
  hitManage,
  hitRegistration,
  pushVerdict,
} from "./limits";
import { purge } from "./purge";
import * as storage from "./storage";
import { parseLabel, parsePush, parseRegistration } from "./validate";

export const VERSION = "2.0.0";

/** The most the Worker reads of any request body. A push is at most 4096 bytes of payload plus a few fields. */
export const MAX_BODY_BYTES = 8192;

/** What a handler gets. Building it touches neither D1 nor Apple. */
interface Call {
  request: Request;
  env: Env;
  deps: Deps;
  deviceId: string;
  secretId: string;
  /** SHA-256 of the client address's keys: tells clients apart without naming them. */
  client: Client;
}

type Handler = (call: Call) => Promise<Reply>;

interface Route {
  /** The name in the log line: the pattern, never the path, which holds a device id. */
  name: string;
  methods: Record<string, Handler>;
}

interface Match {
  route: Route;
  deviceId: string;
  secretId: string;
}

const DEVICE_PATH = /^\/v1\/devices\/([A-Za-z0-9_-]{1,64})(\/secrets(?:\/([A-Za-z0-9_-]{1,64}))?)?$/;

function match(pathname: string): Match | null {
  const top = (route: Route): Match => ({ route, deviceId: "", secretId: "" });
  switch (pathname) {
    case "/v1/health":
      return top({ name: "/v1/health", methods: { GET: health } });
    case "/v1/devices":
      return top({ name: "/v1/devices", methods: { POST: register } });
    case "/v1/push":
      return top({ name: "/v1/push", methods: { POST: push } });
  }
  const device = DEVICE_PATH.exec(pathname);
  if (!device) return null;
  const deviceId = device[1] ?? "";
  const secretId = device[3] ?? "";
  if (secretId) {
    return { route: { name: "/v1/devices/:id/secrets/:secret", methods: { DELETE: deleteSecret } }, deviceId, secretId };
  }
  if (device[2]) {
    return { route: { name: "/v1/devices/:id/secrets", methods: { POST: mintSecret } }, deviceId, secretId };
  }
  return {
    route: { name: "/v1/devices/:id", methods: { GET: showDevice, PUT: updateDevice, DELETE: unregister } },
    deviceId,
    secretId,
  };
}

/**
 * Everything here and in the handlers runs in one order: the checks that cost nothing first
 * (the route, the method, the short-window limits, the shape of the credential and of the
 * body), D1 only after all of them pass. A flood of junk therefore never reaches the
 * database, whose daily budget for rows written is the thing to keep.
 */
export async function handleRequest(request: Request, env: Env, deps: Deps): Promise<Response> {
  const found = match(new URL(request.url).pathname);
  const handler = found?.route.methods[request.method];
  const name = found ? (handler ? `${request.method} ${found.route.name}` : found.route.name) : "unknown";

  // Cloudflare sets this header itself and overwrites a client's own.
  const keys = addressKeys(request.headers.get("cf-connecting-ip"));
  const client: Client = {
    address: await sha256Hex(keys.key),
    wide: keys.wide === null ? null : await sha256Hex(keys.wide),
  };

  let reply: Reply;
  // The address first: a client over its own limit doesn't use up the brake everyone shares.
  if (!(await allowedBy(env.RL_ADDRESS, client.address))) {
    reply = rateLimited(LIMITS.addressPerMinute.windowSeconds, "Too many requests from this address.");
  } else if (!(await allowedBy(env.RL_GLOBAL, "all"))) {
    reply = rateLimited(LIMITS.allPerMinute.windowSeconds, "The gateway is busy. Try again later.");
  } else if (!found) {
    reply = fail(404, "not_found", "No such route.");
  } else if (!handler) {
    reply = {
      ...fail(405, "method_not_allowed", "This route does not accept that method."),
      headers: { allow: Object.keys(found.route.methods).join(", ") },
    };
  } else {
    try {
      reply = await handler({ request, env, deps, deviceId: found.deviceId, secretId: found.secretId, client });
    } catch (error) {
      // Only the error's name: a message can quote a query or a value.
      reply = { ...fail(500, "internal_error", "The gateway failed."), reason: errorName(error) };
    }
  }
  // The whole log: the route, the status and Apple's answer. Never a payload, token, key or secret.
  console.log(
    JSON.stringify({ route: name, status: reply.status, apns_status: reply.apnsStatus, reason: reply.reason }),
  );
  return toResponse(reply);
}

function errorName(error: unknown): string {
  return error instanceof Error && /^[A-Za-z0-9]{1,64}$/.test(error.name) ? error.name : "Error";
}

function tooMany(verdict: Verdict & { allowed: false }, message: string): Reply {
  return rateLimited(verdict.retryAfter, message);
}

async function health(): Promise<Reply> {
  return ok(200, { ok: true, version: VERSION });
}

/** The answer when a token already has the most devices it may. It names no device. */
function tooManyDevices(): Reply {
  return fail(409, "too_many_devices", `This token already has the ${MAX_DEVICES_PER_TOKEN} registrations it may hold.`);
}

async function register({ request, env, deps, client }: Call): Promise<Reply> {
  const body = await readJson(request, MAX_BODY_BYTES);
  if (!body.ok) return body.reply;
  const parsed = parseRegistration(body.value);
  if (!parsed.ok) return fail(400, "invalid_request", parsed.message);

  const now = deps.now();
  const tokenHash = await sha256Hex(parsed.value.apnsToken);
  const verdict = await hitRegistration(env.DB, client, tokenHash, now);
  if (!verdict.allowed) {
    return "full" in verdict ? tooManyDevices() : tooMany(verdict, "Too many registrations. Try again later.");
  }

  const deviceId = randomToken(20);
  const ownerKey = randomToken(32);
  const added = await storage.insertDevice(
    env.DB,
    {
      deviceId,
      ownerHash: await sha256Hex(ownerKey),
      apnsToken: parsed.value.apnsToken,
      tokenHash,
      environment: parsed.value.environment,
    },
    now,
  );
  // Another registration took the token's last place between the check and the insert.
  if (!added) return tooManyDevices();
  // The only time the key exists outside the phone: from here on we hold its hash.
  return ok(201, { device_id: deviceId, owner_key: ownerKey });
}

/*
 * The owner-key routes. An unknown device id and a wrong owner key get the same 401 on every
 * one of them, so nothing tells a caller whether an id exists.
 */

async function showDevice({ request, env, deps, deviceId, client }: Call): Promise<Reply> {
  const ownerKey = bearer(request);
  if (!ownerKey) return unauthorized();
  const device = await storage.findOwned(env.DB, deviceId, await sha256Hex(ownerKey), client, deps.now());
  if (!device) return unauthorized();
  return ok(200, { environment: device.environment, secrets: await storage.listSecrets(env.DB, deviceId) });
}

/**
 * The owner-key check and the daily caps on management writes, for the four routes that
 * change a device: minting a secret and a token change (`change`), deleting a secret
 * (`delete`) and deleting the device (`deviceGoes`). Null means go ahead; a reply is the
 * refusal.
 *
 * The write is counted only for a caller who proved the owner key and only after the
 * request is known to be well formed. It is counted against the device, the client address
 * and the global budget of its kind, and refused with nothing written when any of them is
 * spent. A device whose token is dead is managed like any other: its owner can still read
 * it, give it a new token and delete it.
 *
 * `newTokenHash` is the token a token change asks for. One that already has the most
 * devices it may is refused here, before anything is counted.
 */
async function countChange(
  { env, deviceId, client }: Call,
  ownerHash: string,
  now: number,
  kind: ManageKind,
  newTokenHash: string | null = null,
): Promise<Reply | null> {
  const device = await storage.findOwned(env.DB, deviceId, ownerHash, client, now, newTokenHash);
  if (!device) return unauthorized();
  if (device.othersWithToken >= MAX_DEVICES_PER_TOKEN) return tooManyDevices();
  // A row from before `token_hash` gets its hash with this write. A token change stores
  // the new token's hash itself.
  const fill = device.unhashedToken !== null && newTokenHash === null ? await sha256Hex(device.unhashedToken) : null;
  const verdict = await hitManage(env.DB, deviceId, client, device, now, kind, fill);
  return verdict.allowed ? null : tooMany(verdict, "Too many changes today. Try again later.");
}

async function updateDevice(call: Call): Promise<Reply> {
  const { request, env, deps, deviceId } = call;
  const ownerKey = bearer(request);
  if (!ownerKey) return unauthorized();
  const body = await readJson(request, MAX_BODY_BYTES);
  if (!body.ok) return body.reply;
  const parsed = parseRegistration(body.value);
  if (!parsed.ok) return fail(400, "invalid_request", parsed.message);

  const { apnsToken, environment } = parsed.value;
  const ownerHash = await sha256Hex(ownerKey);
  const tokenHash = await sha256Hex(apnsToken);
  const now = deps.now();
  const refused = await countChange(call, ownerHash, now, "change", tokenHash);
  if (refused) return refused;

  const updated = await storage.updateToken(env.DB, deviceId, ownerHash, apnsToken, tokenHash, environment, now);
  if (updated) return ok(200, {});
  // Between the check and the write the device went, which is the same answer as never
  // there, or another device took the token's last place.
  return (await storage.isOwned(env.DB, deviceId, ownerHash)) ? tooManyDevices() : unauthorized();
}

async function unregister(call: Call): Promise<Reply> {
  const { request, env, deps, deviceId } = call;
  const ownerKey = bearer(request);
  if (!ownerKey) return unauthorized();
  const ownerHash = await sha256Hex(ownerKey);
  const refused = await countChange(call, ownerHash, deps.now(), "deviceGoes");
  if (refused) return refused;
  const deleted = await storage.deleteOwned(env.DB, deviceId, ownerHash);
  return deleted ? { status: 204 } : unauthorized();
}

async function mintSecret(call: Call): Promise<Reply> {
  const { request, env, deps, deviceId } = call;
  const ownerKey = bearer(request);
  if (!ownerKey) return unauthorized();
  const body = await readJson(request, MAX_BODY_BYTES);
  if (!body.ok) return body.reply;
  const parsed = parseLabel(body.value);
  if (!parsed.ok) return fail(400, "invalid_request", parsed.message);

  const ownerHash = await sha256Hex(ownerKey);
  const now = deps.now();
  const refused = await countChange(call, ownerHash, now, "change");
  if (refused) return refused;

  const secretId = randomToken(12);
  const pushSecret = randomToken(32);
  const added = await storage.insertSecret(
    env.DB,
    deviceId,
    ownerHash,
    { secretId, secretHash: await sha256Hex(pushSecret), label: parsed.value },
    now,
  );
  if (!added) return fail(409, "too_many_secrets", "This device already has the most secrets it may hold.");
  // The only time the secret exists outside the phone and its helper: we keep its hash.
  return ok(201, { secret_id: secretId, push_secret: pushSecret });
}

async function deleteSecret(call: Call): Promise<Reply> {
  const { request, env, deps, deviceId, secretId } = call;
  const ownerKey = bearer(request);
  if (!ownerKey) return unauthorized();
  const refused = await countChange(call, await sha256Hex(ownerKey), deps.now(), "delete");
  if (refused) return refused;
  // 204 also when the secret is already gone: the caller wanted it gone, and it is.
  await storage.deleteSecret(env.DB, deviceId, secretId);
  return { status: 204 };
}

/** The answer for a device whose token Apple no longer accepts. `reason` is Apple's, when this push heard it. */
function unregistered(reason?: string): Reply {
  return fail(
    410,
    "unregistered",
    "Apple no longer accepts this device's token.",
    reason === undefined ? {} : { reason },
  );
}

async function push({ request, env, deps }: Call): Promise<Reply> {
  const secret = bearer(request);
  if (!secret) return unauthorized();
  const body = await readJson(request, MAX_BODY_BYTES);
  if (!body.ok) return body.reply;
  const now = deps.now();
  const parsed = parsePush(body.value, now);
  if (!parsed.ok) {
    return fail(parsed.status, parsed.status === 413 ? "payload_too_large" : "invalid_request", parsed.message);
  }

  // Keyed by the hash, so the limiter never holds a secret. Asked before D1, so a helper in
  // a loop, or a guesser, is stopped without a database read.
  const secretHash = await sha256Hex(secret);
  if (!(await allowedBy(env.RL_SECRET, secretHash))) {
    return rateLimited(LIMITS.secretPerMinute.windowSeconds, "Too many pushes. Try again later.");
  }

  const target = await storage.findBySecret(env.DB, secretHash, now);
  if (!target) return unauthorized();

  // A dead token is answered from the read: no write, no budget and no request to Apple.
  // The device stays for its owner to give it a new token or delete it, and for the purge.
  if (target.dead) return unregistered();

  // The caps decide from the same read, before Apple.
  const verdict = pushVerdict(target, now);
  if (!verdict.allowed) return tooMany(verdict, "Too many pushes. Try again later.");

  const config: ApnsConfig = {
    keyId: env.APNS_KEY_ID,
    teamId: env.APNS_TEAM_ID,
    topic: env.APNS_TOPIC,
    keyPem: env.APNS_KEY_P8,
  };
  const result = await sendPush(deps, config, target, parsed.value);

  // Every push that went to Apple is counted, whatever the answer, in two rows. Counting
  // after the answer lets the device's row take `dead` in that same write.
  const dead = result.kind === "rejected" && tokenIsDead(result.status, result.reason);
  await countPush(env.DB, target.deviceId, dead, now);

  switch (result.kind) {
    case "sent":
      return ok(200, { apns_id: result.apnsId });
    case "unreachable":
      return fail(502, "apns_unreachable", "The request to Apple failed.");
    case "rejected": {
      const { status, reason } = result;
      if (dead) return { ...unregistered(reason), reason, apnsStatus: status };
      return {
        ...fail(502, "apns_error", "Apple refused the push.", { status, reason }),
        reason,
        apnsStatus: status,
      };
    }
  }
}

/** The cron trigger's work (wrangler.toml, `[triggers]`). Logs counts only. */
export async function handleScheduled(env: Env, now: number): Promise<void> {
  try {
    const { devices, counters } = await purge(env.DB, now);
    console.log(JSON.stringify({ task: "purge", devices, counters }));
  } catch (error) {
    console.log(JSON.stringify({ task: "purge", failed: errorName(error) }));
    // Thrown again so Cloudflare records the run as failed.
    throw error;
  }
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env, {
      fetch: (url, init) => fetch(url, init),
      now: () => Math.floor(Date.now() / 1000),
    });
  },
  scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    return handleScheduled(env, Math.floor(Date.now() / 1000));
  },
} satisfies ExportedHandler<Env>;
