/**
 * Every limit the gateway enforces, and the counters behind the ones kept in D1.
 *
 * The short windows (per minute) are not in D1: they use the Workers Rate Limiting binding,
 * which counts in memory at each Cloudflare location. Its three limits are repeated in
 * wrangler.toml because the config can't read this file; a test compares the two.
 *
 * The daily limits are in D1, in two layers.
 *
 *   Per APNs token, per device and per client address. Pushes are counted per token: each
 *   device's row carries its own count for the day, and the cap applies to the sum over the
 *   rows that hold the same token (found by `token_hash`, at most MAX_DEVICES_PER_TOKEN of
 *   them). So the devices of one token have one allowance between them, the same a device
 *   alone on its token has, and a push still writes one device row: its own. A row whose
 *   `token_hash` is NULL (it is older than the column) is counted alone until its next
 *   management write fills the hash in. Management writes (a secret minted or deleted, a
 *   token change, the device deleted) are counted on the device's row and for the client
 *   address they come from. Registrations are counted for the client address, per hour and
 *   per day. The two `PUT` routes a phone can send again are counted by what a request
 *   does: a `PUT` that makes a device is a registration, one that changes a token is a
 *   token change, one that stores or replaces a secret is a secret minted, and one that
 *   finds the device or the secret as it says is not counted and writes nothing. An IPv6 client is counted under its /64 and under its /48, and a request needs
 *   room under both; an IPv4 client has the one key (src/address.ts).
 *
 *   Global budgets, one each for pushes, registrations, deletes (a secret or a device
 *   deleted) and the other management writes (a secret minted, a token change). Each has
 *   its own counter, so one that is spent leaves the others as they were: phones that are
 *   registered keep getting pushes, and a phone can still turn a helper or itself off, on a
 *   day when registrations or management writes reach their budget.
 *
 * A device whose token Apple no longer accepts takes part in no budget: the push that
 * learns it sets `dead` on the device's row in the write that counts that push, and every
 * later push for the device is refused from the read alone (src/index.ts, `push`).
 *
 * The most one token, device or address can take of a global budget is fixed:
 *
 *   pushes          one token       1,500 of 30,000 =  5 %
 *   registrations   one /64 or IPv4    20 of  1,000 =  2 %     one /48    60 =  6 %
 *   management      one device         60 of  1,000 =  6 %
 *                   one /64 or IPv4   120 of  1,000 = 12 %     one /48   240 = 24 %
 *   deletes         one device         60 of    600 = 10 %
 *
 * A delete counts on the same device counter as the other management writes, so the two
 * kinds together stay within 60 a device. It counts on no address counter: a phone can turn
 * a helper or itself off whatever else its address did that day.
 *
 * The global budgets are sized by the gateway's own daily budget for D1: 100,000 rows
 * written a day. The account is on the Workers Paid plan, whose D1 allowance is 50 million
 * rows written a month, so the budget is a small part of it, and it is what keeps the
 * usage-based bill small. An index entry counts as a row. Rows written by each operation,
 * at most, for an IPv6 client, which has two address counters where an IPv4 client has one
 * (ROWS below):
 *
 *   push              the device's row (its day count, which is also its last use, and
 *                     `dead` when Apple said so) and the `sends` counter                =  2
 *   registration      four address counters (hour and day, /64 and /48), the
 *                     `registrations` counter, the device and its `token_hash` entry    =  7
 *                     (`POST /v1/devices`, or a `PUT /v1/devices/{id}` that makes the
 *                     device)
 *   management write  four counts (the device's row, two address counters, the
 *                     `manage` counter), then the change itself:
 *                       mint a secret    4 + the secret and its index entry             =  6
 *                       (`POST …/secrets`, or a `PUT …/secrets/{id}` that stores one)
 *                       replace a secret 4 + the secret, which takes its new hash, and
 *                                        its index entry (`PUT …/secrets/{id}`)         =  6
 *                       token change     4 + the device and its `token_hash` entry      =  6
 *                       (`PUT /v1/devices/{id}` with another token or environment)
 *                       a mint or a replacement, once, for a row older than
 *                       `token_hash`: the entry of the hash that the count fills in     =  7
 *   a `PUT` again     the device holds that token and environment, or the secret is
 *                     stored under that id: one read                                    =  0
 *   a refusal         a cap that is spent, a secret for a device that holds
 *                     MAX_SECRETS_PER_DEVICE, a token that has MAX_DEVICES_PER_TOKEN
 *                     devices, a push secret that is in use: one read                   =  0
 *   delete            a secret: two counts (the device's row and the `deletes` counter) +
 *                     the secret and its index entry                                    =  4
 *                     the device: the `deletes` counter (its row is not counted, it
 *                     goes) + the device, its `token_hash` entry and 10 secrets x 2     = 23
 *   daily purge       200 devices x (1 + 1 + 10 secrets x 2) + 500 counters             = 4,900
 *
 * The worst day spends every budget in full, and every management write and delete is the
 * dearest of its kind (WORST_DAY_ROWS below):
 *
 *   pushes               30,000 x  2 = 60,000
 *   registrations         1,000 x  7 =  7,000
 *   management writes     1,000 x  7 =  7,000
 *   deletes                 600 x 23 = 13,800
 *   daily purge                         4,900
 *                              total   92,700 of 100,000
 *
 * A refused request writes nothing and counts nothing: each cap, and each limit on how many
 * rows there may be (devices a token, secrets a device), is checked against what the
 * request already read, so traffic past any of them costs D1 reads only. The statements
 * that count and that write repeat their checks, for requests that race each other to a
 * last place: the one that comes second is refused after its read, with what it counted
 * until then (src/index.ts, `countChange`).
 */

