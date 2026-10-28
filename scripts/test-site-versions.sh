#!/bin/bash
#
# Tests of the site scripts that need no build tools and no GitHub access:
# the formats and versions helpers (site-versions.sh), the version order,
# the previous-final-release choice, the release files of
# build-versions.sh (with stub gh, git and build-site.sh), and the landing
# page of gen-site-index.sh.
#
#   scripts/test-site-versions.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/site-versions.sh"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
fails=0
eq() { # <what> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else
    echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; fails=$((fails + 1)); fi
}
fails_with() { # <what> <command...>
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL $what: no error"; fails=$((fails + 1)); else echo "ok   $what"; fi
}

# --- formats
eq "default formats" "html,epub,pdf" "$(site_formats "")"
eq "canonical order and duplicates" "html,pdf,pdf-weasyprint" "$(site_formats "pdf-weasyprint,html,pdf,html")"
eq "spaces ignored" "epub,pdf-typst" "$(site_formats " pdf-typst , epub")"
eq "pdf-only" "pdf-weasyprint" "$(site_formats "pdf-weasyprint")"
fails_with "unknown format" site_formats "html,docx"
fails_with "only commas" site_formats ","
eq "release files" "cll-1.3.6-html.tar.gz cll.epub cll.pdf cll-weasyprint.pdf" \
  "$(site_release_files "html,epub,pdf,pdf-weasyprint" 1.3.6 | paste -sd' ')"
eq "download files" "cll-typst.pdf cll-context.pdf" \
  "$(site_download_files "html,pdf-typst,pdf-context" 1.3.6 | paste -sd' ')"

# --- versions
eq "prerelease detection" "yes no" \
  "$(site_is_prerelease 1.3.6-rc1 && echo yes || echo no) $(site_is_prerelease 1.3.6 && echo yes || echo no)"
eq "version syntax" "1.3.6 1.3.6-rc1 1.10" \
  "$(for v in 1.3.6 1.3.6-rc1 1.10 1.3.6rc1 v1.3 1.3.6-; do site_is_version "$v" && printf '%s ' "$v"; done | sed 's/ $//')"
eq "version order" "1.3.5 1.3.6-rc1 1.3.6-rc2 1.3.6-rc10 1.3.6 1.3.10-rc1 1.3.10" \
  "$(printf '%s\n' 1.3.10 1.3.6 1.3.6-rc10 1.3.5 1.3.6-rc2 1.3.10-rc1 1.3.6-rc1 | site_sort_versions | paste -sd' ')"

printf '# comment\n1.3.6\tedition/1.3.6\thtml,epub,pdf,pdf-weasyprint\n1.3.6-rc1\tedition/1.3.6-rc1\tpdf-weasyprint\n\n1.3.5\tedition/1.3.5\n' > "$t/v.tsv"
eq "rows oldest first, default formats filled in" \
  "1.3.5 edition/1.3.5 html,epub,pdf|1.3.6-rc1 edition/1.3.6-rc1 pdf-weasyprint|1.3.6 edition/1.3.6 html,epub,pdf,pdf-weasyprint" \
  "$(site_rows "$t/v.tsv" | tr '\t' ' ' | paste -sd'|')"
printf '1.3.5\tedition/1.3.5\n1.3.5\tedition/x\n' > "$t/dup.tsv"
fails_with "duplicate version" site_rows "$t/dup.tsv"
printf '1.3.5\tedition/1.3.5\thtml,odt\n' > "$t/bad.tsv"
fails_with "unknown format in a row" site_rows "$t/bad.tsv"
printf 'v1.3.5\tedition/1.3.5\n' > "$t/bad2.tsv"
fails_with "bad version in a row" site_rows "$t/bad2.tsv"
printf '1.3.5\n' > "$t/bad3.tsv"
fails_with "row without a ref" site_rows "$t/bad3.tsv"
eq "the real versions.tsv parses" "0" "$(site_rows "$here/../pages/versions.tsv" >/dev/null; echo $?)"

# --- build-versions.sh with stubs
# A copy of the pages tooling, where build-site.sh records its arguments
# and makes the files of its formats, and gh and git are stubs that work
# on a directory of fake releases.
w="$t/bv"; mkdir -p "$w/scripts" "$w/bin" "$w/rel" "$w/log"
cp "$here/build-versions.sh" "$here/site-versions.sh" "$here/docbook-diff.py" "$here/docbook-diff.xsl" "$w/scripts/"
cat > "$w/scripts/build-site.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
. scripts/site-versions.sh
src="$1" ver="$2" out="$4" prev="${5-}" label="${6-}"
formats="$(site_formats "${FORMATS:-}")"
echo "$ver formats=$formats prev=$prev label=$label diffs_only=${DIFFS_ONLY:-}" >> "$LOG/build-site"
d="$out/$ver"; mkdir -p "$d"
if [ -z "${DIFFS_ONLY:-}" ]; then
  if site_has_format "$formats" html; then mkdir -p "$d/xhtml_no_chunks"; echo built > "$d/xhtml_no_chunks/index.html"; fi
  for f in $(site_download_files "$formats" "$ver"); do echo "built $ver" > "$d/$f"; done
