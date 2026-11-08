#!/bin/sh
# Shared by CI and Dockerfile.verifier. Install into an explicit, absolute directory:
#   sh scripts/install-foundry.sh /tmp/imd-foundry/bin
#
# Pin the archive as well as the version: foundryup's changing installer and attestation
# download endpoint have both broken builds while FOUNDRY_VERSION stayed pinned.
# These SHA-256 digests come from the immutable official release's assets:
# https://github.com/foundry-rs/foundry/releases/tag/v1.9.0
# Update the version and digests together when upgrading. No installer is fetched or executed.
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: sh scripts/install-foundry.sh /absolute/install/directory" >&2
  exit 1
fi
install_dir=$1
case "$install_dir" in
  /*) ;;
  *) echo "Foundry install directory must be absolute" >&2; exit 1 ;;
esac

version=v1.9.0
platform="$(uname -s)/$(uname -m)"
case "$platform" in
  Linux/x86_64)
    target=linux_amd64
    sha256=8d17599b42e3139f1a9c171be3798c4ed8e743ae17b84cc3435e57bf2a51ae99
    ;;
  Linux/aarch64|Linux/arm64)
    target=linux_arm64
    sha256=22d3060fa83515fb901690a2c59a5f552bd41c241886195b2159562fc4947abc
    ;;
  Darwin/x86_64)
    target=darwin_amd64
    sha256=88f234f458652878499d9e363dea37eb06653a948dbe709adef8d8389e0a9025
    ;;
  Darwin/arm64)
    target=darwin_arm64
    sha256=38f9af72b266c38ce2e4dfc659ae9cbd1f78c01b34738a76b6c4cb9610579426
    ;;
  *) echo "Unsupported Foundry platform: $platform" >&2; exit 1 ;;
esac

staging=$(mktemp -d "${TMPDIR:-/tmp}/imd-foundry.XXXXXX")
trap 'rm -rf "$staging"' 0
trap 'exit 1' 1 2 15
archive="foundry_${version}_${target}.tar.gz"
echo "Installing Foundry $version ($target), checking pinned SHA-256"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --retry 3 --retry-delay 2 --retry-max-time 300 --connect-timeout 15 --max-time 180 \
  --output "$staging/$archive" \
  "https://github.com/foundry-rs/foundry/releases/download/$version/$archive"

if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$staging/$archive")
elif command -v shasum >/dev/null 2>&1; then
  actual=$(shasum -a 256 "$staging/$archive")
else
  echo "Foundry installation requires sha256sum or shasum" >&2
  exit 1
fi
actual=${actual%% *}
if [ "$actual" != "$sha256" ]; then
  echo "Foundry archive checksum mismatch: expected $sha256, got $actual" >&2
  exit 1
fi

# Validate before touching the destination, including whether the binary can run here.
tar -xzf "$staging/$archive" -C "$staging"
for binary in forge cast anvil chisel; do
  test -x "$staging/$binary"
done
"$staging/forge" --version
mkdir -p "$install_dir"
for binary in forge cast anvil chisel; do
  install -m 0755 "$staging/$binary" "$install_dir/$binary"
done
