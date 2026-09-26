#!/bin/bash
# The PDF running head and the ePub must name this edition, from .env, and
# never the first edition (issue #121). This check runs without a book build:
# it reads the stylesheet and the ePub templates, and it fills the templates
# the way scripts/build_epub.sh does.

set -e
cd "$(dirname "$0")/.."

fail=0
bad() { echo "FAIL $*"; fail=1; }

# 1. No stylesheet or ePub template names a book. The book text itself can
#    still name the first edition, so chapters/ is out of scope.
if grep -n 'Complete Lojban Language' assets/css/*.css epub/*.s[0-9] epub/*.html; then
  bad "a stylesheet or an ePub template names the first edition"
fi

# 2. The left-hand running head takes the title from the title page.
grep -q 'content: string(booktitle, first);' assets/css/master.css ||
  bad "the left-hand running head of master.css does not use string(booktitle)"
grep -q 'booktitle content()' assets/css/master.css ||
  bad "master.css does not set the string booktitle from the title page"

# 3. The filled templates carry the title and the publisher from .env.
read_var() {
  grep "^$1=" .env | head -n 1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}
export TITLE="$(read_var TITLE)"
export PUBLISHER="$(read_var PUBLISHER)"
export REVISER="$(read_var REVISER)"
export AUTHOR="John Woldemar Cowan"
[ -n "$TITLE" ] || bad ".env has no TITLE"
[ -n "$PUBLISHER" ] || bad ".env has no PUBLISHER"
[ -n "$REVISER" ] || bad ".env has no REVISER"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for t in content.opf.s1 toc.xhtml.s1 cover.html; do
  ruby scripts/epub_branding.rb fill <"epub/$t" >"$tmp/$t"
  if grep -n 'REPLACETITLE\|REPLACEFILEAS\|REPLACEPUBLISHER\|REPLACEREVISER' "$tmp/$t"; then
    bad "epub/$t keeps a placeholder after filling"
  fi
  grep -qF "$TITLE" "$tmp/$t" || bad "epub/$t does not name the title from .env"
done
grep -qF "<dc:publisher>$PUBLISHER</dc:publisher>" "$tmp/content.opf.s1" ||
  bad "content.opf.s1 does not name the publisher from .env"
grep -qF "<dc:contributor id=\"reviser\">$REVISER</dc:contributor>" "$tmp/content.opf.s1" ||
  bad "content.opf.s1 does not name the reviser from .env"
if grep -n 'urn:isbn:' "$tmp/content.opf.s1"; then
  bad "content.opf.s1 uses an ISBN, but this edition has none"
fi

# 4. The title page and the cover credit the reviser from .env.
grep -q '^revised by \$reviser$' scripts/merge.sh ||
  bad "scripts/merge.sh does not print \"revised by \$reviser\" on the title page"
grep -q 'reviser=\$(read_var REVISER .env)' scripts/merge.sh ||
  bad "scripts/merge.sh does not read REVISER from .env"

# 5. The generated cover is well-formed SVG and names the title.
ruby scripts/epub_branding.rb cover >"$tmp/cover.svg"
python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "$tmp/cover.svg" ||
  bad "the generated cover is not well-formed XML"
grep -qF ">revised by $REVISER<" "$tmp/cover.svg" ||
  bad "the cover does not show \"revised by $REVISER\""
for word in $TITLE; do
  grep -qF ">$word<" "$tmp/cover.svg" || grep -qF " $word<" "$tmp/cover.svg" ||
    grep -qF ">$word " "$tmp/cover.svg" || bad "the cover does not show the word $word of the title"
done

if [ "$fail" = 0 ]; then
  echo "check-edition-branding: the running head and the ePub name \"$TITLE\""
fi
exit $fail
