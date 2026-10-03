#!/usr/bin/env bash
# Backs up the database, or with surface set that surface from the config,
# and sets the snapshot-id output.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need jq "It reads the backup's result."
[ -f "$SAFEGRD_CONFIG_FILE" ] || fail "No config at $SAFEGRD_CONFIG_FILE: the config step did not run."
check_inputs

# A relative path in the config (a files surface's root, a sqlite: file) is
# read from the workspace, where actions/checkout puts the repository.
if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE" ]; then
  cd "$GITHUB_WORKSPACE"
fi

if [ -n "${SURFACE:-}" ]; then
  before="$(surface_field "$SURFACE" last_snapshot_id)"
  if ! run_safegrd - backup --surface "$SURFACE"; then
    fail "The backup of surface $SURFACE failed. The lines above say why."
  fi
  # read_surfaces keeps its stderr apart, so not_recorded below still reads
  # the backup's.
  read_surfaces
  snapshot="$(surface_field "$SURFACE" last_snapshot_id)"
  last_error="$(surface_field "$SURFACE" last_error)"
  if [ -z "$snapshot" ] || [ "$snapshot" = "$before" ]; then
    fail "The backup of surface $SURFACE finished but recorded no new snapshot."
  fi
  echo "snapshot-id=$snapshot" >>"$GITHUB_OUTPUT"
  echo "Backed up surface $SURFACE ($ENGINE)."
  echo "Snapshot: $snapshot"
  if not_recorded; then
    warn "The remote server has no record of snapshot $snapshot. The backup is in storage. The log above says why it was not recorded."
  elif [ -n "$last_error" ]; then
    warn "Surface $SURFACE was backed up as snapshot $snapshot, with an error: $last_error"
  fi
  exit 0
fi

result="$SAFEGRD_DIR/backup.json"
if ! run_safegrd "$result" backup --json; then
  fail "The backup failed. The lines above say why."
fi

snapshot="$(jq -r '.snapshot_id // empty' "$result")"
[ -n "$snapshot" ] || fail "The backup finished but printed no snapshot ID."
echo "snapshot-id=$snapshot" >>"$GITHUB_OUTPUT"

case "$ENGINE" in
  mongodb) echo "Backed up $(jq -r '.total_tables // 0' "$result") collections, $(jq -r '.total_rows // 0' "$result") documents." ;;
  *) echo "Backed up $(jq -r '.total_tables // 0' "$result") tables, $(jq -r '.total_rows // 0' "$result") rows." ;;
esac
echo "Snapshot: $snapshot"

if [ "$(jq -r '.is_poison_pill_frozen // false' "$result")" = "true" ]; then
  warn "Threat Shield marked snapshot $snapshot anomalous: an abnormal schema or volume drop. Restore from the snapshot before it."
fi
if not_recorded; then
  warn "The remote server has no record of snapshot $snapshot. The backup is in storage. The log above says why it was not recorded."
fi
