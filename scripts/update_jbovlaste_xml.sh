#!/bin/bash

set -euo pipefail

# Find and go to where the script lives
sdir="$(dirname "$(readlink -f "$0")")"
cd "$sdir"
# And step out one
cd ..

if [ -z "${1:-}" ]
then
  echo "Usage: update_jbovlaste_xml.sh BUILD_DIR [--refresh]" >&2
  exit 1
fi

builddir=$1
if [[ "${2:-}" != "" && "${2:-}" != --refresh ]]; then
  echo "Unknown option: $2" >&2
  exit 1
fi

# Jbovlaste is read-only. Lensisku is its de facto successor, but Lensisku's
# XML export is a different shape (<entry><word>, not <valsi word>), and the
# glossary reads the Jbovlaste export. Keep this URL while it still serves that
# export.
jbovlaste_url='http://jbovlaste.lojban.org/export/xml-export.html?lang=en&bot_key=z2BsnKYJhAB0VNsl'

if [[ "${2:-}" != --refresh && -s dictionary/all_words.xml ]]
then
  echo
  echo "Using dictionary/all_words.xml for the glossary. Run cll_build -j to fetch a fresh Jbovlaste export."
  echo
else
  echo
  echo "Fetching dictionary/all_words.xml from the Jbovlaste XML export."
  echo "Jbovlaste is read-only, and Lensisku is its de facto successor. Lensisku's XML is a different shape, so this build still uses the Jbovlaste export."
  echo "Review the file before committing it, so builds stay reproducible."
  echo
  temporary=$(mktemp dictionary/all_words.xml.XXXXXX)
  trap '[[ -z "${temporary:-}" ]] || rm -f -- "$temporary"' EXIT
  if ! wget "$jbovlaste_url" -O "$temporary"; then
    echo "The Jbovlaste download failed. dictionary/all_words.xml was not changed." >&2
    exit 1
  fi
  # Do not replace a usable dictionary with a failed or empty download.
  if ! test -s "$temporary" || ! xmllint --nonet --noout "$temporary"; then
    echo "The download was empty or not well-formed XML. dictionary/all_words.xml was not changed." >&2
    exit 1
  fi
  # mktemp is private (mode 600). A wget download is readable.
  chmod 644 -- "$temporary"
  mv -- "$temporary" dictionary/all_words.xml
  temporary=""
  trap - EXIT
fi

cp dictionary/all_words.xml "$builddir/jbovlaste.xml.new"

sizenew="$(stat -c %s "$builddir/jbovlaste.xml.new" || echo 0)"
if [ ! -f "$builddir/jbovlaste.xml.new" -o ! "$sizenew" -o "$sizenew" -lt 100 ]
then
  echo
  echo "Couldn't fetch jbovlaste file; bailing."
  echo
  exit 1
fi

size="$(stat -c %s "$builddir/jbovlaste.xml" || echo 0)"
if [ ! -f "$builddir/jbovlaste.xml" -o ! "$size" -o "$size" -lt 100 ]
then
  echo
  echo "old jbovlaste build file is bad or doesn't exist; replacing"
  echo
  mv "$builddir/jbovlaste.xml.new" "$builddir/jbovlaste.xml"
else
  if diff -q "$builddir/jbovlaste.xml.new" "$builddir/jbovlaste.xml" >/dev/null 2>&1
  then
    echo
    echo "jbovlaste file has not changed."
    echo
  else
    echo
    echo "New jbovlaste file found; putting in place."
    echo
    cp "$builddir/jbovlaste.xml.new" "$builddir/jbovlaste.xml"
  fi
fi
