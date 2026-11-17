-- One row per registered phone. owner_hash and secret_hash are SHA-256 (hex) of credentials
-- only the phone and its helper hold, so a dump of this table can't push to anyone.
CREATE TABLE devices (
  device_id   TEXT PRIMARY KEY,
  owner_hash  TEXT NOT NULL,
  secret_hash TEXT NOT NULL UNIQUE,  -- the UNIQUE index serves the lookup on every push
  apns_token  TEXT NOT NULL,
  environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  last_used   INTEGER
);

-- Fixed-window counters for the rate limits and daily caps. A row is reused when its window
-- has ended; rows nobody comes back to are deleted by the sweep on registration.
CREATE TABLE counters (
  key        TEXT PRIMARY KEY,
  count      INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX counters_expires_at ON counters (expires_at);
