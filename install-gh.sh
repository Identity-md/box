#!/bin/sh
# The GitHub CLI, for `imd github link`: the worker opens a proof's pull request through the holder's own
# gh and never reads its token. Install into an explicit, absolute directory:
#   sh install-gh.sh /usr/local/bin
#
# These SHA-256 digests come from the official release's own checksums file:
# https://github.com/cli/cli/releases/tag/v2.103.3 (gh_2.103.3_checksums.txt)
# Update the version and digests together. No installer is fetched or executed.
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: sh install-gh.sh /absolute/install/directory" >&2
  exit 1
fi
install_dir=$1
case "$install_dir" in
  /*) ;;
  *) echo "gh install directory must be absolute" >&2; exit 1 ;;
esac

version=2.103.3
case "$(uname -m)" in
  x86_64)
    target=linux_amd64
    sha256=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
    ;;
  aarch64|arm64)
    target=linux_arm64
    sha256=ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63
    ;;
  *) echo "Unsupported gh platform: $(uname -m)" >&2; exit 1 ;;
esac

staging=$(mktemp -d "${TMPDIR:-/tmp}/imd-gh.XXXXXX")
trap 'rm -rf "$staging"' 0
trap 'exit 1' 1 2 15
archive="gh_${version}_${target}.tar.gz"
echo "Installing gh $version ($target), checking pinned SHA-256"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --retry 3 --retry-delay 2 --retry-max-time 300 --connect-timeout 15 --max-time 180 \
  --output "$staging/$archive" \
  "https://github.com/cli/cli/releases/download/v$version/$archive"

actual=$(sha256sum "$staging/$archive")
actual=${actual%% *}
if [ "$actual" != "$sha256" ]; then
  echo "gh archive checksum mismatch: expected $sha256, got $actual" >&2
  exit 1
fi

tar -xzf "$staging/$archive" -C "$staging"
binary="$staging/gh_${version}_${target}/bin/gh"
test -x "$binary"
"$binary" --version | head -1
mkdir -p "$install_dir"
install -m 0755 "$binary" "$install_dir/gh"
