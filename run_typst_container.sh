#!/bin/bash
# An isolated container launcher for the optional Typst target.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$repo"
container_bin=${CONTAINER_BIN:-}
if [ -z "$container_bin" ]; then
  container_bin=$(command -v podman || command -v docker || true)
fi
if [ -z "$container_bin" ] || ! "$container_bin" info >/dev/null 2>&1; then
  echo 'Start podman or Docker, or set CONTAINER_BIN to a working container command.' >&2
  exit 1
fi
mkdir -p build
# Preserve absolute and relative build symlinks by mounting both host paths unchanged.
builddir=$(realpath build)
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
      mkdir -p "$OPTARG"
      archive=$(realpath "$OPTARG")
      volumes+=(-v "$archive:/srv/typst-export")
      args+=(-a /srv/typst-export)
      ;;
    *) echo 'Unsupported or incomplete option. Use -h for Typst build usage.' >&2; exit 2 ;;
  esac
done
shift "$((OPTIND - 1))"
args+=("$@")
# Podman/Docker assigns a fresh container ID. No shared container is stopped.
"$container_bin" build --target typst -t "$image" -f Dockerfile .
user_args=(--user "$(id -u):$(id -g)")
if [[ $(basename "$container_bin") == podman ]]; then user_args=(--userns=keep-id); fi
terminal=()
if [[ -t 0 && -t 1 ]]; then terminal=(-it); fi
exec "$container_bin" run --rm "${terminal[@]}" "${user_args[@]}" "${volumes[@]}" --workdir "$repo" \
  "$image" ./cll_build -n -T pdf_typst "${args[@]}"
