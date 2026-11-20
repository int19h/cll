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
# that is not a plain container name before calling the engine. Validate the
# raw override: command substitution would silently drop trailing newlines.
if [ -n "${CLL_CONTAINER_NAME:-}" ]; then
  if ! cll_valid_container_name "$CLL_CONTAINER_NAME"; then
    echo "Invalid container name '$CLL_CONTAINER_NAME'. Set CLL_CONTAINER_NAME to letters, digits, '_', '.' and '-', starting with a letter or digit." >&2
    exit 2
  fi
  container_name=$CLL_CONTAINER_NAME
else
  container_name=$(cll_container_name "$dir")
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
# engine in a private directory made just for this run. Cleanup uses only
# that ID, never the name, so it can neither touch another run's container
# nor miss this run's own. There is no startup removal: an occupied name is
# the engine's error. The signal handling, background execution, and
# cleanup below are shared with the other launchers (see container-names.sh).
rundir=$(mktemp -d "${TMPDIR:-/tmp}/cll-run.XXXXXXXX") || exit 1
cidfile=$rundir/container-id
iidfile=$rundir/image-id
rclog=$rundir/build.log
remove_run_files() {
  rm -f "$cidfile" "$iidfile" "$rclog"
  rmdir "$rundir" 2>/dev/null || true
}
cll_cidfile=$cidfile
cll_run_tag=
cll_install_traps
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
cll_take_lock "$build_dir/.container.lock" \
  "Another build already uses this checkout's build directory ($build_dir)."
mounts=(-v "$dir:$dir" -v "$build_dir:$build_dir")
build_version=$("$dir/scripts/build-version.sh") || exit 1

# One fixed tag for every build (issue #297), spelled out in full so the
# reference is always explicit. The build also attaches a second tag that
# is unique to this run and keeps the image referenced until this run's
# container exists, even if another checkout rebuilds the shared tag in
# between (Docker's containerd store can otherwise drop the image at once).
# Cleanup removes only the run tag, never any other tag.
# scripts/diff_upstream names the same tag.
image="lojban/cll_build:latest"
cll_run_tag="lojban/cll_build:run-$$"

# FOR TESTING; forces complete container rebuild
# "${engine[@]}" build --no-cache -t "$image" -f Dockerfile .
# "${engine[@]}" rmi "$image"
echo "Running container image build; this may take a while."
echo "Image tag: $image"
echo "Container name: $container_name"
echo
build_rc=0
cll_run_bg "${engine[@]}" build -t "$image" -t "$cll_run_tag" --iidfile "$iidfile" -f "$dir/Dockerfile" "$dir" >"$rclog" 2>&1 || build_rc=$?
# The build log lives in the private run directory, so an interrupted build
# leaves no file behind either: the traps remove it.
if [ "$build_rc" -ne 0 ]; then
  echo "Container image build failed.  Here's the output: "
  echo
  cat "$rclog"
  echo
  echo
  echo "Container image build failed.  Output is above."
  echo
  echo
  exit 1
fi

# Run the immutable image this build produced, not the tag: another checkout
# can retag the name under this run between the build and the run.
image_id=$(cat "$iidfile" 2>/dev/null) || image_id=
if [ -z "$image_id" ]; then
  echo "Container image build did not report its ID." >&2
  exit 1
fi
echo "Image ID: $image_id"

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
# The run stays in the foreground but off exec, through the shared helper:
# the traps stay in place so a signal stops this run's own container at
# once, and the EXIT trap removes that container however the build ends
# (--rm removes it too). The helper attaches the launcher's own standard
# input: without it, the engine would read /dev/null even with a terminal.
run_rc=0
cll_run_bg "${engine[@]}" run --init --rm --name "$container_name" --cidfile "$cidfile" \
  "${user_args[@]}" "${mounts[@]}" "${extra_vols[@]}" -w "$dir" \
  -e HOME=/tmp -e XDG_CACHE_HOME=/tmp/.cache \
  -e CLL_BUILD_VERSION="$build_version" "${terminal[@]}" "$image_id" \
  ./scripts/container-command.sh ./cll_build "${args[@]}" || run_rc=$?
exit "$run_rc"
