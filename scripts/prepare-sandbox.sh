#!/usr/bin/env bash
# Waits for the sandbox server to accept connections, then creates the
# database SANDBOX_URL names if it does not exist yet. It connects to the
# server's `postgres` database to do that. A database that already exists is
# left as it is: the drill refuses one that holds tables.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

case "$SANDBOX_URL" in
  postgres://* | postgresql://*) ;;
  *)
    echo "The sandbox is not PostgreSQL, so it is used as it is."
    exit 0
    ;;
esac
need psql "It creates the sandbox database. postgres-version installs it."

# scheme://userinfo@host:port/dbname?params
database="$(printf '%s' "$SANDBOX_URL" | sed -E 's#^[a-z]+://[^/?]*/?([^?]*).*$#\1#')"
maintenance="$(printf '%s' "$SANDBOX_URL" | sed -E 's#^([a-z]+://[^/?]*)(/[^?]*)?#\1/postgres#')"
case "$database" in
  '' | postgres) fail "sandbox-url must name a database of its own, such as .../drill. Got '${database:-none}'." ;;
esac
if ! printf '%s' "$database" | grep -Eq '^[a-z_][a-z0-9_]*$'; then
  fail "The sandbox database name '$database' needs quoting. Create it yourself, or use lower-case letters, digits and underscores."
fi

for _ in $(seq 1 30); do
  if exists="$(psql "$maintenance" -tAc "SELECT 1 FROM pg_database WHERE datname = '$database'" 2>"$SAFEGRD_DIR/psql.err")"; then
    if [ "$exists" = "1" ]; then
      echo "Sandbox database $database exists."
    else
      psql "$maintenance" -qc "CREATE DATABASE $database" >/dev/null
      echo "Created the sandbox database $database."
    fi
    exit 0
  fi
  sleep 2
done
cat "$SAFEGRD_DIR/psql.err" >&2
fail "The sandbox server did not accept connections within 60 seconds."