export interface Limit {
  max: number;
  windowSeconds: number;
}

export const DAY = 86400;

export const LIMITS = {
  /** Rate Limiting binding RL_ADDRESS: every request, per client address (IPv6 by /64). */
  addressPerMinute: { max: 120, windowSeconds: 60 },
  /** Rate Limiting binding RL_SECRET: pushes per secret. */
  secretPerMinute: { max: 30, windowSeconds: 60 },
  /** Rate Limiting binding RL_GLOBAL: every request, one key. A brake on floods. */
  allPerMinute: { max: 3000, windowSeconds: 60 },

  /** D1: registrations per client address (an IPv4 address or an IPv6 /64), per hour and per day. */
  registerPerAddressPerHour: { max: 10, windowSeconds: 3600 },
  registerPerAddressPerDay: { max: 20, windowSeconds: DAY },
  /** D1: registrations per IPv6 /48, per hour and per day. */
  registerPerWideAddressPerHour: { max: 30, windowSeconds: 3600 },
  registerPerWideAddressPerDay: { max: 60, windowSeconds: DAY },
  /** D1: registrations from everyone. */
  registerPerDay: { max: 1000, windowSeconds: DAY },

  /** D1: management writes per device, counted on the device's row. Deletes count. */
  managePerDevicePerDay: { max: 60, windowSeconds: DAY },
  /** D1: management writes per client address (an IPv4 address or an IPv6 /64). Deletes count. */
  managePerAddressPerDay: { max: 120, windowSeconds: DAY },
  /** D1: management writes per IPv6 /48. Deletes count. */
  managePerWideAddressPerDay: { max: 240, windowSeconds: DAY },
  /** D1: secrets minted and token changes, from everyone. */
  managePerDay: { max: 1000, windowSeconds: DAY },
  /** D1: secrets and devices deleted, from everyone. */
  deletesPerDay: { max: 600, windowSeconds: DAY },

  /** D1: pushes per APNs token, summed over the devices that share it and all their secrets. */
  pushPerTokenPerDay: { max: 1500, windowSeconds: DAY },
  /** D1: pushes from everyone. */
  pushPerDay: { max: 30000, windowSeconds: DAY },
} as const satisfies Record<string, Limit>;

/** One per helper, and a phone pairs with a handful of computers. */
export const MAX_SECRETS_PER_DEVICE = 10;

/** Registrations that may hold the same APNs token at one time. */
export const MAX_DEVICES_PER_TOKEN = 3;

/** A device nobody registered, updated or pushed to for this long is deleted. */
export const IDLE_SECONDS = 180 * DAY;
/** The most one purge run deletes, so a backlog is spread over several days. */
export const PURGE_DEVICES_PER_RUN = 200;
export const PURGE_COUNTERS_PER_RUN = 500;

