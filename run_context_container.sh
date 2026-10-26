#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")" && pwd)
if [ -n "${CONTAINER_BIN:-}" ]; then
  container=$CONTAINER_BIN
elif command -v podman >/dev/null; then
  container=podman
else
  container=docker
fi
"$container" info >/dev/null
mkdir -p "$repo/build"
build=$(realpath "$repo/build")
args=("$@")
mounts=(-v "$repo:$repo" -v "$build:$build")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    -t|-s|-n) ;;
    -a)
      ((i+=1))
      if [ "$i" -ge "${#args[@]}" ]; then
        echo '-a requires an output directory.' >&2
        exit 2
      fi
      mkdir -p "${args[i]}"
      args[i]=$(realpath "${args[i]}")
      mounts+=(-v "${args[i]}:${args[i]}") ;;
    -*)
      echo 'Supported options: -t, -s, -n, and -a DIRECTORY, followed by chapter paths.' >&2
      exit 2 ;;
  esac
done
# The image ID and unnamed disposable container avoid shared tags and names.
"$container" build --iidfile "$build/context-image.id" -f "$repo/Dockerfile.context" "$repo"
user_args=(--user "$(id -u):$(id -g)")
if [[ $(basename "$container") == podman ]]; then
  user_args=(--userns=keep-id)
fi
"$container" run --rm "${user_args[@]}" "${mounts[@]}" \
  -w "$repo" "$(cat "$build/context-image.id")" \
  ./cll_build -n -T pdf_context "${args[@]}"
