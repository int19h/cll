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

eq "dotted prerelease identifiers" "1.3.6-alpha.1 1.3.6-rc.2 1.3.6-rc.10 1.3.6" \
  "$(printf '%s\n' 1.3.6 1.3.6-rc.10 1.3.6-alpha.1 1.3.6-rc.2 | site_sort_versions | paste -sd' ')"
for candidate in 1.3.6-alpha.1 1.3.6-rc.2 1.3.6-1; do
  eq "prerelease syntax $candidate" yes "$(site_is_version "$candidate" && echo yes || echo no)"
done

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
  if site_has_format "$formats" html; then mkdir -p "$d/xhtml_no_chunks" "$d/xhtml_section_chunks"; echo built > "$d/xhtml_no_chunks/index.html"; echo built > "$d/xhtml_section_chunks/index.html"; fi
  for f in $(site_download_files "$formats" "$ver"); do echo "built $ver" > "$d/$f"; done
fi
echo index > "$d/index.html"
# Simulate another actor publishing a release while the build runs.
if [ -n "${PUBLISH_DURING_BUILD:-}" ]; then
  jq '.draft = false' "$REL/$PUBLISH_DURING_BUILD.json" > "$REL/next.json"
  mv "$REL/next.json" "$REL/$PUBLISH_DURING_BUILD.json"
fi
if [ -n "${ADD_DURING_BUILD:-}" ]; then
  echo added > "$REL/$ADD_DURING_BUILD/late-asset.txt"
fi
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
  "api -X") echo "create site-build-cache" >> "$LOG/events"; echo "gh $*" >> "$LOG/gh"; t="$(printf '%s\n' "$@" | sed -n 's/^tag_name=//p')"; mkdir -p "$REL/$t"; echo '{"id":9,"draft":true,"prerelease":false}' > "$REL/$t.json" ;;
  "release view") tag="$3"
    echo "view $tag" >> "$LOG/events"
    if [ "${FAIL_VIEW_TAG:-}" = "$tag" ]; then exit 7; fi
    assets="$(cd "$REL/$tag" && for a in *; do [ ! -e "$a" ] || printf '{"name":"%s"},' "$a"; done)"
    jq -c --argjson a "[${assets%,}]" '{isDraft:.draft,assets:$a}' "$REL/$tag.json" ;;
  "release download") tag="$3"; shift 3; pat="" dir=""
    while [ $# -gt 0 ]; do case "$1" in -p) pat="$2"; shift 2 ;; -D) dir="$2"; shift 2 ;; *) shift ;; esac; done
    cp "$REL/$tag/$pat" "$dir/"
    if [ "$tag" = site-build-cache ] && [ -n "${PUBLISH_DURING_DOWNLOAD:-}" ]; then
      jq '.draft = false' "$REL/$PUBLISH_DURING_DOWNLOAD.json" > "$REL/next.json"
      mv "$REL/next.json" "$REL/$PUBLISH_DURING_DOWNLOAD.json"
    fi ;;
  "release upload") tag="$3"; echo "upload $tag" >> "$LOG/events"; shift 3
    while [ $# -gt 0 ]; do case "$1" in -R) shift 2 ;; --clobber) shift ;;
      *) cp "$1" "$REL/$tag/"; echo "upload $tag $(basename "$1")" >> "$LOG/gh"; shift ;; esac; done ;;
  "release delete-asset") echo "delete $3" >> "$LOG/events"; rm -f "$REL/$3/$4"; echo "delete $3 $4" >> "$LOG/gh" ;;
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
mkdir -p "$t/arch/1.3.5/xhtml_section_chunks"; echo released > "$t/arch/1.3.5/xhtml_section_chunks/index.html"
tar -C "$t/arch" -czf "$w/rel/v1.3.5/cll-1.3.5-html.tar.gz" 1.3.5
rel v1.3.6-rc1 false true cll-weasyprint.pdf
rel v1.3.6-rc2 true true
rel v1.3.6 true false cll-typst.pdf notes.txt
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
  eq "a published release without its file stops the run" "1" "$(grep -c 'published release v1.3.6-rc1 has a different asset set' "$w/log/run")"; fi
rel v1.3.6-rc1 false false cll-weasyprint.pdf
run_bv
eq "a prerelease release not marked as prerelease gets a warning" "1" "$(grep -c 'release v1.3.6-rc1 is for a prerelease version but is not marked' "$w/log/run")"