/** D1 rows written by one operation. The comment at the top of this file explains each. */
const DEVICE_WITH_SECRETS = 1 + 1 + MAX_SECRETS_PER_DEVICE * 2;
export const ROWS = {
  push: 2,
  registration: 7,
  /** The dearest management write that is not a delete: a mint that also fills a row's `token_hash` in. */
  manage: 7,
  /** The dearest delete: a device that holds the most secrets. */
  delete: 1 + DEVICE_WITH_SECRETS,
  purge: PURGE_DEVICES_PER_RUN * DEVICE_WITH_SECRETS + PURGE_COUNTERS_PER_RUN,
} as const;

/** Rows written on a day that spends every budget in full: 92,700 of the budget of 100,000. */
export const WORST_DAY_ROWS =
  LIMITS.pushPerDay.max * ROWS.push +
  LIMITS.registerPerDay.max * ROWS.registration +
  LIMITS.managePerDay.max * ROWS.manage +
  LIMITS.deletesPerDay.max * ROWS.delete +
  ROWS.purge;

/**
 * A client address as the counters know it: SHA-256 of each of its keys (src/address.ts),
 * because the table needs to tell clients apart, not to know them. `wide` is the /48 of an
 * IPv6 client and null for everyone else.
 */
export interface Client {
  address: string;
  wide: string | null;
}

export const counterKey = {
  /** Registrations in the hour and in the day, from one address key's hash. */
  register: (addressHash: string) => `reg:${addressHash}`,
  registerDay: (addressHash: string) => `regd:${addressHash}`,
  registrations: () => "registrations",
  manageFrom: (addressHash: string) => `mng:${addressHash}`,
  manage: () => "manage",
  deletes: () => "deletes",
  sends: () => "sends",
};

export type Verdict = { allowed: true } | { allowed: false; retryAfter: number };

export function windowEnd(limit: Limit, now: number): number {
  return (Math.floor(now / limit.windowSeconds) + 1) * limit.windowSeconds;
}

/** The UTC day number of `now`, the unit a device's own counters are kept in. */
export function utcDay(now: number): number {
  return Math.floor(now / DAY);
}

function refusal(limit: Limit, now: number): Verdict {
  return { allowed: false, retryAfter: Math.max(1, windowEnd(limit, now) - now) };
}

/**
 * Asks a Rate Limiting binding. A missing binding (tests, a deployment without it) and a
 * failing one both count as allowed: the caps in D1 still hold, and a broken limiter must
 * not take the gateway down with it.
 */
export async function allowedBy(binding: RateLimit | undefined, key: string): Promise<boolean> {
  if (!binding) return true;
  try {
    return (await binding.limit({ key })).success;
  } catch {
    return true;
  }
}

/**
 * Counts one use of `key` and returns the new count, in one statement.
 *
 * A row whose window has ended starts again at 1. A row at its limit is left alone: the
 * `WHERE` fails, nothing is written and `RETURNING` yields no row, which is the refusal.
 * So a client that hammers a spent limit costs reads only, and nothing of the daily budget for rows written.
 */
