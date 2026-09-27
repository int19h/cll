#!/bin/bash
#
# Build or restore every published version of the site (issue #128).
#
#   scripts/build-versions.sh <versions.tsv> <baseline-nochunks-dir> <out-dir>
#
# Each release v<version> carries an archive of its version's site output,
# cll-<version>-html.tar.gz, which unpacks to <version>/ and holds a
# BUILD-INFO file. A version is restored from that archive instead of
# being rebuilt when its BUILD-INFO matches this run:
#
#   commit             the version's content commit (its git ref today)
#   build_site_sha256  sha256 of scripts/build-site.sh
#   previous_commit    the content commit of the version before it
#   baseline_commit    the UnCLL baseline commit (diff_from_uncll)
#
# previous_commit and baseline_commit are compared only when the archive
# records them. The archives backfilled by hand from deploy run
# 36278151590 record only the first two.
#
# A version that is rebuilt gets a new archive, uploaded to its release
# with --clobber. Its cll.pdf and cll.epub are uploaded too, but only when
# the release does not have them yet, or when the release is a draft: the
# files of a published release never change behind its back.
#
# When the release does not exist, the version is built and not uploaded,
# so the next deploy builds it again. So create the release, as a draft
# with its notes, before adding the version to pages/versions.tsv. The
# deploy then attaches the PDF, the ePub, and the HTML archive to it.
#
# Environment:
#   GH_TOKEN            token for gh (contents: write)
#   GITHUB_REPOSITORY   owner/repo
#   FORCE_REBUILD       "true" rebuilds every version and replaces the
#                       HTML archives (for toolchain changes that change
#                       the output)
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
  asset="cll-$ver-html.tar.gz"
  release_json="$(gh release view "$tag" -R "$repo" --json isDraft,assets 2>/dev/null || true)"
  reuse=""
  if [ -n "$release_json" ] && [ "$force" != "true" ] \
     && echo "$release_json" | jq -e --arg a "$asset" 'any(.assets[]; .name == $a)' >/dev/null; then
    rm -rf "$dl"/* "$outdir/$ver"
    gh release download "$tag" -R "$repo" -p "$asset" -D "$dl"
    tar -xzf "$dl/$asset" -C "$outdir"
    bi="$outdir/$ver/BUILD-INFO"
    if [ -f "$bi" ] \
       && [ "$(info "$bi" commit)" = "$commit" ] \
       && [ "$(info "$bi" build_site_sha256)" = "$bs_sha" ] \
       && { [ -z "$(info "$bi" previous_commit)" ] || [ "$(info "$bi" previous_commit)" = "$prev_commit" ]; } \
       && { [ -z "$(info "$bi" baseline_commit)" ] || [ "$(info "$bi" baseline_commit)" = "$baseline_commit" ]; } \
       && [ -s "$outdir/$ver/xhtml_no_chunks/index.html" ]; then
      reuse=yes
      echo "==> [$ver] restored from $tag/$asset"
    else
      echo "==> [$ver] $tag/$asset does not match this run; rebuilding"
      rm -rf "$outdir/$ver"
    fi
  fi

  if [ -z "$reuse" ]; then
    git worktree add --detach "_v_$ver" "origin/$ref"
    bash scripts/build-site.sh "_v_$ver" "$ver" "$baseline" "$outdir" "$prev" "$prevlabel"
    printf 'version=%s\nref=%s\ncommit=%s\nbuild_site_sha256=%s\nprevious_commit=%s\nbaseline_commit=%s\npages_commit=%s\nworkflow_run=%s\n' \
      "$ver" "$ref" "$commit" "$bs_sha" "$prev_commit" "$baseline_commit" \
      "$(git rev-parse HEAD)" "${GITHUB_RUN_ID:-local}" > "$outdir/$ver/BUILD-INFO"
    if [ -n "$release_json" ]; then
      tar -C "$outdir" -czf "$dl/$asset" "$ver"
      gh release upload "$tag" -R "$repo" --clobber "$dl/$asset"
      draft="$(echo "$release_json" | jq -r .isDraft)"
      for f in cll.pdf cll.epub; do
        [ -f "$outdir/$ver/$f" ] || continue
        if [ "$draft" = "true" ]; then
          gh release upload "$tag" -R "$repo" --clobber "$outdir/$ver/$f"
        elif ! echo "$release_json" | jq -e --arg a "$f" 'any(.assets[]; .name == $a)' >/dev/null; then
          gh release upload "$tag" -R "$repo" "$outdir/$ver/$f"
        fi
      done
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
