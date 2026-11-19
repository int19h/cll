#!/bin/bash
# Shared container naming for the run_*_container.sh launchers (issue #297).
#
# Fixed container names and image tags make concurrent builds from different
# checkouts kill each other: `kill cll_build` stops any running build, and
# rebuilding `lojban/cll_build` from another checkout's Dockerfile retags the
# name under the running build. These helpers derive both from the run
# instead, so equal build inputs still share the image cache while
# different ones never share a tag. Source this file; it runs nothing.
#
# Bash 3.2 treats empty arrays as unset, so callers keep nounset disabled.
# Callers use default glob options; the tag function only relies on the
# caller's directory never leaking into its word splitting (see below).

# Prints the container name for this run. $CLL_CONTAINER_NAME overrides the
# derived name so a caller can pick a stable name of its own. Callers must
# validate an override before passing it to the engine.
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

# True when the argument is a safe container name: letters, digits, '_',
# '.' and '-', starting with a letter or digit. In particular a name never
# starts with a hyphen, so it cannot parse as an engine option.
cll_valid_container_name() {
  case "$1" in
    [a-zA-Z0-9]*)
      case "$1" in
        *[!a-zA-Z0-9_.-]*) return 1 ;;
      esac
      return 0 ;;
  esac
  return 1
}

# Prints a content hash for an image build: the Dockerfile, every local file
# its COPY and ADD instructions take from the context directory, and any
# extra words (such as a build target). COPY steps with --from take their
# files from another build stage rather than the context, so they contribute
# nothing. Remote ADD sources have no local file; the Dockerfile line that
# names them is already part of the hash.
#
# Only plain COPY and ADD lines are supported: no trailing comments, no
# JSON-array form, no quoted names. Anything else fails loudly instead of
# returning a tag, and so does any missing source or unreadable file.
# Supported lines name their sources exactly as the engine resolves them:
# relative to the context directory, with Dockerfile globs expanded there,
# and backslash continuations joined before parsing.
cll_image_tag() {
  local dockerfile context tmp line logical stripped verb rest srcs src
  local match matches found frel n i from_stage token glob_off mode extra
  dockerfile=$1
  context=$2
  shift 2 || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/cll-imagetag.XXXXXXXX") || return 1
  sha256sum < "$dockerfile" > "$tmp" || { rm -f "$tmp"; return 1; }
  for extra in "$@"; do
    printf '%s\0' "$extra" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done
  fail() {
    echo "cll_image_tag: $1" >&2
    rm -f "$tmp"
    return 1
  }
  hash_one() {
    # $1 is a context-relative path of a regular file; $2 its absolute path.
    printf 'f\0%s\0' "$1" >> "$tmp" || return 1
    mode=$(stat -c '%a %u %g' "$2" 2>/dev/null || stat -f '%Lp %u %g' "$2") || return 1
    printf '%s\0' "$mode" >> "$tmp" || return 1
    sha256sum < "$2" >> "$tmp" || return 1
  }
  logical=
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    # A trailing backslash continues the instruction on the next line.
    logical=$logical$line
    case "$logical" in
      *\\) logical=${logical%\\}; continue ;;
    esac
    # Dockerfile keywords are case-insensitive and may be indented.
    stripped=${logical#"${logical%%[![:space:]]*}"}
    logical=
    [ -n "$stripped" ] || continue
    verb=${stripped%%[[:space:]]*}
    case "$verb" in
      [Cc][Oo][Pp][Yy]|[Aa][Dd][Dd]) ;;
      *) continue ;;
    esac
    rest=${stripped#"$verb"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    rest=${rest%"${rest##*[![:space:]]}"}
    [ -n "$rest" ] || { fail "$verb without sources in $dockerfile"; return 1; }
    # Split into words without pathname expansion: globs resolve against
    # the build context below, never the caller's directory.
    srcs=()
    from_stage=
    case $- in *f*) glob_off=1 ;; *) set -f; glob_off= ;; esac
    for token in $rest; do
      case "$token" in
        --from=*) from_stage=1 ;;
        --*) ;;
        *) srcs+=("$token") ;;
      esac
    done
    if [ -z "$glob_off" ]; then set +f; fi
    n=${#srcs[@]}
    if [ "$n" -lt 2 ]; then fail "$verb without destination in $dockerfile"; return 1; fi
    case "${srcs[0]}" in
      \[*) fail "JSON-array $verb is not supported in $dockerfile"; return 1 ;;
    esac
    if [ -n "$from_stage" ]; then continue; fi
    # Every word but the last is a source; the last is the destination.
    i=0
    while [ "$i" -lt $((n - 1)) ]; do
      src=${srcs[$i]}
      case "$src" in
        *://*) i=$((i + 1)); continue ;;
      esac
      # Expand Dockerfile globs against the context directory only.
      matches=( "$context"/$src )
      if [ "${#matches[@]}" -eq 0 ]; then
        fail "no such $verb source in context $context: $src"; return 1
      fi
      for match in "${matches[@]}"; do
        if [ ! -e "$match" ] && [ ! -L "$match" ]; then
          fail "no such $verb source in context $context: $src"; return 1
        fi
        if [ -d "$match" ] && [ ! -L "$match" ]; then
          while IFS= read -r -d '' found; do
            frel=${found#"$context"/}
            if [ -d "$found" ] && [ ! -L "$found" ]; then
              printf 'd\0%s\0' "$frel" >> "$tmp" || { fail "cannot write hash"; return 1; }
              mode=$(stat -c '%a %u %g' "$found" 2>/dev/null || stat -f '%Lp %u %g' "$found") || { fail "cannot stat $frel"; return 1; }
              printf '%s\0' "$mode" >> "$tmp" || { fail "cannot write hash"; return 1; }
            elif [ -r "$found" ]; then
              hash_one "$frel" "$found" || { fail "cannot hash $frel"; return 1; }
            else
              fail "cannot read $frel"; return 1
            fi
          done < <(find "$match" -print0 | LC_ALL=C sort -z)
        elif [ -r "$match" ]; then
          hash_one "${match#"$context"/}" "$match" || { fail "cannot hash $src"; return 1; }
        else
          fail "cannot read $src"; return 1
        fi
      done
      i=$((i + 1))
    done
  # The Dockerfile was already hashed successfully above, so reaching this
  # point means every instruction was accepted; read ends the loop, not an error.
  done < "$dockerfile"
  if [ -n "$logical" ]; then
    fail "unterminated continued line in $dockerfile"
    return 1
  fi
  sha256sum "$tmp" | cut -c1-16
  rm -f "$tmp"
}
