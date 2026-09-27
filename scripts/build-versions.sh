#!/bin/bash
#
# Build or restore every published version of the site (issue #128).
#
#   scripts/build-versions.sh <versions.tsv> <baseline-nochunks-dir> <out-dir>
#
# The site output of a version, <out-dir>/<version>/, is kept as the
# archive cll-<version>-html.tar.gz. It unpacks to <version>/ and holds a
# BUILD-INFO file.
#
# The policy (maintainer decision, issue #128):
#
# - A published version serves the book files of its release, unchanged:
#   the HTML (xhtml_section_chunks, xhtml_no_chunks) from the release's
#   archive, and cll.pdf and cll.epub from the release's own assets. Only
#   its comparison pages (diff_from_*) and its landing page are made again,
#   with the current tooling (build-site.sh with DIFFS_ONLY=1).
# - A version without a published release is built from source. A draft
#   release gets the PDF, the ePub, and the archive of each run. So create
#   the release as a draft with its notes before adding the version to
#   pages/versions.tsv, then check the draft and publish it.
# - The deploy never changes a published release.
#
# The build cache is a draft release named site-build-cache. Drafts are
# not public, and the deploy replaces its assets freely: a failed upload
# there costs at most one rebuild. A cache entry is used when its
# BUILD-INFO matches this run in all of these fields:
#
#   commit             the version's content commit (its git ref today)
#   build_site_sha256  sha256 of scripts/build-site.sh
#   previous_commit    the content commit of the version before it
#                      (diff_from_previous)
#   baseline_commit    the UnCLL baseline commit (diff_from_uncll)
#   release_files      for a published version, the names and sha256
#                      digests of the release files it serves; empty
#                      otherwise
#
# Any error of the GitHub API fails the run.
#
# Environment:
#   GH_TOKEN            token for gh (contents: write)
#   GITHUB_REPOSITORY   owner/repo
#   FORCE_REBUILD       "true" ignores the cache: every version without a
#                       published release is built again, and every
#                       published version rebuilds its diffs. Published
#                       releases stay as they are.
#   BASELINE_COMMIT     the baseline commit, recorded in BUILD-INFO
set -euo pipefail

tsv="${1:?usage: build-versions.sh <versions.tsv> <baseline-dir> <out-dir>}"
baseline="${2:?missing baseline dir}"
outdir="$(mkdir -p "${3:?missing out-dir}" && cd "$3" && pwd)"
repo="${GITHUB_REPOSITORY:?}"
force="${FORCE_REBUILD:-false}"
baseline_commit="${BASELINE_COMMIT:?}"
bs_sha="$(sha256sum scripts/build-site.sh | cut -c1-64)"
cache_tag="site-build-cache"
dl="$(mktemp -d)"
trap 'rm -rf "$dl"' EXIT

# All releases, drafts included, read once. The tag endpoint does not
# return drafts, and an error here must stop the run rather than look
# like a missing release.
releases="$dl/releases.json"
gh api --paginate "repos/$repo/releases" --jq '.[]' | jq -s . > "$releases"

release_field() { # <tag> <jq-field>
  jq -r --arg t "$1" "map(select(.tag_name == \$t)) | if length > 0 then .[0].$2 else \"\" end" "$releases"
}
has_asset() { # <tag> <name>
  jq -e --arg t "$1" --arg n "$2" \
    'map(select(.tag_name == $t)) | .[0].assets // [] | any(.name == $n)' "$releases" >/dev/null
}

# The cache must stay a draft, or the uploads below would change a
# published release.
if [ -n "$(release_field "$cache_tag" id)" ] && [ "$(release_field "$cache_tag" draft)" != "true" ]; then
  echo "the release $cache_tag is published; make it a draft again before deploying" >&2
  exit 1
fi
if [ -z "$(release_field "$cache_tag" id)" ]; then
  gh api -X POST "repos/$repo/releases" -f tag_name="$cache_tag" \
    -f name="Site build cache (do not publish)" \
    -f body="The Pages deploy keeps the site output of each version here (scripts/build-versions.sh). Never publish this draft." \
    -F draft=true >/dev/null
  echo "==> created the draft release $cache_tag"
fi

