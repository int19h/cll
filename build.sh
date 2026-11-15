chcon -R -t container_file_t .
mkdir -p build && find "$PWD/build/" -mindepth 1 -maxdepth 1 -exec scripts/safe-rm-tree.sh --root "$PWD/build" {} + && ./run_container.sh -d && cp -avr build ~/public_html/cll
restorecon -FRv ~/public_html/cll
