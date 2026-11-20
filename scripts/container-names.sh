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

# Shared engine-run lifecycle for the run_*_container.sh launchers
# (issue #297). Each launcher tracks its own run in these variables and in
# one caller-defined remove_run_files function, then shares the rest:
#
#   cll_name      this run's container name (unique per run)
#   cll_run_tag   extra image tag this run attached at build time
#
# Call cll_install_traps once, before the first engine call that needs
# cleanup. Run each foreground engine step as
# "cll_run_bg <engine> ... || step_rc=$?"; the step runs in the background
# with the launcher's own standard input attached, so a trapped signal
# interrupts the wait at once (and a terminal stays the engine's terminal).
# Cleanup uses only the recorded container name and run tag, never any
# other container, image, or tag. The container is removed only when its
# cll.run label matches this run's tag, so a run that never started its
# own container (a shared name taken by another run, a failed build, an
# early signal) can never stop someone else's.
#
# Guard a build folder with cll_take_lock <lock-file> <busy-message>: it
# takes a nonblocking flock, or warns and runs unguarded when flock is not
# installed (as on macOS) instead of reporting a busy checkout that does
# not exist.
cll_child=0
cll_name=
cll_run_tag=
# Prints the random part of a mktemp -d directory made from a
# "<name>.XXXXXXXX" template, for run tags that stay unique even when two
# launchers share a PID namespace and its PIDs.
cll_run_id() {
  local base=${1##*/}
  printf '%s\n' "${base#*.}"
}
cll_take_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$1"
    flock -n 9 || { echo "$2" >&2; exit 1; }
  else
    echo 'Warning: flock not found; this run does not guard the build folder.' >&2
  fi
}
# One `container inspect` call (never the generic `inspect`, so a name can
# never resolve to an image) returns the full container ID and its cll.run
# label. The ID pins the container: with --rm the name can be freed and
# taken by another run between separate stop and rm calls, but an ID cannot
# be reused for a different object.
cll_lookup_container() {
  "${engine[@]}" container inspect --format '{{.Id}} {{ index .Config.Labels "cll.run" }}' "$1" 2>/dev/null || true
}
cll_cleanup_container() {
  local record id owner tries
  # Never match an empty or missing tag: an early exit happens before this
  # run's tag exists, and then any comparison against an empty label would
  # wrongly succeed on Podman (empty) or a missing container (empty).
  [ -n "$cll_name" ] || return 0
  [ -n "$cll_run_tag" ] || return 0
  record=$(cll_lookup_container "$cll_name") || record=
  id=${record%% *}
  owner=${record#* }
  # Only this run's own container, proven by its label, is stopped and
  # removed. Anything else keeps running, including a same-named container
  # that another run started after ours exited. With --rm the engine
  # usually removes the container itself when the run ends, so a missing
  # container or a foreign label simply skips this part.
  if [ -n "$id" ] && [ "$owner" = "$cll_run_tag" ]; then
    "${engine[@]}" stop -t 10 "$id" >/dev/null 2>&1 || true
    "${engine[@]}" rm -f "$id" >/dev/null 2>&1 || true
  fi
  # Always untag this run's own run tag afterwards: it belongs to this
  # run alone, so removing it is safe whatever happened to the container.
  # With --rm the engine's own auto-remove can still hold the image for a
  # moment after our rm, so a single rmi can fail while a later one
  # succeeds; retry while the tag still resolves, then give up quietly
  # rather than failing the build over tag cleanup. When the tag never
  # existed (a failed build) the first check ends this at once.
  tries=0
  until "${engine[@]}" rmi "$cll_run_tag" >/dev/null 2>&1; do
    "${engine[@]}" image inspect --format '{{.Id}}' "$cll_run_tag" \
      >/dev/null 2>&1 || break
    tries=$((tries + 1))
    [ "$tries" -ge 5 ] && break
    sleep 2
  done
  return 0
}
cll_on_signal() {
  local sig
  sig=$1
  # Stop the active engine call at once; bash would otherwise wait for it.
  if [ "$cll_child" -ne 0 ]; then kill "$cll_child" 2>/dev/null || true; fi
  cll_cleanup_container
  # Remove the private files here as well as in the EXIT trap: bash can
  # skip the EXIT trap when the shell dies inside this handler.
  remove_run_files
  # Exit with the signal status: reset the handler and re-raise the signal.
  trap - "$sig"
  kill -s "$sig" "$$"
}
cll_install_traps() {
  local sig
  for sig in INT TERM HUP; do trap "cll_on_signal $sig" "$sig"; done
  # Single quotes: the paths expand when the trap runs, from variables that
  # never change, so no directory name is ever parsed as shell syntax again.
  trap 'cll_cleanup_container; remove_run_files' EXIT
}
cll_run_bg() {
  "$@" <&0 &
  cll_child=$!
  local rc=0
  wait "$cll_child" || rc=$?
  cll_child=0
  return "$rc"
}
