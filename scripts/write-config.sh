#!/usr/bin/env bash
# Writes the config input to a file only this job's user can read. The file
# is in RUNNER_TEMP, which the runner empties when the job ends.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

if [ -z "${SAFEGRD_CONFIG_BODY//[[:space:]]/}" ]; then
  fail "The config input is empty. Pass the host's config file from a secret, such as config: \${{ secrets.SAFEGRD_CONFIG }}."
fi

umask 077
mkdir -p "$SAFEGRD_DIR"
printf '%s\n' "$SAFEGRD_CONFIG_BODY" >"$SAFEGRD_CONFIG_FILE"
chmod 600 "$SAFEGRD_CONFIG_FILE"
echo "Wrote the config to $SAFEGRD_CONFIG_FILE (mode 600)."
