#!/bin/bash

# Bash 3.2 treats empty arrays as unset, so keep nounset disabled.
set -eo pipefail

script_path=$(readlink -f "$0")
dir=${script_path%/*}
dir=${dir:-/}
. "$dir/scripts/container-names.sh"
# A name unique to this run (issue #297): builds from different checkouts
# must not stop each other. A caller can set CLL_CONTAINER_NAME for a stable
# name of its own; sharing one reintroduces the collision, so that is the
# caller's choice. The name becomes an engine argument, so reject anything
# that is not a plain container name before calling the engine.
container_name=$(cll_container_name "$dir")
if ! cll_valid_container_name "$container_name"; then
  echo "Invalid container name '$container_name'. Set CLL_CONTAINER_NAME to letters, digits, '_', '.' and '-', starting with a letter or digit." >&2
  exit 2
fi

# Select one engine; do not fall back when the selected engine is unavailable.
engine=()
if [ -n "${CONTAINER_BIN:-}" ]; then
  container_bin=$CONTAINER_BIN
  read -r -a engine <<< "$container_bin"
else
  container_bin=$(command -v podman || command -v docker || true)
  if [ -n "$container_bin" ]; then engine=("$container_bin"); fi
fi
if [ "${#engine[@]}" -eq 0 ]; then
  echo 'Install Podman or Docker, or set CONTAINER_BIN to a container command.' >&2
  exit 1
fi
if ! "${engine[@]}" info >/dev/null 2>&1; then
  echo "Container command '$container_bin info' failed. Check that the selected engine is running and accessible." >&2
  exit 1
fi

# Manually pull any -a or -A arguments so we can use them to build
# volume-sharing options into our container run call.
args=( "$@" )
extra_vols=()
for index in "${!args[@]}"
do
  arg=${args[$index]}
  if [ "$arg" = '-a' -o "$arg" = '-A' ]
  then
    if [ "$((index + 1))" -ge "${#args[@]}" ] || [ -z "${args[$index+1]}" ]; then
      echo "$arg requires an output directory." >&2
      exit 2
    fi
    mkdir -p -- "${args[$index+1]}"
    nextarg=$(realpath -- "${args[$index+1]}")
    nextargfile="/tmp/cll-export-$index"
    extra_vols+=(-v "$nextarg:$nextargfile")
    args[$index+1]="$nextargfile"
  fi
done

# This run's container is tracked by its immutable ID, recorded by the
# engine in a private file. Cleanup uses only that ID, never the name, so
# it can neither touch another run's container nor miss this run's own.
# There is no startup removal: an occupied name is the engine's error.
child=0
cidfile=$(mktemp "${TMPDIR:-/tmp}/cll-container.XXXXXXXX") || exit 1
rm -f "$cidfile"
iidfile=$(mktemp "${TMPDIR:-/tmp}/cll-image.XXXXXXXX") || exit 1
rm -f "$iidfile"
container_id() {
  cat "$cidfile" 2>/dev/null || true
}
cleanup_container() {
  local id
  id=$(container_id)
  if [ -n "$id" ]; then
    "${engine[@]}" rm -f "$id" >/dev/null 2>&1 || true
  fi
}
on_signal() {
  local sig id
  sig=$1
  # Stop the active engine call at once; bash would otherwise wait for it.
  if [ "$child" -ne 0 ]; then kill "$child" 2>/dev/null || true; fi
  id=$(container_id)
  if [ -n "$id" ]; then
    "${engine[@]}" stop -t 10 "$id" >/dev/null 2>&1 || true
  fi
  cleanup_container
  # Remove the private files here as well as in the EXIT trap: bash can
  # skip the EXIT trap when the shell dies inside this handler.
  rm -f "$cidfile" "$iidfile"
  # Exit with the signal status: reset the handler and re-raise the signal.
  trap - "$sig"
  kill -s "$sig" "$$"
}
for sig in INT TERM HUP; do trap "on_signal $sig" "$sig"; done
# The double quotes expand the file paths now, while they are known.
trap "cleanup_container; rm -f \"$cidfile\" \"$iidfile\"" EXIT
mkdir -p "$dir/build"
# Preserve trailing newlines so the whitespace check sees the full path.
build_dir=$(realpath "$dir/build" && printf .)
build_dir=${build_dir%$'\n.'}
case "$dir:$build_dir" in
  *[[:space:]]*)
    echo 'Checkout and build directory paths must not contain whitespace. scripts/Makefile does not support it.' >&2
    printf 'Checkout: %s\nBuild directory: %s\n' "$dir" "$build_dir" >&2
    exit 2 ;;
esac
# One writer per checkout build folder. Unique container names keep two runs
# from one checkout from stopping each other, but both would still write the
# same intermediate files, so the second run fails fast instead.
# run_weasyprint_container.sh guards its build folder the same way.
exec 9>"$build_dir/.container.lock"
flock -n 9 || {
  echo "Another build already uses this checkout's build directory ($build_dir)." >&2
  exit 1
}
mounts=(-v "$dir:$dir" -v "$build_dir:$build_dir")
build_version=$("$dir/scripts/build-version.sh") || exit 1

# The tag follows the build context's content (issue #297): different
# Dockerfiles never share a tag, equal ones share the image cache.
# lojban/cll_build stays as an alias for callers that name it.
image_tag=$(cll_image_tag "$dir/Dockerfile" "$dir" prince) || exit 1
image="lojban/cll_build:$image_tag"

# FOR TESTING; forces complete container rebuild
# "${engine[@]}" build --no-cache -t "$image" -f Dockerfile .
# "${engine[@]}" rmi "$image"
echo "Running container image build; this may take a while."
echo "Image tag: $image"
echo "Container name: $container_name"
echo
"${engine[@]}" build -t "$image" --iidfile "$iidfile" -f "$dir/Dockerfile" "$dir" >/tmp/rc.$$ 2>&1 &
child=$!
build_rc=0
wait "$child" || build_rc=$?
child=0
if [ "$build_rc" -ne 0 ]; then
  echo "Container image build failed.  Here's the output: "
  echo
  cat /tmp/rc.$$
  echo
  echo
  echo "Container image build failed.  Output is above."
  echo
  echo
  rm -f /tmp/rc.$$
  exit 1
fi

rm -f /tmp/rc.$$

# Run the immutable image this build produced, not the tag: another checkout
# can retag the name under this run between the build and the run.
image_id=$(cat "$iidfile" 2>/dev/null) || image_id=
if [ -z "$image_id" ]; then
  echo "Container image build did not report its ID." >&2
  exit 1
fi
echo "Image ID: $image_id"

"${engine[@]}" tag "$image_id" lojban/cll_build

user_args=(--user "$(id -u):$(id -g)")
if "${engine[@]}" --version | grep -qi podman; then
  user_args=(--userns=keep-id)
elif security_options=$("${engine[@]}" info --format '{{.SecurityOptions}}' 2>/dev/null); then
  if [[ "$security_options" == *name=rootless* ]]; then
    # Root in a rootless Docker container maps to the daemon's host user.
    user_args=()
  fi
else
  echo "Warning: could not check whether Docker is rootless; running the container as $(id -u):$(id -g)." >&2
fi
terminal=()
if [ -t 0 ]; then
  terminal+=(-i)
  if [ -t 1 ]; then terminal+=(-t); fi
fi

# Numeric Docker users may have no passwd entry or writable home directory.
# The run stays in the foreground but off exec: the traps above must stay in
# place so a signal stops this run's own container at once, and the EXIT
# trap removes that container however the build ends (--rm removes it too).
"${engine[@]}" run --init --rm --name "$container_name" --cidfile "$cidfile" \
  "${user_args[@]}" "${mounts[@]}" "${extra_vols[@]}" -w "$dir" \
  -e HOME=/tmp -e XDG_CACHE_HOME=/tmp/.cache \
  -e CLL_BUILD_VERSION="$build_version" "${terminal[@]}" "$image_id" \
  ./scripts/container-command.sh ./cll_build "${args[@]}" &
child=$!
run_rc=0
wait "$child" || run_rc=$?
child=0
exit "$run_rc"