function hitStatement(db: D1Database, key: string, limit: Limit, now: number): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO counters (key, count, expires_at) VALUES (?1, 1, ?2)
       ON CONFLICT (key) DO UPDATE SET
         count = CASE WHEN counters.expires_at <= ?3 THEN 1 ELSE counters.count + 1 END,
         expires_at = ?2
       WHERE counters.expires_at <= ?3 OR counters.count < ?4
       RETURNING count`,
    )
    .bind(key, windowEnd(limit, now), now, limit.max);
}

export async function hit(db: D1Database, key: string, limit: Limit, now: number): Promise<Verdict> {
  const row = await hitStatement(db, key, limit, now).first<{ count: number }>();
  return row ? { allowed: true } : refusal(limit, now);
}

/** The registration counters of one client, each with its limit: the address's, then the global one. */
function registrationChecks(client: Client): [string, Limit][] {
  const checks: [string, Limit][] = [
    [counterKey.register(client.address), LIMITS.registerPerAddressPerHour],
    [counterKey.registerDay(client.address), LIMITS.registerPerAddressPerDay],
  ];
  if (client.wide !== null) {
    checks.push(
      [counterKey.register(client.wide), LIMITS.registerPerWideAddressPerHour],
      [counterKey.registerDay(client.wide), LIMITS.registerPerWideAddressPerDay],
    );
  }
  checks.push([counterKey.registrations(), LIMITS.registerPerDay]);
  return checks;
}

/** A registration's verdict. `full` is the token that already has the most devices it may. */
export type RegistrationVerdict = Verdict | { allowed: false; full: true };

/**
 * Counts one registration against the address's hourly and daily limits and the global
 * daily cap, for a token that still has a place.
 *
 * Everything is read first, in one statement, and nothing is written unless every counter
 * has room and fewer than MAX_DEVICES_PER_TOKEN devices hold the token. So a registration
 * past any cap costs one read, whatever address it comes from.
 */
export async function hitRegistration(
  db: D1Database,
  client: Client,
  tokenHash: string,
  now: number,
): Promise<RegistrationVerdict> {
  const checks = registrationChecks(client);
  const keys = checks.map(([key]) => key);
  const places = keys.map((_, index) => `?${index + 3}`).join(", ");
  // The second row set is the devices of the token. No counter key starts with `#`.
  const live = await db
    .prepare(
      `SELECT key, count FROM counters WHERE key IN (${places}) AND expires_at > ?1
       UNION ALL
       SELECT '#devices', COUNT(*) FROM devices WHERE token_hash = ?2`,
    )
    .bind(now, tokenHash, ...keys)
    .all<{ key: string; count: number }>();
  for (const [key, limit] of checks) {
    const row = live.results.find((r) => r.key === key);
    if (row && row.count >= limit.max) return refusal(limit, now);
  }
  const devices = live.results.find((r) => r.key === "#devices")?.count ?? 0;
  if (devices >= MAX_DEVICES_PER_TOKEN) return { allowed: false, full: true };

  return countAll(
    db,
    checks.map(([key, limit]) => [hitStatement(db, key, limit, now), limit]),
    now,
  );
}

/** Runs the counting statements together. The first one that counted nothing is the refusal. */
async function countAll(
  db: D1Database,
  checks: [D1PreparedStatement, Limit][],
  now: number,
): Promise<Verdict> {
  const results = await db.batch<Record<string, number>>(checks.map(([statement]) => statement));
  // The caller checked every cap against what it read, so only a request that raced
  // another to the last place gets a refusal here. Its other counters have counted it.
  for (const [index, [, limit]] of checks.entries()) {
    if (results[index]?.results.length !== 1) return refusal(limit, now);
  }
  return { allowed: true };
}

/** What the push handler already read about its token and the global counter. */
export interface PushCounts {
  /** Today's pushes to the device's token, over every device that shares it. */
  tokenCount: number;
  /** Pushes from everyone today. */
  sentToday: number;
}

/**
 * Decides one push from the counts its read brought, without a write: the token's cap
 * first, so a token at its cap is refused whatever the global count is.
 */
export function pushVerdict(counts: PushCounts, now: number): Verdict {
  if (counts.tokenCount >= LIMITS.pushPerTokenPerDay.max) return refusal(LIMITS.pushPerTokenPerDay, now);
  if (counts.sentToday >= LIMITS.pushPerDay.max) return refusal(LIMITS.pushPerDay, now);
  return { allowed: true };
}

/**
 * Counts one push: exactly two rows written, the device's and the global counter's, in one
 * batch. It runs once Apple has answered, so the device's row also takes `dead` when the
 * answer was that the token will never work again.
 *
 * The device's count goes up while its token has room: the sum of today's counts over the
 * rows with the same `token_hash`, or the row's own count while its hash is NULL. Each
 * statement repeats its check, so requests that race can never write a counter past its
 * cap. A dead token is recorded whatever the counts are.
 */
export async function countPush(db: D1Database, deviceId: string, dead: boolean, now: number): Promise<void> {
  const device = db
    .prepare(
      `UPDATE devices SET
         push_count = CASE WHEN push_day = ?2 THEN push_count + 1 ELSE 1 END,
         push_day = ?2,
         dead = MAX(dead, ?4)
       WHERE device_id = ?1 AND (?4 = 1 OR ?3 > CASE
         WHEN token_hash IS NULL THEN CASE WHEN push_day = ?2 THEN push_count ELSE 0 END
         ELSE (SELECT COALESCE(SUM(o.push_count), 0) FROM devices o
               WHERE o.token_hash = devices.token_hash AND o.push_day = ?2)
       END)`,
    )
    .bind(deviceId, utcDay(now), LIMITS.pushPerTokenPerDay.max, dead ? 1 : 0);
  await db.batch([device, hitStatement(db, counterKey.sends(), LIMITS.pushPerDay, now)]);
}

