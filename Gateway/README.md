# Pteron push gateway

A Cloudflare Worker that sends Pteron's push notifications to Apple (APNs). It holds the APNs
key and each phone's APNs token, so Pteron Beacon (the helper) holds neither. A phone registers its token
here, mints one `push_secret` for each helper and hands it over. A secret can push to that one
phone through this app's topic and do nothing else, and the phone can take it back at any time
without touching its other helpers.

TypeScript on the plain Workers runtime, no runtime dependencies. Devices, secrets and the
daily counters live in D1 (`migrations/`).

## API

JSON in and out. Errors are `{"error": "<code>", "message": "<sentence>"}`.

| Route | Auth | Does | Answers |
|---|---|---|---|
| `GET /v1/health` | none | Nothing. Touches neither Apple nor D1. | `200 {"ok": true, "version"}` |
| `POST /v1/devices` | none | Registers `{"apns_token", "environment"}`. At most 3 registrations per token. | `201 {"device_id", "owner_key"}`, `400`, `409 too_many_devices`, `429` |
| `GET /v1/devices/{id}` | owner key | Shows the registration, so a phone can learn whether it and a helper's secret still exist. | `200 {"environment", "secrets": [{"secret_id", "label", "created_at"}]}`, `401` |
| `PUT /v1/devices/{id}` | owner key | Replaces the token and environment. The secrets stay, and a device whose token was dead is live again. With an id the phone chose it also makes the device (see below). | `200 {}`, `201 {"device_id"}`, `400`, `401`, `409 too_many_devices`, `429` |
| `DELETE /v1/devices/{id}` | owner key | Unregisters: deletes the device and all its secrets. | `204`, `401`, `429` |
| `POST /v1/devices/{id}/secrets` | owner key | Mints a secret for one helper from `{"label"}` (1 to 64 printable characters). At most 10 per device. | `201 {"secret_id", "push_secret"}`, `400`, `401`, `409 too_many_secrets`, `429` |
| `PUT /v1/devices/{id}/secrets/{secret_id}` | owner key | Stores `{"label", "push_secret"}`, a secret the phone chose, under an id it chose, or puts it in the place of the one under that id (see below). At most 10 per device. | `201 {"secret_id"}`, `200 {"secret_id"}`, `400`, `401`, `409 conflict`, `409 too_many_secrets`, `429` |
| `DELETE /v1/devices/{id}/secrets/{secret_id}` | owner key | Deletes one secret. It stops working at once. | `204` (also when already gone), `401`, `429` |
| `POST /v1/push` | push secret | Sends `{"payload", "push_type", "priority", "collapse_id", "expiration"}` to the secret's phone. | `200 {"apns_id"}`, `400`, `401`, `410`, `413`, `429`, `502` |

Every route can also answer `429` from the per-minute limits below.

Auth is `Authorization: Bearer <value>`. Every `401` is the same response, body
`{"error":"unauthorized","message":"Missing or invalid credentials."}`: a missing, malformed or
unknown credential, a wrong owner key and an unknown device id can't be told apart, on any
method. So a device that is gone answers `401`, not `404`, also to `DELETE`. The fixed body lets
a client tell the gateway's own `401` from a proxy's.

### Requests a phone can send again

A phone has two ways to register and to make a secret. With `POST` the gateway makes the
values and answers them once. With `PUT` the phone makes them, stores them before it sends,
and can send the same request again: after an answer that never arrived, the repeat gets the
same device or the same secret, and nothing new is made. Both ways work on the same devices
and secrets, and every other route treats them alike.

**`PUT /v1/devices/{device_id}`**, body `{"apns_token", "environment"}`,
`Authorization: Bearer <owner_key>`.

- `owner_key` is 32 random bytes as base64url without padding: 43 characters, in the one
  spelling 32 bytes have. Another form answers `401`.
- `device_id` is the first 22 characters of
  base64url(SHA-256(`"rexduo-device-v1\n"` + `owner_key`)), where the hash is taken over
  those bytes of text. An id of 22 characters that is not the id of the key in the request
  answers `400 invalid_request`. The gateway decides that from the request alone, before it
  reads D1, so the answer is the same whether a device has the id or not, and a key only
  ever reaches its own device. The ids `POST` makes have 27 characters; for those and any
  other length `PUT` is the token change it always was, with `401` for an id no device has.
- No device has the id: it is made, `201 {"device_id"}`. This is a registration, with every
  cap a registration has, the 3 devices per token among them.
