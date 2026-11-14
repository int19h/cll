#!/bin/bash

set -e

if [ ! "$1" ]
then
  echo "Give base dir as sole argument."
  exit 1
fi
basedir="$1"
builddir="$basedir/build"
epubbuilddir="$builddir/epub"
srcdir="$basedir/epub"

# The title and the publisher come from .env, like the title page that
# scripts/merge.sh makes. No template names the book.
read_var() {
  grep "^$1=" "$basedir/.env" | head -n 1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}
export TITLE="$(read_var TITLE)"
export PUBLISHER="$(read_var PUBLISHER)"
export PUBLISHER_DISCLAIMER="$(read_var PUBLISHER_DISCLAIMER)"
export REVISER="$(read_var REVISER)"
export AUTHOR="John Woldemar Cowan"
brand="ruby $basedir/scripts/epub_branding.rb"

rm -rf $epubbuilddir/
mkdir $epubbuilddir/

# cp -pr epub/META-INF epub/content.opf epub/mimetype epub/toc.xhtml epub-temp
cp -pr $srcdir/META-INF $srcdir/mimetype $epubbuilddir/
cp -pr $builddir/epub-xhtml/* $epubbuilddir/
rm -rf $epubbuilddir/dtd
# Keep the ConTeXt renderer's source files out of the reader package.
rm -rf "$epubbuilddir/assets/context"

# Each content page: drop scripts, rename lists, and write the ePub contract.
html_pages=()
while IFS= read -r -d '' page
do
  html_pages+=("$page")
done < <(find "$epubbuilddir" -name '*.html' -print0)
if [ "${#html_pages[@]}" -eq 0 ]
then
  echo "No HTML pages in $epubbuilddir ; bailing."
  exit 1
fi
ruby "$basedir/scripts/epub_pages.rb" "${html_pages[@]}"

# The stylesheet run wrote the finished navigation document (issue #208).
navdir="$builddir/epub-nav"
for navfile in toc.xhtml spine.txt
do
  if [ ! -f "$navdir/$navfile" ]
  then
    echo "The navigation file $navdir/$navfile is missing ; bailing."
    exit 1
  fi
done
cp -p "$navdir/toc.xhtml" "$epubbuilddir/toc.xhtml"

version="$(xmllint --nonet --loaddtd --xpath 'normalize-space(/*[local-name()="book"]/*[local-name()="info"]/*[local-name()="releaseinfo"])' "$builddir/cll.xml")"
RELEASEINFO="$version" $brand fill <$srcdir/content.opf.s1 | \
  sed "s/REPLACEDATE/$(date -u +%Y-%m-%dT%H:%M:%SZ)/" >$epubbuilddir/content.opf

cd $epubbuilddir/

for file in $(find -type f | grep -P -v '/(mimetype|toc.xhtml|final.css|content.opf|META-INF.*)$' | sed 's;^.\/;;')
do
  type=""
  if [[ $file =~ \.png$ ]]
  then
    type="image/png"
  elif [[ $file =~ \.otf$ ]]
  then
    type="application/x-font-opentype"
  elif [[ $file =~ \.gif$ ]]
  then
    type="image/gif"
  elif [[ $file =~ \.css$ ]]
  then
    type="text/css"
  elif [[ $file =~ \.svg$ ]]
  then
    type="image/svg"
  elif [[ $file =~ \.html$ ]]
  then
    type="application/xhtml+xml"
  fi

  properties=""
  if grep -q '<math' $file
  then
    properties="properties=\"mathml\""
  fi

  if [ ! "$type" ]
  then
    echo "No type found for $file ; bailing."
    exit 1
  fi

  id="$(echo $file | tr -d '_./-')"
  echo "<item id=\"$id\" $properties href=\"$file\" media-type=\"$type\"/>" >>$epubbuilddir/content.opf
done

cat $srcdir/content.opf.s2 >>$epubbuilddir/content.opf

# The spine is the stylesheet's own list of the pages, in reading order.
while IFS= read -r ref || [ -n "$ref" ]
do
  [ -n "$ref" ] || continue
  if [ ! -f "$epubbuilddir/$ref" ]
  then
    echo "Spine file $ref is not in the package ; bailing."
    exit 1
  fi
  id="$(echo $ref | tr -d '_./-')"
  echo "<itemref linear=\"yes\" idref=\"$id\"/>" >>$epubbuilddir/content.opf
done <"$navdir/spine.txt"

cat $srcdir/content.opf.s3 >>$epubbuilddir/content.opf

$brand cover >$epubbuilddir/assets/media/cover.svg
$brand fill <$srcdir/cover.html >$epubbuilddir/cover.html

rm -f $basedir/build/cll.epub

zip -q -X -r $basedir/build/cll.epub mimetype *