fi
echo index > "$d/index.html"
EOF
cat > "$w/bin/git" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "rev-parse HEAD") echo pagescommit ;;
  "rev-parse "*) echo "commit-of-${2#origin/}" ;;
  "worktree add") echo "git $*" >> "$LOG/git" ;;
  *) echo "unexpected git $*" >&2; exit 1 ;;
esac
EOF
cat > "$w/bin/gh" <<'EOF'
#!/bin/bash
# Fake releases: $REL/<tag>/ holds the assets, $REL/<tag>.json the fields.
set -euo pipefail
case "$1 $2" in
  "api --paginate")
    for j in "$REL"/*.json; do
      tag="$(basename "$j" .json)"
      assets="$(cd "$REL/$tag" 2>/dev/null && for a in *; do [ -e "$a" ] && printf '{"name":"%s","digest":"sha256:%s"},' "$a" "$(sha256sum "$a" | cut -c1-8)"; done || true)"
      jq -c --arg t "$tag" --argjson a "[${assets%,}]" '. + {tag_name: $t, assets: $a}' "$j"
    done ;;
  "api -X") echo "gh $*" >> "$LOG/gh"; t="$(printf '%s\n' "$@" | sed -n 's/^tag_name=//p')"; mkdir -p "$REL/$t"; echo '{"id":9,"draft":true,"prerelease":false}' > "$REL/$t.json" ;;
  "release download") tag="$3"; shift 3; pat="" dir=""
    while [ $# -gt 0 ]; do case "$1" in -p) pat="$2"; shift 2 ;; -D) dir="$2"; shift 2 ;; *) shift ;; esac; done
    cp "$REL/$tag/$pat" "$dir/" ;;
  "release upload") tag="$3"; shift 3
    while [ $# -gt 0 ]; do case "$1" in -R) shift 2 ;; --clobber) shift ;;
      *) cp "$1" "$REL/$tag/"; echo "upload $tag $(basename "$1")" >> "$LOG/gh"; shift ;; esac; done ;;
  "release delete-asset") rm -f "$REL/$3/$4"; echo "delete $3 $4" >> "$LOG/gh" ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$w/bin/"* "$w/scripts/build-site.sh"
rel() { # <tag> <draft> <prerelease> <assets...>
  local tag="$1"; mkdir -p "$w/rel/$tag"
  printf '{"id":1,"draft":%s,"prerelease":%s}\n' "$2" "$3" > "$w/rel/$tag.json"
  shift 3; local a; for a in "$@"; do echo "released $a" > "$w/rel/$tag/$a"; done
}
# 1.3.5: published, default formats. 1.3.6-rc1: published prerelease,
# PDF only. 1.3.6-rc2: draft prerelease, html and WeasyPrint. 1.3.6:
# draft final with a stale cll-typst.pdf. 1.3.7: no release.
rel v1.3.5 false false cll-1.3.5-html.tar.gz cll.pdf cll.epub
mkdir -p "$t/arch/1.3.5/xhtml_no_chunks"; echo released > "$t/arch/1.3.5/xhtml_no_chunks/index.html"
tar -C "$t/arch" -czf "$w/rel/v1.3.5/cll-1.3.5-html.tar.gz" 1.3.5
rel v1.3.6-rc1 false true cll-weasyprint.pdf
rel v1.3.6-rc2 true true
rel v1.3.6 true false cll-typst.pdf
printf '1.3.7\tedition/1.3.7\thtml\n1.3.6\tedition/1.3.6\thtml,epub,pdf,pdf-weasyprint\n1.3.6-rc2\tedition/1.3.6-rc2\thtml,pdf-weasyprint\n1.3.6-rc1\tedition/1.3.6-rc1\tpdf-weasyprint\n1.3.5\tedition/1.3.5\n' > "$w/versions.tsv"
run_bv() {
  ( cd "$w" && PATH="$w/bin:$PATH" REL="$w/rel" LOG="$w/log" GITHUB_REPOSITORY=o/r BASELINE_COMMIT=b \
      FORCE_REBUILD="${1:-false}" bash scripts/build-versions.sh versions.tsv origin/baseline "$w/out" ) > "$w/log/run" 2>&1
}
if run_bv; then echo "ok   build-versions.sh runs"; else echo "FAIL build-versions.sh"; cat "$w/log/run"; fails=$((fails + 1)); fi
eq "order, formats and previous final release" \
"1.3.5 formats=html,epub,pdf prev= label= diffs_only=1|1.3.6-rc1 formats=pdf-weasyprint prev=origin/edition/1.3.5 label=v1.3.5 diffs_only=1|1.3.6-rc2 formats=html,pdf-weasyprint prev=origin/edition/1.3.5 label=v1.3.5 diffs_only=|1.3.6 formats=html,epub,pdf,pdf-weasyprint prev=origin/edition/1.3.5 label=v1.3.5 diffs_only=|1.3.7 formats=html prev=origin/edition/1.3.6 label=v1.3.6 diffs_only=" \
  "$(paste -sd'|' "$w/log/build-site")"
eq "published 1.3.5 serves its released PDF" "released cll.pdf" "$(cat "$w/out/1.3.5/cll.pdf")"
eq "published 1.3.5 serves its released HTML" "released" "$(cat "$w/out/1.3.5/xhtml_no_chunks/index.html")"
eq "published PDF-only prerelease has only its PDF" "BUILD-INFO cll-weasyprint.pdf index.html" "$(ls "$w/out/1.3.6-rc1" | paste -sd' ')"
eq "draft rc2 gets exactly its files" "cll-1.3.6-rc2-html.tar.gz cll-weasyprint.pdf" "$(ls "$w/rel/v1.3.6-rc2" | paste -sd' ')"
eq "draft 1.3.6 gets its files and loses the stale one" "cll-1.3.6-html.tar.gz cll-weasyprint.pdf cll.epub cll.pdf" "$(ls "$w/rel/v1.3.6" | paste -sd' ')"
eq "published releases did not change" "" "$(grep -E ' v1\.3\.(5|6-rc1) ' "$w/log/gh" || true)"
eq "a release without a draft gets a warning" "1" "$(grep -c 'release v1.3.7 does not exist' "$w/log/run")"
eq "BUILD-INFO records the formats" "formats=pdf-weasyprint" "$(grep '^formats=' "$w/out/1.3.6-rc1/BUILD-INFO")"
# A second run restores every version from the cache.
: > "$w/log/build-site"
run_bv
eq "second run restores everything from the cache" "" "$(cat "$w/log/build-site")"
# A changed format list misses the cache for that version only.
sed -i 's/^1.3.7\tedition\/1.3.7\thtml$/1.3.7\tedition\/1.3.7\thtml,pdf-typst/' "$w/versions.tsv"
run_bv
eq "a changed format list rebuilds that version" "1.3.7 formats=html,pdf-typst prev=origin/edition/1.3.6 label=v1.3.6 diffs_only=" "$(cat "$w/log/build-site")"
# A published release that lacks a file of its formats stops the run.
rm "$w/rel/v1.3.6-rc1/cll-weasyprint.pdf"
if run_bv; then echo "FAIL a published release without its file must stop the run"; fails=$((fails + 1)); else
  eq "a published release without its file stops the run" "1" "$(grep -c 'published release v1.3.6-rc1 has no cll-weasyprint.pdf' "$w/log/run")"; fi
rel v1.3.6-rc1 false false cll-weasyprint.pdf
run_bv
eq "a prerelease release not marked as prerelease gets a warning" "1" "$(grep -c 'release v1.3.6-rc1 is for a prerelease version but is not marked' "$w/log/run")"

# --- gen-site-index.sh
s="$t/site"; mkdir -p "$s"/{1.3.5,1.3.6-rc1,1.3.6-rc2,1.3.6,notaversion}
bash "$here/gen-site-index.sh" "$s" >/dev/null
eq "landing page order and marks" \
  '1.3.6</a> <span class="muted">(latest)</span>|1.3.6-rc2</a> <span class="muted">(release candidate)</span>|1.3.6-rc1</a> <span class="muted">(release candidate)</span>|1.3.5</a>' \
  "$(grep -o '[0-9.rc-]*</a>.*</li>' "$s/index.html" | sed 's|</li>$||' | paste -sd'|')"
eq "latest is the final release" 'url=../1.3.6/' "$(grep -o 'url=[^"]*' "$s/latest/index.html")"
rm -rf "$s/1.3.6"
bash "$here/gen-site-index.sh" "$s" >/dev/null
eq "latest skips prereleases" 'url=../1.3.5/' "$(grep -o 'url=[^"]*' "$s/latest/index.html")"
rm -rf "$s/1.3.5"
bash "$here/gen-site-index.sh" "$s" >/dev/null
eq "latest is a prerelease when no final exists" 'url=../1.3.6-rc2/' "$(grep -o 'url=[^"]*' "$s/latest/index.html")"

if [ "$fails" -gt 0 ]; then echo "test-site-versions: $fails failures"; exit 1; fi
echo "test-site-versions: all tests pass"
