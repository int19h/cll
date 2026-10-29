#!/bin/bash
#
# Build or restore every published version of the site (issue #128).
#
#   scripts/build-versions.sh <versions.tsv> <baseline-ref> <out-dir>
#
# The site output of a version, <out-dir>/<version>/, is kept as the
# archive cll-<version>-html.tar.gz. It unpacks to <version>/ and holds a
# BUILD-INFO file.
#
# Each row of <versions.tsv> names a version, its git ref, and optionally
# its formats (scripts/site-versions.sh). A row without formats has
# html,epub,pdf. The release files of a version are exactly the files of
# its formats: cll-<version>-html.tar.gz for html, and cll.pdf, cll.epub,
# cll-weasyprint.pdf, cll-typst.pdf, cll-context.pdf for the others.
#
# The policy (maintainer decision, issue #128):
#
# - A published version serves the book files of its release, unchanged:
#   the HTML (xhtml_section_chunks, xhtml_no_chunks) from the release's
#   archive, and the other files from the release's own assets. A
#   published release that lacks a file of its formats stops the run.
#   Only its comparison pages (diff_from_*) and its landing page are made again,
#   with the current tooling (build-site.sh with DIFFS_ONLY=1).
# - A version without a published release is built from source. A draft
#   release gets the files of its formats from each run, and loses the
#   files of registered formats that its row no longer lists. Other draft
#   assets stay in place with warnings. So create the release
#   as a draft with its notes before adding the version to
#   pages/versions.tsv, then check the draft and publish it.
# - While a Pages deploy runs, do not publish a release. Wait for the whole
#   deploy to finish. A fresh read does not lock the release. Publication
#   can still race with the following asset requests.
# - Prepare files before changing releases. At each version's end, read
#   the live draft state and keep that release's uploads and deletions
#   together. Guard cache uploads with their own fresh draft read too.
#
# Versions are built oldest first, prereleases (such as 1.3.6-rc1) before
# their final release. diff_from_previous of every version compares with
# the latest final release before it: prereleases are never the previous
# release. The release of a prerelease must be marked as a prerelease.
#
# The build cache is a draft release named site-build-cache. Its entry for
# a version is the archive of the whole <out-dir>/<version>/, named
# cll-<version>-html.tar.gz whatever the formats. Drafts are
# not public, and the deploy replaces its assets freely: a failed upload
# there costs at most one rebuild. A cache entry is used when its
# BUILD-INFO matches this run in all of these fields:
#
#   commit             the version's content commit (its git ref today)
#   formats            the version's formats, in canonical order
#   tools_sha256       sha256 of the site tooling: build-site.sh,
#                      site-versions.sh, docbook-diff.py, docbook-diff.xsl
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

tsv="${1:?usage: build-versions.sh <versions.tsv> <baseline-ref> <out-dir>}"
baseline="${2:?missing baseline ref}"
outdir="$(mkdir -p "${3:?missing out-dir}" && cd "$3" && pwd)"
repo="${GITHUB_REPOSITORY:?}"
force="${FORCE_REBUILD:-false}"
baseline_commit="${BASELINE_COMMIT:?}"
# shellcheck source=site-versions.sh
. scripts/site-versions.sh
rows="$(site_rows "$tsv")"
bs_sha="$(cat scripts/build-site.sh scripts/site-versions.sh scripts/docbook-diff.py scripts/docbook-diff.xsl | sha256sum | cut -c1-64)"
cache_tag="site-build-cache"
dl="$(mktemp -d)"
trap 'rm -rf "$dl"' EXIT

# The initial snapshot selects build inputs. Before any asset changes,
# read that release again. The tag endpoint does not
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

