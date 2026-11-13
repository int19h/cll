#!/bin/bash

# These scripts run in the build container, or in a native Linux build.
# Stop when a tool fails, and do not replace a page with an empty file.
set -euo pipefail

cufile="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/xhtml_postprocess_cleanup_file.rb"
[[ -f "$cufile" ]] || { echo "Can't find $cufile" >&2; exit 1; }
cd "${1:?Give the HTML directory as the sole argument}"

tmp=""
list=""
trap '[[ -z "$list" ]] || rm -f -- "$list"; [[ -z "$tmp" ]] || rm -f -- "$tmp" "$tmp.tmp" "$tmp.ruby"' EXIT

# Collect names first. A temporary file created while find is walking this
# directory can otherwise be picked up and processed.
list=$(mktemp)
find . -type f -print0 > "$list"

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
  sed -r -e 's;<html xmlns=([^> ]*);<html xmlns=\1 xml:lang="en" lang="en";' \
    -e 's; "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">; "dtd/xhtml1-transitional.dtd">;' \
    "$original" > "$tmp"
  ruby "$cufile" "$tmp" > "$tmp.ruby"
  mv -- "$tmp.ruby" "$tmp"
  chmod --reference="$original" "$tmp"
  mv -- "$tmp" "$original"
  tmp=""
done < "$list"
