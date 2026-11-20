/**
 * Desk presence: the leases a phone's own computers hold while its person sits at one of them.
 *
 * One Durable Object per phone (`idFromName("phone:" + device_id)`), SQLite-backed, binding
 * `PRESENCE_DO`. It holds at most MAX_LEASES `{tag, until}` pairs. A tag is an HMAC the
 * computers make with a key only the phone and its own computers hold, so what is stored
 * here names no computer and no person. Nothing else is kept but a count of the day's
 * writes.
 *
 * Presence only ever holds a push back, and a hold is the one thing that can delay a
 * question, so every rule here leans toward sending: an unknown phone holds nothing, a lease
 * past its time holds nothing, and a request that can't be answered is answered "send" by
 * the Worker (src/index.ts, `deskHolds`).
 *
 * The Durable Object takes the clock from the Worker's request (`now`), so tests set it. Only
 * the alarm reads the real clock, and never earlier than the time it was set for.
 */
import { DurableObject } from "cloudflare:workers";
import { DAY, utcDay } from "./limits";

/** The most leases a phone holds. When full, a new tag takes the place of the one closest to expiry. */
export const MAX_LEASES = 4;

/** The longest lease a computer may ask for, in seconds. Beacon asks for 600. */
export const MAX_LEASE_SECONDS = 900;

/**
 * Leases written per phone per UTC day. 4 desks renewing every 5 minutes all day write
 * 4 x 288 = 1,152; this leaves a quarter more for arrivals. Removing a lease is never refused.
 */
export const LEASE_WRITES_PER_DAY = 1500;

/** What a tag looks like: base64url(HMAC-SHA256(…))[:22]. */
export const TAG = /^[A-Za-z0-9_-]{22}$/;

interface Lease {
  tag: string;
  /** Unix time in seconds at which the lease ends. */
  until: number;
}

interface State {
  leases: Lease[];
  /** The UTC day `writes` counts. */
  day: number;
  writes: number;
  /** Unix time in seconds the alarm is set for. */
  wake: number;
}

export type LeaseResult = { stored: true } | { stored: false; retryAfter: number };

const KEY = "state";

export class Presence extends DurableObject {
  /** True when one of `tags` holds a lease that is still running at `now`. Writes nothing. */
  async holds(tags: string[], now: number): Promise<boolean> {
    const state = await this.ctx.storage.get<State>(KEY);
    if (!state) return false;
    return state.leases.some((lease) => lease.until > now && tags.includes(lease.tag));
  }

  /**
   * Stores `tag` until `now + ttl`, or removes it when `ttl` is 0. Only that tag changes. A
   * lease past the day's LEASE_WRITES_PER_DAY is refused with the seconds to the next UTC
   * day; a removal never is, and removing a tag that is not there writes nothing.
   */
  async lease(tag: string, ttl: number, now: number): Promise<LeaseResult> {
    const today = utcDay(now);
    const stored = await this.ctx.storage.get<State>(KEY);
    const state: State = stored ?? { leases: [], day: today, writes: 0, wake: 0 };
    if (state.day !== today) {
      state.day = today;
      state.writes = 0;
    }
    const live = state.leases.filter((lease) => lease.until > now && lease.tag !== tag);

    if (ttl === 0) {
      if (!state.leases.some((lease) => lease.tag === tag)) return { stored: true };
      state.leases = live;
    } else {
      if (state.writes >= LEASE_WRITES_PER_DAY) return { stored: false, retryAfter: (today + 1) * DAY - now };
      state.writes++;
      while (live.length >= MAX_LEASES) {
        // The lease closest to its end makes room.
        let soonest = 0;
        for (let i = 1; i < live.length; i++) if ((live[i]?.until ?? 0) < (live[soonest]?.until ?? 0)) soonest = i;
        live.splice(soonest, 1);
      }
      live.push({ tag, until: now + ttl });
      state.leases = live;
    }
    await this.save(state, now);
    return { stored: true };
  }

  /**
   * Removes every lease of the phone, when one of its computers stops being trusted. Tags
   * name no secret, so all go; the computers still trusted write theirs again at their next
   * renewal, and until then pushes are sent. The day's count stays. No state, no write.
   */
  async clear(now: number): Promise<void> {
    const state = await this.ctx.storage.get<State>(KEY);
    if (!state || state.leases.length === 0) return;
    state.leases = [];
    await this.save(state, now);
  }

  /**
   * Runs when the last lease ends: the leases go, and with them every tag. The day's count
   * of writes stays until that day is over, so a computer can't start the count again by
   * letting its leases run out; then everything goes.
   */
  async alarm(): Promise<void> {
    const state = await this.ctx.storage.get<State>(KEY);
    if (!state) {
      await this.ctx.storage.deleteAll();
      return;
    }
    // Never earlier than the time the alarm was set for, which is the Worker's clock.
    const now = Math.max(Math.floor(Date.now() / 1000), state.wake);
    state.leases = state.leases.filter((lease) => lease.until > now);
    await this.save(state, now);
  }

  /** Writes `state` and sets the alarm for its next change, or deletes everything when nothing is left. */
  private async save(state: State, now: number): Promise<void> {
    const last = state.leases.reduce((latest, lease) => Math.max(latest, lease.until), 0);
    const dayEnds = (state.day + 1) * DAY;
    let wake: number;
    if (state.leases.length > 0) wake = last;
    else if (state.writes > 0 && dayEnds > now) wake = dayEnds;
    else {
      await this.ctx.storage.deleteAlarm();
      await this.ctx.storage.deleteAll();
      return;
    }
    state.wake = wake;
    await this.ctx.storage.put(KEY, state);
    await this.ctx.storage.setAlarm(wake * 1000);
  }
}
