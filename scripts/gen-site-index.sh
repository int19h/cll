#!/bin/bash
#
# Generate the top-level site landing page and a /latest/ redirect from
# the version directories present under a site root.
#
#   scripts/gen-site-index.sh <site-dir> [latest-version]
#
# Version dirs are any immediate subdirectories matching a version number
# (e.g. 1.3, 1.4, 1.10), with an optional prerelease suffix (e.g.
# 1.3.6-rc1; see scripts/site-versions.sh). A prerelease is listed below
# its final release and marked as such. If latest-version is omitted, the
# highest final version present is used, or the highest prerelease when
# there is no final version.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/site-versions.sh"

site="${1:?usage: gen-site-index.sh <site-dir> [latest-version]}"
latest="${2-}"

# collect version dirs, sorted newest first
mapfile -t versions < <(
  find "$site" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' \
    | grep -E "$SITE_VERSION_RE" | site_sort_versions | tac)

[ "${#versions[@]}" -gt 0 ] || { echo "no version dirs under $site" >&2; exit 1; }
newest_final=""
for v in "${versions[@]}"; do
  site_is_prerelease "$v" || { newest_final="$v"; break; }
done
if [ -z "$latest" ]; then latest="${newest_final:-${versions[0]}}"; fi
if ! site_is_version "$latest" || [ ! -d "$site/$latest" ]; then
  echo "unknown latest version: $latest" >&2; exit 1
fi
if [ -n "$newest_final" ] && site_is_prerelease "$latest"; then
  echo "latest must be a final release when one exists" >&2; exit 1
fi

# /latest/ meta-refresh redirect (GitHub Pages has no symlinks)
mkdir -p "$site/latest"
cat > "$site/latest/index.html" <<HTML
<!doctype html><meta charset="utf-8">
<meta http-equiv="refresh" content="0; url=../$latest/">
<link rel="canonical" href="../$latest/">
<p>Redirecting to <a href="../$latest/">version $latest</a>&hellip;</p>
HTML

# top-level landing page
{
  cat <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>The Contemporary Lojban Language</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:44rem;margin:3rem auto;padding:0 1rem}
h1{font-size:1.6rem}a{color:#0b6}li{margin:.5rem 0}.muted{color:#666;font-size:.9rem}
.latest{font-weight:600}</style>
</head><body>
<h1>The Contemporary Lojban Language</h1>
<p>A community edition of <i>The Complete Lojban Language</i>, updated to describe
current Lojban, with every change labelled by its level of authority. An unofficial
publication &mdash; not by the LLG.</p>
<h2>Versions</h2>
<ul>
HTML
  for v in "${versions[@]}"; do
    tag=""
    site_is_prerelease "$v" && tag=" <span class=\"muted\">($(site_prerelease_label "$v"))</span>"
    [ "$v" = "$latest" ] && tag="$tag <span class=\"muted\">(latest)</span>"
    printf '<li class="%s"><a href="%s/">%s</a>%s' \
      "$([ "$v" = "$latest" ] && echo latest)" "$v" "$v" "$tag"
    echo '<div>'
    site_format_links "$site/$v" "$v" "$v/"
    echo '</div></li>'
  done
  cat <<HTML
</ul>
<p class="muted">Each version offers the book in some of these formats: online
(section-by-section and single-page) with visual diffs against the official
CLL&nbsp;1.1, against UnCLL&nbsp;1.2.16, and against the previous release, and
as a downloadable PDF or ePub. The page of each version lists its formats.
Source: <a href="https://github.com/int19h/cll">github.com/int19h/cll</a>.</p>
</body></html>
HTML
} > "$site/index.html"

echo "wrote $site/index.html and $site/latest/ (latest=$latest, versions: ${versions[*]})"
