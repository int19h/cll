#!/bin/bash
# Shared container naming for the run_*_container.sh launchers (issue #297).
#
# Fixed container names and image tags make concurrent builds from different
# checkouts kill each other: `kill cll_build` stops any running build, and
# rebuilding `lojban/cll_build` from another checkout's Dockerfile retags the
# name under the running build. These helpers derive both from the run
# instead, so equal build contexts still share the image cache while
# different ones never share a tag. Source this file; it runs nothing.
#
# Bash 3.2 treats empty arrays as unset, so callers keep nounset disabled.

# Prints the container name for this run. $CLL_CONTAINER_NAME overrides the
# derived name so a caller can pick a stable name for its own run.
cll_container_name() {
  if [ -n "${CLL_CONTAINER_NAME:-}" ]; then
    printf '%s\n' "$CLL_CONTAINER_NAME"
    return 0
  fi
  local dir key
  dir=$1
  key=$(printf '%s' "$dir" | sha256sum | cut -c1-12)
  printf 'cll_build_%s_%s\n' "$key" "$$"
}

# Prints a content hash for an image build: the Dockerfile, every local file
# its COPY and ADD instructions take from the context directory, and any
# extra words (such as a build target). COPY steps with --from take their
# files from another build stage rather than the context, so they contribute
# nothing. Remote ADD sources have no local file; the Dockerfile line that
# names them is already part of the hash.
cll_image_tag() {
  local dockerfile context tmp extra line from_stage srcs token src match found
  dockerfile=$1
  context=$2
  shift 2
  tmp=$(mktemp) || return 1
  sha256sum < "$dockerfile" > "$tmp"
  for extra in "$@"; do
    printf '%s\0' "$extra" >> "$tmp"
  done
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      COPY\ *|ADD\ *)
        from_stage=
        srcs=
        for token in $line; do
          case "$token" in
            COPY|ADD) ;;
            --from=*) from_stage=1 ;;
            --*) ;;
            *) srcs="$srcs $token" ;;
          esac
        done
        [ -n "$from_stage" ] && continue
        # The last word is the destination, not a source.
        srcs=${srcs% *}
        src=
        for src in $srcs; do
          case "$src" in
            *://*) continue ;;
          esac
          # Expand Dockerfile globs against the context directory. Record
          # each source under its context-relative name plus its content,
          # so equal contexts share the tag at any absolute path.
          match=
          for match in "$context"/$src; do
            if [ -e "$match" ]; then
              if [ -d "$match" ]; then
                found=
                for found in $(find "$match" -type f | LC_ALL=C sort); do
                  printf '%s\0' "${found#$context/}" >> "$tmp"
                  sha256sum < "$found" >> "$tmp"
                done
              else
                printf '%s\0' "${match#$context/}" >> "$tmp"
                sha256sum < "$match" >> "$tmp"
              fi
            else
              echo "cll_image_tag: no such COPY source: $src" >&2
              rm -f "$tmp"
              return 1
            fi
          done
        done
        ;;
    esac
  done < "$dockerfile"
  sha256sum "$tmp" | cut -c1-16
  rm -f "$tmp"
}
