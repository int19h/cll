#!/bin/bash
# Bash 3.2 treats empty arrays as unset, so keep nounset disabled.
set -eo pipefail

# Select one engine; do not fall back when the selected engine is unavailable.
container_bin=${CONTAINER_BIN:-$(command -v podman || command -v docker || true)}
engine=()
read -r -a engine <<< "$container_bin"
if [ "${#engine[@]}" -eq 0 ]; then
  echo 'Install Podman or Docker, or set CONTAINER_BIN to a container command.' >&2
  exit 1
fi
if ! "${engine[@]}" info >/dev/null 2>&1; then
  echo "Container command '$container_bin info' failed. Check that the selected engine is running and accessible." >&2
  exit 1
fi

repo=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$repo/build"
build=$(realpath "$repo/build")
args=("$@")
mounts=(-v "$repo:$repo" -v "$build:$build")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    -t|-s|-n) ;;
    -a)
      ((i+=1))
      if [ "$i" -ge "${#args[@]}" ] || [ -z "${args[i]}" ]; then
        echo '-a requires an output directory.' >&2
        exit 2
      fi
      mkdir -p -- "${args[i]}"
      args[i]=$(realpath "${args[i]}")
      mounts+=(-v "${args[i]}:${args[i]}") ;;
    -*)
      echo 'Supported options: -t, -s, -n, and -a DIRECTORY, followed by chapter paths.' >&2
      exit 2 ;;
  esac
done
# The image ID and unnamed disposable container avoid shared tags and names.
build_version=$(cd "$repo" && scripts/build-version.sh)
image=$("${engine[@]}" build --quiet -f "$repo/Dockerfile.context" "$repo")
user_args=(--user "$(id -u):$(id -g)")
if "${engine[@]}" --version | grep -qi podman; then
  user_args=(--userns=keep-id)
fi
terminal=()
if [ -t 0 ]; then
  terminal+=(-i)
  if [ -t 1 ]; then terminal+=(-t); fi
fi
exec "${engine[@]}" run --init --rm "${terminal[@]}" "${user_args[@]}" "${mounts[@]}" \
  -e HOME=/tmp -e CLL_BUILD_VERSION="$build_version" \
  -w "$repo" "$image" \
  ./scripts/container-command.sh ./cll_build -n -T pdf_context "${args[@]}"
