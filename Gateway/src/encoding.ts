const encoder = new TextEncoder();

export function utf8(text: string): Uint8Array {
  return encoder.encode(text);
}

/** Base64url without padding (RFC 4648 §5), the form JWS and our credentials use. */
export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** `byteCount` random bytes as base64url: 32 bytes give 43 characters, 20 give 27. */
export function randomToken(byteCount: number): string {
  return base64url(crypto.getRandomValues(new Uint8Array(byteCount)));
}

async function sha256(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", utf8(text)));
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await sha256(text);
  let hex = "";
  for (const b of digest) hex += b.toString(16).padStart(2, "0");
  return hex;
}

/**
 * True for the one way to write 32 bytes as base64url without padding: 43 characters, the
 * last of which carries four bits of the bytes and two that are zero. An owner key and a
 * push secret a phone chooses have this form, so each value has exactly one spelling.
 */
export function isKey(text: string): boolean {
  return /^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/.test(text);
}

/** How long a device id a phone chooses is. The ids the gateway makes have 27 characters. */
export const CHOSEN_DEVICE_ID_LENGTH = 22;

/**
 * The device id that belongs to an owner key a phone chose: the first 22 characters of
 * base64url(SHA-256("rexduo-device-v1\n" + owner_key)). The phone derives it the same way,
 * so a key names one device and the gateway can check the pair without a lookup.
 */
export async function deviceIdFor(ownerKey: string): Promise<string> {
  return base64url(await sha256(`rexduo-device-v1\n${ownerKey}`)).slice(0, CHOSEN_DEVICE_ID_LENGTH);
}
