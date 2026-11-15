chcon -R -t container_file_t .
scripts/safe-rm-tree.sh --root "$(dirname "$PWD")" "$PWD/build" && ./run_container.sh -d && cp -avr build ~/public_html/cll
restorecon -FRv ~/public_html/cll
