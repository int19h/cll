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
. "$repo/scripts/container-names.sh"
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
# One tag per checkout, as before issue #297. The build also attaches a
# second tag that is unique to this run and keeps the image referenced
# until this run's container exists.
key=$(printf '%s' "$repo" | sha256sum | cut -c 1-16)
image="localhost/cll-typst:$key"
cll_run_tag="$image-run-$$"
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
# This run's files live in a private directory, so a root-owned image ID
# file never lands where this user cannot remove it (as with
# CONTAINER_BIN="sudo docker"). Traps go in right after it, before the
# first engine call, and cover a failed build as well as the run. Signal
# handling, background execution, and cleanup are shared with the other
# launchers (see scripts/container-names.sh).
image_dir=$(mktemp -d "${TMPDIR:-/tmp}/cll-image.XXXXXXXX") || exit 1
iidfile=$image_dir/image-id
remove_run_files() {
  rm -f "$image_dir/container-id" "$iidfile"
  rmdir "$image_dir" 2>/dev/null || true
}
cll_cidfile=$image_dir/container-id
cll_install_traps
# Podman/Docker assigns a fresh container ID. No shared container is stopped.
build_rc=0
cll_run_bg "${engine[@]}" build --target typst -t "$image" -t "$cll_run_tag" --iidfile "$iidfile" -f Dockerfile . || build_rc=$?
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
terminal=()
if [ -t 0 ]; then
  terminal+=(-i)
  if [ -t 1 ]; then terminal+=(-t); fi
fi
# The run stays in the foreground but off exec, through the shared helper:
# the traps stay in place so a signal stops this run's own container at
# once, and the EXIT trap removes that container however the build ends.
run_rc=0
cll_run_bg "${engine[@]}" run --init --rm --cidfile "$image_dir/container-id" "${terminal[@]}" "${user_args[@]}" "${volumes[@]}" --workdir "$repo" \
  -e HOME=/tmp -e CLL_BUILD_VERSION="$build_version" "$image_id" ./scripts/container-command.sh ./cll_build -n -T pdf_typst "${args[@]}" || run_rc=$?
exit "$run_rc"
