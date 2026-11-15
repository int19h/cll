#!/bin/bash
# Install EPUBCheck 5.4.0 from the official release. The SHA-256 is checked
# before extraction. A second run with the same destination does nothing.
# A destination that already holds unrelated files is left unchanged.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/install-epubcheck.sh DESTINATION_DIRECTORY' >&2
  exit 2
fi
version=5.4.0
url="https://github.com/w3c/epubcheck/releases/download/v${version}/epubcheck-${version}.zip"
sha256=33350c61038e71dfb3d45a76aed04bf5481e6d5500cb780f6e98db8bbd15a28c
dest=$(realpath -m "$1")
mkdir -p "$dest"
script_dir=$(dirname "$(readlink -f "$0")")
safe_rm_tree="$script_dir/safe-rm-tree.sh"
# A copied installer (tests) finds the helper in the checkout instead.
[ -x "$safe_rm_tree" ] || safe_rm_tree="scripts/safe-rm-tree.sh"
# Drop scratch directories left by an interrupted install.
find "$dest" -mindepth 1 -maxdepth 1 -name '.epubcheck-install.*' -print0 |
  while IFS= read -r -d '' stale; do
    "$safe_rm_tree" --root "$dest" "$stale"
  done
if [ -f "$dest/epubcheck.jar" ] && [ -d "$dest/lib" ] \
    && [ "$(cat "$dest/.sha256" 2>/dev/null || true)" = "$sha256" ]; then
  exit 0
fi
if [ -n "$(find "$dest" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    && [ ! -e "$dest/epubcheck.jar" ] && [ ! -e "$dest/.sha256" ]; then
  echo "EPUBCheck destination holds unrelated files and has no install marker: $dest" >&2
  exit 1
fi
scratch=$(mktemp -d "$dest/.epubcheck-install.XXXXXX")
cleanup_scratch() {
  case ${scratch:-} in
    "$dest"/.epubcheck-install.*) "$safe_rm_tree" --root "$dest" "$scratch" ;;
    *) echo "refusing to delete unexpected scratch folder: ${scratch:-}" >&2 ;;
  esac
}
trap cleanup_scratch EXIT
archive="$scratch/epubcheck.zip"
if [ -n "${EPUBCHECK_ARCHIVE:-}" ]; then
  cp "${EPUBCHECK_ARCHIVE}" "$archive"
else
  curl -fL -sS --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 600 \
    "$url" -o "$archive"
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
# A marker keeps a killed copy from looking like an unrelated directory.
# The real stamp is written only after the new jar runs.
: > "$dest/.sha256"
# Replace only the files this installer writes. Leave anything else in place.
for name in epubcheck.jar lib licenses LICENSE.txt CHANGELOG.txt README.txt THIRD-PARTY.txt; do
  "$safe_rm_tree" --root "$dest" "$dest/$name"
done
cp -a "$src/." "$dest/"
test -f "$dest/epubcheck.jar"
test -d "$dest/lib"
java -jar "$dest/epubcheck.jar" --version
printf '%s\n' "$sha256" > "$dest/.sha256"
