#!/bin/bash
# An isolated container launcher for the optional Typst target.
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

script_path=$(readlink -f "$0")
repo=${script_path%/*}
repo=${repo:-/}
mkdir -p "$repo/build"
# Preserve absolute and relative build symlinks by mounting both host paths unchanged.
# Preserve trailing newlines so the whitespace check sees the full path.
builddir=$(realpath "$repo/build" && printf .)
builddir=${builddir%$'\n.'}
case "$repo:$builddir" in
  *[[:space:]]*)
    echo 'Checkout and build directory paths must not contain whitespace. scripts/Makefile does not support it.' >&2
    printf 'Checkout: %s\nBuild directory: %s\n' "$repo" "$builddir" >&2
    exit 2 ;;
esac
key=$(printf '%s' "$repo" | sha256sum | cut -c 1-16)
image="localhost/cll-typst:$key"
args=()
volumes=(-v "$repo:$repo" -v "$builddir:$builddir")
while getopts ':nstSha:' opt; do
  case "$opt" in
    n|s|t|S) args+=("-$opt") ;;
    h)
      echo 'Usage: ./run_typst_container.sh [-s|-t] [-a DIRECTORY] [CHAPTERS...]'
      echo 'Builds pdf_typst only. Each checkout needs its own build directory.'
      exit 0
      ;;
    a)
      if [ -z "$OPTARG" ]; then
        echo '-a requires an output directory.' >&2
        exit 2
      fi
      mkdir -p -- "$OPTARG"
      archive=$(realpath "$OPTARG")
      volumes+=(-v "$archive:/srv/typst-export")
      args+=(-a /srv/typst-export)
      ;;
    *) echo 'Unsupported or incomplete option. Use -h for Typst build usage.' >&2; exit 2 ;;
  esac
done
shift "$((OPTIND - 1))"
args+=("$@")
cd "$repo"
build_version=$(scripts/build-version.sh)
# Podman/Docker assigns a fresh container ID. No shared container is stopped.
"${engine[@]}" build --target typst -t "$image" -f Dockerfile .
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
exec "${engine[@]}" run --init --rm "${terminal[@]}" "${user_args[@]}" "${volumes[@]}" --workdir "$repo" \
  -e HOME=/tmp -e CLL_BUILD_VERSION="$build_version" "$image" ./scripts/container-command.sh ./cll_build -n -T pdf_typst "${args[@]}"
