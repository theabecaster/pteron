import { base64url, utf8 } from "./encoding";
import type { Deps } from "./env";
import type { Environment, PushRequest } from "./validate";

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  topic: string;
  /** The .p8 file: a PKCS#8 P-256 key in PEM. */
  keyPem: string;
}

export type ApnsResult =
  | { kind: "sent"; apnsId: string }
  | { kind: "rejected"; status: number; reason: string }
  | { kind: "unreachable" };

/** Apple accepts a provider token for an hour and throttles a key that changes it within 20 minutes. */
export const TOKEN_BUCKET_SECONDS = 1800;

/** The helper waits 10 s for us, so give up on Apple early enough to still answer. */
const APNS_TIMEOUT_MS = 8000;

// Module globals live as long as the isolate. Promises are cached, not values, so requests
// that arrive together share one import and one signature.
let cachedKey: { pem: string; key: Promise<CryptoKey> } | undefined;
let cachedToken: { id: string; token: Promise<string> } | undefined;

function importKey(pem: string): Promise<CryptoKey> {
  if (cachedKey?.pem === pem) return cachedKey.key;
  const base64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const key = (async () => {
    const der = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
    return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  })();
  cachedKey = { pem, key };
  key.catch(() => {
    if (cachedKey?.key === key) cachedKey = undefined;
  });
  return key;
}

async function sign(config: ApnsConfig, issuedAt: number): Promise<string> {
  const header = base64url(utf8(JSON.stringify({ alg: "ES256", kid: config.keyId })));
  const claims = base64url(utf8(JSON.stringify({ iss: config.teamId, iat: issuedAt })));
  const input = `${header}.${claims}`;
  const key = await importKey(config.keyPem);
  // WebCrypto's ECDSA signature is the raw 64-byte r||s that JWS ES256 wants, not DER.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(input));
  return `${input}.${base64url(new Uint8Array(signature))}`;
}

/**
 * The provider JWT for `now`. `iat` is the start of a fixed 30-minute bucket, so every
 * isolate in every location carries the same `iat`, it changes at most every 30 minutes
 * (Apple refuses changes more often than every 20) and is never an hour old (Apple's limit).
 */
export function providerToken(config: ApnsConfig, now: number): Promise<string> {
  const issuedAt = Math.floor(now / TOKEN_BUCKET_SECONDS) * TOKEN_BUCKET_SECONDS;
  const id = `${issuedAt} ${config.keyId} ${config.teamId} ${config.keyPem}`;
  if (cachedToken?.id === id) return cachedToken.token;
  const token = sign(config, issuedAt);
  cachedToken = { id, token };
  token.catch(() => {
    if (cachedToken?.token === token) cachedToken = undefined;
  });
  return token;
}

/** Forget the cached JWT, so the next request signs a new one. */
export function dropProviderToken(): void {
  cachedToken = undefined;
}

export function hostFor(environment: Environment): string {
  return environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
}

/** True when Apple's answer means this token will never work again for our app. */
export function tokenIsDead(status: number, reason: string): boolean {
  return status === 410 || (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"));
}

/** Apple's reasons are CamelCase words. Anything else is not echoed or logged. */
function reasonFrom(body: string): string {
  try {
    const reason: unknown = (JSON.parse(body) as { reason?: unknown } | null)?.reason;
    return typeof reason === "string" && /^[A-Za-z0-9]{1,64}$/.test(reason) ? reason : "";
  } catch {
    return "";
  }
}

/**
 * Sends one push. The host comes from the device's stored environment and the topic from
 * our config; nothing in the caller's request reaches the URL or the topic header.
 */
export async function sendPush(
  deps: Deps,
  config: ApnsConfig,
  device: { apnsToken: string; environment: Environment },
  push: PushRequest,
): Promise<ApnsResult> {
  const jwt = await providerToken(config, deps.now());
  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    "apns-topic": config.topic,
    "apns-push-type": push.pushType,
    "apns-priority": String(push.priority),
    "content-type": "application/json",
  };
  if (push.collapseId !== undefined) headers["apns-collapse-id"] = push.collapseId;
  if (push.expiration !== undefined) headers["apns-expiration"] = String(push.expiration);

  let status: number;
  let apnsId: string;
  let body: string;
  try {
    const response = await deps.fetch(`https://${hostFor(device.environment)}/3/device/${device.apnsToken}`, {
      method: "POST",
      headers,
      body: push.payload,
      signal: AbortSignal.timeout(APNS_TIMEOUT_MS),
    });
    status = response.status;
    apnsId = response.headers.get("apns-id") ?? "";
    body = await response.text();
  } catch {
    return { kind: "unreachable" };
  }

  if (status === 200) return { kind: "sent", apnsId };
  const reason = reasonFrom(body);
  // Apple no longer accepts this JWT. Sign a new one for the next request.
  if (status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) {
    dropProviderToken();
  }
  return { kind: "rejected", status, reason };
}