- The device holds this token and environment: `200 {}`. Nothing is written or counted.
- The device holds another token or environment: they are replaced, `200 {}`. This is a
  token change: one management write, with the caps a token change has. A device marked dead
  is in this case also with the token it holds, and is live again, as after any token
  change.

**`PUT /v1/devices/{device_id}/secrets/{secret_id}`**, body `{"label", "push_secret"}`,
owner key as above, for a device made by either route.

- `secret_id` is 16 url-safe characters and `push_secret` 32 random bytes as base64url, 43
  characters, and not the owner key. `label` is as for `POST`. Anything else answers
  `400 invalid_request`. The gateway stores the hash of `push_secret`, as for a secret it
  minted.
- The device holds nothing under the id: the secret is stored, `201 {"secret_id"}`. One
  management write, within the 10 secrets a device may hold. The 10 are ids, however often
  each was sent. A device that holds 10 answers `409 too_many_secrets` to an id it does not
  hold, from the one read: nothing is written or counted. An id it holds is still answered
  as below.
- The device holds this secret under the id: `200 {"secret_id"}`. Nothing is written or
  counted, and the label stays as it was stored.
- The device holds another secret under the id: it is replaced, with the label and the time
  of this request, `200 {"secret_id"}`. One management write. The secret that was there
  stops working at once.
- `push_secret` is already stored in another row: `409 conflict`, and nothing is written or
  counted.
  The answer is the same whether that row is this device's or another's.

A secret belongs to the device it was stored for and stays there: a push secret names
exactly one row, and no route gives a row another device. Secret ids are each device's own,
so two devices may use the same id for different secrets.

Push answers:

- `410 unregistered`: Apple said the token is dead (`410`, or `400` with `BadDeviceToken` or
  `DeviceTokenNotForTopic`). The push that hears it carries Apple's `reason` and marks the
  device dead. From then on every push for that device, through any of its secrets, gets
  `410 unregistered` without a `reason`: the gateway answers from one D1 read, writes nothing,
  counts nothing and does not ask Apple. The helper must drop the device. Its owner still
  reaches it with the owner key: `GET` shows it, `PUT` with a new token makes it live again
  with the secrets it had, and `DELETE` removes it. The daily purge deletes the devices that
  are still dead, with their secrets.
- `502 apns_error` with Apple's `status` and `reason`, or `502 apns_unreachable` when the request
  to Apple failed. The device stays.
- `400 invalid_request`: the body or the payload is not what the table below allows.
- `413 payload_too_large`: the payload is over 4096 bytes, or the whole body over 8 KB.
- `429 rate_limited` with `Retry-After` in seconds.

Rules the caller can't change: the APNs host comes from the device's stored environment, the
topic is always `dev.abrahamgonzalez.rexduo`, and the token is the one the phone registered.

The fields beside the payload:

| Field | Holds |
|---|---|
| `push_type` | `alert`, which is also the default. No other type is sent. |
| `priority` | `10` (the default) or `5`. |
| `collapse_id` | optional, 1 to 64 visible ASCII characters. |
| `expiration` | optional, a unix time in seconds from now to 3600 seconds from now, by the gateway's clock. The helper sends an hour from its own clock, so a minute either side is accepted: now − 60 to now + 3660. |

The payload is the notification the helper builds (`Relay/src/push.rs`) and nothing else. Every
field is a string, and a field that is not in this table is refused with `400`:

| Field | Holds | At most |
|---|---|---|
| `aps.alert.title`, `aps.alert.body` | required | 120 and 1000 characters |
| `aps.alert.subtitle` | optional | 256 characters |
| `aps.category` | `AGENT_BLOCKED`, `AGENT_DONE` or `NOTICE` | |
| `aps.interruption-level` | `passive`, `active` or `time-sensitive` | |
| `aps.thread-id` | the pane's id | 256 characters |
| `aps.sound` | `default` | |
| `server` | the Rex server's address | 512 characters |
| `session_id`, `window_id`, `block_id` | ids the app opens | 256 characters each |

It reaches Apple as `JSON.stringify` of the parsed `payload`: same keys, order and values,
compact, which is what the helper sends. The 4096-byte limit applies to that text.

## Layout

- `src/index.ts`: routing, the handlers and the cron handler. `handleRequest` takes the clock and
  the `fetch` used for Apple, which is how tests replace both.