# Each release's fresh read and mutations form one uninterrupted group.
# The cache gets a separate live read after that version's asset changes.
for target in v1.3.6-rc2 v1.3.6; do
  eq "fresh view directly precedes upload for $target" "view $target" \
    "$(awk -v target="$target" '$0 == "upload " target {print previous; exit} {previous=$0}' "$w/log/events")"
done

# Isolated race fixtures use the real orchestrator and fake API state.
race_case() { # <case> <publication target> <failed-read target> <late-asset target>
  local name="$1" publish="$2" failed_read="$3" late="$4"
  local original="$w" w="$t/race-$1"
  mkdir -p "$w/scripts" "$w/bin" "$w/rel" "$w/log"
  cp "$original/scripts/"* "$w/scripts/"
  cp "$original/bin/"* "$w/bin/"
  rel v1.4 true false cll-typst.pdf
  rel site-build-cache true false
  printf '1.4\tedition/1.4\tpdf-weasyprint\n' > "$w/versions.tsv"
  if PUBLISH_DURING_BUILD="$publish" FAIL_VIEW_TAG="$failed_read" ADD_DURING_BUILD="$late" run_bv true; then
    eq "$name succeeds" yes "$([ -z "$publish$failed_read" ] && echo yes || echo no)"
  else
    eq "$name refuses unsafe writes" yes "$([ -n "$publish$failed_read" ] && echo yes || echo no)"
  fi
  if [ -n "$publish$failed_read" ]; then
    local blocked="${publish:-$failed_read}"
    eq "$name leaves $blocked assets unchanged" "" "$(grep -E "^(upload|delete) $blocked( |$)" "$w/log/gh" 2>/dev/null || true)"
    eq "$name reports the refusal" 1 "$(grep -c 'refusing asset changes' "$w/log/run")"
    if [ "$blocked" = v1.4 ]; then
      eq "$name writes no cache before refusal" "" "$(cat "$w/log/gh" 2>/dev/null || true)"
    fi
  else
    eq "late assets are removed using live state" "cll-weasyprint.pdf" "$(ls "$w/rel/v1.4" | paste -sd' ')"
    eq "all version writes stay together after one fresh read" \
      $'view v1.4\nupload v1.4\ndelete v1.4\ndelete v1.4\nview site-build-cache\nupload site-build-cache' \
      "$(cat "$w/log/events")"
  fi
}
race_case "publish version during build" v1.4 '' ''
race_case "publish cache during build" site-build-cache '' ''
race_case "version read failure" '' v1.4 ''
race_case "cache read failure" '' site-build-cache ''
race_case "fresh asset cleanup" '' '' v1.4

# A cache hit still needs a new decision before uploading to a draft.
cached_race() {
  local w="$t/race-fresh asset cleanup"
  : > "$w/log/gh"; : > "$w/log/build-site"
  if PUBLISH_DURING_DOWNLOAD=v1.4 run_bv; then
    echo "FAIL publication during cache restore must refuse writes"; fails=$((fails + 1))
  else
    echo "ok   publication during cache restore refuses writes"
  fi
  eq "cached publication race runs no build" "" "$(cat "$w/log/build-site")"
  eq "cached publication race changes no release" "" "$(cat "$w/log/gh")"
}
cached_race

# --- gen-site-index.sh
s="$t/site"; mkdir -p "$s"/{1.3.5,1.3.6-rc1,1.3.6-rc2,1.3.6,notaversion}
bash "$here/gen-site-index.sh" "$s" >/dev/null
eq "landing page lists only final releases" \
  '1.3.6</a> <span class="muted">(latest)</span>|1.3.5</a>' \
  "$(grep -o '[0-9][0-9.rc-]*</a>.*'  "$s/index.html" | sed 's|<div>$||' | paste -sd'|')"
eq "latest is the final release" 'url=../1.3.6/' "$(grep -o 'url=[^"]*' "$s/latest/index.html")"
rm -rf "$s/1.3.6"
bash "$here/gen-site-index.sh" "$s" >/dev/null
eq "latest skips prereleases" 'url=../1.3.5/' "$(grep -o 'url=[^"]*' "$s/latest/index.html")"
rm -rf "$s/1.3.5"
bash "$here/gen-site-index.sh" "$s" >/dev/null
eq "no latest redirect when no final exists" no "$([ -e "$s/latest" ] && echo yes || echo no)"
eq "only prereleases gives an empty final index" 1 "$(grep -c 'No final releases are available' "$s/index.html")"
fails_with "explicit latest rejects RC without a final" bash "$here/gen-site-index.sh" "$s" 1.3.6-rc2

