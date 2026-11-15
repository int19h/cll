#!/bin/bash
# The one place that may run a recursive delete on a variable (issue #271).
#
# Usage: scripts/safe-rm-tree.sh --root ROOT PATH...
#
# ROOT must be an existing directory, and not /, not $HOME, and not a
# repository root (a folder that holds .git). Every PATH must lie strictly
# inside ROOT once its parent is resolved. Checks run for every PATH before
# anything is deleted. A PATH that does not exist is fine. A symbolic link
# PATH is unlinked, never followed. A ROOT inside a Git work tree (an
# ancestor holds .git) is refused unless it is that work tree's build or
# coverage/build folder or below one of them, reached without a link into
# the source tree: a build link to a source folder must not become a
# delete root. A ROOT outside every Git work tree is fine. A ROOT or PATH
# with a newline or any other control character is refused: command
# substitution would strip a trailing newline and could retarget the
# delete at a sibling.
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
worktree=""
ancestor=$root
while :; do
  if [ -e "$ancestor/.git" ]; then
    worktree=$ancestor
    break
  fi
  [ "$ancestor" != "/" ] || break
  ancestor=$(dirname -- "$ancestor")
done
if [ -n "$worktree" ]; then
  case $root in
    "$worktree"/build|"$worktree"/build/*|"$worktree"/coverage/build|"$worktree"/coverage/build/*) ;;
    *) fail "ROOT is inside a Git work tree but is not its build folder: $root" ;;
  esac
  case $root_arg in
    /*) given=$root_arg ;;
    *) given=$PWD/$root_arg ;;
  esac
  current=""
  IFS=/ read -ra given_parts <<< "$given"
  for part in "${given_parts[@]}"; do
    [ -n "$part" ] || continue
    current="$current/$part"
    if [ -L "$current" ]; then
      target=$(realpath -- "$current") || fail "cannot resolve: $root_arg"
      case $target in
        "$worktree"|"$worktree"/*)
          case $target in
            "$worktree"/build|"$worktree"/build/*|"$worktree"/coverage/build|"$worktree"/coverage/build/*) ;;
            *) fail "ROOT reaches the build folder through a link into the source tree: $root_arg" ;;
          esac
          ;;
      esac
    fi
  done
fi

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
