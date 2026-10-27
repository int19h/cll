#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo 'Usage: scripts/build_context.sh BUILD_DIRECTORY' >&2
  exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
build=$(realpath "$1")
renderer=${CONTEXT_BIN:-context}
command -v "$renderer" >/dev/null || {
  echo 'ConTeXt is missing. Install ConTeXt LMTX or set CONTEXT_BIN to its context executable.' >&2
  exit 1
}

mkdir -p "$build/context"
# Each checkout has its own working directory and font/format cache.
export TEXMFCACHE="$build/context/cache"
export OSFONTDIR="$build/context/assets/fonts//"
cd "$repo"
ruby scripts/docbook_to_context.rb "$build/cll_processed_xhtml.xml" \
  "$build/context/cll-context.tex" "$build/context/conversion.json"
python3 scripts/context_assets.py "$repo" "$build/context"
cp assets/context/cll-layout.tex "$build/context/cll-layout.tex"
cd "$build/context"
mtxrun=${MTXRUN_BIN:-$(dirname "$(command -v "$renderer")")/mtxrun}
if ! "$mtxrun" --generate > cache.log 2>&1 ||
   ! "$mtxrun" --script fonts --reload >> cache.log 2>&1; then
  tail -40 cache.log >&2
  exit 1
fi
"$renderer" --version > engine-version.txt
# A launcher can exit successfully without starting the engine. Reject stale output.
rm -f cll-context.pdf
"$renderer" --batchmode --nonstopmode --maxnofruns=5 cll-context.tex > renderer.log 2>&1 || {
  tail -80 renderer.log >&2
  exit 1
}
test -s cll-context.pdf
# Publish only a successful output. Prince's cll.pdf is never touched.
cp cll-context.pdf "$build/cll-context.pdf.tmp"
mv "$build/cll-context.pdf.tmp" "$build/cll-context.pdf"
