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
