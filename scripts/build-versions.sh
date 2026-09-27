#!/bin/bash
#
# Build or restore every published version of the site (issue #128).
#
#   scripts/build-versions.sh <versions.tsv> <baseline-nochunks-dir> <out-dir>
#
# The site output of a version, <out-dir>/<version>/, is kept as the
# archive cll-<version>-html.tar.gz. It unpacks to <version>/ and holds a
# BUILD-INFO file. A version is restored from an archive instead of being
# rebuilt when BUILD-INFO matches this run in all of these fields:
#
#   commit             the version's content commit (its git ref today)
#   build_site_sha256  sha256 of scripts/build-site.sh
#   previous_commit    the content commit of the version before it
#                      (diff_from_previous)
#   baseline_commit    the UnCLL baseline commit (diff_from_uncll)
#
# Where the archives live:
#
# - The build cache is a draft release named site-build-cache. Drafts are
#   not public, and the deploy replaces its assets freely: a failed upload
#   there costs at most one rebuild.
# - A draft release v<version> gets the PDF, the ePub, and the archive of
#   its version on every deploy. Create the release as a draft with its
#   notes before adding the version to pages/versions.tsv, then check the
#   draft and publish it.
# - A published release is never changed by the deploy. Its archive, if
#   it has one, is only a source to restore from when the cache has no
#   matching entry.
#
# Any error of the GitHub API fails the run.
#
# Environment:
#   GH_TOKEN            token for gh (contents: write)
#   GITHUB_REPOSITORY   owner/repo
#   FORCE_REBUILD       "true" ignores every archive and rebuilds every
#                       version. It refreshes the cache and the draft
#                       releases. Published releases stay as they are.
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

# Unpack <tag>/<archive> into <out-dir> and keep it when it matches this
# run. Returns 1, with nothing left behind, when it does not.
try_restore() { # <tag> <archive> <ver> <commit> <prev-commit>
  local tag="$1" archive="$2" ver="$3" bi
  has_asset "$tag" "$archive" || return 1
  rm -rf "$dl/$archive" "$outdir/$ver"
  gh release download "$tag" -R "$repo" -p "$archive" -D "$dl"
  tar -xzf "$dl/$archive" -C "$outdir"
  bi="$outdir/$ver/BUILD-INFO"
  if [ -f "$bi" ] \
     && [ "$(info "$bi" commit)" = "$4" ] \
     && [ "$(info "$bi" build_site_sha256)" = "$bs_sha" ] \
     && [ "$(info "$bi" previous_commit)" = "$5" ] \
     && [ "$(info "$bi" baseline_commit)" = "$baseline_commit" ] \
     && [ -s "$outdir/$ver/xhtml_no_chunks/index.html" ]; then
    return 0
  fi
  rm -rf "$outdir/$ver"
  return 1
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
  from=""
  if [ "$force" != "true" ]; then
    if try_restore "$cache_tag" "$archive" "$ver" "$commit" "$prev_commit"; then
      from="$cache_tag"
    elif [ -n "$(release_field "$tag" id)" ] \
         && try_restore "$tag" "$archive" "$ver" "$commit" "$prev_commit"; then
      from="$tag"
    fi
  fi

  if [ -n "$from" ]; then
    echo "==> [$ver] restored from $from/$archive"
  else
    git worktree add --detach "_v_$ver" "origin/$ref"
    bash scripts/build-site.sh "_v_$ver" "$ver" "$baseline" "$outdir" "$prev" "$prevlabel"
    printf 'version=%s\nref=%s\ncommit=%s\nbuild_site_sha256=%s\nprevious_commit=%s\nbaseline_commit=%s\npages_commit=%s\nworkflow_run=%s\n' \
      "$ver" "$ref" "$commit" "$bs_sha" "$prev_commit" "$baseline_commit" \
      "$(git rev-parse HEAD)" "${GITHUB_RUN_ID:-local}" > "$outdir/$ver/BUILD-INFO"
  fi

  if [ "$from" != "$cache_tag" ]; then
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
