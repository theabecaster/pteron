import { IDLE_SECONDS, PURGE_COUNTERS_PER_RUN, PURGE_DEVICES_PER_RUN, utcDay } from "./limits";

export interface PurgeResult {
  devices: number;
  counters: number;
}

/**
 * The daily clean-up. It deletes devices whose token Apple no longer accepts (`dead`),
 * devices that were not registered, updated or pushed to for 180 days (a phone that
 * uninstalled the app without unregistering, a registration nobody ever used), all with
 * their secrets, and counters whose window has ended.
 *
 * "Pushed to" is the day on the device's row that every push writes with its count. The day
 * of the device's last management write is beside it, so pairing a helper also counts as use.
 *
 * Each delete is bounded, so one run can't spend the day's budget for rows written on a
 * backlog. The next runs take the rest.
 */
export async function purge(db: D1Database, now: number): Promise<PurgeResult> {
  const cutoff = now - IDLE_SECONDS;
  const devices = await db
    .prepare(
      `DELETE FROM devices WHERE device_id IN (
         SELECT device_id FROM devices
         WHERE dead <> 0 OR (updated_at < ?1 AND push_day < ?2 AND manage_day < ?2)
         LIMIT ?3)
       RETURNING device_id`,
    )
    .bind(cutoff, utcDay(cutoff), PURGE_DEVICES_PER_RUN)
    .all();
  const counters = await db
    .prepare("DELETE FROM counters WHERE key IN (SELECT key FROM counters WHERE expires_at <= ?1 LIMIT ?2)")
    .bind(now, PURGE_COUNTERS_PER_RUN)
    .run();
  // The returned rows are counted, not `changes`, which also counts the secrets the foreign
  // key deleted with each device.
  return { devices: devices.results.length, counters: counters.meta.changes };
}
