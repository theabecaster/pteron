#!/usr/bin/env bash
# Tests scripts/migration-guard.sh against temporary files. It needs no network and no
# Cloudflare account.
#
#   scripts/test-migration-guard.sh
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/migration-guard.sh
. scripts/migration-guard.sh

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
failures=0

# expect NAME WANT APPLIED [ALLOW]: runs the check on $dir with the applied names in
# APPLIED (space separated) and compares its exit status with WANT.
expect() {
  local name="$1" want="$2" applied="$3" allow="${4:-}" got
  printf '%s\n' $applied | ALLOW_DESTRUCTIVE_MIGRATION="$allow" check_migrations "$dir" 2>/dev/null
  got=$?
  if [ "$got" = "$want" ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name: expected status $want, got $got"
    failures=$((failures + 1))
  fi
}

printf 'CREATE TABLE a (id TEXT PRIMARY KEY);\n' > "$dir/0001_init.sql"
printf 'DROP TABLE IF EXISTS a;\nCREATE TABLE a (id TEXT PRIMARY KEY, n INTEGER);\n' > "$dir/0002_again.sql"
printf -- '-- Nothing here may DROP TABLE or DELETE FROM a table.\nALTER TABLE a ADD COLUMN m INTEGER;\nCREATE INDEX IF NOT EXISTS a_m ON a (m);\n' > "$dir/0003_add.sql"

expect "a pending file that only adds passes" 0 "0001_init.sql 0002_again.sql"
expect "nothing pending passes" 0 "0001_init.sql 0002_again.sql 0003_add.sql"
expect "a pending DROP TABLE is refused" 1 "0001_init.sql"
expect "a database with nothing applied is refused when a file drops a table" 1 ""
expect "ALLOW_DESTRUCTIVE_MIGRATION=1 lets a pending DROP TABLE pass" 0 "0001_init.sql" 1
expect "any other value of ALLOW_DESTRUCTIVE_MIGRATION does not" 1 "0001_init.sql" yes
expect "a DROP TABLE in a file that is applied is not looked at" 0 "0001_init.sql 0002_again.sql"

printf 'delete\n  from a WHERE n = 0;\n' > "$dir/0004_rows.sql"
expect "a pending DELETE FROM is refused, in any case and across lines" 1 "0001_init.sql 0002_again.sql 0003_add.sql"
expect "and passes once it is applied" 0 "0001_init.sql 0002_again.sql 0003_add.sql 0004_rows.sql"

printf 'UPDATE a SET m = 0 WHERE m IS NULL; -- instead of DELETE FROM a\n' > "$dir/0005_fill.sql"
expect "the words in a comment are not SQL" 0 "0001_init.sql 0002_again.sql 0003_add.sql 0004_rows.sql"

# The real files: 0004 on top of a database at 0003 passes, and a database with nothing
# applied is refused, because 0002 and 0003 drop tables.
real() {
  local name="$1" want="$2" applied="$3" got
  printf '%s\n' $applied | ALLOW_DESTRUCTIVE_MIGRATION= check_migrations migrations 2>/dev/null
  got=$?
  if [ "$got" = "$want" ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name: expected status $want, got $got"
    failures=$((failures + 1))
  fi
}
real "migrations/: everything after 0003 only adds" 0 "0001_init.sql 0002_secrets.sql 0003_device_counters.sql"
real "migrations/: nothing applied is refused" 1 ""

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
