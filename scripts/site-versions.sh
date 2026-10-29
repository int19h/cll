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

# Add a format here. Fields: name | release file | link label | build
# target (or container launcher) | toolchain. {version} is substituted.
# Existing native targets use cll_build. A new toolchain also needs its
# installer in build-site.sh and its runner dependencies in pages.yml.
SITE_FORMAT_REGISTRY=(
  'html|cll-{version}-html.tar.gz|Read online|xhtml_sections xhtml_nochunks|base'
  'epub|cll.epub|Download ePub|epub|java'
  'pdf|cll.pdf|Download PDF|pdf|prince'
  'pdf-weasyprint|cll-weasyprint.pdf|Download PDF (WeasyPrint)|pdf_weasyprint|weasyprint'
  'pdf-typst|cll-typst.pdf|Download PDF (Typst)|pdf_typst|typst'
  'pdf-context|cll-context.pdf|Download PDF (ConTeXt)|run_context_container.sh|container'
)
SITE_FORMATS=()
for site_entry in "${SITE_FORMAT_REGISTRY[@]}"; do
  SITE_FORMATS+=("${site_entry%%|*}")
done
unset site_entry
SITE_ALL_FORMATS="$(IFS=,; echo "${SITE_FORMATS[*]}")"
SITE_DEFAULT_FORMATS="html,epub,pdf"

site_edition_version() { # <version> <ref> <commit>
  local version="$1" ref="$2" commit="$3" value
  # Other refs keep the source tree's development-version resolver.
  case "$ref" in edition/*) ;; *) return 0 ;; esac
  if [ "$ref" != "edition/$version" ]; then
    echo "site: ref '$ref' does not match row $version; expected edition/$version" >&2
    return 1
  fi
  value="$(git show "$commit:.env" | sed -n 's/^VERSION=//p' | tr -d '"')" || return 1
  if [ "$value" != "colojban-$version" ]; then
    echo "site: $ref .env VERSION='$value'; expected colojban-$version" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

site_format_field() { # <format> <field-number, starting at 1>
  local entry
  for entry in "${SITE_FORMAT_REGISTRY[@]}"; do
    if [ "${entry%%|*}" = "$1" ]; then
      cut -d'|' -f"$2" <<< "$entry"
      return
    fi
  done
  echo "unknown format '$1'" >&2; return 1
}

site_toolchains() { # <canonical formats>
  local f IFS=,
  for f in $1; do site_format_field "$f" 5; done | sort -u
}

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
  local file
  file="$(site_format_field "$1" 2)" || return 1
  echo "${file//\{version\}/$2}"
}

# True for a registered format's release filename, for any valid version.
# Use the registry templates so new formats need no separate filename list.
site_is_format_file() { # <filename>
  local file="$1" f template prefix suffix version
  for f in "${SITE_FORMATS[@]}"; do
    template="$(site_format_field "$f" 2)"
    if [[ "$template" == *'{version}'* ]]; then
      prefix="${template%%\{version\}*}"
      suffix="${template#*\{version\}}"
      [[ "$file" == "$prefix"*"$suffix" ]] || continue
      version="${file#"$prefix"}"
      version="${version%"$suffix"}"
      if site_is_version "$version"; then return 0; fi
    elif [ "$file" = "$template" ]; then
      return 0
    fi
  done
  return 1
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
  return 0
}

# The label of a format on a landing page.
site_download_label() { site_format_field "$1" 3; }

# Print links only for the formats present on disk. Both landing pages
# use this function. The prefix is relative to the page being written.
site_format_links() { # <version-dir> <version> <URL-prefix>
  local f file label
  if [ -s "$1/xhtml_section_chunks/index.html" ]; then
    printf '<a href="%sxhtml_section_chunks/">Read online (section by section)</a> ' "$3"
  fi
  if [ -s "$1/xhtml_no_chunks/index.html" ]; then
    printf '<a href="%sxhtml_no_chunks/">Read online (single page)</a> ' "$3"
  fi
  for f in "${SITE_FORMATS[@]}"; do
    [ "$f" != html ] || continue
    file="$(site_format_file "$f" "$2")"
    label="$(site_download_label "$f")"
    if [ -s "$1/$file" ]; then
      printf '<a href="%s%s">%s</a> ' "$3" "$file" "$label"
    fi
  done
  return 0
}

SITE_VERSION_RE='^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

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
  local line ver ref formats rest rows="" n=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    ver="${line%%$'\t'*}"
    ref=""; formats=""
    if [[ "$line" == *$'\t'* ]]; then
      rest="${line#*$'\t'}"
      ref="${rest%%$'\t'*}"
      if [[ "$rest" == *$'\t'* ]]; then
        formats="${rest#*$'\t'}"
        if [[ "$formats" == *$'\t'* ]]; then
          echo "versions.tsv: $ver has more than three columns" >&2; return 1
        fi
      fi
    fi
    if ! site_is_version "$ver"; then
      echo "versions.tsv: '$ver' is not a version number" >&2; return 1
    fi
    [ -n "$ref" ] || { echo "versions.tsv: $ver has no git ref" >&2; return 1; }
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
    printf '%s' "$rows" | awk -F'\t' -v v="$v" '("x" $1) == ("x" v)'
  done
}
