#!/bin/bash
# Format targets match pages:scripts/build-site.sh.
# The ePub target installs the pinned EPUBCheck before the book build.
set -euo pipefail
formats=${1:?Usage: build-selected-formats.sh 'FORMAT ...' OUTPUT_DIRECTORY}
out=$(realpath -m "${2:?missing output directory}")
# Validate the whole list before installing tools or building anything.
for f in $formats; do
  case "$f" in html|epub|pdf|pdf-weasyprint|pdf-typst|pdf-context) ;; *) echo "Unknown format: $f" >&2; exit 1 ;; esac
done
mkdir -p "$out"
version=$(scripts/build-version.sh)
# Validate metadata before inserting it into the landing page.
[[ "$version" =~ ^[A-Za-z0-9.+_-]+$ ]] || { echo 'Unsafe build version' >&2; exit 1; }
commit=$(git rev-parse HEAD)
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid source commit' >&2; exit 1; }
need_output() {
  [ -s "$1" ] || { echo "Missing or empty output: $1" >&2; exit 1; }
}
for f in $formats; do
  dest="$out/$f"
  mkdir -p "$dest"
  case "$f" in
    html)
      for target in xhtml_sections xhtml_nochunks; do ./cll_build -n -T "$target"; done
      for dir in xhtml_section_chunks xhtml_no_chunks; do
        need_output "build/$dir/index.html"
        cp -pr "build/$dir" "$dest/"
      done
      find "$dest" -name 'sed*' -type f -delete
      cat > "$dest/index.html" <<HTML
<!doctype html><meta charset="utf-8"><title>CLL preview</title>
<h1>CLL preview</h1><p>Version: $version<br>Commit: $commit</p>
<p><a href="xhtml_section_chunks/index.html">Read section by section</a></p>
<p><a href="xhtml_no_chunks/index.html">Read on one page</a></p>
HTML
      continue ;;
    epub)
      ./scripts/install-epubcheck.sh build/tools/epubcheck
      export EPUBCHECK_JAR="$PWD/build/tools/epubcheck/epubcheck.jar"
      target=epub
      file=cll.epub
      ;;
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
  need_output "build/$file"
  cp -p "build/$file" "$dest/"
done
