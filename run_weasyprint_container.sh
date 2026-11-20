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
. "$repo_dir/scripts/container-names.sh"
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
cll_take_lock "$build_dir/.weasyprint.lock" \
  'A WeasyPrint build already uses this build directory.'
# One tag per checkout, as before issue #297. The build also attaches a
# second tag that is unique to this run and keeps the image referenced
# until this run's container exists. The image ID file lives in a private
# directory, so a root-owned file never lands where this user cannot remove
# it (as with CONTAINER_BIN="sudo docker"). Signal handling, background
# execution, and cleanup are shared with the other launchers
# (see scripts/container-names.sh).
workspace_id=$(printf '%s' "$repo_dir" | sha256sum | cut -c1-16)
image="localhost/cll-weasyprint:$workspace_id"
cll_run_tag="$image-run-$$"
image_dir=$(mktemp -d "${TMPDIR:-/tmp}/cll-image.XXXXXXXX") || exit 1
iidfile=$image_dir/image-id
remove_run_files() {
  rm -f "$image_dir/container-id" "$iidfile"
  rmdir "$image_dir" 2>/dev/null || true
}
cll_cidfile=$image_dir/container-id
cll_install_traps
build_rc=0
cll_run_bg "${engine[@]}" build -t "$image" -t "$cll_run_tag" --iidfile "$iidfile" -f "$repo_dir/Dockerfile.weasyprint" "$repo_dir/scripts/weasyprint" || build_rc=$?
# Run the immutable image this build produced, not the tag: another checkout
# can retag the name under this run between the build and the run.
if [ "$build_rc" -ne 0 ]; then
  echo "Container image build failed." >&2
  exit 1
fi
image_id=$(cat "$iidfile" 2>/dev/null) || image_id=
if [ -z "$image_id" ]; then
  echo "Container image build did not report its ID." >&2
  exit 1
fi
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
# Preserve the checkout and build paths, including external relative symlinks.
mount_args=(-v "$repo_dir:$repo_dir" -v "$build_dir:$build_dir")
terminal=()
if [ -t 0 ]; then
  terminal+=(-i)
  if [ -t 1 ]; then terminal+=(-t); fi
fi
# The run stays in the foreground but off exec, through the shared helper:
# the traps stay in place so a signal stops this run's own container at
# once, and the EXIT trap removes that container however the build ends.
run_rc=0
cll_run_bg "${engine[@]}" run --init --rm --cidfile "$image_dir/container-id" "${terminal[@]}" "${user_args[@]}" "${mount_args[@]}" "${extra_vols[@]}" \
  -w "$repo_dir" -e TMPDIR="$build_dir/tmp" -e XDG_CACHE_HOME="$build_dir/cache" \
  -e HOME=/tmp -e CLL_BUILD_VERSION="$build_version" \
  "$image_id" ./scripts/container-command.sh ./cll_build -n -T pdf_weasyprint "${args[@]}" || run_rc=$?
exit "$run_rc"
