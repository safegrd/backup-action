#!/usr/bin/env bash
# With drill: true, restores the snapshot the backup step took and checks it:
# into sandbox-url when one is given, otherwise in memory. A files or email
# surface always drills in memory. The CLI reports the result to the remote
# server.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

case "${DRILL:-false}" in
  true) ;;
  false | "")
    echo "No drill this run (drill: false)."
    exit 0
    ;;
  *) fail "drill must be true or false. Got '$DRILL'." ;;
esac

[ -n "${SNAPSHOT_ID:-}" ] || fail "The backup step set no snapshot ID, so there is nothing to drill."

if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE" ]; then
  cd "$GITHUB_WORKSPACE"
fi

if [ -z "${SANDBOX_URL:-}" ]; then
  echo "Restoring $SNAPSHOT_ID in memory."
  if ! run_safegrd - verify --snapshot "$SNAPSHOT_ID" --dry-run; then
    fail "The drill of $SNAPSHOT_ID failed. The lines above say which check failed."
  fi
else
  "$(dirname "$0")/prepare-sandbox.sh"
  if ! run_safegrd - verify --snapshot "$SNAPSHOT_ID" --sandbox-target "$SANDBOX_URL"; then
    fail "The drill of $SNAPSHOT_ID failed. The lines above say which check failed."
  fi
fi

echo "Drill of $SNAPSHOT_ID passed."
if not_recorded; then
  warn "The drill of $SNAPSHOT_ID passed, but the remote server has no record of it. The log above says why."
fi
