#!/usr/bin/env bash
# Run on the host before starting a container whose checkout lacks Git metadata.
set -euo pipefail
if [ -n "${CLL_BUILD_VERSION:-}" ]; then
  printf '%s\n' "$CLL_BUILD_VERSION"
  exit 0
fi
cd "$(dirname "$(readlink -f "$0")")/.."
version=$(sed -n 's/^VERSION=//p' .env | tr -d '"')
base=${version%+dev}
if ! commit=$(git rev-parse --short=7 HEAD 2>/dev/null); then
  echo 'Cannot read the source commit. Set CLL_BUILD_VERSION when building an exported source tree.' >&2
  exit 1
fi
tag_version=${base#*-}
if [ -n "$(git tag --points-at HEAD --list "v$tag_version" "$base")" ]; then
  printf '%s\n' "$base"
else
  printf '%s+%s\n' "$base" "$commit"
fi