info() { # <file> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

asset_digest() { # <tag> <name>
  jq -r --arg t "$1" --arg n "$2" \
    'map(select(.tag_name == $t)) | .[0].assets // [] | map(select(.name == $n)) | if length > 0 then (.[0].digest // "") else "" end' "$releases"
}

# Download one asset. A failure is an API error and ends the run. (The
# callers run inside if conditions, where set -e does not apply.)
fetch() { # <tag> <name> <dir>
  if ! gh release download "$1" -R "$repo" -p "$2" -D "$3" --clobber; then
    echo "download of $1/$2 failed" >&2
    exit 1
  fi
}

# Unpack an archive into <out-dir>. Returns 1, with nothing left behind,
# when the archive is damaged.
unpack() { # <file> <ver>
  rm -rf "$outdir/$2"
  if ! tar -tzf "$1" >/dev/null || ! tar -xzf "$1" -C "$outdir"; then
    echo "::warning::$(basename "$1") is damaged"
    rm -rf "$outdir/$2"
    return 1
  fi
}

# The fields that a cache entry must match. For a published version they
# include the digests of its release files, so the entry proves that its
# book files are the release's.
expect() { # <ver> <commit> <prev-commit> <released-digests>
  printf 'commit=%s\nbuild_site_sha256=%s\nprevious_commit=%s\nbaseline_commit=%s\nrelease_files=%s\n' \
    "$2" "$bs_sha" "$3" "$baseline_commit" "$4"
}
matches() { # <ver> <expected-fields>
  local bi="$outdir/$1/BUILD-INFO" key val
  [ -f "$bi" ] && [ -s "$outdir/$1/xhtml_no_chunks/index.html" ] || return 1
  while IFS='=' read -r key val; do
    [ "$(info "$bi" "$key")" = "$val" ] || return 1
  done <<< "$2"
}

prev=""; prevlabel=""; prev_commit=""
# oldest first, so each version's output can serve as the "previous
# release" side of the next version's diff_from_previous
while IFS=$'\t' read -r ver ref; do
  case "$ver" in ''|'#'*) continue ;; esac
  echo "::group::$ver from $ref"
  commit="$(git rev-parse "origin/$ref")"
  tag="v$ver"
  archive="cll-$ver-html.tar.gz"
  published=""
  released=""
  if [ -n "$(release_field "$tag" id)" ] && [ "$(release_field "$tag" draft)" != "true" ]; then
    if has_asset "$tag" "$archive"; then
      published=yes
      released="$archive:$(asset_digest "$tag" "$archive")"
      for f in cll.pdf cll.epub; do
        has_asset "$tag" "$f" && released="$released,$f:$(asset_digest "$tag" "$f")"
      done
    else
      echo "::warning::published release $tag has no $archive; building $ver from source, so the site can differ from the release"
    fi
  fi
  want="$(expect "$ver" "$commit" "$prev_commit" "$released")"

  from=""
  if [ "$force" != "true" ] && has_asset "$cache_tag" "$archive"; then
    fetch "$cache_tag" "$archive" "$dl"
    if unpack "$dl/$archive" "$ver" && matches "$ver" "$want"; then
      from=cache
      echo "==> [$ver] restored from $cache_tag/$archive"
    else
      rm -rf "$outdir/$ver"
    fi
  fi

  if [ -z "$from" ]; then
    git worktree add --detach "_v_$ver" "origin/$ref"
    if [ -n "$published" ]; then
      # The book files of a published version come from its release: the
      # HTML from the archive, the PDF and the ePub from the release's own
      # assets. Only the diffs and the landing page are made again.
      fetch "$tag" "$archive" "$dl"
      unpack "$dl/$archive" "$ver" || { echo "the release archive $tag/$archive is damaged" >&2; exit 1; }
      rm -rf "$outdir/$ver"/diff_from_* "$outdir/$ver/BUILD-INFO" "$outdir/$ver/cll.pdf" "$outdir/$ver/cll.epub"
      for f in cll.pdf cll.epub; do
        if has_asset "$tag" "$f"; then fetch "$tag" "$f" "$outdir/$ver"; fi
      done
      DIFFS_ONLY=1 bash scripts/build-site.sh "_v_$ver" "$ver" "$baseline" "$outdir" "$prev" "$prevlabel"
      echo "==> [$ver] served the book files of $tag, rebuilt its diffs"
    else
      bash scripts/build-site.sh "_v_$ver" "$ver" "$baseline" "$outdir" "$prev" "$prevlabel"
    fi
    { echo "version=$ver"; echo "ref=$ref"; echo "$want";
      echo "pages_commit=$(git rev-parse HEAD)"; echo "workflow_run=${GITHUB_RUN_ID:-local}"; } > "$outdir/$ver/BUILD-INFO"
    tar -C "$outdir" -czf "$dl/$archive" "$ver"
    gh release upload "$cache_tag" -R "$repo" --clobber "$dl/$archive"
    echo "==> [$ver] stored in $cache_tag"
  fi

  # A draft release gets the files of this run. A published one is fixed.
  if [ "$(release_field "$tag" draft)" = "true" ]; then
    [ -f "$dl/$archive" ] || tar -C "$outdir" -czf "$dl/$archive" "$ver"
    files=("$dl/$archive")
    for f in cll.pdf cll.epub; do
      [ -f "$outdir/$ver/$f" ] && files+=("$outdir/$ver/$f")
    done
    gh release upload "$tag" -R "$repo" --clobber "${files[@]}"
    echo "==> [$ver] attached the PDF, the ePub, and $archive to the draft $tag"
  elif [ -z "$(release_field "$tag" id)" ]; then
    echo "::warning::release $tag does not exist; create it as a draft to receive the files of $ver"
  fi
  rm -f "$dl/$archive"

  prev="$outdir/$ver/xhtml_no_chunks"
  prevlabel="v$ver"
  prev_commit="$commit"
  echo "::endgroup::"
done < <(tac "$tsv")
