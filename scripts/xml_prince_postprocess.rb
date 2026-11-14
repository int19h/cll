require 'nokogiri'
require 'yaml'

mydir=File.expand_path(File.dirname(__FILE__))
require "#{mydir}/util.rb"

$document = Nokogiri::XML(File.read(ARGV[0])) do |config|
  config.options = Nokogiri::XML::ParseOptions::STRICT | Nokogiri::XML::ParseOptions::NONET
end

# Fix the fact that there are two things named "index" at totally
# different levels.
if $document.css('div.index')
  $document.css('div.index').each do |node|
    first = node.element_children.first
    if first and first.name == 'div' and first[:class] == 'titlepage'
      node[:class] = 'whole-index'
    end
  end
end

# Build the document. The writer keeps empty anchors as end tags, which is
# what Prince's HTML parser requires.
doc = serialize_page($document, mode: :html)

# Hack to work with a seperator, "--CHAPBR--", inserted by xml/docbook2html_config_prince.xsl
#
# There are two cases here.  In this case:
#
#       <h1 class="title"><a id="chapter-letterals"></a>Chapter 2--CHAPBR--As Easy As A-B-C? The Lojban Letteral System And Its Uses</h1>
#
# we want to turn it into a <br/> tag for presentation on the
# chapter title page.
#
# The no-break space may be a raw character or a character reference.
# libxml chooses one or the other. A reference must still match, or the
# following substitution would put a <br /> inside the title attribute.
nbsp = '(?:\u00A0|&#x0*[Aa]0;|&#160;|&nbsp;)'
doc = doc.gsub(%r{title="Chapter#{nbsp}[0-9]+--CHAPBR--}, 'title="')
#
# In this case: 
#
#       <a class="xref" href="#chapter-tour" title="Chapter 1--CHAPBR--COVERAGE: FULL">Chapter 1</a>
#
# we want to remove everything up to and including the --CHAPBR--,
# so that the a's text and title give different information.
#
# The space before the break matters: a bare <br/> leaves the heading's text
# content as "Chapter 21Formal grammars", which is what PDF bookmarks and any
# other text extraction of the heading see. The space separates the two parts
# there while the break still puts them on separate lines in print.
doc = doc.gsub( %r{--CHAPBR--}, ' <br />' )
#
# In both cases, regex is *WAY* easier, and shouldn't cause any
# trouble.

print doc

exit 0
