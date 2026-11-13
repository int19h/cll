#!/bin/bash
# Run EPUBCheck on one ePub. Warnings are printed and the status stays 0.
# An error exits 1, which stops the ePub build.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/run-epubcheck.sh EPUB_FILE' >&2
  exit 2
fi
epub=$1
root=$(cd "$(dirname "$0")/.." && pwd)
if [ -n "${EPUBCHECK_JAR:-}" ]; then
  jar=$EPUBCHECK_JAR
elif [ -f /usr/local/share/epubcheck/epubcheck.jar ]; then
  jar=/usr/local/share/epubcheck/epubcheck.jar
else
  dest=$root/build/tools/epubcheck
  jar=$dest/epubcheck.jar
  if [ ! -f "$jar" ] || [ ! -d "$dest/lib" ]; then
    "$root/scripts/install-epubcheck.sh" "$dest"
  fi
fi
if [ ! -f "$jar" ]; then
  echo "EPUBCheck jar not found: $jar" >&2
  exit 1
fi
exec java -jar "$jar" "$epub"
