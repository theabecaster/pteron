#!/usr/bin/env bash
# The check scripts/deploy.sh runs before it applies migrations: a pending migration only
# adds. Sourced, not run. scripts/test-migration-guard.sh runs it against temporary files.

# pending_migrations DIR: the .sql files of DIR, in order, whose names are not among the
# applied names read from stdin (one a line).
pending_migrations() {
  local dir="$1" applied file
  applied="$(cat)"
  for file in "$dir"/*.sql; do
    [ -e "$file" ] || continue
    printf '%s\n' "$applied" | grep -qxF "$(basename "$file")" || printf '%s\n' "$file"
  done
}

# removes_data FILE: true when the file's SQL, comments aside, drops a table or deletes rows.
removes_data() {
  sed -e 's/--.*$//' "$1" | tr '\n' ' ' | grep -Eiq '(DROP[[:space:]]+TABLE|DELETE[[:space:]]+FROM)'
}

# check_migrations DIR: reads the applied names from stdin and fails, naming the files, when
# a pending migration removes data. ALLOW_DESTRUCTIVE_MIGRATION=1 lets it pass.
check_migrations() {
  local dir="$1" file found=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if removes_data "$file"; then
      found="$found $(basename "$file")"
    fi
  done <<PENDING
$(pending_migrations "$dir")
PENDING
  [ -n "$found" ] || return 0
  if [ "${ALLOW_DESTRUCTIVE_MIGRATION:-}" = 1 ]; then
    echo "migrations: applying with ALLOW_DESTRUCTIVE_MIGRATION=1:$found" >&2
    return 0
  fi
  echo "migrations: not applied. These pending files hold DROP TABLE or DELETE FROM:$found" >&2
  echo "migrations: a migration only adds. Set ALLOW_DESTRUCTIVE_MIGRATION=1 to apply them anyway." >&2
  return 1
}
