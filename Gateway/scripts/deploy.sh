#!/usr/bin/env bash
# Deploys the push gateway to Cloudflare. Safe to run again: each step does nothing when its
# work is already done.
#
#   scripts/deploy.sh
#
# Needs a wrangler login (`npx wrangler login`) or CLOUDFLARE_API_TOKEN, and the APNs key file.
# APNS_KEY overrides where the key is read from. The key goes straight from that file to
# Cloudflare's secret store: it is never printed, copied or written anywhere else.
#
# Migrations only add. A pending migration that holds DROP TABLE or DELETE FROM stops the
# script before anything is applied, unless ALLOW_DESTRUCTIVE_MIGRATION=1 is set. The Worker
# is deployed only once every migration is recorded as applied.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/migration-guard.sh
. scripts/migration-guard.sh

# No account id is written here or in wrangler.toml. With one Cloudflare account wrangler
# picks it. With several, set CLOUDFLARE_ACCOUNT_ID in the environment.
APNS_KEY="${APNS_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_5G2D4URHAC.p8}"
DB_NAME="rexduo-push"
PLACEHOLDER="PLACEHOLDER_SET_BY_DEPLOY_SCRIPT"
# wrangler.toml with the real database id. Gitignored, rewritten on every run.
CONFIG="wrangler.deploy.toml"

die() {
  echo "deploy: $*" >&2
  exit 1
}

[ -r "$APNS_KEY" ] || die "can't read the APNs key at $APNS_KEY (set APNS_KEY to its path)"
grep -q "$PLACEHOLDER" wrangler.toml || die "wrangler.toml lost its database_id placeholder"

[ -d node_modules ] || npm ci
wrangler() { npx --no-install wrangler "$@"; }

echo "== checks"
npx --no-install tsc --noEmit
npx --no-install vitest run
scripts/test-migration-guard.sh
# Builds and checks the whole config (the D1, cron and rate limiting sections) and uploads
# nothing, so a config wrangler would refuse stops the script before anything remote changes.
wrangler deploy --dry-run >/dev/null

# Prints the database's id, or nothing when the account has no database of that name.
database_id() {
  wrangler d1 list --json | python3 -c '
import json, sys
text = sys.stdin.read()
for db in json.loads(text[text.index("["):]):
    if db.get("name") == sys.argv[1]:
        print(db["uuid"])
' "$DB_NAME"
}

echo "== database"
id="$(database_id)"
created=""
if [ -z "$id" ]; then
  created=1
  # --update-config=false: the tracked wrangler.toml keeps its placeholder.
  wrangler d1 create "$DB_NAME" --update-config=false </dev/null
  id="$(database_id)"
fi
[[ "$id" =~ ^[0-9a-f-]{36}$ ]] || die "could not find the id of the D1 database $DB_NAME"
echo "D1 database $DB_NAME: $id"

sed "s/$PLACEHOLDER/$id/" wrangler.toml > "$CONFIG"

# Prints the names of the migrations the database has recorded as applied, one a line.
# Nothing when it has none, or when the answer can't be read: every file then counts as
# pending, and the check below looks at all of them.
applied_migrations() {
  wrangler d1 execute "$DB_NAME" --remote --config "$CONFIG" --json \
    --command "SELECT name FROM d1_migrations ORDER BY id" 2>/dev/null </dev/null | python3 -c '
import json, sys
text = sys.stdin.read()
try:
    for answer in json.loads(text[text.index("["):]):
        for row in answer.get("results", []):
            print(row["name"])
except Exception:
    pass
' || true
}

echo "== migrations"
if [ -n "$created" ]; then
  # A database made a moment ago holds nothing a migration could remove.
  echo "new database: every migration is applied"
else
  applied="$(applied_migrations)"
  echo "recorded as applied: $(printf '%s' "$applied" | grep -c . || true)"
  printf '%s\n' "$applied" | check_migrations migrations || die "a pending migration removes data (see above)"
fi
# Applies only the migrations the database has not recorded, so a second run does nothing.
# Without a terminal on stdin wrangler applies pending migrations without asking.
wrangler d1 migrations apply "$DB_NAME" --remote --config "$CONFIG" </dev/null
# The Worker reads every column the migrations add, so it never runs on a database that lacks
# one. Every file must now be recorded as applied; an answer that can't be read counts as none.
missing="$(applied_migrations | pending_migrations migrations)"
[ -z "$missing" ] || die "not deployed: these migrations are not applied: $(printf '%s ' $missing)"

echo "== secret"
# On the first run this also creates the Worker, empty, to hold the secret until the deploy below.
wrangler secret put APNS_KEY_P8 --config "$CONFIG" < "$APNS_KEY"

echo "== deploy"
# The deploy also sets the cron trigger and the rate limiting bindings from the config:
# neither is a resource to create first, and deploying the same config again changes nothing.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
wrangler deploy --config "$CONFIG" | tee "$log"

url="$(grep -Eo 'https://[A-Za-z0-9.-]+\.workers\.dev' "$log" | head -n 1 || true)"
[ -n "$url" ] || die "deployed, but wrangler printed no workers.dev URL (see its output above)"
echo
echo "Worker URL: $url"
echo "Smoke test: scripts/smoke.sh $url"
