#!/bin/bash
# Issue #292: validate the whole book with the real glossary, without
# rendering it. A <valsi> word with no dictionary entry becomes a
# glossterm link to a glossary ID that nothing defines, and the release
# build only finds out when xmlto validates the merged book. The usual
# single-chapter builds use -t, whose placeholder glossary defines every
# ID, so they cannot see it.
#
# This script runs the same first steps as the release build: merge all
# chapters with the real glossary (scripts/merge.sh, no -t), preprocess
# (scripts/xml_preprocess.rb), then run the validation command that xmlto
# itself runs before it transforms anything:
#   xmllint --noout --nonet --xinclude --postvalid --noent <file>
# It stops there; no XHTML, ePub, or PDF is rendered.
#
# Usage: scripts/check-whole-book-validation.sh [build-dir]
# The build dir defaults to build/whole-book-validation and is kept.

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

builddir=${1:-build/whole-book-validation}
mkdir -p "$builddir"

# The merged book names its DTD and entities by paths relative to itself
# (dtd/..., xml/iso-pub.ent), so copy them beside it, as the Makefile's
# cll.xml rule does.
cp -pr xml "$builddir/"
cp -pr dtd "$builddir/"

start=$(date +%s)

# cll_build's default chapter set and order.
# shellcheck disable=SC2207
chapters=($(ls chapters/*.xml))

scripts/merge.sh -b "$builddir" "${chapters[@]}" >"$builddir/merge.log" 2>&1 || {
  echo "merge with the real glossary failed; last log lines:" >&2
  tail -n 20 "$builddir/merge.log" >&2
  exit 1
}

ruby scripts/xml_preprocess.rb "$builddir/cll.xml" >"$builddir/cll_processed_xhtml.xml" 2>"$builddir/preprocess.log" || {
  echo "xml_preprocess failed; last log lines:" >&2
  tail -n 20 "$builddir/preprocess.log" >&2
  exit 1
}

if xmllint --noout --nonet --xinclude --postvalid --noent "$builddir/cll_processed_xhtml.xml" 2>"$builddir/validation.log"; then
  echo "whole book validates with the real glossary (took $(( $(date +%s) - start ))s)"
  exit 0
fi

echo "whole-book validation failed (the xmlto validation step):" >&2
cat "$builddir/validation.log" >&2
# --postvalid exits nonzero without naming the errors. A --valid rerun
# names them; the DTD's own element redefinitions are the book header's
# doing and appear on every run, so drop those lines.
xmllint --noout --nonet --valid --noent "$builddir/cll_processed_xhtml.xml" 2>&1 \
  | grep 'validity error' | grep -v 'Redefinition of element' >&2 || true
grep 'NO JBOVLASTE DEFINITION FOUND' "$builddir/merge.log" >&2 || true
exit 1
