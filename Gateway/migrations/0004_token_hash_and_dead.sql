-- From this migration on, migrations only add: the database holds registrations that stay.
-- A migration adds columns, tables and indexes, and fills new columns from what the rows
-- already hold. scripts/deploy.sh checks every pending file for that before it applies one.

-- token_hash is SHA-256 (hex) of apns_token. The devices that share a token are found by
-- it: at most three may, and their pushes are counted together. SQLite has no SHA-256, so a
-- row that was here before this column keeps NULL, which reads as "shares its token with no
-- other row", until the Worker fills it in with the device's next management write.
ALTER TABLE devices ADD COLUMN token_hash TEXT;

-- 1 once Apple said the token will never work again. The push that learns it sets the flag
-- in the write that counts the push. A token change sets it back to 0, and the daily purge
-- deletes the devices that still carry it. Every row that was here before starts at 0.
ALTER TABLE devices ADD COLUMN dead INTEGER NOT NULL DEFAULT 0;

-- Finds the devices of one token. A push does not write it: it changes neither column.
CREATE INDEX IF NOT EXISTS devices_token ON devices (token_hash);
