#!/bin/bash
# The one place that may run a recursive delete on a variable (issue #271).
#
# Usage: scripts/safe-rm-tree.sh --root ROOT PATH...
#
# ROOT must be an existing directory, and not /, not $HOME, and not a
# repository root (a folder that holds .git). Every PATH must lie strictly
# inside ROOT once its parent is resolved. Checks run for every PATH before
# anything is deleted. A PATH that does not exist is fine. A symbolic link
# PATH is unlinked, never followed. A ROOT or PATH with a newline or any
# other control character is refused: command substitution would strip a
# trailing newline and could retarget the delete at a sibling.
# Limit: the checks and the delete are separate steps, so this helper does
# not defend against a concurrent process swapping a folder for a link in
# between. Needs only bash and coreutils.
set -u

fail() { echo "safe-rm-tree: $*" >&2; exit 2; }
no_control() {
  case $1 in
    *[[:cntrl:]]*) fail "$2 contains a control character" ;;
  esac
}

[ "${1:-}" = "--root" ] || fail "usage: safe-rm-tree.sh --root ROOT PATH..."
[ $# -ge 3 ] || fail "usage: safe-rm-tree.sh --root ROOT PATH..."
root_arg=$2
shift 2

[ -n "$root_arg" ] || fail "ROOT is empty"
no_control "$root_arg" "ROOT"
root=$(realpath -- "$root_arg" 2>/dev/null) || fail "ROOT does not exist: $root_arg"
no_control "$root" "ROOT"
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
  no_control "$path" "PATH"
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
  no_control "$candidate" "PATH"
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
    rm -rf --one-file-system -- "$target" || exit 1
  fi
done
