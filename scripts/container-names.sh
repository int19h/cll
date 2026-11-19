#!/bin/bash
# Shared container naming for the run_*_container.sh launchers (issue #297).
#
# A fixed container name makes concurrent builds from different checkouts
# kill each other: `kill cll_build` stops any running build. These helpers
# derive the name from the run instead, and validate a caller-supplied
# override. Each run starts its container by the immutable image ID its
# own build returned, so sharing one image tag with another checkout is
# safe. Source this file; it runs nothing.
#
# Bash 3.2 treats empty arrays as unset, so callers keep nounset disabled.

# Prints the container name for this run. $CLL_CONTAINER_NAME overrides the
# derived name so a caller can pick a stable name of its own. Callers must
# validate an override before passing it to the engine.
cll_container_name() {
  if [ -n "${CLL_CONTAINER_NAME:-}" ]; then
    printf '%s\n' "$CLL_CONTAINER_NAME"
    return 0
  fi
  local dir key
  dir=$1
  key=$(printf '%s' "$dir" | sha256sum | cut -c1-12)
  printf 'cll_build_%s_%s\n' "$key" "$$"
}

# True when the argument is a safe container name: letters, digits, '_',
# '.' and '-', starting with a letter or digit. In particular a name never
# starts with a hyphen, so it cannot parse as an engine option.
cll_valid_container_name() {
  case "$1" in
    [a-zA-Z0-9]*)
      case "$1" in
        *[!a-zA-Z0-9_.-]*) return 1 ;;
      esac
      return 0 ;;
  esac
  return 1
}
