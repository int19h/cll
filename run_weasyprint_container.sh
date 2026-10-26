#!/usr/bin/env bash
# Keep this backend independent of run_container.sh's shared image and name.
set -euo pipefail
repo_dir=$(dirname "$(readlink -f "$0")")
cd "$repo_dir"
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo 'Usage: ./run_weasyprint_container.sh [-t|-s] [chapters/NN.xml ...]'
      echo 'Builds build/cll-weasyprint.pdf. A build/ symlink can point outside the checkout.'
      exit 0 ;;
    -t|-s) ;;
    -*) echo "Unsupported option: $arg" >&2; exit 2 ;;
  esac
done
container_bin=${CONTAINER_BIN:-}
if [ -z "$container_bin" ]; then
  container_bin=$(command -v podman || command -v docker)
fi
mkdir -p build
build_dir=$(readlink -f build)
mkdir -p "$build_dir/tmp" "$build_dir/cache"
exec 9>"$build_dir/.weasyprint.lock"
flock -n 9 || { echo 'A WeasyPrint build already uses this build directory.' >&2; exit 1; }
workspace_id=$(printf '%s' "$repo_dir" | sha256sum | cut -c1-16)
image="localhost/cll-weasyprint:$workspace_id"
"$container_bin" build -t "$image" -f "$repo_dir/Dockerfile.weasyprint" "$repo_dir/scripts/weasyprint"
user_args=(--user "$(id -u):$(id -g)")
if "$container_bin" --version | grep -qi podman; then
  user_args=(--userns=keep-id)
fi
# Mount the symlink target at the same absolute path, so it resolves in-container.
mount_args=(-v "$repo_dir:/srv/cll")
if [ -L build ]; then
  mount_args+=(-v "$build_dir:$build_dir")
fi
"$container_bin" run --rm "${user_args[@]}" "${mount_args[@]}" \
  -e TMPDIR=/srv/cll/build/tmp -e XDG_CACHE_HOME=/srv/cll/build/cache \
  "$image" ./cll_build -n -T pdf_weasyprint "$@"
