# Shared by the action's steps. Sourced, never run.
#
# The scripts run under bash 3.2 as well (macOS), so: no associative arrays,
# and no "${array[@]}" of an empty array under `set -u`.

# Where the config is written. RUNNER_TEMP is emptied at the end of every job.
SAFEGRD_DIR="${RUNNER_TEMP:?RUNNER_TEMP is not set}/safegrd"
SAFEGRD_CONFIG_FILE="$SAFEGRD_DIR/safegrd.yaml"

# fail prints a GitHub error annotation and exits.
fail() {
  echo "::error title=SafeGrd::$*"
  exit 1
}

# warn prints a GitHub warning annotation; the job goes on.
warn() {
  echo "::warning title=SafeGrd::$*"
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is not installed on this runner. $2"
}

# run_safegrd runs the CLI with the action's config. Its stdout goes to the
# file named by $1, or to the log when $1 is "-". Its stderr goes to the log
# and is also kept in $SAFEGRD_DIR/stderr, so a caller can look for the
# notices the CLI prints there. Returns the CLI's exit status.
run_safegrd() {
  local out="$1"
  shift
  local status=0
  if [ "$out" = "-" ]; then
    safegrd --config "$SAFEGRD_CONFIG_FILE" "$@" 2>"$SAFEGRD_DIR/stderr" || status=$?
  else
    safegrd --config "$SAFEGRD_CONFIG_FILE" "$@" >"$out" 2>"$SAFEGRD_DIR/stderr" || status=$?
  fi
  cat "$SAFEGRD_DIR/stderr" >&2
  return "$status"
}

# not_recorded is true when the CLI said the remote server has no record of
# what it just did. The backup or drill itself is fine; the console will not
# show it.
not_recorded() {
  grep -q "NOT RECORDED" "$SAFEGRD_DIR/stderr" 2>/dev/null
}

# engine_of_url names the engine a connection URL selects, the way the CLI
# picks one: mysql:// and mariadb:// are MySQL, mongodb:// and
# mongodb+srv:// are MongoDB, sqlite: is SQLite, anything else is PostgreSQL.
engine_of_url() {
  case "$1" in
    mysql://* | mariadb://*) echo mysql ;;
    mongodb://* | mongodb+srv://*) echo mongodb ;;
    [Ss][Qq][Ll][Ii][Tt][Ee]:*) echo sqlite ;;
    *) echo postgres ;;
  esac
}

# engine_name is an engine as the log names it.
engine_name() {
  case "$1" in
    postgres) echo PostgreSQL ;;
    mysql) echo "MySQL or MariaDB" ;;
    mongodb) echo MongoDB ;;
    sqlite) echo SQLite ;;
    *) echo "$1" ;;
  esac
}

# read_surfaces writes the config's surfaces, as `safegrd daemon status
# --json` lists them, to $SAFEGRD_DIR/surfaces.json.
read_surfaces() {
  need jq "It reads the config's surfaces."
  if ! safegrd --config "$SAFEGRD_CONFIG_FILE" daemon status --json >"$SAFEGRD_DIR/surfaces.json" 2>"$SAFEGRD_DIR/surfaces.err"; then
    cat "$SAFEGRD_DIR/surfaces.err" >&2
    fail "Could not read the config's surfaces. The lines above say why."
  fi
}

# surface_field prints field $2 of surface $1 from the last read_surfaces.
surface_field() {
  jq -r --arg id "$1" --arg f "$2" '.surfaces[] | select(.id == $id) | .[$f] // empty' "$SAFEGRD_DIR/surfaces.json"
}

