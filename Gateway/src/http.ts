/** What a handler answers. `reason` and `apnsStatus` are Apple's, kept for the log line. */
export interface Reply {
  status: number;
  body?: Record<string, unknown>;
  headers?: Record<string, string>;
  reason?: string;
  apnsStatus?: number;
}

export function ok(status: number, body: Record<string, unknown>): Reply {
  return { status, body };
}

export function fail(status: number, error: string, message: string, extra: Record<string, unknown> = {}): Reply {
  return { status, body: { error, message, ...extra } };
}

export function rateLimited(retryAfter: number, message: string): Reply {
  return { ...fail(429, "rate_limited", message), headers: { "retry-after": String(retryAfter) } };
}

/** One generic answer for a missing, malformed or unknown credential, so none can be told apart. */
export function unauthorized(): Reply {
  return fail(401, "unauthorized", "Missing or invalid credentials.");
}

/** No CORS headers on purpose: the phone and the helper are the only clients, never a browser. */
export function toResponse(reply: Reply): Response {
  const headers = new Headers(reply.headers);
  headers.set("content-type", "application/json");
  headers.set("cache-control", "no-store");
  return new Response(reply.body === undefined ? null : JSON.stringify(reply.body), { status: reply.status, headers });
}

export type BodyResult = { ok: true; value: unknown } | { ok: false; reply: Reply };

/**
 * Reads at most `maxBytes` of the request body and parses it as JSON. `Content-Length` is
 * checked first to refuse early, and the read itself is bounded because the header can be
 * absent (chunked) and nothing should make the Worker buffer more than it asked for.
 */
export async function readJson(request: Request, maxBytes: number): Promise<BodyResult> {
  const tooLarge: BodyResult = {
    ok: false,
    reply: fail(413, "payload_too_large", `The request body is larger than ${maxBytes} bytes.`),
  };
  const malformed: BodyResult = { ok: false, reply: fail(400, "invalid_request", "The body is not valid JSON.") };

  const declared = request.headers.get("content-length");
  if (declared !== null) {
    if (!/^\d{1,15}$/.test(declared)) return malformed;
    if (Number(declared) > maxBytes) return tooLarge;
  }
  if (!request.body) return malformed;

  const bytes = new Uint8Array(maxBytes);
  let length = 0;
  const reader = request.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (length + value.byteLength > maxBytes) {
      await reader.cancel();
      return tooLarge;
    }
    bytes.set(value, length);
    length += value.byteLength;
  }

  try {
    const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes.subarray(0, length));
    return { ok: true, value: JSON.parse(text) };
  } catch {
    // The parser's message can quote the input, so it is neither returned nor logged.
    return malformed;
  }
}

const BEARER = /^Bearer ([A-Za-z0-9_-]{43})$/i;

/** The credential from `Authorization: Bearer …`, or null unless it has the shape of one of ours. */
export function bearer(request: Request): string | null {
  return BEARER.exec(request.headers.get("authorization") ?? "")?.[1] ?? null;
}
