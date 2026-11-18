import { isKey, utf8 } from "./encoding";

export type Environment = "sandbox" | "production";
/** The one APNs push type the gateway sends. */
export type PushType = "alert";

export type Parsed<T> = { ok: true; value: T } | { ok: false; status: 400 | 413; message: string };

export interface Registration {
  apnsToken: string;
  environment: Environment;
}

export interface PushRequest {
  /** The payload as it goes to Apple: `JSON.stringify` of what the caller sent. */
  payload: string;
  pushType: PushType;
  priority: 5 | 10;
  collapseId?: string;
  expiration?: number;
}

/** Apple's limit for an alert payload. */
export const MAX_PAYLOAD_BYTES = 4096;
const MAX_COLLAPSE_ID_BYTES = 64;

/**
 * How long Apple may keep a push for a phone that is off: the helper asks for an hour
 * (Relay/src/gateway.rs, `KEEP_SECONDS`) by its own clock. `expiration` is accepted from
 * a minute before the gateway's clock to a minute past that hour, which is the room two
 * clocks that differ by up to a minute need.
 */
export const MAX_KEEP_SECONDS = 3600;
export const CLOCK_DIFFERENCE_SECONDS = 60;

function invalid(message: string): { ok: false; status: 400; message: string } {
  return { ok: false, status: 400, message };
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseRegistration(body: unknown): Parsed<Registration> {
  if (!isObject(body)) return invalid("The body must be a JSON object.");
  const { apns_token: token, environment } = body;
  if (typeof token !== "string" || !/^[0-9a-fA-F]{64,200}$/.test(token)) {
    return invalid("apns_token must be 64 to 200 hex characters.");
  }
  if (environment !== "sandbox" && environment !== "production") {
    return invalid('environment must be "sandbox" or "production".');
  }
  return { ok: true, value: { apnsToken: token.toLowerCase(), environment } };
}

const MAX_LABEL_CHARACTERS = 64;

/**
 * Checks the body that mints a secret. The label is the name the phone shows for the
 * computer, so it may hold any printable text, but nothing a list or a log line would trip
 * over: no control characters, no line or paragraph separators, no lone surrogates.
 */
export function parseLabel(body: unknown): Parsed<string> {
  if (!isObject(body)) return invalid("The body must be a JSON object.");
  const { label } = body;
  // The `u` flag makes the pattern count characters (code points), not UTF-16 units.
  if (typeof label !== "string" || !/^[^\p{Cc}\p{Zl}\p{Zp}\p{Cs}]{1,64}$/u.test(label) || label.trim() === "") {
    return invalid(`label must be 1 to ${MAX_LABEL_CHARACTERS} printable characters.`);
  }
  return { ok: true, value: label };
}

export interface ChosenSecret {
  label: string;
  pushSecret: string;
}

/** A secret id a phone chooses: 16 url-safe characters, the length of the ids the gateway makes. */
export function isSecretId(text: string): boolean {
  return /^[A-Za-z0-9_-]{16}$/.test(text);
}

/**
 * Checks the body that stores a secret the phone chose: the label as for a minted secret,
 * and `push_secret`, 32 bytes as base64url.
 */
export function parseChosenSecret(body: unknown): Parsed<ChosenSecret> {
  const label = parseLabel(body);
  if (!label.ok) return label;
  const { push_secret: pushSecret } = body as Record<string, unknown>;
  if (typeof pushSecret !== "string" || !isKey(pushSecret)) {
    return invalid("push_secret must be 32 bytes as base64url, 43 characters.");
  }
  return { ok: true, value: { label: label.value, pushSecret } };
}

/** What a payload field may hold: a string of at most this many characters, or one of these words. */
type Rule = number | readonly string[];

/*
 * The payload the helper sends (Relay/src/push.rs, `PushMessage::payload`), field by field.
 * A payload may hold these and nothing else, and every one of them is a string. The title
 * and body lengths are the ones the helper cuts its text to; the other fields are names and
 * ids.
 */
const PAYLOAD_FIELDS: Record<string, Rule> = { server: 512, session_id: 256, window_id: 256, block_id: 256 };
const APS_FIELDS: Record<string, Rule> = {
  sound: ["default"],
  "thread-id": 256,
  category: ["AGENT_BLOCKED", "AGENT_DONE", "NOTICE"],
  "interruption-level": ["passive", "active", "time-sensitive"],
};
const ALERT_FIELDS: Record<string, Rule> = { title: 120, subtitle: 256, body: 1000 };

/** Characters (code points), which is how the helper counts when it cuts a text. */
function characters(text: string): number {
  let count = 0;
  for (const _ of text) count++;
  return count;
}

/**
 * Checks the fields of one object of the payload against its rules. `nested` is the one key
 * that holds an object and is checked by the caller. Returns what is wrong, or null.
 */
function fieldsProblem(object: Record<string, unknown>, rules: Record<string, Rule>, name: string, nested?: string): string | null {
  for (const key of Object.keys(object)) {
    if (key === nested) continue;
    const rule = Object.hasOwn(rules, key) ? rules[key] : undefined;
    if (rule === undefined) return `${name} holds a field the gateway does not pass on.`;
    const value = object[key];
    if (typeof value !== "string") return `${name}.${key} must be a string.`;
    if (typeof rule === "number") {
      if (value.length > rule && characters(value) > rule) return `${name}.${key} must be at most ${rule} characters.`;
    } else if (!rule.includes(value)) {
      return `${name}.${key} must be one of: ${rule.join(", ")}.`;
    }
  }
  return null;
}

/** Checks that a payload is one the helper sends: an alert with a title and a body, and the fields above. */
function payloadProblem(payload: Record<string, unknown>): string | null {
  const { aps } = payload;
  if (!isObject(aps)) return "payload.aps must be a JSON object.";
  const { alert } = aps;
  if (!isObject(alert)) return "payload.aps.alert must be a JSON object.";
  if (typeof alert.title !== "string" || typeof alert.body !== "string") {
    return "payload.aps.alert needs a title and a body.";
  }
  return (
    fieldsProblem(payload, PAYLOAD_FIELDS, "payload", "aps") ??
    fieldsProblem(aps, APS_FIELDS, "payload.aps", "alert") ??
    fieldsProblem(alert, ALERT_FIELDS, "payload.aps.alert")
  );
}

/**
 * Checks a push. Only the fields named here are read: there is no way to name a token, a
 * topic or a host, so a caller can reach nothing but its own device through our app. The
 * payload is passed on only when it is the notification the helper sends. `now` is the
 * gateway's clock, which `expiration` is measured against.
 */
export function parsePush(body: unknown, now: number): Parsed<PushRequest> {
  if (!isObject(body)) return invalid("The body must be a JSON object.");

  if (!isObject(body.payload)) return invalid("payload must be a JSON object.");
  const payload = JSON.stringify(body.payload);
  if (utf8(payload).byteLength > MAX_PAYLOAD_BYTES) {
    return { ok: false, status: 413, message: `payload is larger than ${MAX_PAYLOAD_BYTES} bytes.` };
  }
  const problem = payloadProblem(body.payload);
  if (problem) return invalid(problem);

  // The payload is always an alert, so that is the one type. Other types (background, voip,
  // liveactivity, location…) carry other payloads or need other topics and entitlements.
  const pushType = body.push_type ?? "alert";
  if (pushType !== "alert") return invalid('push_type must be "alert".');

  const priority = body.priority ?? 10;
  if (priority !== 5 && priority !== 10) return invalid("priority must be 5 or 10.");

  const value: PushRequest = { payload, pushType, priority };

  if (body.collapse_id !== undefined) {
    const id = body.collapse_id;
    // It becomes a header value, so it is kept to visible ASCII, where bytes equal characters.
    if (typeof id !== "string" || !/^[\x21-\x7e]+$/.test(id) || id.length > MAX_COLLAPSE_ID_BYTES) {
      return invalid(`collapse_id must be 1 to ${MAX_COLLAPSE_ID_BYTES} visible ASCII characters.`);
    }
    value.collapseId = id;
  }

  if (body.expiration !== undefined) {
    const at = body.expiration;
    if (
      typeof at !== "number" ||
      !Number.isSafeInteger(at) ||
      at < now - CLOCK_DIFFERENCE_SECONDS ||
      at > now + MAX_KEEP_SECONDS + CLOCK_DIFFERENCE_SECONDS
    ) {
      return invalid(`expiration must be a unix time in seconds, from now to ${MAX_KEEP_SECONDS} seconds from now.`);
    }
    value.expiration = at;
  }

  return { ok: true, value };
}
