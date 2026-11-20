#!/bin/sh
# Install the AirVPN tunnel process used by Core into an existing bin directory.
set -eu
dest=${1:?usage: install_wireproxy.sh BIN_DIRECTORY}
case "$(uname -m)" in
    x86_64) arch=amd64; sha=e88c1d090740373fc606c1bafd81d9a5eadc642cce5667616e20e9d7a444f51c ;;
    aarch64|arm64) arch=arm64; sha=370e00bd2167960d1ecd1c3c1439715bbaa94a0a110a2040468670c9af6021b6 ;;
    *) echo "Unsupported wireproxy architecture: $(uname -m)" >&2; exit 1 ;;
esac
stage=$(mktemp -d "$dest/.wireproxy.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
curl -fsSL --retry 3 "https://github.com/whyvl/wireproxy/releases/download/v1.1.3/wireproxy_linux_${arch}.tar.gz" -o "$stage/archive"
echo "$sha  $stage/archive" | sha256sum -c -
tar --no-same-owner -xzf "$stage/archive" -C "$stage" wireproxy
chmod 0755 "$stage/wireproxy"
setpriv --pdeathsig KILL -- "$stage/wireproxy" --version
mv -fT -- "$stage/wireproxy" "$dest/wireproxy"
