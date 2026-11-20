/**
 * Pteron push gateway. It holds the APNs key and the phones' APNs tokens, so the helper on
 * each computer needs neither: a phone registers its token here, mints one secret per helper
 * and hands it over. A secret can push to that phone and do nothing else.
 */
import { addressKeys } from "./address";
import { type ApnsConfig, sendPush, tokenIsDead } from "./apns";
import { CHOSEN_DEVICE_ID_LENGTH, deviceIdFor, isKey, randomToken, sha256Hex } from "./encoding";
import type { Deps, Env } from "./env";
import { type Reply, bearer, fail, ok, rateLimited, readJson, toResponse, unauthorized } from "./http";
import {
  type Client,
  LIMITS,
  MAX_DEVICES_PER_TOKEN,
  MAX_SECRETS_PER_DEVICE,
  type ManageKind,
  type Verdict,
  allowedBy,
  countPush,
  hitManage,
  hitRegistration,
  pushVerdict,
} from "./limits";
import type { LeaseResult } from "./presence";
import { purge } from "./purge";
import * as storage from "./storage";
import {
  type Registration,
  isSecretId,
  parseChosenSecret,
  parseLabel,
  parsePresence,
  parsePush,
  parseRegistration,
} from "./validate";

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
    case "/v1/presence":
      return top({ name: "/v1/presence", methods: { PUT: putPresence } });
  }
  const device = DEVICE_PATH.exec(pathname);
  if (!device) return null;
  const deviceId = device[1] ?? "";
  const secretId = device[3] ?? "";
  if (secretId) {
    return {
      route: { name: "/v1/devices/:id/secrets/:secret", methods: { PUT: putSecret, DELETE: deleteSecret } },
      deviceId,
      secretId,
    };
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
 *
 * A phone can also choose its owner key, and with it its device id, which is derived from
 * the key (src/encoding.ts, `deviceIdFor`). `PUT` on such an id checks the pair before
 * anything else: an id that is not its key's is `400`, decided from the request alone, so
 * that answer is the same whether a device has the id or not.
 */

async function showDevice({ request, env, deps, deviceId, client }: Call): Promise<Reply> {
  const ownerKey = bearer(request);
  if (!ownerKey) return unauthorized();
  const device = await storage.findOwned(env.DB, deviceId, await sha256Hex(ownerKey), client, deps.now());
  if (!device) return unauthorized();
  return ok(200, { environment: device.environment, secrets: await storage.listSecrets(env.DB, deviceId) });
}

/**
 * The owner-key check and the daily caps on management writes, for the routes that change
 * a device: a secret minted, stored or replaced and a token change (`change`), deleting a
 * secret (`delete`) and deleting the device (`deviceGoes`). Null means go ahead; a reply is
 * the refusal.
 *
 * The write is counted only for a caller who proved the owner key and only after the
 * request is known to be well formed. It is counted against the device, the client address
 * and the global budget of its kind, and refused with nothing written when any of them is
 * spent. A device whose token is dead is managed like any other: its owner can still read
 * it, give it a new token and delete it.
 *
 * `newTokenHash` is the token a token change asks for. One that already has the most
 * devices it may is refused here, before anything is counted.
 *
 * A request that is refused writes nothing and counts nothing: every refusal on these
 * routes (`400`, `401`, `409`, `429`) is decided from the request or from the one read,
 * before the count. The counting and the change are separate statements, and each repeats
 * its own check so that two requests at once can't both take a last place (of a counter, of
 * a token's devices, of a device's secrets, of a push secret's hash). Only the request that
 * comes second in such a race is refused after its read, and what it counted by then stays.
 */
async function countChange(
  call: Call,
  ownerHash: string,
  now: number,
  kind: ManageKind,
  newTokenHash: string | null = null,
): Promise<Reply | null> {
  const { env, deviceId, client } = call;
  const device = await storage.findOwned(env.DB, deviceId, ownerHash, client, now, newTokenHash);
  if (!device) return unauthorized();
  return countOwned(call, device, now, kind, newTokenHash);
}

/** The caps of `countChange`, for a caller that already read its device with `findOwned`. */
async function countOwned(
  { env, deviceId, client }: Call,
  device: storage.OwnedDevice,
  now: number,
  kind: ManageKind,
  newTokenHash: string | null = null,
): Promise<Reply | null> {
  if (device.othersWithToken >= MAX_DEVICES_PER_TOKEN) return tooManyDevices();
  // A row from before `token_hash` gets its hash with this write. A token change stores
  // the new token's hash itself.
  const fill = device.unhashedToken !== null && newTokenHash === null ? await sha256Hex(device.unhashedToken) : null;
  const verdict = await hitManage(env.DB, deviceId, client, device, now, kind, fill);
  return verdict.allowed ? null : tooMany(verdict, "Too many changes today. Try again later.");
}

async function updateDevice(call: Call): Promise<Reply> {
  const { request, deps, deviceId } = call;
  const ownerKey = bearer(request);
  if (!ownerKey) return unauthorized();
  // An id of the length a phone chooses is the phone's own: the key must be 32 bytes and
  // the id the one derived from it. Both are checked here, before the body and before D1.
  const chosen = deviceId.length === CHOSEN_DEVICE_ID_LENGTH;
  if (chosen) {
    if (!isKey(ownerKey)) return unauthorized();
    if (deviceId !== (await deviceIdFor(ownerKey))) {
      return fail(400, "invalid_request", "device_id is not the id of this owner key.");
    }
  }
  const body = await readJson(request, MAX_BODY_BYTES);
  if (!body.ok) return body.reply;
  const parsed = parseRegistration(body.value);
  if (!parsed.ok) return fail(400, "invalid_request", parsed.message);

  const ownerHash = await sha256Hex(ownerKey);
  const tokenHash = await sha256Hex(parsed.value.apnsToken);
  const now = deps.now();
  if (chosen) return putDevice(call, ownerHash, parsed.value, tokenHash, now);
  const refused = await countChange(call, ownerHash, now, "change", tokenHash);
  return refused ?? changeToken(call, ownerHash, parsed.value, tokenHash, now);
}

/** The write of a token change, once it is counted. */
async function changeToken(
  { env, deviceId }: Call,
  ownerHash: string,
  { apnsToken, environment }: Registration,
  tokenHash: string,
  now: number,
): Promise<Reply> {
  const updated = await storage.updateToken(env.DB, deviceId, ownerHash, apnsToken, tokenHash, environment, now);
  if (updated) return ok(200, {});
  // Between the check and the write the device went, which is the same answer as never
  // there, or another device took the token's last place.
  return (await storage.isOwned(env.DB, deviceId, ownerHash)) ? tooManyDevices() : unauthorized();
}

/**
 * `PUT` for a device id the phone chose: the request says what the device is, and sending
 * it again changes nothing. One read decides which of three things it is.
 *
 *   No such device: it is made. This is a registration, counted and capped as one.
 *   The device holds this token and environment: nothing to do. No write, no count.
 *   Anything else: a token change, counted and capped as one. A device marked dead is in
 *   this case also with the token it holds, because a token change is what makes a device
 *   live again, and a phone that sends its token says the token is in use.
 */
async function putDevice(
  call: Call,
  ownerHash: string,
  registration: Registration,
  tokenHash: string,
  now: number,
): Promise<Reply> {
  const { env, deviceId, client } = call;
  const { apnsToken, environment } = registration;
  const read = (): Promise<storage.OwnedDevice | null> =>
    storage.findOwned(env.DB, deviceId, ownerHash, client, now, tokenHash);

  let device = await read();
  if (!device) {
    const verdict = await hitRegistration(env.DB, client, tokenHash, now);
    if (!verdict.allowed) {
      return "full" in verdict ? tooManyDevices() : tooMany(verdict, "Too many registrations. Try again later.");
    }
    const added = await storage.insertDevice(env.DB, { deviceId, ownerHash, apnsToken, tokenHash, environment }, now);
    if (added) return ok(201, { device_id: deviceId });
    // Nothing was added: the same request, sent twice at once, made the device first, and
    // this one goes on as a repeat; or another registration took the token's last place.
    device = await read();
    if (!device) return tooManyDevices();
  }
  if (!device.dead && device.apnsToken === apnsToken && device.environment === environment) return ok(200, {});
  const refused = await countOwned(call, device, now, "change", tokenHash);
  return refused ?? changeToken(call, ownerHash, registration, tokenHash, now);
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
  const { request, env, deps, deviceId, client } = call;
  const ownerKey = bearer(request);
  if (!ownerKey) return unauthorized();
  const body = await readJson(request, MAX_BODY_BYTES);
  if (!body.ok) return body.reply;
  const parsed = parseLabel(body.value);
  if (!parsed.ok) return fail(400, "invalid_request", parsed.message);

  const ownerHash = await sha256Hex(ownerKey);
  const now = deps.now();
  const device = await storage.findOwned(env.DB, deviceId, ownerHash, client, now);
  if (!device) return unauthorized();
  // A device that holds the most secrets it may is answered from the read: nothing is
  // written and nothing is counted.
  if (device.secretsHeld >= MAX_SECRETS_PER_DEVICE) return tooManySecrets();
  const refused = await countOwned(call, device, now, "change");
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
  // Nothing was added: a request at the same time took the device's last place between
  // the read and the insert. This request is counted, and its count stays.
  if (!added) return tooManySecrets();
  // The only time the secret exists outside the phone and its helper: we keep its hash.
  return ok(201, { secret_id: secretId, push_secret: pushSecret });
}

function tooManySecrets(): Reply {
  return fail(409, "too_many_secrets", "This device already has the most secrets it may hold.");
}

/** One answer for a push secret that is in another row. It says nothing about that row. */
function secretInUse(): Reply {
  return fail(409, "conflict", "This push secret is already in use.");
}

/**
 * `PUT` for a secret the phone chose, under an id it chose: the request says what the
 * secret is, and sending it again changes nothing. One read decides which of five things
 * it is, for a caller who proved the owner key.
 *
 *   The push secret is in another row, of this device or of any other: `409 conflict`.
 *   A secret names exactly one row, and a row never changes its device.
 *   The device holds this secret under this id: nothing to do. No write, no count.
 *   The device holds another secret under this id: that one is replaced, a management write.
 *   The device holds nothing under this id and has room: the secret is added, a management
 *   write.
 *   The device holds nothing under this id and holds the most secrets it may:
 *   `409 too_many_secrets`. No write, no count.
 */
async function putSecret(call: Call): Promise<Reply> {
  const { request, env, deps, deviceId, secretId, client } = call;
  const ownerKey = bearer(request);
  if (!ownerKey || !isKey(ownerKey)) return unauthorized();
  if (!isSecretId(secretId)) return fail(400, "invalid_request", "secret_id must be 16 url-safe characters.");
  const body = await readJson(request, MAX_BODY_BYTES);
  if (!body.ok) return body.reply;
  const parsed = parseChosenSecret(body.value);
  if (!parsed.ok) return fail(400, "invalid_request", parsed.message);
  const { label, pushSecret, presence } = parsed.value;
  // A push secret goes to a helper, and the owner key never leaves the phone.
  if (pushSecret === ownerKey) return fail(400, "invalid_request", "push_secret must not be the owner key.");

  const ownerHash = await sha256Hex(ownerKey);
  const secret: storage.NewSecret = { secretId, secretHash: await sha256Hex(pushSecret), label };
  if (presence !== undefined) secret.presence = presence;
  const now = deps.now();
  const read = (): Promise<storage.OwnedDevice | null> =>
    storage.findOwned(env.DB, deviceId, ownerHash, client, now, null, secret);
  /** The answer when there is nothing to write, or null. */
  const settled = (device: storage.OwnedDevice): Reply | null => {
    if (device.secretTaken) return secretInUse();
    // The same secret with the flag as stored, or with no flag, which keeps the stored one.
    if (device.heldSecretHash === secret.secretHash && (presence === undefined || presence === device.heldPresence)) {
      return ok(200, { secret_id: secretId });
    }
    // A full device takes no new id. An id it holds is one of its secrets, and is replaced.
    return device.heldSecretHash === null && device.secretsHeld >= MAX_SECRETS_PER_DEVICE ? tooManySecrets() : null;
  };

  const device = await read();
  if (!device) return unauthorized();
  const answer = settled(device);
  if (answer) return answer;
  const refused = await countOwned(call, device, now, "change");
  if (refused) return refused;

  const adding = device.heldSecretHash === null;
  // The secret is stored already and only its flag changes: `presence` is set, or `settled`
  // would have answered.
  const flagOnly = device.heldSecretHash === secret.secretHash;
  const written = adding
    ? await storage.insertSecret(env.DB, deviceId, ownerHash, secret, now)
    : flagOnly
      ? await storage.setSecretPresence(env.DB, deviceId, secretId, secret.secretHash, presence === true)
      : await storage.replaceSecret(env.DB, deviceId, secret, now);
  if (written) {
    // The flag went from set to cleared: no lease of the phone outlives that trust.
    if (device.heldPresence === true && presence === false) await clearLeases(env, deviceId, now);
    return ok(adding ? 201 : 200, { secret_id: secretId });
  }

  // Nothing was written: a request at the same time took the device's last place, stored
  // this secret or took its hash, between the read and the write. What is there now is the
  // answer. This request is counted, and its count stays.
  const after = await read();
  if (!after) return unauthorized();
  return settled(after) ?? (adding && after.heldSecretHash === null ? tooManySecrets() : secretInUse());
}

async function deleteSecret(call: Call): Promise<Reply> {
  const { request, env, deps, deviceId, secretId } = call;
  const ownerKey = bearer(request);
  if (!ownerKey) return unauthorized();
  const refused = await countChange(call, await sha256Hex(ownerKey), deps.now(), "delete");
  if (refused) return refused;
  // 204 also when the secret is already gone: the caller wanted it gone, and it is.
  const wasOwn = await storage.deleteSecret(env.DB, deviceId, secretId);
  // A computer that is no longer trusted holds nothing back from then on.
  if (wasOwn) await clearLeases(env, deviceId, deps.now());
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

  // Held while the person is at one of the named desks: nothing goes to Apple and nothing is
  // counted. Asked only for a well-formed field from one of the phone's own computers; any
  // doubt sends the push.
  const holdIfDesk = parsed.value.holdIfDesk;
  if (holdIfDesk && target.presence && hasPresence(env)) {
    if (await deskHolds(env.PRESENCE_DO, target.deviceId, holdIfDesk, now)) {
      return ok(202, { held: true, retry_after: HELD_RETRY_SECONDS });
    }
  }

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

/*
 * Desk presence (src/presence.ts). It can only hold a push back, and every fault (a slow,
 * failing or missing Durable Object, a malformed field, a secret that is not the phone's
 * own) sends the push as before. A helper or an app that sends none of its fields gets the
 * gateway as it was before presence.
 */

/** How long a push waits for the Durable Object before it is sent anyway. */
export const HOLD_TIMEOUT_MS = 1000;

/** What a held push tells its helper: ask again in this many seconds. */
export const HELD_RETRY_SECONDS = 60;

/** A Worker without the binding has no presence. */
function hasPresence(env: Env): env is Env & { PRESENCE_DO: NonNullable<Env["PRESENCE_DO"]> } {
  return env.PRESENCE_DO !== undefined;
}

function presenceOf(namespace: NonNullable<Env["PRESENCE_DO"]>, deviceId: string) {
  return namespace.get(namespace.idFromName(`phone:${deviceId}`));
}

/**
 * True only when the phone's Durable Object answers, within HOLD_TIMEOUT_MS, that one of
 * `tags` holds a lease. An error, a timeout or any answer but `true` is false: send.
 */
export async function deskHolds(
  namespace: NonNullable<Env["PRESENCE_DO"]> | undefined,
  deviceId: string,
  tags: string[],
  now: number,
  timeoutMs = HOLD_TIMEOUT_MS,
): Promise<boolean> {
  if (!namespace) return false;
  let timer: ReturnType<typeof setTimeout> | null = null;
  const timeout = new Promise<false>((resolve) => {
    timer = setTimeout(() => resolve(false), timeoutMs);
  });
  try {
    const answer = Promise.resolve()
      .then(() => presenceOf(namespace, deviceId).holds(tags, now))
      .then(
        (held) => held === true,
        () => false,
      );
    return await Promise.race([answer, timeout]);
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Removes every lease of the phone, once, without a retry, waiting at most HOLD_TIMEOUT_MS.
 * A failure changes no answer; a lease left behind ends by itself within MAX_LEASE_SECONDS.
 */
async function clearLeases(env: Env, deviceId: string, now: number): Promise<void> {
  if (!hasPresence(env)) return;
  let timer: ReturnType<typeof setTimeout> | null = null;
  const timeout = new Promise<void>((resolve) => {
    timer = setTimeout(resolve, HOLD_TIMEOUT_MS);
  });
  const cleared = Promise.resolve()
    .then(() => presenceOf(env.PRESENCE_DO, deviceId).clear(now))
    .catch(() => undefined);
  await Promise.race([cleared, timeout]);
  clearTimeout(timer);
}

/**
 * `PUT /v1/presence`, bearer: a push secret. Stores or removes the lease of one desk for
 * the secret's phone. Only a secret flagged as the phone's own computer stores anything;
 * any other answers `200 {"stored": false}`. A Worker without the binding answers `404`, as
 * a gateway from before presence does.
 */
async function putPresence({ request, env, deps }: Call): Promise<Reply> {
  if (!hasPresence(env)) return fail(404, "not_found", "No such route.");
  const secret = bearer(request);
  if (!secret) return unauthorized();
  const body = await readJson(request, MAX_BODY_BYTES);
  if (!body.ok) return body.reply;
  const parsed = parsePresence(body.value);
  if (!parsed.ok) return fail(400, "invalid_request", parsed.message);

  // Its own key in the secret's limiter, so leases never take a push's place.
  const secretHash = await sha256Hex(secret);
  if (!(await allowedBy(env.RL_SECRET, `presence:${secretHash}`))) {
    return rateLimited(LIMITS.secretPerMinute.windowSeconds, "Too many presence updates. Try again later.");
  }
  const found = await storage.findPresenceSecret(env.DB, secretHash);
  if (!found) return unauthorized();
  if (found.dead) return unregistered();
  if (!found.presence) return ok(200, { stored: false });

  let result: LeaseResult;
  try {
    result = await presenceOf(env.PRESENCE_DO, found.deviceId).lease(parsed.value.desk, parsed.value.ttl, deps.now());
  } catch (error) {
    return { ...fail(503, "presence_unavailable", "The presence store failed. Try again later."), reason: errorName(error) };
  }
  if (!result.stored) return rateLimited(result.retryAfter, "Too many presence updates today. Try again later.");
  return ok(200, { stored: true });
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
