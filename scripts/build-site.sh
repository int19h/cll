#!/bin/bash
#
# Build one published version of the book site into an output directory.
#
#   scripts/build-site.sh <src-tree> <version> <baseline-nochunks-dir> <out-dir> \
#                         [<previous-nochunks-dir> <previous-label>]
#
# <src-tree>  a checked-out worktree of the version's source (its own
#             cll_build / scripts / chapters are used to build it, so
#             each version builds with its own build system)
# <version>   the version label, e.g. 1.3
# <baseline>  a prebuilt UnCLL xhtml_no_chunks dir (with index.html) used
#             as the "old" side of the diff; pass "" to skip the diff.
#             Build it with the SAME toolchain for a clean diff.
# <out-dir>   site root; output goes to <out-dir>/<version>/
# <previous>  the previous release's xhtml_no_chunks dir (built earlier in
#             the same run) and the label to link it under (e.g. v1.3.2).
#             Omit both for the oldest version, whose predecessor is the
#             UnCLL baseline: diff_from_previous then mirrors
#             diff_from_uncll for layout parity, without its own link.
#
# Produces under <out-dir>/<version>/:
#   xhtml_section_chunks/   per-section browsable HTML
#   xhtml_no_chunks/        single-page HTML
#   cll.pdf, cll.epub       downloadable formats (when prince/java present)
#   diff_from_uncll/        difference.html, difference_prefixed.html
#   diff_from_official/     same, vs the official CLL 1.1 rendering
#                           (official/cll_v1.1_xhtml-no-chunks in the
#                           version's own tree, as UnCLL shipped it)
#   diff_from_previous/     same, vs the previous release
#   index.html              version landing page
#
# Toolchain: xmlto, xsltproc, ruby (+ nokogiri optimist htmlentities),
# node (+ regenerator), tidy; plus prince (PDF) and a JRE (ePub epubcheck)
# for the downloadable formats, which are skipped with a warning when the
# tools are absent.
set -euo pipefail

src="$(cd "${1:?usage: build-site.sh <src-tree> <version> <baseline> <out-dir> [<previous> <previous-label>]}" && pwd)"
version="${2:?missing version}"
baseline="${3-}"
outdir="$(mkdir -p "${4:?missing out-dir}" && cd "$4" && pwd)"
previous="${5-}"
prevlabel="${6-}"

dest="$outdir/$version"
mkdir -p "$dest"
cd "$src"

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

# Produce one visual diff: <old-tree> vs this build's xhtml_no_chunks,
# published as <dest>/<outname>/difference{,_prefixed}.html.
# scripts/diff (htmldiff) resolves paths relative to its own dir, so the
# temp tree must live under this src tree's build/.
make_diff() {
  local old="$1" outname="$2"
  local d="build/site_diff" type=xhtml_no_chunks
  rm -rf "$d"; mkdir -p "$d"
  cp -pr "$old"                "$d/diff_old_$type"
  cp -pr build/xhtml_no_chunks "$d/diff_new_$type"
  find "$d" -name 'sed*' -type f -delete 2>/dev/null || true
  # same normalization as scripts/diff_official
  find "$d" -name '*.html' -type f | xargs sed -r -i \
    -e 's/<a id="idm[0-9]+"/<a id="idmXXX"/g' -e 's/#idm[0-9]+"/#idmXXX"/g' -e 's/</\n</g'
  find "$d" -name '*.html' -type f | xargs sed -r -i -e '/^\s*$/d'
  node "$src/scripts/diff" "$d"
  rm -rf "$dest/$outname"; mkdir -p "$dest/$outname"
  cp -p "$d/difference.html" "$d/difference_prefixed.html" "$dest/$outname/"
  rm -rf "$d"
}

if [ -n "$baseline" ] && [ -s "$baseline/index.html" ]; then
  echo "==> [$version] diffing vs UnCLL baseline"
  make_diff "$baseline" diff_from_uncll
else
  echo "==> [$version] no baseline; skipping diff"
fi

official="$src/official/cll_v1.1_xhtml-no-chunks"
if [ -s "$official/index.html" ]; then
  echo "==> [$version] diffing vs official CLL 1.1"
  make_diff "$official" diff_from_official
else
  echo "==> [$version] WARNING: no official CLL 1.1 tree in this src; skipping diff_from_official" >&2
fi

if [ -n "$previous" ] && [ -s "$previous/index.html" ]; then
  echo "==> [$version] diffing vs previous release ($prevlabel)"
  make_diff "$previous" diff_from_previous
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
<li><a href="diff_from_official/difference.html">Visual diff vs CLL&nbsp;1.1 (the official book)</a>
    &middot; <a href="diff_from_official/difference_prefixed.html">(with change markers)</a></li>
<li><a href="diff_from_uncll/difference.html">Visual diff vs UnCLL&nbsp;1.2.16</a>
    &middot; <a href="diff_from_uncll/difference_prefixed.html">(with change markers)</a></li>
$( [ -n "$prevlabel" ] && echo '<li><a href="diff_from_previous/difference.html">Visual diff vs '"$prevlabel"' (previous release)</a>
    &middot; <a href="diff_from_previous/difference_prefixed.html">(with change markers)</a></li>' )
</ul>
<p class="muted"><a href="../">All versions</a></p>
</body></html>
HTML

echo "==> [$version] done: $dest"
