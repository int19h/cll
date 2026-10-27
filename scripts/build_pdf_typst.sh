#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/build_pdf_typst.sh BUILD_DIRECTORY' >&2
  exit 2
fi
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
builddir=$(realpath "$1")
typst_bin=${TYPST:-typst}
if ! command -v "$typst_bin" >/dev/null; then
  echo 'Typst is missing. Use run_typst_container.sh or install Typst 0.15.1 and set TYPST to its executable.' >&2
  exit 1
fi
if [[ $("$typst_bin" --version) != 'typst 0.15.1 '* ]]; then
  echo 'This layout requires Typst 0.15.1. Set TYPST to that executable.' >&2
  exit 1
fi
out="$builddir/typst"
mkdir -p "$out/assets/fonts" "$out/assets/media"
cp typst/book.typ "$out/book.typ"
cp -a assets/fonts/. "$out/assets/fonts/"
# The PDF contains chapter illustrations, not the audio recordings.
find assets/media -maxdepth 1 -type f -exec cp -t "$out/assets/media" -- {} +
convert_args=()
if [[ ${TYPST_ALLOW_MISSING_REFS:-0} == 1 ]]; then convert_args+=(--allow-missing-references); fi
ruby scripts/docbook_to_typst.rb "${convert_args[@]}" "$builddir/cll_processed_xhtml.xml" "$out/cll.typ" 2>"$out/conversion.log" || {
  cat "$out/conversion.log" >&2
  exit 1
}
"$typst_bin" --version > "$out/version.txt"
"$typst_bin" compile --root "$out" --font-path "$out/assets/fonts" --ignore-system-fonts \
  "$out/cll.typ" "$out/cll.pdf" 2>"$out/compile.log" || {
    cat "$out/compile.log" >&2
    exit 1
  }
cat "$out/compile.log" >&2
# Keep a previous successful PDF until compilation finishes.
cp "$out/cll.pdf" "$builddir/cll-typst.pdf.tmp"
mv "$builddir/cll-typst.pdf.tmp" "$builddir/cll-typst.pdf"
echo "Typst PDF: $builddir/cll-typst.pdf"
