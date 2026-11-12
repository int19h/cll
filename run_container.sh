#!/bin/bash

set -euo pipefail

# Select one engine; do not fall back when the selected engine is unavailable.
CONTAINER_BIN=${CONTAINER_BIN:-$(command -v podman || command -v docker || true)}
if [ -z "$CONTAINER_BIN" ]; then
  echo 'Install Podman or Docker, or set CONTAINER_BIN to a container command.' >&2
  exit 1
fi
if ! "$CONTAINER_BIN" info >/dev/null 2>&1; then
  echo "Container command '$CONTAINER_BIN info' failed. Check that the selected engine is running and accessible." >&2
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

"$CONTAINER_BIN" kill cll_build >/dev/null 2>&1 || true
"$CONTAINER_BIN" rm cll_build >/dev/null 2>&1 || true

dir=$(dirname "$(readlink -f "$0")")
mkdir -p "$dir/build"
build_dir=$(realpath "$dir/build")
mounts=(-v "$dir:/srv/cll")
if [ -L "$dir/build" ]; then
  mounts+=(-v "$build_dir:$build_dir")
fi
build_version=$("$dir/scripts/build-version.sh") || exit 1

# FOR TESTING; forces complete container rebuild
# $CONTAINER_BIN build --no-cache -t lojban/cll_build -f Dockerfile .
# $CONTAINER_BIN rmi lojban/cll_build
echo "Running container image build; this may take a while."
echo
"$CONTAINER_BIN" build -t lojban/cll_build -f "$dir/Dockerfile" "$dir" >/tmp/rc.$$ 2>&1 || {
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
if "$CONTAINER_BIN" --version | grep -qi podman; then
  user_args=(--userns=keep-id)
fi
terminal=()
if [ -t 0 ]; then terminal=(-it); fi

# Numeric Docker users may have no passwd entry or writable home directory.
exec "$CONTAINER_BIN" run --name cll_build \
  "${user_args[@]}" "${mounts[@]}" "${extra_vols[@]}" \
  -e HOME=/tmp -e XDG_CACHE_HOME=/tmp/.cache \
  -e CLL_BUILD_VERSION="$build_version" "${terminal[@]}" lojban/cll_build \
  ./cll_build "${args[@]}"
