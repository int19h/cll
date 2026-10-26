#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/install_typst.sh DESTINATION_DIRECTORY' >&2
  exit 2
fi
version=0.15.1
case $(uname -m) in
  aarch64|arm64)
    arch=aarch64
    sha=5aa8d74a3d906e60ea12a66ac2f37f8eef1b14cbad7182a745e393a10c23dcee
    ;;
  x86_64|amd64)
    arch=x86_64
    sha=a6d077d0a95eed5a2eba715b2dae06be954f624ccbf85758a03f389ded33118c
    ;;
  *) echo 'The pinned Typst installer supports Linux x86_64 and aarch64.' >&2; exit 1 ;;
esac
mkdir -p "$1"
dest=$(realpath "$1")
# Keep the download and extraction next to the destination, not in a shared cache.
scratch=$(mktemp -d "$dest/.typst-install.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
archive="typst-$arch-unknown-linux-musl"
curl -fL --retry 3 "https://github.com/typst/typst/releases/download/v$version/$archive.tar.xz" -o "$scratch/typst.tar.xz"
(cd "$scratch" && echo "$sha  typst.tar.xz" | sha256sum --check --status)
tar -xJf "$scratch/typst.tar.xz" -C "$scratch"
install -m 755 "$scratch/$archive/typst" "$dest/typst"
"$dest/typst" --version
