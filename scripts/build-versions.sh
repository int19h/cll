#!/bin/bash
#
# Build or restore every published version of the site (issue #128).
#
#   scripts/build-versions.sh <versions.tsv> <baseline-nochunks-dir> <out-dir>
#
# Each release v<version> carries its version's site output as three
# assets: cll-<version>-html.tar.gz (unpacks to <version>/, with a
# BUILD-INFO file), cll.pdf, and cll.epub. A version is restored from its
# archive instead of being rebuilt when BUILD-INFO matches this run in all
# of these fields:
#
#   commit             the version's content commit (its git ref today)
#   build_site_sha256  sha256 of scripts/build-site.sh
#   previous_commit    the content commit of the version before it
#                      (diff_from_previous)
#   baseline_commit    the UnCLL baseline commit (diff_from_uncll)
#
# A version that is rebuilt replaces all three assets of its release, so a
# release never mixes the outputs of two builds. Each replacement is
# uploaded under a temporary name first, and only then does the old asset
# go away, so a failed upload never loses a published file. A restored
# version checks the PDF and the ePub of its release against the copies in
# its archive, and uploads the archive's copy when one is missing or
# differs, so an interrupted upload heals on the next run.
#
# When the release does not exist, the version is built and not archived,
# so the next deploy builds it again. So create the release, as a draft
# with its notes, before adding the version to pages/versions.tsv. The
# deploy then attaches the PDF, the ePub, and the HTML archive to it.
# Any error of the GitHub API fails the run.
#
# Environment:
#   GH_TOKEN            token for gh (contents: write)
#   GITHUB_REPOSITORY   owner/repo
#   FORCE_REBUILD       "true" rebuilds every version and replaces its
#                       assets (for toolchain changes that change the
#                       output)
#   BASELINE_COMMIT     the baseline commit, recorded in BUILD-INFO
set -euo pipefail

tsv="${1:?usage: build-versions.sh <versions.tsv> <baseline-dir> <out-dir>}"
baseline="${2:?missing baseline dir}"
outdir="$(mkdir -p "${3:?missing out-dir}" && cd "$3" && pwd)"
repo="${GITHUB_REPOSITORY:?}"
force="${FORCE_REBUILD:-false}"
baseline_commit="${BASELINE_COMMIT:?}"
bs_sha="$(sha256sum scripts/build-site.sh | cut -c1-64)"
dl="$(mktemp -d)"
trap 'rm -rf "$dl"' EXIT

# All releases, drafts included, read once. The tag endpoint does not
# return drafts, and an error here must stop the run rather than look
# like a missing release.
releases="$dl/releases.json"
gh api --paginate "repos/$repo/releases" --jq '.[]' | jq -s . > "$releases"

release_id() { # <tag>
  jq -r --arg t "$1" 'map(select(.tag_name == $t)) | if length > 0 then .[0].id else "" end' "$releases"
}
asset_id() { # <tag> <name>
  jq -r --arg t "$1" --arg n "$2" \
    'map(select(.tag_name == $t)) | .[0].assets // [] | map(select(.name == $n)) | if length > 0 then .[0].id else "" end' "$releases"
}

# Replace (or add) one asset without a window in which it is missing.
put_asset() { # <tag> <release-id> <file> <name>
  local tag="$1" rid="$2" file="$3" name="$4" tmpname old new
  tmpname="$name.new-${GITHUB_RUN_ID:-local}"
  cp "$file" "$dl/$tmpname"
  gh release upload "$tag" -R "$repo" --clobber "$dl/$tmpname"
  rm -f "$dl/$tmpname"
  new="$(gh api "repos/$repo/releases/$rid/assets" --paginate --jq ".[] | select(.name == \"$tmpname\") | .id")"
  old="$(gh api "repos/$repo/releases/$rid/assets" --paginate --jq ".[] | select(.name == \"$name\") | .id")"
  [ -n "$new" ] || { echo "upload of $tmpname to $tag did not appear" >&2; exit 1; }
  [ -z "$old" ] || gh api -X DELETE "repos/$repo/releases/assets/$old" >/dev/null
  gh api -X PATCH "repos/$repo/releases/assets/$new" -f name="$name" >/dev/null
}

info() { # <file> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
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
  rid="$(release_id "$tag")"
  reuse=""
  if [ -n "$rid" ] && [ "$force" != "true" ] && [ -n "$(asset_id "$tag" "$archive")" ]; then
    rm -rf "$dl/$archive" "$outdir/$ver"
    gh release download "$tag" -R "$repo" -p "$archive" -D "$dl"
    tar -xzf "$dl/$archive" -C "$outdir"
    bi="$outdir/$ver/BUILD-INFO"
    if [ -f "$bi" ] \
       && [ "$(info "$bi" commit)" = "$commit" ] \
       && [ "$(info "$bi" build_site_sha256)" = "$bs_sha" ] \
       && [ "$(info "$bi" previous_commit)" = "$prev_commit" ] \
       && [ "$(info "$bi" baseline_commit)" = "$baseline_commit" ] \
       && [ -s "$outdir/$ver/xhtml_no_chunks/index.html" ]; then
      reuse=yes
      echo "==> [$ver] restored from $tag/$archive"
      # The archive holds the PDF and the ePub of the same build. A release
      # whose copy is missing or differs (for example after an interrupted
      # upload) gets the archive's copy, so its assets always agree.
      for f in cll.pdf cll.epub; do
        [ -f "$outdir/$ver/$f" ] || continue
        if [ -n "$(asset_id "$tag" "$f")" ]; then
          rm -f "$dl/$f"
          gh release download "$tag" -R "$repo" -p "$f" -D "$dl"
          cmp -s "$dl/$f" "$outdir/$ver/$f" && continue
        fi
        put_asset "$tag" "$rid" "$outdir/$ver/$f" "$f"
        echo "==> [$ver] replaced $f on $tag with the copy from $archive"
      done
    else
      echo "==> [$ver] $tag/$archive does not match this run; rebuilding"
      rm -rf "$outdir/$ver"
    fi
  fi

  if [ -z "$reuse" ]; then
    git worktree add --detach "_v_$ver" "origin/$ref"
    bash scripts/build-site.sh "_v_$ver" "$ver" "$baseline" "$outdir" "$prev" "$prevlabel"
    printf 'version=%s\nref=%s\ncommit=%s\nbuild_site_sha256=%s\nprevious_commit=%s\nbaseline_commit=%s\npages_commit=%s\nworkflow_run=%s\n' \
      "$ver" "$ref" "$commit" "$bs_sha" "$prev_commit" "$baseline_commit" \
      "$(git rev-parse HEAD)" "${GITHUB_RUN_ID:-local}" > "$outdir/$ver/BUILD-INFO"
    if [ -n "$rid" ]; then
      tar -C "$outdir" -czf "$dl/$archive" "$ver"
      # The archive last: after an interruption, either the old archive no
      # longer matches and the next run rebuilds, or the new archive is in
      # place and the next restore repairs the PDF and the ePub from it.
      for f in cll.pdf cll.epub; do
        [ -f "$outdir/$ver/$f" ] && put_asset "$tag" "$rid" "$outdir/$ver/$f" "$f"
      done
      put_asset "$tag" "$rid" "$dl/$archive" "$archive"
      echo "==> [$ver] uploaded to $tag"
    else
      echo "::warning::release $tag does not exist; $ver was built but not archived, so the next deploy builds it again"
    fi
  fi

  prev="$outdir/$ver/xhtml_no_chunks"
  prevlabel="v$ver"
  prev_commit="$commit"
  echo "::endgroup::"
done < <(tac "$tsv")