# Refuse API failures and every state other than an explicit live draft.
# Return the live assets too, so cleanup does not use the old snapshot.
draft_release() { # <tag>
  local release
  release="$(gh release view "$1" -R "$repo" --json isDraft,assets)" || {
    echo "::error::cannot read live release $1; refusing asset changes" >&2
    return 1
  }
  if ! jq -e '.isDraft == true' <<< "$release" >/dev/null; then
    echo "::error::release $1 is not a draft; refusing asset changes" >&2
    return 1
  fi
  printf '%s\n' "$release"
}

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
expect() { # <ver> <commit> <prev-commit> <released-digests> <formats>
  printf 'commit=%s\nformats=%s\ntools_sha256=%s\nprevious_commit=%s\nbaseline_commit=%s\nrelease_files=%s\n' \
    "$2" "$5" "$bs_sha" "$3" "$baseline_commit" "$4"
}
matches() { # <ver> <expected-fields> <formats>
  local bi="$outdir/$1/BUILD-INFO" key val f
  [ -f "$bi" ] || return 1
  [ -s "$outdir/$1/index.html" ] || return 1
  if site_has_format "$3" html; then
    [ -s "$outdir/$1/xhtml_no_chunks/index.html" ] || return 1
    [ -s "$outdir/$1/xhtml_section_chunks/index.html" ] || return 1
  fi
  for f in $(site_download_files "$3" "$1"); do
    [ -s "$outdir/$1/$f" ] || return 1
  done
  while IFS='=' read -r key val; do
    [ "$(info "$bi" "$key")" = "$val" ] || return 1
  done <<< "$2"
}

# Refuse every published asset mismatch before any upload or deletion,
# including cache writes. A published release cannot be repaired here.
while IFS=$'\t' read -r ver ref formats; do
  tag="v$ver"
  if [ -n "$(release_field "$tag" id)" ] && [ "$(release_field "$tag" draft)" != true ]; then
    expected="$(site_release_files "$formats" "$ver" | sort)"
    actual="$(jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .assets[].name' "$releases" | sort)"
    if [ "$actual" != "$expected" ]; then
      echo "::error::published release $tag has a different asset set; leave the release unchanged" >&2
      printf 'Expected:\n%s\nFound:\n%s\n' "$expected" "$actual" >&2
      exit 1
    fi
  fi
done <<< "$rows"

# The cache must stay a draft, or the uploads below would change a
# published release.
if [ -n "$(release_field "$cache_tag" id)" ] && [ "$(release_field "$cache_tag" draft)" != "true" ]; then
  echo "the release $cache_tag is published; make it a draft again before deploying" >&2
  exit 1
fi

