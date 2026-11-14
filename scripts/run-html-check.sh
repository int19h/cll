#!/bin/bash
# Run the HTML5 contract checks and the Nu Html Checker.
# The one-page book and the section chunks are required.
# Chapter chunks, the ePub pages, and the PDF HTML are checked when present.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/run-html-check.sh BUILD_DIRECTORY' >&2
  exit 2
fi
builddir=$(realpath "$1")
root=$(cd "$(dirname "$0")/.." && pwd)
if [ ! -d "$builddir/xhtml_no_chunks" ] || [ ! -d "$builddir/xhtml_section_chunks" ]; then
  echo 'html_check needs the one-page book and the section chunks' >&2
  exit 1
fi
if [ -n "${VNU_JAR:-}" ]; then
  jar=$VNU_JAR
elif [ -f /usr/local/share/vnu/vnu.jar ]; then
  jar=/usr/local/share/vnu/vnu.jar
else
  dest=$root/build/tools/vnu
  "$root/scripts/install-vnu.sh" "$dest"
  jar=$dest/vnu.jar
fi
if [ ! -f "$jar" ]; then
  echo "Nu Html Checker jar not found: $jar" >&2
  exit 1
fi

dirs=("$builddir/xhtml_no_chunks" "$builddir/xhtml_section_chunks")
for extra in xhtml_chapter_chunks epub pdf weasyprint; do
  if [ -d "$builddir/$extra" ]; then
    dirs+=("$builddir/$extra")
  fi
done
ruby "$root/scripts/check-html-polyglot.rb" "${dirs[@]}"
python3 "$root/scripts/check-html-links.py" "${dirs[@]}"

# CSS is not an argument. xargs keeps the command under ARG_MAX.
find "$builddir/xhtml_no_chunks" "$builddir/xhtml_section_chunks" \
  -type f -name '*.html' -print0 \
  | xargs -0 java -jar "$jar" --errors-only \
      --filterfile "$root/scripts/vnu-filters.txt"