# Empty fields must not shift later columns. The final row can omit LF.
printf '1.4\tedition/1.4\t\n1.5\tedition/1.5' > "$t/empty.tsv"
eq "empty and missing format columns" $'1.4\tedition/1.4\thtml,epub,pdf\n1.5\tedition/1.5\thtml,epub,pdf' "$(site_rows "$t/empty.tsv")"
printf '1.4\t\thtml\n' > "$t/empty-ref.tsv"
fails_with "empty ref does not consume formats" site_rows "$t/empty-ref.tsv"
printf '1.4\tedition/1.4\t\thtml\n' > "$t/extra.tsv"
fails_with "empty third field still rejects fourth column" site_rows "$t/extra.tsv"
eq "default toolchains omit optional engines" "base java prince" "$(site_toolchains "$(site_formats '')" | paste -sd' ')"
eq "one engine selects only its toolchain" weasyprint "$(site_toolchains pdf-weasyprint)"

# Both missing and extra assets on published releases fail before writes.
echo extra > "$w/rel/v1.3.6-rc1/extra.txt"
: > "$w/log/gh"
fails_with "extra published asset fails" run_bv
eq "published mismatch writes nothing, including cache" "" "$(cat "$w/log/gh")"
rm "$w/rel/v1.3.6-rc1/extra.txt"

mkdir -p "$s/1.3.5"
fails_with "explicit latest cannot select RC when final exists" bash "$here/gen-site-index.sh" "$s" 1.3.6-rc2
fails_with "explicit latest must exist" bash "$here/gen-site-index.sh" "$s" 9.9
mkdir -p "$s/1.3.5/xhtml_no_chunks"
echo html > "$s/1.3.5/xhtml_no_chunks/index.html"
echo pdf > "$s/1.3.6-rc1/cll-weasyprint.pdf"
echo pdf > "$s/1.3.5/cll-weasyprint.pdf"
bash "$here/gen-site-index.sh" "$s" >/dev/null
eq "top page links available HTML" 1 "$(grep -c 'href="1.3.5/xhtml_no_chunks/"' "$s/index.html")"
eq "top page links available WeasyPrint" 1 "$(grep -c 'href="1.3.5/cll-weasyprint.pdf"' "$s/index.html")"
eq "top page omits prerelease links" 0 "$(grep -c 'href="1.3.6-rc' "$s/index.html" || true)"
eq "top page omits unavailable Prince" 0 "$(grep -c 'href="[^"]*/cll.pdf"' "$s/index.html" || true)"

# Run the real build-site script with stub renderers. This tests dispatch,
# removal of old output, native installers, fresh Prince markers, and links.
b="$t/bs"; mkdir -p "$b/src/scripts" "$b/src/xml" "$b/bin" "$b/tools"
cp "$here/build-site.sh" "$here/site-versions.sh" "$b/tools/"
cat > "$b/bin/git" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$b/bin/prince" <<'EOF'
#!/bin/bash
exit 0
EOF
cp "$b/bin/prince" "$b/bin/java"
cat > "$b/src/cll_build" <<'EOF'
#!/bin/bash
set -euo pipefail
[ "$1 $2" = '-n -T' ]
[ "${CLL_BUILD_VERSION:-}" = source-version ]
echo "$3" >> "$BS_LOG"
mkdir -p build
case "$3" in
  xhtml_sections) mkdir -p build/xhtml_section_chunks; echo html > build/xhtml_section_chunks/index.html ;;
  xhtml_nochunks) mkdir -p build/xhtml_no_chunks; echo html > build/xhtml_no_chunks/index.html ;;
  pdf) [ ! -e build/pdf.done ]; echo prince > build/cll.pdf; touch build/pdf.done ;;
  epub) echo epub > build/cll.epub ;;
  pdf_weasyprint) echo weasy > build/cll-weasyprint.pdf ;;
  pdf_typst) echo typst > build/cll-typst.pdf ;;
  *) exit 1 ;;
