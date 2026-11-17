-- Secrets become per helper: a phone (device) holds 0 to 10 of them, one for each computer
-- it gets pushes from. Nothing built on the first schema was released and its rows were only
-- tests, so the tables are dropped and made again instead of altered.
DROP TABLE IF EXISTS counters;
DROP TABLE IF EXISTS devices;

-- The tables are WITHOUT ROWID and carry as few indexes as the queries need, because D1's
-- daily allowance counts every row written, and an index entry is a row.

-- One row per registered phone. owner_hash is SHA-256 (hex) of a key only the phone holds.
-- updated_at is the last registration or token change; the daily purge reads it.
CREATE TABLE devices (
  device_id   TEXT PRIMARY KEY,
  owner_hash  TEXT NOT NULL,
  apns_token  TEXT NOT NULL,
  environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
) WITHOUT ROWID;

-- One row per helper a phone handed a secret to. secret_hash is SHA-256 (hex) of the secret,
-- so a dump of this table can't push to anyone. It is the primary key because every push
-- looks its secret up by it.
--
-- day is the UTC day number (unix time / 86400) of the secret's last push, or of its creation
-- before the first one, and day_count is the pushes on that day. One UPDATE per push keeps
-- the daily cap and tells the purge when the secret was last used.
CREATE TABLE secrets (
  secret_hash TEXT PRIMARY KEY,
  device_id   TEXT NOT NULL REFERENCES devices (device_id) ON DELETE CASCADE,
  secret_id   TEXT NOT NULL,
  label       TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  day         INTEGER NOT NULL,
  day_count   INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;

-- Lists a device's secrets, finds one by its id, and serves the cascade when a device goes.
CREATE UNIQUE INDEX secrets_device ON secrets (device_id, secret_id);

-- Fixed-window counters for the caps kept in D1. A row is reused when its window has ended;
-- rows nobody comes back to are deleted by the daily purge. No index on expires_at: the
-- table is small, and an index would add a written row to every count.
CREATE TABLE counters (
  key        TEXT PRIMARY KEY,
  count      INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
) WITHOUT ROWID;
