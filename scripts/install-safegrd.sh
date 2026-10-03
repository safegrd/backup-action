#!/usr/bin/env bash
# Installs the SafeGrd CLI from its GitHub release, after checking the archive
# against the release's checksums.txt. A release with no checksum for the
# archive is refused.
#
# SAFEGRD_DOWNLOAD_BASE replaces the release's download URL (file:// works),
# so a build can be tested before it is published.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

need curl "It downloads the release."
need tar "It unpacks the release."

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) fail "SafeGrd runs on Linux and macOS runners, not $(uname -s)." ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) fail "SafeGrd is built for amd64 and arm64, not $(uname -m)." ;;
esac

version="${SAFEGRD_VERSION:-latest}"
if [ "$version" = "latest" ]; then
  if [ -n "${SAFEGRD_DOWNLOAD_BASE:-}" ]; then
    fail "With SAFEGRD_DOWNLOAD_BASE set, name the version too."
  fi
  need jq "It reads the latest release's tag."
  # The job's token lifts the API's rate limit for unauthenticated calls,
  # which runners sharing an address run into.
  if [ -n "${GH_TOKEN:-}" ]; then
    release="$(curl -fsSL -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/repos/safegrd/cli/releases/latest)" ||
      fail "Could not read the latest release of safegrd/cli from GitHub. Set version to a tag such as v0.0.4."
  else
    release="$(curl -fsSL https://api.github.com/repos/safegrd/cli/releases/latest)" ||
      fail "Could not read the latest release of safegrd/cli from GitHub. Set version to a tag such as v0.0.4."
  fi
  version="$(printf '%s' "$release" | jq -r '.tag_name // empty')"
  [ -n "$version" ] || fail "GitHub named no latest release of safegrd/cli. Set version to a tag such as v0.0.4."
fi

case "$version" in
  v*) tag="$version" ;;
  *) tag="v$version" ;;
esac
number="${tag#v}"

archive="safegrd_${number}_${os}_${arch}.tar.gz"
base="${SAFEGRD_DOWNLOAD_BASE:-https://github.com/safegrd/cli/releases/download/$tag}"
work="$RUNNER_TEMP/safegrd-install-$tag"
rm -rf "$work"
mkdir -p "$work"

curl -fsSL "$base/$archive" -o "$work/$archive" || fail "Could not download $base/$archive. Check that release $tag exists at https://github.com/safegrd/cli/releases."
curl -fsSL "$base/checksums.txt" -o "$work/checksums.txt" || fail "Could not download checksums.txt for $tag, so the archive cannot be checked."

expected="$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1 }' "$work/checksums.txt" | head -n 1)"
[ -n "$expected" ] || fail "checksums.txt for $tag lists no $archive."
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$work/$archive" | awk '{ print $1 }')"
else
  actual="$(shasum -a 256 "$work/$archive" | awk '{ print $1 }')"
fi
[ "$expected" = "$actual" ] || fail "$archive does not match checksums.txt (expected $expected, got $actual)."

tar -xzf "$work/$archive" -C "$work"
bin_dir="$RUNNER_TEMP/safegrd-bin"
mkdir -p "$bin_dir"
install -m 0755 "$work/safegrd_${number}_${os}_${arch}/safegrd" "$bin_dir/safegrd"
rm -rf "$work"
echo "$bin_dir" >>"$GITHUB_PATH"

installed="$("$bin_dir/safegrd" --version | sed -n 's/^safegrd version \([^ ]*\).*/\1/p' | head -n 1)"
[ "$installed" = "$number" ] || fail "The installed binary says it is version '$installed', not $number."
echo "Installed SafeGrd $installed ($os/$arch) in $bin_dir."
echo "SHA-256: $actual"