# check_inputs refuses inputs that cannot work together, before anything is
# backed up, and sets ENGINE to what this run backs up: postgres, mysql,
# mongodb or sqlite for a database, files or email for such a surface. ENGINE
# is empty when this step cannot tell.
check_inputs() {
  ENGINE=""
  if [ -n "${SURFACE:-}" ]; then
    if [ -n "${SAFEGRD_DATABASE_URL:-}" ]; then
      fail "Set database-url or surface, not both. surface backs up what the config defines for that surface."
    fi
    read_surfaces
    ENGINE="$(surface_field "$SURFACE" type | tr '[:upper:]' '[:lower:]')"
    if [ -z "$ENGINE" ]; then
      fail "The config has no surface $SURFACE. It has: $(jq -r '[.surfaces[].id] | join(", ")' "$SAFEGRD_DIR/surfaces.json")."
    fi
  else
    # A database in the config is a surface, named with the surface input;
    # without one, this run backs up the database-url input.
    local url="${SAFEGRD_DATABASE_URL:-}"
    [ -z "$url" ] || ENGINE="$(engine_of_url "$url")"
  fi

  if sandbox_drill && [ -n "$ENGINE" ]; then
    case "$ENGINE" in
      files | email)
        fail "Surface $SURFACE is a $ENGINE surface. Its drill restores in memory and takes no sandbox, so leave out sandbox-url."
        ;;
    esac
    local sandbox
    sandbox="$(engine_of_url "$SANDBOX_URL")"
    if [ "$sandbox" != "$ENGINE" ]; then
      fail "This run backs up a $(engine_name "$ENGINE") database, so sandbox-url must name one too. It names a $(engine_name "$sandbox") database."
    fi
  fi
}

# sandbox_drill is true when the drill restores into sandbox-url.
sandbox_drill() {
  [ "${DRILL:-false}" = "true" ] && [ -n "${SANDBOX_URL:-}" ]
}

# find_tool prints the first working tool among the names given, looking
# where the CLI looks: only at the path in the environment variable $1 when
# that is set, otherwise on PATH, then in the directories in $2 (globs
# allowed). Returns 1 when there is none.
find_tool() {
  local env="$1" dirs="$2" n d p
  shift 2
  if [ -n "${!env:-}" ]; then
    if "${!env}" --version >/dev/null 2>&1; then
      echo "${!env}"
      return 0
    fi
    return 1
  fi
  for n in "$@"; do
    if p="$(command -v "$n" 2>/dev/null)" && "$p" --version >/dev/null 2>&1; then
      echo "$p"
      return 0
    fi
  done
  for d in $dirs; do
    for n in "$@"; do
      p="$d/$n"
      if [ -x "$p" ] && "$p" --version >/dev/null 2>&1; then
        echo "$p"
        return 0
      fi
    done
  done
  return 1
}

# The directories the CLI searches for the MySQL and MongoDB tools.
mysql_dirs() {
  if [ "$(uname -s)" = "Darwin" ]; then
    echo /opt/homebrew/opt/mysql-client/bin "/opt/homebrew/opt/mysql-client@*/bin" /opt/homebrew/opt/mariadb/bin \
      /usr/local/opt/mysql-client/bin /usr/local/opt/mariadb/bin /usr/bin /usr/local/mysql/bin
  else
    echo /usr/bin /usr/local/mysql/bin
  fi
}
mongo_dirs() {
  if [ "$(uname -s)" = "Darwin" ]; then
    echo /usr/bin /usr/local/bin /opt/homebrew/bin /opt/homebrew/opt/mongodb-database-tools/bin
  else
    echo /usr/bin /usr/local/bin
  fi
}

find_mysqldump() { find_tool SAFEGRD_MYSQLDUMP "$(mysql_dirs)" mysqldump mariadb-dump; }
find_mysql() { find_tool SAFEGRD_MYSQL "$(mysql_dirs)" mysql mariadb; }
find_mongodump() { find_tool SAFEGRD_MONGODUMP "$(mongo_dirs)" mongodump; }
find_mongorestore() { find_tool SAFEGRD_MONGORESTORE "$(mongo_dirs)" mongorestore; }

# tool_version prints the first line of a tool's --version, less the path
# some tools start it with.
tool_version() {
  "$1" --version 2>&1 | head -n 1 | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/ $//' -e 's#^/[^ ]*/##'
}

has_apt() {
  [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1
}

# as_root runs a command through sudo when the job's user is not root.
as_root() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  else
    sudo "$@"
  fi
}