- `src/apns.ts`: the provider JWT and the request to Apple.
- `src/limits.ts`: every limit as a constant, the arithmetic behind them, and the counters.
- `src/storage.ts`: the device and secret queries. `src/purge.ts`: the daily clean-up.
- `src/address.ts`: the client address a limit is keyed by (IPv6 by /64 and by /48).
- `src/validate.ts`: the request bodies. `src/http.ts`: replies, the bounded body read, the
  bearer header.

## Secrets

- `owner_key` and `push_secret` are 32 random bytes each, made by the gateway (`POST`, which
  returns each once) or by the phone (`PUT`). The gateway stores only the SHA-256 of each, so
  a copy of the database can't push to anyone or manage a device.
- The APNs key is the Workers Secret `APNS_KEY_P8` (the `.p8` file's text). `scripts/deploy.sh`
  reads it from the APNs key file in `~/.appstoreconnect/private_keys/` (the default name is in
  the script), or from the path in `APNS_KEY`, and pipes it to `wrangler secret put`. It is in no
  file of this repo and must never be. The key id, team id and topic are plain vars in `wrangler.toml`.
- The provider JWT is cached per isolate. Its `iat` is the start of a fixed 30-minute bucket, so
  every isolate signs the same claims and Apple never sees the token change more often than it
  allows (every 20 minutes) or age past its limit (an hour).
- The Worker logs one line per request: the route pattern, the status, and Apple's status and
  reason. The daily purge logs how many rows it deleted. Never a payload, token, key, secret,
  label, device id or address. Cloudflare's own per-request log is off in `wrangler.toml`
  because it records URLs.
- The rate limiters and the counters are keyed by SHA-256 of the client address and of the
  secret, never by the values.
- A device's row holds SHA-256 of its APNs token beside the token. The gateway uses it to
  find the devices that share a token. No reply carries it.

## Limits

All of them are constants in `src/limits.ts`.

| Limit | Value | Window | Kept in |
|---|---|---|---|
| Requests per client address | 120 | 60 s | Rate Limiting binding `RL_ADDRESS` |
| Requests, everyone | 3,000 | 60 s | Rate Limiting binding `RL_GLOBAL` |
| Pushes per secret | 30 | 60 s | Rate Limiting binding `RL_SECRET` |
| Pushes per APNs token, all the devices that share it and all their secrets together | 1,500 | UTC day | D1, on the devices' rows |
| Management writes per device | 60 | UTC day | D1, on the device's row |
| Secrets minted and token changes per client address (IPv4 address or IPv6 /64) | 120 | UTC day | D1 counter |
| Secrets minted and token changes per IPv6 /48 | 240 | UTC day | D1 counter |
| Registrations per client address (IPv4 address or IPv6 /64) | 10 and 20 | hour and UTC day | D1 counters |
| Registrations per IPv6 /48 | 30 and 60 | hour and UTC day | D1 counters |
| Pushes, everyone | 30,000 | UTC day | D1 counter |
| Registrations, everyone | 1,000 | UTC day | D1 counter |
| Secrets minted and token changes, everyone | 1,000 | UTC day | D1 counter |
| Secrets and devices deleted, everyone | 600 | UTC day | D1 counter |
| Devices per APNs token | 3 | | D1 |
| Secrets per device | 10 | | D1 |

**Per token.** At most 3 registrations hold one APNs token at a time; a registration or a
token change that would make a fourth answers `409 too_many_devices`. Pushes are counted per
token: each device's row carries its own count for the day, and the cap applies to the sum
over the devices with the same token, so three devices on one token have the 1,500 pushes one
device alone has. A push still writes one device row, its own.

**Management writes.** A management write is a secret minted, a secret deleted, a token change
or the device deleted. A `PUT` that stores or replaces a secret counts as a secret minted, a
`PUT` that makes a device counts as a registration, and a `PUT` that finds the device or the
secret as the request says counts as nothing. Every one counts for its device, also the delete of a secret that is
already gone. A mint or a token change counts for its client address as well; a delete does
not, so a phone can turn a helper or itself off whatever else its address did that day. A
device can always delete itself, whatever its own count is. Globally they draw on two budgets:
deletes on one, mints and token changes on the other.

**Global budgets.** The four "everyone" rows per day are separate budgets with a counter
each. One that is spent leaves the others as they were: phones that are registered keep
getting pushes on a day when registrations or management writes reach their budget, and a
phone can still delete a secret or itself, which is how notifications are turned off, on a
day when the budget for mints and token changes is spent. The most one token can take is 5 %
of the day's pushes. One device can take 6 % of the mints and token changes and 10 % of the
deletes; one client address 12 % of the mints and token changes, one /48 24 %; and one client
address 2 % of the registrations, one /48 6 %. A delete counts on the device and on the
budget for deletes only, never on an address, so a phone can turn a helper or itself off
whatever else its address did that day.

**Dead tokens** take part in no budget: see `410 unregistered` above.

A refusal by a limit is `429 rate_limited` with `Retry-After` in seconds.

"Client address" is the IPv4 address in `CF-Connecting-IP`, or the /64 prefix of an IPv6
address, because one IPv6 client usually owns a whole /64. An IPv4-mapped IPv6 address counts
as its IPv4 address. For the caps kept in D1 an IPv6 client is counted a second time under
its /48, the size of prefix a whole site is usually given, with a higher cap, and a request
needs room under both. An IPv4 client has the one key.

How a request is checked, cheapest first:

1. The two per-minute limits that apply to every request (address, then everyone), including
   requests that will answer `400`, `401`, `404` or `405`.
2. The route and method, the shape of the bearer credential (43 url-safe characters), the body
   size (8 KB) and the body itself. For the two `PUT` routes also the form of the key, that
   a device id of 22 characters is its key's, and the form of the secret id and the push
   secret. Anything wrong here is answered without touching D1.
3. For a push, the per-minute limit of its secret. Still no D1.
4. D1: one read brings the credential, the counts its caps need and, on the owner-key routes,
   how many secrets the device holds and how many devices hold the token asked for. A request
   at a cap, a secret for a device that holds 10, a token that has 3 devices, a push secret
   that is in use and a push for a dead token are refused from that read.

**A request that is refused writes nothing and counts nothing.** Every `400`, `401`, `404`,
`405`, `409`, `413` and `429` is decided in steps 1 to 4, before the request is counted on
its device, its address or a global budget, so requests that are refused take nothing from
any allowance, however many they are. The counting and the change that follow are separate
statements, and each repeats its own check, so that two requests at the same moment can't
both take a last place: of a counter, of a token's 3 devices, of a device's 10 secrets, or
of a push secret. The request that comes second in such a race is refused after its read,
and what it counted until then stays counted.

A push is counted once Apple has answered, in the write that also records a dead token.

The per-minute limits use the
[Workers Rate Limiting binding](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
(`[[ratelimits]]` in `wrangler.toml`), which counts in memory and costs no D1 write. Cloudflare
counts it separately at each of its locations and calls it approximate, so these are brakes on
a flood, not exact quotas; the daily caps in D1 are the budget. The bindings are optional at
runtime: without them (the tests, or a deployment that removed the `[[ratelimits]]` sections)
every request passes step 1 and 3 and only the D1 caps apply.

A cron trigger runs once a day (03:17 UTC) and deletes devices whose token is dead, devices
that were not registered, updated, managed or pushed to for 180 days, all with their secrets,
and counters whose window has ended. It deletes at most 200 devices and 500 counters per run
and takes the rest on the next days.

## Costs (Workers Paid plan)

The account is on the Workers Paid plan. Beyond the plan's monthly fee the cost follows use:
Worker requests, and D1 rows read and written, each with a monthly amount the plan includes.
The plan has no daily limit on requests. The caps above keep the use small.

**D1 rows written: the gateway's own budget is 100,000 a day.** The plan's allowance is 50
million rows written a month, so this budget is a small part of it. The Worker stays under
it by itself. A push writes exactly two rows: the device's own row, which carries its daily
count, the day it was last used and whether its token is dead, and the global counter. The
budgets bound everything else. The arithmetic is kept in `src/limits.ts`, and this is the day
that spends every budget in full, with every write at its dearest (an IPv6 client, which has
two address counters, and a device that holds 10 secrets):

| What | Most per day | Rows each | Rows |
|---|---|---|---|
| Pushes | 30,000 | 2 (the device, the counter) | 60,000 |
| Registrations | 1,000 | 7 (four address counters, the global counter, the device and its token-hash index entry) | 7,000 |
| Secrets minted and token changes | 1,000 | 7 at most (see below) | 7,000 |
| Secrets and devices deleted | 600 | 23 at most (see below) | 13,800 |
| Daily purge | 200 devices with up to 10 secrets each, 500 counters | 22 and 1 | 4,900 |
| Total | | | 92,700 |

A mint or a token change first counts itself in four rows (the device, the two address
counters, the global counter). Minting a secret then writes 2 more (the secret and its index
entry) and a token change 2 more (the device and its token-hash index entry), 6 in all; a
device registered before the token hash existed gets the hash with its first such write, one
more row, once: 7, the figure the table uses. The `PUT` routes write the same rows: making a
device is a registration, 7; a token update is a token change, 6; a secret stored is a mint,
6; a secret replaced is 4 counts, the secret's row with its new hash and its index entry, 6
(7 with the hash filled in, as for a mint). A `PUT` that finds things as it says, and one
answered `409 conflict` or `409 too_many_secrets`, costs one read and writes nothing. Deleting a secret counts in two rows (the
device and the counter for deletes) and writes 2 more, 4 in all. Deleting the device counts
in the counter for deletes alone, because its own row goes, and then writes the device, its
token-hash index entry and up to 10 secrets with an index entry each: 23, the figure the
table uses for every delete.

An index entry counts as a row written, so the tables are `WITHOUT ROWID` and carry two
secondary indexes between them. Refused requests write nothing (see "How a request is
checked"). Past a cap the Worker answers
`429` until 00:00 UTC, and the helper drops those pushes.

**Worker requests.** Cloudflare counts a request when it arrives, before any code here runs,
so a request this Worker refuses with `429` is a billed request like any other. The limits
keep such requests away from D1 and Apple, which is where a request costs more than itself.

## Test

```sh
npm ci
npx vitest run        # a few seconds
npx tsc --noEmit
npx wrangler deploy --dry-run    # builds, uploads nothing
scripts/test-migration-guard.sh  # the check deploy.sh makes before migrating
```

The tests run inside workerd (`@cloudflare/vitest-plugin`) against a real local D1 with the
migrations applied. Apple is always a fake, the signing key is generated by the test run, and
the rate limiters are fakes or absent, because the tests set their own clock.
`wrangler dev` can't reach Apple at all: the local runtime has no HTTP/2 client, and APNs speaks
only HTTP/2. Only a deployed Worker can send, which is what the smoke test is for.

## Deploy

```sh
npx wrangler login     # once per machine
scripts/deploy.sh
```

It runs the checks, creates the D1 database `rexduo-push` if the account has none, applies the
migrations the database doesn't have yet, sets `APNS_KEY_P8` from the key file, deploys, and
prints the Worker URL. The deploy also sets the cron trigger and the rate limiting bindings from
`wrangler.toml`. It can be run again at any time. `wrangler.toml` keeps a placeholder for the
database id; the script writes the real one into `wrangler.deploy.toml` (gitignored) and deploys
with that. No account id is in the repo: wrangler uses the login's account, or
`CLOUDFLARE_ACCOUNT_ID` from the environment when the login has several.

Migrations only add. From `0004` on a migration adds columns, tables and indexes and fills new
columns from what the rows hold; the registrations in the database stay. `deploy.sh` reads
which migrations the database has recorded and refuses to apply when a pending file holds
`DROP TABLE` or `DELETE FROM`, unless `ALLOW_DESTRUCTIVE_MIGRATION=1` is set.
`scripts/test-migration-guard.sh` tests that check against temporary files, and the deploy
runs it. `0002` and `0003` made the tables anew; they are recorded as applied on the deployed
database and do not run there again, and a database the script has just created takes them
without the variable.

## Smoke test

```sh
scripts/smoke.sh https://rexduo-push.<subdomain>.workers.dev
```

It registers a token no device has, mints a secret for it, pushes with the secret and expects
`410` with reason `BadDeviceToken`. Then it expects `410` without a reason for a second push,
because the gateway marked the device dead and answers by itself, and `200` for
`GET /v1/devices/{id}` with the owner key. Last it deletes the device and expects `401`. Apple
can only say `BadDeviceToken` after an HTTP/2 request with a JWT it accepts, so a pass proves
the path to Apple and the key. Nothing is delivered. Run it after every deploy.

## If Apple's HTTP/2 path breaks

A deployed Worker reaches APNs because Cloudflare's proxy speaks HTTP/2 to the origin on
`fetch`. Cloudflare doesn't document that. If it stops, pushes answer `502 apns_unreachable`
and step 4 of the smoke test fails.

The fallback is to run the same API as a small always-on service on a full runtime with its own
HTTP/2 client: Railway (about $5 a month) or Fly.io (about $2 a month). The
contract and the D1 schema carry over; only the transport to Apple changes. In this code that
is one place, the `fetch` in `Deps` that `sendPush` calls. Phones and helpers only need the new
base URL. Not an option: a Worker opening its own TCP socket, because the sockets API can't
negotiate HTTP/2, and certificate (mTLS) auth, which fails from Workers.
