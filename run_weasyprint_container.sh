#!/usr/bin/env bash
# Keep this backend independent of run_container.sh's shared image and name.
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
repo_dir=${script_path%/*}
repo_dir=${repo_dir:-/}
args=("$@")
extra_vols=()
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    -h|--help)
      echo 'Usage: ./run_weasyprint_container.sh [-t|-s] [-a DIRECTORY] [chapters/NN.xml ...]'
      echo 'Builds build/cll-weasyprint.pdf. A build/ symlink can point outside the checkout.'
      exit 0 ;;
    -t|-s|-n) ;;
    -a)
      ((i+=1))
      if [ "$i" -ge "${#args[@]}" ] || [ -z "${args[i]}" ]; then
        echo '-a requires an output directory.' >&2
        exit 2
      fi
      mkdir -p -- "${args[i]}"
      archive=$(realpath -- "${args[i]}")
      destination="/tmp/cll-export-$i"
      extra_vols+=(-v "$archive:$destination")
      args[i]=$destination ;;
    -*) echo "Unsupported option: ${args[i]}" >&2; exit 2 ;;
  esac
done
cd "$repo_dir"
mkdir -p build
# Preserve trailing newlines so the whitespace check sees the full path.
build_dir=$(readlink -f build && printf .)
build_dir=${build_dir%$'\n.'}
case "$repo_dir:$build_dir" in
  *[[:space:]]*)
    echo 'Checkout and build directory paths must not contain whitespace. scripts/Makefile does not support it.' >&2
    printf 'Checkout: %s\nBuild directory: %s\n' "$repo_dir" "$build_dir" >&2
    exit 2 ;;
esac
build_version=$(scripts/build-version.sh)
mkdir -p "$build_dir/tmp" "$build_dir/cache"
exec 9>"$build_dir/.weasyprint.lock"
flock -n 9 || { echo 'A WeasyPrint build already uses this build directory.' >&2; exit 1; }
workspace_id=$(printf '%s' "$repo_dir" | sha256sum | cut -c1-16)
image="localhost/cll-weasyprint:$workspace_id"
"${engine[@]}" build -t "$image" -f "$repo_dir/Dockerfile.weasyprint" "$repo_dir/scripts/weasyprint"
user_args=(--user "$(id -u):$(id -g)")
if "${engine[@]}" --version | grep -qi podman; then
  user_args=(--userns=keep-id)
fi
# Preserve the checkout and build paths, including external relative symlinks.
mount_args=(-v "$repo_dir:$repo_dir" -v "$build_dir:$build_dir")
terminal=()
if [ -t 0 ]; then
  terminal+=(-i)
  if [ -t 1 ]; then terminal+=(-t); fi
fi
exec "${engine[@]}" run --init --rm "${terminal[@]}" "${user_args[@]}" "${mount_args[@]}" "${extra_vols[@]}" \
  -w "$repo_dir" -e TMPDIR="$build_dir/tmp" -e XDG_CACHE_HOME="$build_dir/cache" \
  -e HOME=/tmp -e CLL_BUILD_VERSION="$build_version" \
  "$image" ./scripts/container-command.sh ./cll_build -n -T pdf_weasyprint "${args[@]}"
