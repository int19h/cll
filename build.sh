chcon -R -t container_file_t .
# Refuse a build link into the checkout (or to /, home, or a parent of
# the checkout) before cleaning, so the cleanup cannot reach sources.
# The helper and the Makefile repeat checks like these later.
checkout="$(realpath -m -- "$PWD")"
build_res="$(realpath -m -- "$PWD/build")"
case "$build_res" in
  /|"$HOME") echo "build.sh: refusing build folder: $build_res" >&2; exit 1 ;;
esac
case "$checkout" in
  "$build_res"|"$build_res"/*) echo "build.sh: refusing build folder at or above the checkout: $build_res" >&2; exit 1 ;;
esac
case "$build_res" in
  "$checkout"/*)
    if [ "$build_res" != "$checkout/build" ]; then
      echo "build.sh: refusing build link into the checkout: $build_res" >&2; exit 1
    fi ;;
esac
mkdir -p build && find "$PWD/build/" -mindepth 1 -maxdepth 1 -exec scripts/safe-rm-tree.sh --root "$PWD/build" {} + && ./run_container.sh -d && cp -avr build ~/public_html/cll
restorecon -FRv ~/public_html/cll
