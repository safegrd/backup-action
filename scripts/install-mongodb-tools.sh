#!/usr/bin/env bash
# Makes sure the runner has mongodump, and with a sandbox drill mongorestore,
# from the MongoDB Database Tools. It looks where the CLI looks and takes any
# version, as the CLI does. When neither is there it installs
# mongodb-database-tools from MongoDB's signed apt repository.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

missing() {
  find_mongodump >/dev/null || return 0
  if sandbox_drill; then
    find_mongorestore >/dev/null || return 0
  fi
  return 1
}

if missing; then
  if ! has_apt || [ ! -r /etc/os-release ]; then
    fail "No mongodump here, or no mongorestore for the sandbox drill, and this runner has no apt-get. Install the MongoDB Database Tools in an earlier step."
  fi
  need curl "It downloads MongoDB's signing key."
  need gpg "It reads MongoDB's signing key."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_CODENAME:-}" in
    ubuntu:jammy | ubuntu:noble) repo="https://repo.mongodb.org/apt/ubuntu ${VERSION_CODENAME}/mongodb-org/8.0 multiverse" ;;
    debian:bookworm) repo="https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" ;;
    *) fail "MongoDB publishes no apt repository for ${PRETTY_NAME:-this system}. Install the MongoDB Database Tools in an earlier step." ;;
  esac
  keyring=/usr/share/keyrings/mongodb-server-8.0.gpg
  echo "Installing mongodb-database-tools from repo.mongodb.org."
  curl -fsSL https://pgp.mongodb.com/server-8.0.asc | as_root gpg --batch --yes --dearmor -o "$keyring" ||
    fail "Could not fetch MongoDB's signing key from pgp.mongodb.com."
  echo "deb [ arch=amd64,arm64 signed-by=$keyring ] $repo" | as_root tee /etc/apt/sources.list.d/mongodb-org-8.0.list >/dev/null
  as_root apt-get update -qq
  as_root apt-get install -y -qq mongodb-database-tools >/dev/null ||
    fail "Could not install mongodb-database-tools with apt-get. Install the MongoDB Database Tools in an earlier step."
  if missing; then
    fail "Installed mongodb-database-tools, but SafeGrd still finds no mongodump."
  fi
fi

dump="$(find_mongodump)"
echo "Found $dump ($(tool_version "$dump"))."
if sandbox_drill; then
  restore="$(find_mongorestore)"
  echo "Found $restore ($(tool_version "$restore")), for the sandbox."
fi
