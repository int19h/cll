#!/bin/bash
# Install the Nu Html Checker jar from the pinned vnu-jar npm package.
# The SHA-256 is checked before extraction. A second run with the same
# destination does nothing. A destination that already holds unrelated
# files is left unchanged.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/install-vnu.sh DESTINATION_DIRECTORY' >&2
  exit 2
fi
version=26.10.12
url="https://registry.npmjs.org/vnu-jar/-/vnu-jar-${version}.tgz"
sha256=3925f07364f5e5a111cef54a7baefa575b22d05c70f8ced048f0616d4579b7ab
dest=$(realpath -m "$1")
mkdir -p "$dest"
script_dir=$(dirname "$(readlink -f "$0")")
safe_rm_tree="$script_dir/safe-rm-tree.sh"
# A copied installer (tests) finds the helper in the checkout instead.
[ -x "$safe_rm_tree" ] || safe_rm_tree="scripts/safe-rm-tree.sh"
find "$dest" -mindepth 1 -maxdepth 1 -name '.vnu-install.*' -print0 |
  while IFS= read -r -d '' stale; do
    "$safe_rm_tree" --root "$dest" "$stale"
  done
if [ -f "$dest/vnu.jar" ] && [ "$(cat "$dest/.sha256" 2>/dev/null || true)" = "$sha256" ]; then
  exit 0
fi
if [ -n "$(find "$dest" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    && [ ! -e "$dest/vnu.jar" ] && [ ! -e "$dest/.sha256" ]; then
  echo "Nu Html Checker destination holds unrelated files and has no install marker: $dest" >&2
  exit 1
fi
scratch=$(mktemp -d "$dest/.vnu-install.XXXXXX")
cleanup_scratch() {
  case ${scratch:-} in
    "$dest"/.vnu-install.*) "$safe_rm_tree" --root "$dest" "$scratch" ;;
    *) echo "refusing to delete unexpected scratch folder: ${scratch:-}" >&2 ;;
  esac
}
trap cleanup_scratch EXIT
archive="$scratch/vnu.tgz"
if [ -n "${VNU_ARCHIVE:-}" ]; then
  cp "${VNU_ARCHIVE}" "$archive"
else
  curl -fL -sS --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 600 \
    "$url" -o "$archive"
fi
if ! (cd "$scratch" && echo "$sha256  vnu.tgz" | sha256sum --check --status); then
  echo 'Nu Html Checker archive does not match the pinned SHA-256. Extraction did not start.' >&2
  exit 1
fi
tar -xzf "$archive" -C "$scratch"
src="$scratch/package/build/dist/vnu.jar"
if [ ! -f "$src" ]; then
  echo 'Nu Html Checker archive does not contain package/build/dist/vnu.jar.' >&2
  exit 1
fi
: > "$dest/.sha256"
rm -f "$dest/vnu.jar"
cp -a "$src" "$dest/vnu.jar"
test -f "$dest/vnu.jar"
java -jar "$dest/vnu.jar" --version
printf '%s\n' "$sha256" > "$dest/.sha256"
