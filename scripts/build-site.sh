#!/bin/bash
#
# Build one published version of the book site into an output directory.
#
#   scripts/build-site.sh <src-tree> <version> <baseline-ref> <out-dir> \
#                         [<previous-ref> <previous-label>]
#
# <src-tree>  a checked-out worktree of the version's source (its own
#             cll_build / scripts / chapters are used to build it, so
#             each version builds with its own build system)
# <version>   the version label, e.g. 1.3
# <baseline-ref>
#             the git revision of the UnCLL 1.2.16 sources (normally
#             origin/baseline/uncll-1.2.16), the old side of
#             diff_from_uncll; pass "" to skip that diff.
# <out-dir>   site root; output goes to <out-dir>/<version>/
# <previous-ref> <previous-label>
#             the git revision of the previous release's sources (e.g.
#             origin/edition/1.3.4) and the label to link it under (e.g.
#             v1.3.4). Omit both for the oldest version, whose predecessor
#             is the UnCLL baseline: diff_from_previous then mirrors
#             diff_from_uncll for layout parity, without its own link.
#
# Git revisions are resolved in the repository of <src-tree>.
#
# Produces under <out-dir>/<version>/:
#   xhtml_section_chunks/   per-section browsable HTML
#   xhtml_no_chunks/        single-page HTML
#   cll.pdf, cll.epub       downloadable formats (when prince/java present)
#   diff_from_official/     difference.html, difference_prefixed.html:
#                           the whole book with the changes since the
#                           official CLL 1.1 marked in place
#   diff_from_uncll/        same, since UnCLL 1.2.16
#   diff_from_previous/     same, since the previous release
#   index.html              version landing page
#
# DIFFS_ONLY=1 in the environment keeps the book files already in
# <out-dir>/<version>/ (xhtml_section_chunks, xhtml_no_chunks, cll.pdf,
# cll.epub) and makes only the diffs and index.html (issue #128: a
# published version serves the book files of its release).
#
# The diffs are computed on the DocBook sources (issue #127):
# scripts/docbook-diff.py writes annotated chapters into a copy of the
# version's tree (DocBook revisionflag on changed words and blocks,
# deleted material re-inserted, notes where moved material was), which is
# then built as xhtml_no_chunks with scripts/docbook-diff.xsl, a driver
# around DocBook XSL's xhtml/changebars.xsl. The diff pages load their
# images and CSS from the version's own xhtml_no_chunks/.
#
# Toolchain: xmlto, xsltproc, ruby (+ nokogiri optimist htmlentities),
# node (+ regenerator), tidy, python3; plus prince (PDF) and a JRE (ePub
# epubcheck) for the downloadable formats, which are skipped with a
# warning when the tools are absent.

# The source of "the official CLL 1.1" for diff_from_official: the tag
# v1.1-2016-08-26-html (commit 6c0556c7), the sources of "Version 1.1,
# Generated 2016-08-26", the build that lojban.org publishes at
# https://lojban.org/publications/cll/cll_v1.1_xhtml-section-chunks/
# (maintainer decision, issue #127). Its chapters are identical to those of
# bb905337, the source of the 2016 copy the site compared against before.
# The commit is named rather than the tag because the site workflow fetches
# branches only; the commit is on baseline/uncll-1.2.16. (The 2019-11-14
# official build, tag v1.1-2019-11-14-html, is efb2d7e4.)
CLL11_SOURCE="${CLL11_SOURCE:-6c0556c7b17f96b3bf41e8123ba18ef4868e056a}"
CLL11_LABEL="${CLL11_LABEL:-CLL 1.1 (the official book)}"
set -euo pipefail

src="$(cd "${1:?usage: build-site.sh <src-tree> <version> <baseline-ref> <out-dir> [<previous-ref> <previous-label>]}" && pwd)"
version="${2:?missing version}"
baseline="${3-}"
outdir="$(mkdir -p "${4:?missing out-dir}" && cd "$4" && pwd)"
previous="${5-}"
prevlabel="${6-}"

tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The previous-release arguments come as a pair: both empty (the oldest
# version, whose predecessor is the UnCLL baseline) or both set — and a
# supplied previous revision must actually exist. Fail fast rather than
# publish a missing or falsely labelled diff.
if { [ -n "$previous" ] && [ -z "$prevlabel" ]; } || { [ -z "$previous" ] && [ -n "$prevlabel" ]; }; then
  echo "build-site.sh: <previous-ref> and <previous-label> must be given together (got '$previous' / '$prevlabel')" >&2
  exit 1
fi
need_rev() { # <rev> <what>
  git -C "$src" rev-parse -q --verify "$1^{commit}" >/dev/null || {
    echo "build-site.sh: $2 '$1' is not a commit in the repository of $src" >&2
    exit 1
  }
}
[ -z "$previous" ] || need_rev "$previous" "previous release"
[ -z "$baseline" ] || need_rev "$baseline" "baseline"
# The official diff is required (the landing page links it unconditionally),
# so a missing CLL 1.1 source commit must fail here, before any building,
# rather than deploy dead links.
need_rev "$CLL11_SOURCE" "CLL 1.1 source (CLL11_SOURCE)"

dest="$outdir/$version"
mkdir -p "$dest"
cd "$src"

if [ -n "${DIFFS_ONLY:-}" ]; then
  # A published version keeps the book files of its release (restored into
  # <out-dir>/<version>/ by build-versions.sh); only the comparison pages
  # and the landing page are made again. The diffs need only the sources,
  # and their pages load their assets from the restored xhtml_no_chunks/.
  [ -s "$dest/xhtml_no_chunks/index.html" ] || { echo "DIFFS_ONLY: no restored xhtml_no_chunks in $dest" >&2; exit 1; }
  echo "==> [$version] keeping the released book files; rebuilding the diffs only"
else
echo "==> [$version] building xhtml_section_chunks + xhtml_no_chunks in $src"
rm -rf build/xhtml_section_chunks build/xhtml_section_chunks.done \
       build/xhtml_no_chunks build/xhtml_no_chunks.done \
       build/cll.xml build/cll_processed_xhtml.xml
./cll_build -n -T xhtml_sections
./cll_build -n -T xhtml_nochunks
[ -s build/xhtml_section_chunks/index.html ] || { echo "no section-chunks output" >&2; exit 1; }
[ -s build/xhtml_no_chunks/index.html ]      || { echo "no no-chunks output" >&2; exit 1; }

rm -rf "$dest/xhtml_section_chunks" "$dest/xhtml_no_chunks"
cp -pr build/xhtml_section_chunks "$dest/xhtml_section_chunks"
cp -pr build/xhtml_no_chunks      "$dest/xhtml_no_chunks"
find "$dest" -name 'sed*' -type f -delete 2>/dev/null || true

# PDF and ePub (skipped with a warning if the toolchain lacks prince/java,
# so the HTML site can still be built in minimal environments)
if command -v prince >/dev/null 2>&1; then
  echo "==> [$version] building PDF"
  ./cll_build -n -T pdf
  [ -s build/cll.pdf ] || { echo "no PDF output" >&2; exit 1; }
  cp -p build/cll.pdf "$dest/cll.pdf"
else
  echo "==> [$version] WARNING: prince not found; skipping PDF" >&2
fi
if command -v java >/dev/null 2>&1; then
  echo "==> [$version] building ePub"
  ./cll_build -n -T epub
  [ -s build/cll.epub ] || { echo "no ePub output" >&2; exit 1; }
  cp -p build/cll.epub "$dest/cll.epub"
else
  echo "==> [$version] WARNING: java not found; skipping ePub" >&2
fi
fi  # DIFFS_ONLY

# Produce one visual diff: the book of <src-tree> with the changes since
# <old-ref> marked, published as <dest>/<outname>/difference{,_prefixed}.html.
# The annotated tree and its build live under this src tree's build/ and
# are removed afterwards.
make_diff() {
  local oldref="$1" outname="$2" oldlabel="$3"
  local d="$src/build/site_diff/$outname"
  rm -rf "$d"; mkdir -p "$d"
  # a copy of the version's tree, without what the HTML build does not use
  tar -C "$src" --exclude=./.git --exclude=./build --exclude=./official \
      --exclude=./orig --exclude=./epub --exclude=./coverage -cf - . | tar -C "$d" -xf -
  mkdir -p "$d/build"
  python3 "$tools/docbook-diff.py" --repo "$src" --stats "$d/build/dbdiff-stats.json" \
    "$oldref" "$src" "$d"
  cp "$tools/docbook-diff.xsl" "$d/xml/docbook2html_diff.xsl"
  sed -i 's|^\(xhtml_nochunks: xsl_file = \).*|\1xml/docbook2html_diff.xsl|' "$d/scripts/Makefile"
  grep -qx 'xhtml_nochunks: xsl_file = xml/docbook2html_diff.xsl' "$d/scripts/Makefile" || {
    echo "build-site.sh: cannot point $d/scripts/Makefile at the diff stylesheet" >&2
    exit 1
  }
  ( cd "$d" && ./cll_build -n -T xhtml_nochunks )
  [ -s "$d/build/xhtml_no_chunks/index.html" ] || { echo "no diff output for $outname" >&2; exit 1; }
  rm -rf "$dest/$outname"
  python3 "$tools/docbook-diff.py" finish "$d/build/xhtml_no_chunks/index.html" "$dest/$outname" \
    --old-label "$oldlabel" --new-label "$version" --assets ../xhtml_no_chunks/ \
    --stats "$d/build/dbdiff-stats.json"
  rm -rf "$d"
}

if [ -n "$baseline" ]; then
  echo "==> [$version] diffing vs UnCLL baseline ($baseline)"
  make_diff "$baseline" diff_from_uncll "UnCLL 1.2.16"
else
  echo "==> [$version] no baseline; skipping diff"
fi

echo "==> [$version] diffing vs official CLL 1.1 ($CLL11_SOURCE)"
make_diff "$CLL11_SOURCE" diff_from_official "$CLL11_LABEL"

if [ -n "$previous" ]; then
  echo "==> [$version] diffing vs previous release ($prevlabel, $previous)"
  make_diff "$previous" diff_from_previous "$prevlabel"
elif [ -d "$dest/diff_from_uncll" ]; then
  # oldest published version: its predecessor is the UnCLL baseline
  echo "==> [$version] no previous release; mirroring diff_from_uncll as diff_from_previous"
  rm -rf "$dest/diff_from_previous"
  cp -pr "$dest/diff_from_uncll" "$dest/diff_from_previous"
fi

cat > "$dest/index.html" <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>The Contemporary Lojban Language &mdash; $version</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:44rem;margin:3rem auto;padding:0 1rem}
h1{font-size:1.5rem}a{color:#0b6}li{margin:.4rem 0}.muted{color:#666;font-size:.9rem}</style>
</head><body>
<h1>The Contemporary Lojban Language &mdash; version $version</h1>
<p class="muted">An unofficial publication, community edition (not by the LLG).</p>
<ul>
<li><a href="xhtml_section_chunks/">Read online (section by section)</a></li>
<li><a href="xhtml_no_chunks/">Read online (single page)</a></li>
$( [ -s "$dest/cll.pdf" ]  && echo '<li><a href="cll.pdf">Download PDF</a></li>' )
$( [ -s "$dest/cll.epub" ] && echo '<li><a href="cll.epub">Download ePub</a></li>' )
<li><a href="diff_from_official/difference.html">Changes marked vs CLL&nbsp;1.1 (the official book)</a>
    &middot; <a href="diff_from_official/difference_prefixed.html">(with text markers)</a></li>
<li><a href="diff_from_uncll/difference.html">Changes marked vs UnCLL&nbsp;1.2.16</a>
    &middot; <a href="diff_from_uncll/difference_prefixed.html">(with text markers)</a></li>
$( [ -n "$prevlabel" ] && echo '<li><a href="diff_from_previous/difference.html">Changes marked vs '"$prevlabel"' (previous release)</a>
    &middot; <a href="diff_from_previous/difference_prefixed.html">(with text markers)</a></li>' )
</ul>
<p class="muted"><a href="../">All versions</a></p>
</body></html>
HTML

echo "==> [$version] done: $dest"
