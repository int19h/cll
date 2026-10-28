#!/bin/bash
#
# Shared helpers for the site scripts: the formats of a version, and the
# order of versions with prereleases. Source this file; it defines
# functions only.
#
# Formats (the third column of pages/versions.tsv):
#
#   html            the book online (xhtml_section_chunks/, xhtml_no_chunks/),
#                   the visual diffs, and the release archive
#                   cll-<version>-html.tar.gz
#   epub            cll.epub
#   pdf             cll.pdf, made by Prince
#   pdf-weasyprint  cll-weasyprint.pdf
#   pdf-typst       cll-typst.pdf
#   pdf-context     cll-context.pdf
#
# The visual diffs are HTML pages that load their images and CSS from the
# version's xhtml_no_chunks/, so a version has them only with "html".
#
# Version numbers are dotted numbers, such as 1.3.6, with an optional
# prerelease suffix, such as 1.3.6-rc1. A prerelease sorts before its
# final release: 1.3.6-rc1 < 1.3.6-rc2 < 1.3.6.

# All formats, in the order in which they are built and listed.
SITE_FORMATS=(html epub pdf pdf-weasyprint pdf-typst pdf-context)
SITE_ALL_FORMATS="html,epub,pdf,pdf-weasyprint,pdf-typst,pdf-context"
# The formats of a row without a third column: the set before formats
# could be chosen.
SITE_DEFAULT_FORMATS="html,pdf,epub"

# Print the formats of a list in the canonical order, comma-separated.
# An empty list gives the default set. An unknown format is an error.
site_formats() { # <list>
  local list="${1:-$SITE_DEFAULT_FORMATS}" f known out=""
  list="${list// /}"
  [ -n "$list" ] || list="$SITE_DEFAULT_FORMATS"
  local IFS=,
  for f in $list; do
    [ -n "$f" ] || continue
    for known in "${SITE_FORMATS[@]}"; do
      [ "$f" = "$known" ] && continue 2
    done
    echo "unknown format '$f' (known: ${SITE_FORMATS[*]})" >&2
    return 1
  done
  for known in "${SITE_FORMATS[@]}"; do
    case ",$list," in *",$known,"*) out="${out:+$out,}$known" ;; esac
  done
  [ -n "$out" ] || { echo "no formats in '$1'" >&2; return 1; }
  echo "$out"
}

# True when a canonical format list contains a format.
site_has_format() { # <formats> <format>
  case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac
}

# The file name of a format inside <out-dir>/<version>/ and on the release.
# html has no single file here; its release file is the archive.
site_format_file() { # <format> <version>
  case "$1" in
    html)           echo "cll-$2-html.tar.gz" ;;
    epub)           echo "cll.epub" ;;
    pdf)            echo "cll.pdf" ;;
    pdf-weasyprint) echo "cll-weasyprint.pdf" ;;
    pdf-typst)      echo "cll-typst.pdf" ;;
    pdf-context)    echo "cll-context.pdf" ;;
    *) echo "unknown format '$1'" >&2; return 1 ;;
  esac
}

# The release files of a canonical format list, one per line.
site_release_files() { # <formats> <version>
  local f IFS=,
  for f in $1; do site_format_file "$f" "$2"; done
}

# The downloadable files of a canonical format list (all but html).
site_download_files() { # <formats> <version>
  local f IFS=,
  for f in $1; do [ "$f" = html ] || site_format_file "$f" "$2"; done
}

# The label of a downloadable file on a landing page.
site_download_label() { # <file>
  case "$1" in
    cll.pdf)            echo "Download PDF" ;;
    cll.epub)           echo "Download ePub" ;;
    cll-weasyprint.pdf) echo "Download PDF (WeasyPrint)" ;;
    cll-typst.pdf)      echo "Download PDF (Typst)" ;;
    cll-context.pdf)    echo "Download PDF (ConTeXt)" ;;
  esac
}

SITE_VERSION_RE='^[0-9]+(\.[0-9]+)*(-[a-z]+[0-9]*)?$'

site_is_version() { # <string>
  [[ "$1" =~ $SITE_VERSION_RE ]]
}

site_is_prerelease() { # <version>
  [[ "$1" == *-* ]]
}

# A human name for a prerelease suffix: "release candidate" for -rcN.
site_prerelease_label() { # <version>
  case "${1#*-}" in
    rc*) echo "release candidate" ;;
    *)   echo "prerelease" ;;
  esac
}

# Sort version numbers, one per line, oldest first. GNU sort -V sorts "~"
# before the end of a string, so 1.3.6~rc1 comes before 1.3.6.
site_sort_versions() {
  sed 's/-/~/' | sort -V | sed 's/~/-/'
}

# Read pages/versions.tsv and print its rows oldest first, as
# "<version> TAB <ref> TAB <canonical formats>". Comments and empty lines
# are skipped. A malformed row is an error.
site_rows() { # <versions.tsv>
  local ver ref formats rest rows="" n=0
  while IFS=$'\t' read -r ver ref formats rest; do
    case "$ver" in ''|'#'*) continue ;; esac
    if ! site_is_version "$ver"; then
      echo "versions.tsv: '$ver' is not a version number" >&2; return 1
    fi
    [ -n "$ref" ] || { echo "versions.tsv: $ver has no git ref" >&2; return 1; }
    [ -z "$rest" ] || { echo "versions.tsv: $ver has more than three columns" >&2; return 1; }
    formats="$(site_formats "$formats")" || { echo "versions.tsv: bad formats for $ver" >&2; return 1; }
    rows+="$ver"$'\t'"$ref"$'\t'"$formats"$'\n'
    n=$((n + 1))
  done < "$1"
  [ "$n" -gt 0 ] || { echo "versions.tsv: no versions" >&2; return 1; }
  local dup
  dup="$(printf '%s' "$rows" | cut -f1 | sort | uniq -d)"
  [ -z "$dup" ] || { echo "versions.tsv: listed twice: $dup" >&2; return 1; }
  local v
  for v in $(printf '%s' "$rows" | cut -f1 | site_sort_versions); do
    printf '%s' "$rows" | awk -F'\t' -v v="$v" '$1 == v'
  done
}
