#!/usr/bin/env bash
# Makes sure a pg_dump of POSTGRES_VERSION or newer is on the runner. pg_dump
# refuses a server newer than itself and dumps older servers correctly, which
# is also how the CLI picks one: the newest it finds.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

want="${POSTGRES_VERSION:-}"
case "$want" in
  none)
    echo "Using the runner's PostgreSQL client (postgres-version: none)."
    exit 0
    ;;
  '' | *[!0-9]*)
    fail "postgres-version must be a major version such as 17, or none. Got '$want'."
    ;;
esac

# The newest pg_dump on the runner, from the places the CLI looks on Linux.
newest_pg_dump() {
  local best=0 p v
  for p in $(command -v pg_dump 2>/dev/null || true) /usr/lib/postgresql/*/bin/pg_dump; do
    [ -x "$p" ] || continue
    v="$("$p" --version 2>/dev/null | sed -n 's/.*(PostgreSQL) \([0-9][0-9]*\).*/\1/p')"
    if [ -n "$v" ] && [ "$v" -gt "$best" ]; then
      best="$v"
    fi
  done
  echo "$best"
}

have="$(newest_pg_dump)"
if [ "$have" -ge "$want" ]; then
  echo "pg_dump $have is installed. It reads PostgreSQL $want."
  exit 0
fi

if [ "$(uname -s)" != "Linux" ] || ! command -v apt-get >/dev/null 2>&1; then
  found="none"
  [ "$have" = "0" ] || found="pg_dump $have"
  fail "No pg_dump $want or newer here (found: $found), and this runner has no apt-get. Install the PostgreSQL $want client in an earlier step and set postgres-version: none."
fi

sudo=""
if [ "$(id -u)" != "0" ]; then
  sudo="sudo"
fi

echo "Installing the PostgreSQL $want client from apt.postgresql.org."
$sudo apt-get update -qq
$sudo apt-get install -y -qq postgresql-common >/dev/null
$sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null
$sudo apt-get install -y -qq "postgresql-client-$want" >/dev/null

have="$(newest_pg_dump)"
if [ "$have" -lt "$want" ]; then
  fail "Installed postgresql-client-$want, but the newest pg_dump is still $have."
fi
echo "pg_dump $have is installed."
