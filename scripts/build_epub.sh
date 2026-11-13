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

# Clean up HTML headers and crap to make epubchek happy
for file in $(find $epubbuilddir/ -name '*.html')
do
  sed -i -r -e '/^\s*(<!DOCTYPE|<script|<meta) /d' \
    -e 's;^\s*<[?]xml .*;<?xml version="1.0" encoding="UTF-8"?>;' \
    -e 's;^\s*<html .*;<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">;' \
    -e 's;\s+summary="[^"]*";;' "$file"

  # Kindle chokes badly on dl/dt/dd nesting, so we just replace it throughout and fake it with CSS
  sed -i -r -e 's;<dl(( )class="([^"]*)")?>;<ul class="dl\2\3">;g' -e 's;</dl>;</ul>;g' \
    -e 's;<d([dt])(( )class="([^"]*)")?>;<li class="d\1\3\4">;g' -e 's;</d[dt]>;</li>;g' \
    "$file"

  grep '<d[ltd]' "$file" && echo "BAD: $file still has dl/dt/dd elements!"
done
# More of the same, it really wants a dd for every dt
cat build/epub/index.html | ruby -e 'puts STDIN.read.gsub(%r{</dt>\s*<dt>}m, "</dt><dd/><dt>").gsub(%r{</dt>\s*</dl>}m, "</dt><dd/></dl>")' > build/epub/index.html.new
mv build/epub/index.html.new build/epub/index.html

rm -f $epubbuilddir/cll.appcache

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
