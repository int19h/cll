#!/bin/bash
# Install EPUBCheck 5.4.0 from the official release. The SHA-256 is checked
# before extraction. A second run with the same destination does nothing.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/install-epubcheck.sh DESTINATION_DIRECTORY' >&2
  exit 2
fi
version=5.4.0
url="https://github.com/w3c/epubcheck/releases/download/v${version}/epubcheck-${version}.zip"
sha256=33350c61038e71dfb3d45a76aed04bf5481e6d5500cb780f6e98db8bbd15a28c
dest=$(realpath -m "$1")
if [ -f "$dest/epubcheck.jar" ] && [ -d "$dest/lib" ] \
    && [ "$(cat "$dest/.sha256" 2>/dev/null || true)" = "$sha256" ]; then
  exit 0
fi
mkdir -p "$dest"
scratch=$(mktemp -d "$dest/.epubcheck-install.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
archive="$scratch/epubcheck.zip"
if [ -n "${EPUBCHECK_ARCHIVE:-}" ]; then
  cp "${EPUBCHECK_ARCHIVE}" "$archive"
else
  curl -fL --retry 3 --retry-delay 2 "$url" -o "$archive"
fi
if ! (cd "$scratch" && echo "$sha256  epubcheck.zip" | sha256sum --check --status); then
  echo 'EPUBCheck archive does not match the pinned SHA-256. Extraction did not start.' >&2
  exit 1
fi
unzip -q "$archive" -d "$scratch"
src="$scratch/epubcheck-${version}"
if [ ! -f "$src/epubcheck.jar" ] || [ ! -d "$src/lib" ]; then
  echo 'EPUBCheck archive does not contain epubcheck.jar and lib/.' >&2
  exit 1
fi
find "$dest" -mindepth 1 -maxdepth 1 ! -name '.epubcheck-install.*' -exec rm -rf {} +
cp -a "$src/." "$dest/"
test -f "$dest/epubcheck.jar"
test -d "$dest/lib"
java -jar "$dest/epubcheck.jar" --version
printf '%s\n' "$sha256" > "$dest/.sha256"
