import {
  type Client,
  MAX_DEVICES_PER_TOKEN,
  MAX_SECRETS_PER_DEVICE,
  type ManageCounts,
  type PushCounts,
  counterKey,
  utcDay,
} from "./limits";
import type { Environment } from "./validate";

/**
 * Credentials reach this module only as SHA-256 hashes. Each owner-key check is part of a
 * statement's `WHERE` together with the device id, so a wrong key and an unknown device are
 * the same empty result and nothing can tell them apart.
 *
 * `token_hash` is SHA-256 of the APNs token. It is how the rows of one token find each
 * other, and it stays in this module: no reply carries it.
 */

export interface NewDevice {
  deviceId: string;
  ownerHash: string;
  apnsToken: string;
  tokenHash: string;
  environment: Environment;
}

export interface NewSecret {
  secretId: string;
  secretHash: string;
  label: string;
}

export interface SecretInfo {
  secret_id: string;
  label: string;
  created_at: number;
}

/** What an owner-key route needs to know about its device. */
export interface OwnedDevice extends ManageCounts {
  environment: Environment;
  /** The device's token when its row has no `token_hash` yet, so the caller can fill it in. */
  unhashedToken: string | null;
  /** Other devices that hold the token the caller asked about. */
  othersWithToken: number;
}

/** What a push needs to know about the device its secret belongs to. */
export interface PushTarget extends PushCounts {
  deviceId: string;
  apnsToken: string;
  environment: Environment;
  /** Apple said this token will never work again. */
  dead: boolean;
}

/**
 * Adds a device. False when its token already has the most devices it may: the count is
 * part of the insert, so two registrations at once can't both take the last place.
 */
export async function insertDevice(db: D1Database, d: NewDevice, now: number): Promise<boolean> {
  const result = await db
    .prepare(
      `INSERT INTO devices
         (device_id, owner_hash, apns_token, token_hash, environment, created_at, updated_at, push_day, manage_day)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?6, ?7, ?7
       WHERE (SELECT COUNT(*) FROM devices WHERE token_hash = ?4) < ?8`,
    )
    .bind(d.deviceId, d.ownerHash, d.apnsToken, d.tokenHash, d.environment, now, utcDay(now), MAX_DEVICES_PER_TOKEN)
    .run();
  return result.meta.changes > 0;
}

/**
 * The device with this id and owner key, or null. This is the owner-key check. The same read
 * brings the counts the management caps need, so a write at a cap is refused without a
 * write. `newTokenHash` is the token a token change asks for: the read then also counts
 * the other devices that hold it.
 */
export async function findOwned(
  db: D1Database,
  deviceId: string,
  ownerHash: string,
  client: Client,
  now: number,
  newTokenHash: string | null = null,
): Promise<OwnedDevice | null> {
  const counter = (place: number): string => `(SELECT count FROM counters WHERE key = ?${place} AND expires_at > ?3)`;
  const row = await db
    .prepare(
      `SELECT environment, manage_day, manage_count,
              CASE WHEN token_hash IS NULL THEN apns_token END AS unhashed_token,
              ${counter(4)} AS from_address,
              ${counter(5)} AS from_wide,
              ${counter(6)} AS today,
              ${counter(7)} AS deleted,
              (SELECT COUNT(*) FROM devices o WHERE o.token_hash = ?8 AND o.device_id <> ?1) AS others
       FROM devices WHERE device_id = ?1 AND owner_hash = ?2`,
    )
    .bind(
      deviceId,
      ownerHash,
      now,
      counterKey.manageFrom(client.address),
      // No counter has the empty key, so a client without a /48 reads no row here.
      client.wide === null ? "" : counterKey.manageFrom(client.wide),
      counterKey.manage(),
      counterKey.deletes(),
      newTokenHash,
    )
    .first<{
      environment: Environment;
      manage_day: number;
      manage_count: number;
      unhashed_token: string | null;
      from_address: number | null;
      from_wide: number | null;
      today: number | null;
      deleted: number | null;
      others: number;
    }>();
  if (!row) return null;
  return {
    environment: row.environment,
    manageDay: row.manage_day,
    manageCount: row.manage_count,
    managedFromAddress: row.from_address ?? 0,
    managedFromWideAddress: row.from_wide ?? 0,
    managedToday: row.today ?? 0,
    deletedToday: row.deleted ?? 0,
    unhashedToken: row.unhashed_token,
    othersWithToken: row.others,
  };
}

/** True while a device has this id and owner key. */
export async function isOwned(db: D1Database, deviceId: string, ownerHash: string): Promise<boolean> {
  const row = await db
    .prepare("SELECT 1 AS found FROM devices WHERE device_id = ?1 AND owner_hash = ?2")
    .bind(deviceId, ownerHash)
    .first();
  return row !== null;
}

