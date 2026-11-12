#!/bin/bash
# A terminal already delivers signals to its foreground process group.
if [ -t 0 ]; then
  exec "$@"
fi

# Give the build its own process group without requiring another executable.
# Monitor mode also preserves piped stdin for the background command.
set -m
child=
pending_signal=
forward_signal() {
  pending_signal=$1
  if [ -n "$child" ]; then
    kill -s "$1" -- "-$child" 2>/dev/null || true
  fi
}
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM

"$@" &
child=$!
if [ -n "$pending_signal" ]; then forward_signal "$pending_signal"; fi

# A trapped signal interrupts wait before the build necessarily exits.
wait "$child"
result=$?
while kill -0 "$child" 2>/dev/null; do
  wait "$child"
  result=$?
done
exit "$result"
