#!/usr/bin/env bash
# Makes sure the runner has mysqldump or mariadb-dump, and with a sandbox
# drill the mysql or mariadb client that loads the dump. It looks where the
# CLI looks, and takes any version, as the CLI does: either project's tool
# reads both servers, and the CLI prefers the server's own when it finds both.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

missing() {
  find_mysqldump >/dev/null || return 0
  if sandbox_drill; then
    find_mysql >/dev/null || return 0
  fi
  return 1
}

if missing; then
  if ! has_apt; then
    fail "No mysqldump or mariadb-dump here, or no mysql client for the sandbox drill, and this runner has no apt-get. Install the MySQL or MariaDB client in an earlier step."
  fi
  # mysql-client is Ubuntu's; Debian ships the MariaDB client under
  # default-mysql-client.
  package=mysql-client
  case "${SAFEGRD_DATABASE_URL:-}" in mariadb://*) package=mariadb-client ;; esac
  echo "Installing $package from the runner's apt sources."
  as_root apt-get update -qq
  if ! as_root apt-get install -y -qq "$package" >/dev/null; then
    as_root apt-get install -y -qq default-mysql-client >/dev/null ||
      fail "Could not install $package or default-mysql-client with apt-get. Install the MySQL or MariaDB client in an earlier step."
  fi
  if missing; then
    fail "Installed the MySQL client, but SafeGrd still finds no mysqldump or mariadb-dump."
  fi
fi

# The CLI looks again when it runs, and of the tools it finds it takes the
# one from the server's own project, so this names one that works, not
# necessarily the one the backup uses.
dump="$(find_mysqldump)"
echo "Found $dump ($(tool_version "$dump"))."
if sandbox_drill; then
  client="$(find_mysql)"
  echo "Found $client ($(tool_version "$client")), for the sandbox."
fi