/** What an owner-key handler already read about its device, its address and the global counters. */
export interface ManageCounts {
  /** The UTC day the device's management counter belongs to, and its value. */
  manageDay: number;
  manageCount: number;
  /** Management writes today from this client address, and from its /48 (0 without one). */
  managedFromAddress: number;
  managedFromWideAddress: number;
  /** Secrets minted and token changes today, from everyone. */
  managedToday: number;
  /** Secrets and devices deleted today, from everyone. */
  deletedToday: number;
}

/**
 * The kinds of management write. `change` mints a secret or changes the token and draws on
 * the management budget. `delete` removes a secret and `deviceGoes` removes the device;
 * both draw on the budget for deletes.
 */
export type ManageKind = "change" | "delete" | "deviceGoes";

/**
 * Counts one management write against its device and the global budget of its kind, and a
 * mint or a token change against its client address as well.
 *
 * As for a registration, the counts the caller read decide first, and nothing is written
 * unless all of them have room. For `deviceGoes` the device's row is about to go, so its
 * counter is neither checked nor raised. `fillTokenHash` is the hash of the device's token
 * for a row that has none yet: the write that counts on the row stores it.
 */
export async function hitManage(
  db: D1Database,
  deviceId: string,
  client: Client,
  counts: ManageCounts,
  now: number,
  kind: ManageKind,
  fillTokenHash: string | null = null,
): Promise<Verdict> {
  // Deleting the device is how its owner turns every secret off, so the device's own count
  // never stands in its way: it can happen once, and a device is only made again within the
  // registration limits. The budget for deletes still applies.
  if (kind !== "deviceGoes" && counts.manageDay === utcDay(now) && counts.manageCount >= LIMITS.managePerDevicePerDay.max) {
    return refusal(LIMITS.managePerDevicePerDay, now);
  }
  // A delete is how a phone turns a helper or itself off, so no count it shares with other
  // devices at its address is in its way: the address counts are for mints and token changes.
  const byAddress = kind === "change";
  if (byAddress && counts.managedFromAddress >= LIMITS.managePerAddressPerDay.max) {
    return refusal(LIMITS.managePerAddressPerDay, now);
  }
  if (byAddress && counts.managedFromWideAddress >= LIMITS.managePerWideAddressPerDay.max) {
    return refusal(LIMITS.managePerWideAddressPerDay, now);
  }
  const [budgetKey, budget, spent] =
    kind === "change"
      ? ([counterKey.manage(), LIMITS.managePerDay, counts.managedToday] as const)
      : ([counterKey.deletes(), LIMITS.deletesPerDay, counts.deletedToday] as const);
  if (spent >= budget.max) return refusal(budget, now);

  const checks: [D1PreparedStatement, Limit][] = [];
  if (kind !== "deviceGoes") {
    // The hash is named in the statement only when it is filled in: an UPDATE that names an
    // indexed column writes its index entry again.
    const fill = fillTokenHash === null ? "" : ", token_hash = COALESCE(token_hash, ?4)";
    const statement = db.prepare(
      `UPDATE devices SET
         manage_count = CASE WHEN manage_day = ?2 THEN manage_count + 1 ELSE 1 END,
         manage_day = ?2${fill}
       WHERE device_id = ?1 AND (manage_day <> ?2 OR manage_count < ?3)
       RETURNING manage_count`,
    );
    const values = [deviceId, utcDay(now), LIMITS.managePerDevicePerDay.max];
    checks.push([
      fillTokenHash === null ? statement.bind(...values) : statement.bind(...values, fillTokenHash),
      LIMITS.managePerDevicePerDay,
    ]);
  }
  if (byAddress) {
    checks.push([
      hitStatement(db, counterKey.manageFrom(client.address), LIMITS.managePerAddressPerDay, now),
      LIMITS.managePerAddressPerDay,
    ]);
  }
  if (byAddress && client.wide !== null) {
    checks.push([
      hitStatement(db, counterKey.manageFrom(client.wide), LIMITS.managePerWideAddressPerDay, now),
      LIMITS.managePerWideAddressPerDay,
    ]);
  }
  checks.push([hitStatement(db, budgetKey, budget, now), budget]);
  return countAll(db, checks, now);
}
