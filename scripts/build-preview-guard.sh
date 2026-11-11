#!/bin/bash
# Read the live origin branch, independently of the branch being built.
set -euo pipefail
case "${BUILD_PAGES_PREVIEW:-auto}" in
  deny) echo 'Preview skipped: BUILD_PAGES_PREVIEW=deny.'; exit 0 ;;
  allow) echo 'Preview allowed: BUILD_PAGES_PREVIEW=allow overrides release-site detection.'; exit 0 ;;
  auto|'') ;;
  *) echo 'Invalid BUILD_PAGES_PREVIEW: use auto, allow, or deny.' >&2; exit 1 ;;
esac
# ls-remote distinguishes a missing branch from a failed lookup. Fail closed.
refs=$(git ls-remote --heads origin refs/heads/pages)
if [ -z "$refs" ]; then
  echo 'Preview allowed: origin has no pages branch.'
  exit 0
fi
git fetch --quiet --no-tags --depth=1 origin refs/heads/pages
# Inspect the tree, rather than interpreting a failed file lookup as absence.
files=$(git ls-tree -r --name-only FETCH_HEAD)
if grep -qx 'pages/versions.tsv' <<< "$files"; then
  echo 'Preview skipped: pages branch contains pages/versions.tsv (published book site).'
else
  echo 'Preview allowed: pages branch has no pages/versions.tsv.'
fi
