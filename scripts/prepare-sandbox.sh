#!/usr/bin/env bash
# Waits for the sandbox server to accept connections, then creates the
# database SANDBOX_URL names if it does not exist yet: for PostgreSQL through
# the server's `postgres` database, for MySQL and MariaDB with the URL's own
# account. A database that already exists is left as it is: the drill refuses
# one that holds tables. A MongoDB sandbox needs nothing, since MongoDB
# creates a database when the drill first writes to it.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

# scheme://userinfo@host:port/dbname?params, split without printing any of it.
rest="${SANDBOX_URL#*://}"
rest="${rest%%\?*}"
authority="${rest%%/*}"
database=""
case "$rest" in */*) database="${rest#*/}" ;; esac

prepare_postgres() {
  need psql "It creates the sandbox database. postgres-version installs it."
  local maintenance exists
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
      return 0
    fi
    sleep 2
  done
  cat "$SAFEGRD_DIR/psql.err" >&2
  fail "The sandbox server did not accept connections within 60 seconds."
}

# urldecode turns %XX back into bytes. A backslash is kept as it is.
urldecode() {
  local s="${1//\\/\\\\}"
  printf '%b' "${s//%/\\x}"
}

# option_value quotes a value for a MySQL option file.
option_value() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

prepare_mysql() {
  local client userinfo hostport user password host port exists
  client="$(find_mysql)" || fail "No mysql or mariadb client to create the sandbox database with. The client step installs one."
  case "$database" in
    '' | mysql | sys | information_schema | performance_schema)
      fail "sandbox-url must name a database of its own, such as .../drill. Got '${database:-none}'."
      ;;
  esac
  if ! printf '%s' "$database" | grep -Eq '^[A-Za-z0-9_]+$'; then
    fail "The sandbox database name '$database' needs quoting. Create it yourself, or use letters, digits and underscores."
  fi

  userinfo=""
  hostport="$authority"
  case "$authority" in *@*)
    userinfo="${authority%@*}"
    hostport="${authority##*@}"
    ;;
  esac
  user="$(urldecode "${userinfo%%:*}")"
  password=""
  case "$userinfo" in *:*) password="$(urldecode "${userinfo#*:}")" ;; esac
  case "$hostport" in
    \[*)
      host="${hostport%%]*}"
      host="${host#[}"
      port="${hostport##*]}"
      port="${port#:}"
      ;;
    *:*)
      host="${hostport%:*}"
      port="${hostport##*:}"
      ;;
    *)
      host="$hostport"
      port=""
      ;;
  esac
  [ -n "$host" ] || host=127.0.0.1
  [ "$host" != "localhost" ] || host=127.0.0.1
  [ -n "$port" ] || port=3306

  # The password goes to the client in an option file only this job's user
  # can read, never on its command line.
  # Global, for the EXIT trap.
  cnf="$SAFEGRD_DIR/sandbox.cnf"
  (
    umask 077
    {
      echo "[client]"
      [ -z "$user" ] || echo "user=$(option_value "$user")"
      [ -z "$password" ] || echo "password=$(option_value "$password")"
      echo "host=$(option_value "$host")"
      echo "port=$port"
      echo "protocol=TCP"
    } >"$cnf"
  )
  trap 'rm -f "$cnf"' EXIT

  for _ in $(seq 1 30); do
    if exists="$("$client" --defaults-extra-file="$cnf" -N -B -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$database'" 2>"$SAFEGRD_DIR/mysql.err")"; then
      if [ "$exists" = "1" ]; then
        echo "Sandbox database $database exists."
      else
        "$client" --defaults-extra-file="$cnf" -e "CREATE DATABASE \`$database\`" 2>"$SAFEGRD_DIR/mysql.err" || {
          cat "$SAFEGRD_DIR/mysql.err" >&2
          fail "Could not create the sandbox database $database. The line above says why."
        }
        echo "Created the sandbox database $database."
      fi
      return 0
    fi
    sleep 2
  done
  cat "$SAFEGRD_DIR/mysql.err" >&2
  fail "The sandbox server did not accept connections within 60 seconds."
}

case "$SANDBOX_URL" in
  postgres://* | postgresql://*) prepare_postgres ;;
  mysql://* | mariadb://*) prepare_mysql ;;
  mongodb://* | mongodb+srv://*) echo "The MongoDB sandbox is created when the drill writes to it." ;;
  *) echo "The sandbox is used as it is." ;;
esac
