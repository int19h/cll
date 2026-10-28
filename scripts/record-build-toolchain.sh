#!/usr/bin/env bash
# Keep the package and font inventory beside each book build.
set -euo pipefail
output=${1:?Usage: scripts/record-build-toolchain.sh OUTPUT_DIRECTORY}
mkdir -p "$output"
rm -f "$output/system-packages.tsv" "$output/ubuntu.sources" "$output/context-sources.txt" \
  "$output/tools.txt" "$output/fonts.tsv" "$output/book-fonts.sha256" "$output/python-packages.txt"
if command -v dpkg-query >/dev/null; then
  dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' > "$output/system-packages.tsv"
fi
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  cp /etc/apt/sources.list.d/ubuntu.sources "$output/ubuntu.sources"
fi
if [ -f /usr/local/share/cll/context-sources.txt ]; then
  cp /usr/local/share/cll/context-sources.txt "$output/context-sources.txt"
fi
{
  for tool in ruby node npm xsltproc xmllint prince context typst; do
    if command -v "$tool" >/dev/null; then
      "$tool" --version
    fi
  done
  if command -v gem >/dev/null; then
    gem list --local
  fi
} > "$output/tools.txt" 2>&1
if [ -n "${CLL_WEASYPRINT_PYTHON:-}" ]; then
  "$CLL_WEASYPRINT_PYTHON" -m pip freeze > "$output/python-packages.txt"
  "$CLL_WEASYPRINT_PYTHON" -m weasyprint --version >> "$output/tools.txt"
fi
if command -v fc-list >/dev/null; then
  fc-list --format '%{file}\t%{family}\t%{style}\t%{fontversion}\n' | LC_ALL=C sort > "$output/fonts.tsv"
fi
find assets/fonts -type f -exec sha256sum {} + | LC_ALL=C sort > "$output/book-fonts.sha256"