esac
EOF
cat > "$b/src/scripts/install-weasyprint.sh" <<'EOF'
#!/bin/bash
echo install-weasyprint >> "$BS_LOG"
EOF
cat > "$b/src/scripts/install_typst.sh" <<'EOF'
#!/bin/bash
echo install-typst >> "$BS_LOG"
EOF
cat > "$b/src/run_context_container.sh" <<'EOF'
#!/bin/bash
echo context >> "$BS_LOG"
echo context > build/cll-context.pdf
EOF
cat > "$b/src/scripts/build-version.sh" <<'EOF'
#!/bin/bash
echo source-version
EOF
# The diff helper copies HTML for this orchestration test.
cat > "$b/tools/docbook-diff.py" <<'EOF'
import pathlib, sys
if sys.argv[1] == 'finish':
    out = pathlib.Path(sys.argv[3]); out.mkdir(parents=True)
    (out / 'difference.html').write_text('diff')
    (out / 'difference_prefixed.html').write_text('diff')
EOF
echo stylesheet > "$b/tools/docbook-diff.xsl"
echo 'xhtml_nochunks: xsl_file = original' > "$b/src/scripts/Makefile"
chmod +x "$b/bin/"* "$b/src/cll_build" "$b/src/scripts/"*.sh "$b/src/run_context_container.sh"
bs() {
  PATH="$b/bin:$PATH" BS_LOG="$b/log" FORMATS="$1" bash "$b/tools/build-site.sh" "$b/src" 1.4-rc1 '' "$b/out" > "$b/run.log" 2>&1
}
for selection in html epub pdf pdf-weasyprint pdf-typst pdf-context "$SITE_ALL_FORMATS" ''; do
  : > "$b/log"
  if bs "$selection"; then echo "ok   build-site dispatch '$selection'"; else
    echo "FAIL build-site dispatch '$selection'"; cat "$b/run.log"; fails=$((fails + 1))
  fi
  canonical="$(site_formats "$selection")"
  for f in "${SITE_FORMATS[@]}"; do
    if [ "$f" = html ]; then file=xhtml_no_chunks/index.html; else file="$(site_format_file "$f" 1.4-rc1)"; fi
    if site_has_format "$canonical" "$f"; then
      eq "requested $f exists for '$selection'" yes "$([ -s "$b/out/1.4-rc1/$file" ] && echo yes || echo no)"
    else
      eq "unrequested $f absent for '$selection'" no "$([ -e "$b/out/1.4-rc1/$file" ] && echo yes || echo no)"
    fi
  done
  eq "RC label for '$selection'" 1 "$(grep -c 'version 1.4-rc1 (release candidate)' "$b/out/1.4-rc1/index.html")"
done
bs pdf-weasyprint
eq "PDF-only runs no HTML targets or other installers" $'install-weasyprint\npdf_weasyprint' "$(tail -n2 "$b/log")"
eq "PDF-only landing omits HTML links" 0 "$(grep -c 'href="xhtml_' "$b/out/1.4-rc1/index.html" || true)"
eq "PDF-only landing links its PDF" 1 "$(grep -c 'href="cll-weasyprint.pdf"' "$b/out/1.4-rc1/index.html")"

# A future non-PDF format needs one registry entry, with no new dispatch,
# asset-name, or landing-page cases.
python3 - "$b/tools/site-versions.sh" "$b/src/cll_build" <<'EOF'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text().replace('SITE_FORMATS=()', "SITE_FORMAT_REGISTRY+=('text|cll.txt|Download text|text|base')\nSITE_FORMATS=()")
p.write_text(s)
p = Path(sys.argv[2])
s = p.read_text().replace('  *) exit 1 ;;', '  text) echo text > build/cll.txt ;;\n  *) exit 1 ;;')
p.write_text(s)
EOF
: > "$b/log"
bs text
eq "new non-PDF format uses generic dispatch" text "$(cat "$b/log")"
eq "new non-PDF format gets a landing link" 1 "$(grep -c 'href="cll.txt">Download text' "$b/out/1.4-rc1/index.html")"
# A PDF-only version needs no comparison commits.
echo -e '#!/bin/bash\nexit 1' > "$b/bin/git"
: > "$b/log"
bs pdf-weasyprint
eq "PDF-only needs no git comparison commits" $'install-weasyprint\npdf_weasyprint' "$(cat "$b/log")"
fails_with "HTML requires its comparison commit" bs html

if [ "$fails" -gt 0 ]; then echo "test-site-versions: $fails failures"; exit 1; fi
echo "test-site-versions: all tests pass"
