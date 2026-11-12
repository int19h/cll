#!/bin/bash

# These scripts run in the build container, or in a native Linux build.
# Stop when a tool fails, and do not replace a page with an empty file.
set -euo pipefail

cd "${1:?Give the HTML directory as the sole argument}"

tmp=""
list=""
trap '[[ -z "$list" ]] || rm -f -- "$list"; [[ -z "$tmp" ]] || rm -f -- "$tmp" "$tmp.tmp" "$tmp.ruby"' EXIT

# Stage the manifest, then move it into place. Do not list temporary files.
tmp=$(mktemp ./cll.appcache.XXXXXX)
{
  echo 'CACHE MANIFEST'
  echo "# $(date)"
  echo
  echo 'CACHE:'
  find . -type f ! -name '*.appcache*' | sed 's;^\./;;' | sort
  echo
  echo 'NETWORK:'
  echo '*'
} > "$tmp"
mv -- "$tmp" cll.appcache
tmp=""

list=$(mktemp)
find . -type f ! -name '*.appcache*' -print0 > "$list"

while IFS= read -r -d '' file; do
  rc=0
  grep -q '<html xmlns=' "$file" || rc=$?
  if [[ "$rc" -eq 1 ]]; then
    continue
  fi
  if [[ "$rc" -ne 0 ]]; then
    exit "$rc"
  fi
  # Replace the original only after every tool succeeds.
  original=$file
  tmp=$(mktemp "${file}.XXXXXX")
  sed -r 's;<html xmlns=([^> ]*);<html xmlns=\1 manifest="cll.appcache";' "$original" > "$tmp"
  file=$tmp
  xmllint --format --loaddtd "$file" >"$file.tmp"
  mv -- "$file.tmp" "$tmp"
  chmod --reference="$original" "$tmp"
  mv -- "$tmp" "$original"
  tmp=""
done < "$list"
