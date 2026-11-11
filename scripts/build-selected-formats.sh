#!/bin/bash
# Same targets and optional installers as pages:scripts/build-site.sh.
set -euo pipefail
formats=${1:?Usage: build-selected-formats.sh 'FORMAT ...' OUTPUT_DIRECTORY}
out=$(realpath -m "${2:?missing output directory}")
# Validate the whole list before installing tools or building anything.
for f in $formats; do
  case "$f" in html|epub|pdf|pdf-weasyprint|pdf-typst|pdf-context) ;; *) echo "Unknown format: $f" >&2; exit 1 ;; esac
done
mkdir -p "$out"
version=$(scripts/build-version.sh)
# Use the full source version (including a branch commit suffix) in the archive.
[[ "$version" =~ ^[A-Za-z0-9.+_-]+$ ]] || { echo 'Unsafe build version' >&2; exit 1; }
for f in $formats; do
  dest="$out/$f"
  mkdir -p "$dest"
  case "$f" in
    html)
      for target in xhtml_sections xhtml_nochunks; do ./cll_build -n -T "$target"; done
      for dir in xhtml_section_chunks xhtml_no_chunks; do
        test -s "build/$dir/index.html"
        cp -pr "build/$dir" "$dest/"
      done
      find "$dest" -name 'sed*' -type f -delete
      printf '%s\n' '<!doctype html><meta charset="utf-8"><title>CLL preview</title><h1>CLL preview</h1><p><a href="xhtml_section_chunks/">Read section by section</a></p><p><a href="xhtml_no_chunks/">Read on one page</a></p>' > "$dest/index.html"
      tar -C "$dest" -czf "$out/cll-$version-html.tar.gz" .
      mv "$out/cll-$version-html.tar.gz" "$dest/"
      continue ;;
    epub) target=epub; file=cll.epub ;;
    pdf) target=pdf; file=cll.pdf ;;
    pdf-weasyprint)
      ./scripts/install-weasyprint.sh
      target=pdf_weasyprint; file=cll-weasyprint.pdf ;;
    pdf-typst)
      ./scripts/install_typst.sh build/typst-tools
      export TYPST="$PWD/build/typst-tools/typst"
      target=pdf_typst; file=cll-typst.pdf ;;
    pdf-context) target=run_context_container.sh; file=cll-context.pdf ;;
  esac
  rm -f "build/$file" "build/$target.done"
  if [ "$f" = pdf-context ]; then ./run_context_container.sh; else ./cll_build -n -T "$target"; fi
  test -s "build/$file"
  cp -p "build/$file" "$dest/"
done
