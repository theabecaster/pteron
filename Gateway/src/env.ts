import type { Presence } from "./presence";

export interface Env {
  DB: D1Database;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_TOPIC: string;
  /** The .p8 file's PEM text. A Workers Secret, never a var. */
  APNS_KEY_P8: string;
  /**
   * Workers Rate Limiting bindings (wrangler.toml, `[[ratelimits]]`). Optional on purpose: a
   * deployment or a test without them still works and relies on the caps kept in D1.
   */
  RL_ADDRESS?: RateLimit;
  RL_SECRET?: RateLimit;
  RL_GLOBAL?: RateLimit;
  /**
   * Desk presence (src/presence.ts): one Durable Object per phone. Optional: a deployment
   * without the binding has no presence, and pushes and answers as before presence existed.
   */
  PRESENCE_DO?: DurableObjectNamespace<Presence>;
}

/** What a request needs from outside, so tests replace Apple and the clock. */
export interface Deps {
  /** Used only for the request to APNs. */
  fetch: (url: string, init: RequestInit) => Promise<Response>;
  /** Unix time in seconds. */
  now: () => number;
}
