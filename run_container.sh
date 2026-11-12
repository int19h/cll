#!/bin/bash

# Bash 3.2 treats empty arrays as unset, so keep nounset disabled.
set -eo pipefail

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

script_path=$(readlink -f "$0")
dir=${script_path%/*}
dir=${dir:-/}
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
"${engine[@]}" kill cll_build >/dev/null 2>&1 || true
"${engine[@]}" rm cll_build >/dev/null 2>&1 || true

mounts=(-v "$dir:$dir" -v "$build_dir:$build_dir")
build_version=$("$dir/scripts/build-version.sh") || exit 1

# FOR TESTING; forces complete container rebuild
# "${engine[@]}" build --no-cache -t lojban/cll_build -f Dockerfile .
# "${engine[@]}" rmi lojban/cll_build
echo "Running container image build; this may take a while."
echo
"${engine[@]}" build -t lojban/cll_build -f "$dir/Dockerfile" "$dir" >/tmp/rc.$$ 2>&1 || {
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
}

rm -f /tmp/rc.$$

user_args=(--user "$(id -u):$(id -g)")
if "${engine[@]}" --version | grep -qi podman; then
  user_args=(--userns=keep-id)
fi
terminal=()
if [ -t 0 ]; then
  terminal+=(-i)
  if [ -t 1 ]; then terminal+=(-t); fi
fi

# Numeric Docker users may have no passwd entry or writable home directory.
exec "${engine[@]}" run --init --name cll_build \
  "${user_args[@]}" "${mounts[@]}" "${extra_vols[@]}" -w "$dir" \
  -e HOME=/tmp -e XDG_CACHE_HOME=/tmp/.cache \
  -e CLL_BUILD_VERSION="$build_version" "${terminal[@]}" lojban/cll_build \
  ./scripts/container-command.sh ./cll_build "${args[@]}"
