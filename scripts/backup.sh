#!/usr/bin/env bash
# Backs up the database and sets the snapshot-id output.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need jq "It reads the backup's result."
[ -f "$SAFEGRD_CONFIG_FILE" ] || fail "No config at $SAFEGRD_CONFIG_FILE: the config step did not run."

result="$SAFEGRD_DIR/backup.json"
if ! run_safegrd "$result" backup --json; then
  fail "The backup failed. The lines above say why."
fi

snapshot="$(jq -r '.snapshot_id // empty' "$result")"
[ -n "$snapshot" ] || fail "The backup finished but printed no snapshot ID."
echo "snapshot-id=$snapshot" >>"$GITHUB_OUTPUT"

echo "Backed up $(jq -r '.total_tables // 0' "$result") tables, $(jq -r '.total_rows // 0' "$result") rows."
echo "Snapshot: $snapshot"

if [ "$(jq -r '.is_poison_pill_frozen // false' "$result")" = "true" ]; then
  warn "Threat Shield marked snapshot $snapshot anomalous: an abnormal schema or volume drop. Restore from the snapshot before it."
fi
if not_recorded; then
  warn "The remote server has no record of snapshot $snapshot. The backup is in storage. The log above says why it was not recorded."
fi