cache_exists="$(release_field "$cache_tag" id)"
prev=""; prevlabel=""; prev_commit=""
# oldest first, so each final release's ref serves as the "previous
# release" side of the diff_from_previous of the versions after it
while IFS=$'\t' read -r ver ref formats; do
  echo "::group::$ver from $ref ($formats)"
  commit="$(git rev-parse "origin/$ref")"
  # Edition rows use their declared version before publication creates a
  # tag. Validate even cache hits, and pass one label to every format.
  build_version="$(site_edition_version "$ver" "$ref" "$commit")"
  tag="v$ver"
  archive="cll-$ver-html.tar.gz"
  mapfile -t want_files < <(site_release_files "$formats" "$ver")
  mapfile -t downloads < <(site_download_files "$formats" "$ver")
  if [ -n "$(release_field "$tag" id)" ]; then
    marked="$(release_field "$tag" prerelease)"
    if site_is_prerelease "$ver" && [ "$marked" != "true" ]; then
      echo "::warning::release $tag is for a prerelease version but is not marked as a prerelease"
    elif ! site_is_prerelease "$ver" && [ "$marked" = "true" ]; then
      echo "::warning::release $tag is marked as a prerelease but $ver is a final version"
    fi
  fi
  published=""
  released=""
  if [ -n "$(release_field "$tag" id)" ] && [ "$(release_field "$tag" draft)" != "true" ]; then
    # A published release must carry every file of its formats. The site
    # serves exactly these files, so a missing one is an error, not a
    # reason to build from source.
    published=yes
    for f in "${want_files[@]}"; do
      if ! has_asset "$tag" "$f"; then
        echo "::error::published release $tag has no $f; leave the release unchanged"
        exit 1
      fi
      released="${released:+$released,}$f:$(asset_digest "$tag" "$f")"
    done
  fi
  want="$(expect "$ver" "$commit" "$prev_commit" "$released" "$formats")"

  from=""
  store_cache=""
  if [ "$force" != "true" ] && has_asset "$cache_tag" "$archive"; then
    fetch "$cache_tag" "$archive" "$dl"
    if unpack "$dl/$archive" "$ver" && matches "$ver" "$want" "$formats"; then
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
      # HTML from the archive, the other files from the release's own
      # assets. Only the diffs and the landing page are made again.
      if site_has_format "$formats" html; then
        fetch "$tag" "$archive" "$dl"
        unpack "$dl/$archive" "$ver" || { echo "the release archive $tag/$archive is damaged" >&2; exit 1; }
      else
        rm -rf "$outdir/$ver"; mkdir -p "$outdir/$ver"
      fi
      rm -rf "$outdir/$ver"/diff_from_* "$outdir/$ver/BUILD-INFO"
      for f in $(site_download_files "$SITE_ALL_FORMATS" "$ver"); do
        rm -f "$outdir/$ver/$f"
      done
      for f in "${downloads[@]}"; do
        fetch "$tag" "$f" "$outdir/$ver"
      done
      CLL_BUILD_VERSION="$build_version" FORMATS="$formats" DIFFS_ONLY=1 bash scripts/build-site.sh "_v_$ver" "$ver" "$baseline" "$outdir" "$prev" "$prevlabel"
      echo "==> [$ver] served the book files of $tag, rebuilt its diffs"
    else
      CLL_BUILD_VERSION="$build_version" FORMATS="$formats" bash scripts/build-site.sh "_v_$ver" "$ver" "$baseline" "$outdir" "$prev" "$prevlabel"
    fi
    { echo "version=$ver"; echo "ref=$ref"; echo "$want";
      echo "pages_commit=$(git rev-parse HEAD)"; echo "workflow_run=${GITHUB_RUN_ID:-local}"; } > "$outdir/$ver/BUILD-INFO"
    tar -C "$outdir" -czf "$dl/$archive" "$ver"
    store_cache=yes
  fi

  # Attach the requested files to a draft. Clean up only known format
  # files, and preserve other assets with warnings. Published releases
  # still require exactly the selected files.
  if [ "$(release_field "$tag" draft)" = "true" ]; then
    files=()
    for f in "${want_files[@]}"; do
      if [ "$f" = "$archive" ]; then
        [ -f "$dl/$archive" ] || tar -C "$outdir" -czf "$dl/$archive" "$ver"
        files+=("$dl/$archive")
      else
        files+=("$outdir/$ver/$f")
      fi
    done
    # All local preparation is complete. Keep the live read and this
    # release's changes together, without another build or cache upload.
    live_release="$(draft_release "$tag")"
    gh release upload "$tag" -R "$repo" --clobber "${files[@]}"
    echo "==> [$ver] attached ${want_files[*]} to the draft $tag"
    # Remove unlisted format files, including archives of other versions.
    while IFS= read -r f; do
      case " ${want_files[*]} " in *" $f "*) continue ;; esac
      if site_is_format_file "$f"; then
        gh release delete-asset "$tag" "$f" -R "$repo" --yes
        echo "==> [$ver] removed $f from the draft $tag: its format is not listed"
      else
        echo "::warning::draft release $tag has unlisted asset '$f'. The deploy leaves it unchanged." >&2
      fi
    done < <(jq -r '.assets[].name' <<< "$live_release")
  elif [ -z "$(release_field "$tag" id)" ]; then
    echo "::warning::release $tag does not exist; create it as a draft to receive the files of $ver"
  fi
  # Cache writes also wait until this version is ready. A new cache is
  # created as a draft here, then read again before its first upload.
  if [ -n "$store_cache" ]; then
    if [ -z "$cache_exists" ]; then
      gh api -X POST "repos/$repo/releases" -f tag_name="$cache_tag" \
        -f name="Site build cache (do not publish)" \
        -f body="The Pages deploy keeps the site output of each version here (scripts/build-versions.sh). Never publish this draft." \
        -F draft=true >/dev/null
      echo "==> created the draft release $cache_tag"
      cache_exists=yes
    fi
    draft_release "$cache_tag" >/dev/null
    gh release upload "$cache_tag" -R "$repo" --clobber "$dl/$archive"
    echo "==> [$ver] stored in $cache_tag"
  fi
  rm -f "$dl/$archive"

  # A prerelease is never the previous release of another version.
  if ! site_is_prerelease "$ver"; then
    prev="origin/$ref"
    prevlabel="v$ver"
    prev_commit="$commit"
  fi
  echo "::endgroup::"
done <<< "$rows"
