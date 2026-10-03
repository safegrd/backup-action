#!/usr/bin/env bash
# Makes sure the runner has the dump tool the backup needs, chosen by what
# this run backs up: the surface's type with surface set, otherwise the
# database URL's scheme. It installs one only when the runner has none.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

check_inputs

case "$ENGINE" in
  postgres | "")
    # An env: or file: reference this step cannot read is treated as
    # PostgreSQL, as it was before the action read the URL's scheme.
    exec "$(dirname "$0")/install-postgres-client.sh"
    ;;
  mysql) exec "$(dirname "$0")/install-mysql-client.sh" ;;
  mongodb) exec "$(dirname "$0")/install-mongodb-tools.sh" ;;
  sqlite) echo "SQLite needs no client: SafeGrd reads the database file itself." ;;
  files | email) echo "Surface $SURFACE is a $ENGINE surface, which needs no database client." ;;
  *) fail "Surface $SURFACE has type '$ENGINE', which this action does not back up." ;;
esac
