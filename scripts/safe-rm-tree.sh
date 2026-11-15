#!/bin/bash
# The one place that may run a recursive delete on a variable (issue #271).
#
# Usage: scripts/safe-rm-tree.sh --root ROOT PATH...
#
# ROOT must be an existing directory, and not /, not $HOME, and not a
# repository root (a folder that holds .git). Every PATH must lie strictly
# inside ROOT once its parent is resolved. Checks run for every PATH before
# anything is deleted. A PATH that does not exist is fine. A symbolic link
# PATH is unlinked, never followed. Needs only bash and coreutils.
set -u

fail() { echo "safe-rm-tree: $*" >&2; exit 2; }

[ "${1:-}" = "--root" ] || fail "usage: safe-rm-tree.sh --root ROOT PATH..."
[ $# -ge 3 ] || fail "usage: safe-rm-tree.sh --root ROOT PATH..."
root_arg=$2
shift 2

[ -n "$root_arg" ] || fail "ROOT is empty"
root=$(realpath -- "$root_arg" 2>/dev/null) || fail "ROOT does not exist: $root_arg"
[ -d "$root" ] || fail "ROOT is not a directory: $root_arg"
[ "$root" != "/" ] || fail "ROOT is /"
if [ -n "${HOME:-}" ]; then
  home=$(realpath -m -- "$HOME")
  [ "$root" != "$home" ] || fail "ROOT is the home folder: $root"
fi
[ ! -e "$root/.git" ] || fail "ROOT is a repository root: $root"

resolved=()
for path in "$@"; do
  [ -n "$path" ] || fail "a PATH is empty"
  case $path in
    *'*'*|*'?'*|*'['*) fail "PATH is a glob: $path" ;;
  esac
  trimmed=$path
  while [ "${#trimmed}" -gt 1 ] && [ "${trimmed%/}" != "$trimmed" ]; do
    trimmed=${trimmed%/}
  done
  base=$(basename -- "$trimmed")
  [ "$base" != "." ] && [ "$base" != ".." ] || fail "PATH is not a plain name: $path"
  parent=$(dirname -- "$trimmed")
  parent_resolved=$(realpath -m -- "$parent") || fail "cannot resolve: $path"
  if [ "$parent_resolved" = "/" ]; then
    candidate="/$base"
  else
    candidate="$parent_resolved/$base"
  fi
  case $candidate in
    "$root"/*) ;;
    *) fail "PATH is not inside ROOT: $path" ;;
  esac
  resolved+=("$candidate")
done

i=0
for path in "$@"; do
  target=${resolved[$i]}
  i=$((i + 1))
  if [ -L "$target" ]; then
    echo "removing $path" >&2
    unlink -- "$target" || exit 1
  elif [ -e "$target" ]; then
    echo "removing $path" >&2
    rm -rf -- "$target" || exit 1
  fi
done
