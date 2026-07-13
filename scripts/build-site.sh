#!/bin/bash
#
# Build one published version of the book site into an output directory.
#
#   scripts/build-site.sh <src-tree> <version> <baseline-nochunks-dir> <out-dir>
#
# <src-tree>  a checked-out worktree of the version's source (its own
#             cll_build / scripts / chapters are used to build it, so
#             each version builds with its own build system)
# <version>   the version label, e.g. 1.3
# <baseline>  a prebuilt UnCLL xhtml_no_chunks dir (with index.html) used
#             as the "old" side of the diff; pass "" to skip the diff.
#             Build it with the SAME toolchain for a clean diff.
# <out-dir>   site root; output goes to <out-dir>/<version>/
#
# Produces under <out-dir>/<version>/:
#   xhtml_section_chunks/   per-section browsable HTML
#   xhtml_no_chunks/        single-page HTML
#   diff_from_uncll/        difference.html, difference_prefixed.html
#   index.html              version landing page
#
# Toolchain: xmlto, xsltproc, ruby (+ nokogiri optimist htmlentities),
# node (+ regenerator), tidy. Extensible: add xhtml_chapter_chunks / pdf
# / epub build targets and copy them into the version dir.
set -euo pipefail

src="$(cd "${1:?usage: build-site.sh <src-tree> <version> <baseline> <out-dir>}" && pwd)"
version="${2:?missing version}"
baseline="${3-}"
outdir="$(mkdir -p "${4:?missing out-dir}" && cd "$4" && pwd)"

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

if [ -n "$baseline" ] && [ -s "$baseline/index.html" ]; then
  echo "==> [$version] diffing vs UnCLL baseline"
  # scripts/diff (htmldiff) resolves paths relative to its own dir, so the
  # temp tree must live under this src tree's build/.
  d="build/site_diff"; type=xhtml_no_chunks
  rm -rf "$d"; mkdir -p "$d"
  cp -pr "$baseline"           "$d/diff_old_$type"
  cp -pr build/xhtml_no_chunks "$d/diff_new_$type"
  find "$d" -name 'sed*' -type f -delete 2>/dev/null || true
  # same normalization as scripts/diff_official
  find "$d" -name '*.html' -type f | xargs sed -r -i \
    -e 's/<a id="idm[0-9]+"/<a id="idmXXX"/g' -e 's/#idm[0-9]+"/#idmXXX"/g' -e 's/</\n</g'
  find "$d" -name '*.html' -type f | xargs sed -r -i -e '/^\s*$/d'
  node "$src/scripts/diff" "$d"
  mkdir -p "$dest/diff_from_uncll"
  cp -p "$d/difference.html" "$d/difference_prefixed.html" "$dest/diff_from_uncll/"
else
  echo "==> [$version] no baseline; skipping diff"
fi

cat > "$dest/index.html" <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>The Complete Lojban Language &mdash; $version</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:44rem;margin:3rem auto;padding:0 1rem}
h1{font-size:1.5rem}a{color:#0b6}li{margin:.4rem 0}.muted{color:#666;font-size:.9rem}</style>
</head><body>
<h1>The Complete Lojban Language &mdash; version $version</h1>
<p class="muted">Community modernization edition. Work in progress.</p>
<ul>
<li><a href="xhtml_section_chunks/">Read online (section by section)</a></li>
<li><a href="xhtml_no_chunks/">Read online (single page)</a></li>
<li><a href="diff_from_uncll/difference.html">Visual diff vs UnCLL&nbsp;1.2.16</a>
    &middot; <a href="diff_from_uncll/difference_prefixed.html">(with change markers)</a></li>
</ul>
<p class="muted"><a href="../">All versions</a></p>
</body></html>
HTML

echo "==> [$version] done: $dest"
