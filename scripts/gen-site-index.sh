#!/bin/bash
#
# Generate the top-level site landing page and a /latest/ redirect from
# the version directories present under a site root.
#
#   scripts/gen-site-index.sh <site-dir> [latest-version]
#
# Version dirs are any immediate subdirectories matching a version number
# (e.g. 1.3, 1.4, 1.10). If latest-version is omitted, the highest
# version number present is used.
set -euo pipefail

site="${1:?usage: gen-site-index.sh <site-dir> [latest-version]}"
latest="${2-}"

# collect version dirs (numeric, dotted), sorted newest first
mapfile -t versions < <(
  find "$site" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' \
    | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -rV)

[ "${#versions[@]}" -gt 0 ] || { echo "no version dirs under $site" >&2; exit 1; }
[ -n "$latest" ] || latest="${versions[0]}"

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
    tag=""; [ "$v" = "$latest" ] && tag=' <span class="muted">(latest)</span>'
    printf '<li class="%s"><a href="%s/">%s</a>%s</li>\n' \
      "$([ "$v" = "$latest" ] && echo latest)" "$v" "$v" "$tag"
  done
  cat <<HTML
</ul>
<p class="muted">Each version offers the book online (section-by-section and
single-page) and a visual diff against UnCLL&nbsp;1.2.16.
Source: <a href="https://github.com/int19h/cll">github.com/int19h/cll</a>.</p>
</body></html>
HTML
} > "$site/index.html"

echo "wrote $site/index.html and $site/latest/ (latest=$latest, versions: ${versions[*]})"