/**
 * Replaces the token and environment, and with them the token's hash. The device starts
 * again as live: `dead` belonged to the token that is replaced. False when no device has
 * this id and owner key, or when the new token already has the most devices it may; the
 * count is part of the update, so two changes at once can't both take the last place.
 */
export async function updateToken(
  db: D1Database,
  deviceId: string,
  ownerHash: string,
  apnsToken: string,
  tokenHash: string,
  environment: Environment,
  now: number,
): Promise<boolean> {
  const result = await db
    .prepare(
      `UPDATE devices SET apns_token = ?3, token_hash = ?4, environment = ?5, updated_at = ?6, dead = 0
       WHERE device_id = ?1 AND owner_hash = ?2
         AND (SELECT COUNT(*) FROM devices o WHERE o.token_hash = ?4 AND o.device_id <> ?1) < ?7`,
    )
    .bind(deviceId, ownerHash, apnsToken, tokenHash, environment, now, MAX_DEVICES_PER_TOKEN)
    .run();
  return result.meta.changes > 0;
}

/** Deletes the device and, through the foreign key, its secrets. False when the id or key is wrong. */
export async function deleteOwned(db: D1Database, deviceId: string, ownerHash: string): Promise<boolean> {
  const result = await db
    .prepare("DELETE FROM devices WHERE device_id = ?1 AND owner_hash = ?2")
    .bind(deviceId, ownerHash)
    .run();
  return result.meta.changes > 0;
}

export async function listSecrets(db: D1Database, deviceId: string): Promise<SecretInfo[]> {
  const rows = await db
    .prepare("SELECT secret_id, label, created_at FROM secrets WHERE device_id = ?1 ORDER BY created_at, secret_id")
    .bind(deviceId)
    .all<SecretInfo>();
  return rows.results;
}

/**
 * Adds a secret to a device the caller owns. False when the device already holds the most it
 * may: the count is part of the insert, so two requests at once can't both take the last place.
 */
export async function insertSecret(
  db: D1Database,
  deviceId: string,
  ownerHash: string,
  s: NewSecret,
  now: number,
): Promise<boolean> {
  const result = await db
    .prepare(
      `INSERT INTO secrets (secret_hash, device_id, secret_id, label, created_at)
       SELECT ?3, device_id, ?4, ?5, ?6 FROM devices
       WHERE device_id = ?1 AND owner_hash = ?2
         AND (SELECT COUNT(*) FROM secrets WHERE device_id = ?1) < ?7`,
    )
    .bind(deviceId, ownerHash, s.secretHash, s.secretId, s.label, now, MAX_SECRETS_PER_DEVICE)
    .run();
  return result.meta.changes > 0;
}

/** Removes one secret of a device. Removing one that is already gone is not an error. */
export async function deleteSecret(db: D1Database, deviceId: string, secretId: string): Promise<void> {
  await db.prepare("DELETE FROM secrets WHERE device_id = ?1 AND secret_id = ?2").bind(deviceId, secretId).run();
}

/**
 * The lookup is the authentication: a secret is valid when a row holds its hash. The same
 * read brings whether the device's token is dead and the two counts the caps need, so a
 * push for a dead token or at a cap is refused without a write.
 *
 * The token's count is the sum of today's counts over the rows with the device's
 * `token_hash`. A row without a hash is counted alone.
 */
export async function findBySecret(db: D1Database, secretHash: string, now: number): Promise<PushTarget | null> {
  const row = await db
    .prepare(
      `SELECT d.device_id, d.apns_token, d.environment, d.dead,
              CASE
                WHEN d.token_hash IS NULL THEN CASE WHEN d.push_day = ?4 THEN d.push_count ELSE 0 END
                ELSE (SELECT COALESCE(SUM(o.push_count), 0) FROM devices o
                      WHERE o.token_hash = d.token_hash AND o.push_day = ?4)
              END AS token_count,
              (SELECT count FROM counters WHERE key = ?2 AND expires_at > ?3) AS sent_today
       FROM secrets s JOIN devices d ON d.device_id = s.device_id
       WHERE s.secret_hash = ?1`,
    )
    .bind(secretHash, counterKey.sends(), now, utcDay(now))
    .first<{
      device_id: string;
      apns_token: string;
      environment: Environment;
      dead: number;
      token_count: number;
      sent_today: number | null;
    }>();
  if (!row) return null;
  return {
    deviceId: row.device_id,
    apnsToken: row.apns_token,
    environment: row.environment,
    dead: row.dead !== 0,
    tokenCount: row.token_count,
    sentToday: row.sent_today ?? 0,
  };
}
