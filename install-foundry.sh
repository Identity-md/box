#!/bin/sh
# Shared by CI and Dockerfile.verifier. Install into an explicit, absolute directory:
#   sh scripts/install-foundry.sh /tmp/imd-foundry/bin
#
# Pin the archive as well as the version: foundryup's changing installer and attestation
# download endpoint have both broken builds while FOUNDRY_VERSION stayed pinned.
# These SHA-256 digests come from the immutable official release's assets:
# https://github.com/foundry-rs/foundry/releases/tag/v1.8.3
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

version=v1.8.3
platform="$(uname -s)/$(uname -m)"
case "$platform" in
  Linux/x86_64)
    target=linux_amd64
    sha256=7ca48e6ca3cac1bce1403ca67e5bc1dc3bc1fd818199c9957c7165079c228568
    ;;
  Linux/aarch64|Linux/arm64)
    target=linux_arm64
    sha256=93fc23be26c8a902ca58fe54aa6ca28c880b58af95d052674933161df7928e6d
    ;;
  Darwin/x86_64)
    target=darwin_amd64
    sha256=1b469229681b31e3c66a07132811b99460b2874a0a48de3b29500234454f47b8
    ;;
  Darwin/arm64)
    target=darwin_arm64
    sha256=562f9c2f9094e512f1efc1e005c79de7642c27ffc1e7e9dcf8e31baa54577d6e
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
