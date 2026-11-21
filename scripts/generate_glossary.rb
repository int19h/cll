#!/usr/bin/env ruby

require 'rubygems'
require 'optimist'
#require 'yaml'
#require 'highline'
require 'nokogiri'
require 'fileutils'
require 'htmlentities'
require 'digest'
require 'set'

# Initialize our own variables:
mydir=File.expand_path(File.dirname(__FILE__))
testing=""
builddir="build/"
initial_letter=false
new_initial_letter=false
indiv=false


require "#{mydir}/util.rb"

parser = Optimist::Parser.new do
  text "\n\nblah blah blah\n\n---"

  opt :testing, %q{testing mode: will replace all external xrefs in each chapter and turn off the glossary}, :short => 't'
  opt :build_dir, %q{The path of the build dir}, :type => String, :short => 'b'

  stop_on_unknown
end

opts = Optimist::with_standard_exception_handling parser do
  # raise Optimist::HelpNeeded if ARGV.empty? # show help screen
  parser.parse ARGV
end

if opts[:build_dir]
  builddir=opts[:build_dir]
end
# $opts_where=((opts[:where].is_a? String) ? opts[:where].chomp : false)
# $opts_search=((opts[:search].is_a? String) ? opts[:search].chomp : false)

$stderr.puts "\nGenerating glossary entries; this might take a while."

unless opts[:testing]
    $stderr.puts %x{#{mydir}/update_jbovlaste_xml.sh #{builddir}}
    if $?.to_i != 0
      $stderr.puts "jbovlaste file update failed; bailing"
      exit 1
    end
    jbovlaste_tree=Nokogiri::XML(open "#{builddir}/jbovlaste.xml")
    defined_words = jbovlaste_tree.xpath('//valsi').select do |entry|
      !entry.xpath('.//definition').text.strip.empty?
    end.map { |entry| entry['word'] }.to_set
    # A book spelling with no entry of its own may use the entry of a
    # dictionary spelling that differs only in outer pause dots (bare
    # "y" and ".y.", ".lojbangirz." and "lojbangirz"), so a partial build
    # that uses only the book spelling still defines the ID its links
    # point at. The two spellings must otherwise be the same string: an
    # ID match alone is not enough, because slugify also drops the
    # difference between an internal period and an internal comma, and
    # ".i.ov" is not the name ".i,ov". This map keys each defined word
    # by its spelling with outer dots removed.
    bare_spelling = ->(word) { word.sub(/\A\.+/, '').sub(/\.+\z/, '') }
    defined_by_bare = defined_words.group_by { |word| bare_spelling.(word) }
end

coder = HTMLEntities.new

# The cache name covers every input the glossary text depends on. A change to
# this script or to util.rb, or the addition or removal of a pronunciation
# file, must not reuse a glossary written by older code. The button records
# only whether the MP3 is present, so the name list is enough.
audio_dir = File.expand_path('../assets/media/vreji', mydir)
audio_inventory = Dir.glob(File.join(audio_dir, '*.mp3')).select { |path| File.file?(path) }.map { |path| File.basename(path) }.sort
inputs = [__FILE__, File.join(mydir, 'util.rb'), File.join(builddir, 'cll_preglossary.xml')]
inputs << File.join(builddir, 'jbovlaste.xml') unless opts[:testing]
digest = Digest::SHA256.new
inputs.each { |path| digest << Digest::SHA256.file(path).hexdigest << "\n" }
digest << audio_inventory.join("\n") << "\n" << opts[:testing].to_s
glossfile = File.join(builddir, "glossary.xml-#{digest.hexdigest}")
$stderr.puts "glossfile: #{glossfile}; exists: #{File.exist?(glossfile)} size: #{File.size?(glossfile)}"

if File.exist?(glossfile) and File.size?(glossfile) and File.size?(glossfile) > 100
  $stderr.puts "Glossary file already exists; using."
else
  $stderr.puts "Generating new glossary file."
  # write to a temp file and rename, so an interrupted run can never leave
  # a truncated glossary that later runs treat as a valid cache
  File.open(glossfile + ".tmp", 'w') do |gfh|
    tree=Nokogiri::XML(open "#{builddir}/cll_preglossary.xml")
    # A <valsi> wrapped in a cmavo-list <cmavo> or <gismu> cell names the
    # same word as the cell's text. Such a wrapped word is a cell
    # spelling, not body prose: it reaches the grouping only with its
    # own dictionary match, like any other cell word (the "kiha" case
    # below must not remove the entry of body "ki'a", and a wrapped
    # spelling with an entry of its own still counts).
    in_cell = ->(node) do
      node.ancestors.any? do |a|
        %w[cmavo gismu].include?( a.name ) && a.parent && a.parent.name == 'cmavo-entry'
      end
    end
    valsi_nodes = find_lojban_words( tree ).select { |x| x.attributes['valid'].to_s != 'maybe' }
    body_valsi_words = []
    wrapped_valsi_words = []
    valsi_nodes.each do |x|
      if in_cell.( x )
        wrapped_valsi_words << cmavo_list_cell_text( x ).strip
      else
        body_valsi_words << x.text.to_s
      end
    end
    cell_words = find_cmavo_list_words( tree )
    # A cell spelling without an entry of its own must not join a slug
    # group and remove a body word's entry (the "kiha" vs "ki'a" case):
    # only cell words that match the dictionary themselves, exactly or
    # in outer pause dots only, reach the grouping. In testing mode
    # there is no dictionary, so everything counts.
    unless opts[:testing]
      own_match = ->(word) do
        defined_by_bare.fetch( bare_spelling.( word ), [] ).any? do |candidate|
          slugify( candidate ) == slugify( word )
        end
      end
      wrapped_valsi_words = wrapped_valsi_words.select( &own_match )
      cell_words = cell_words.select( &own_match )
    end
    words = body_valsi_words + wrapped_valsi_words + find_frame_words( tree ) + cell_words
    glossary_word_groups(words).each do |slug, spellings|
      # Spellings that slugify to one ID, such as .y. and y, share one
      # entry, and every link uses valsi- plus that same slug. The match
      # is decided per spelling, not per group: a spelling may use an
      # entry only if it matches that dictionary word exactly or differs
      # from it only in outer pause dots. If any spelling in the group
      # has no match of its own, or the spellings match different
      # dictionary words, the group gets no entry at all. Emitting one
      # would define the shared ID and link the unmatched spelling to
      # another word's definition; leaving it undefined fails validation
      # loudly instead. (One ID can join different words: an internal
      # period and an internal comma both become "_", so ".i.ov" and
      # the name ".i,ov" share valsi-i_ov.)
      word = nil
      if opts[:testing]
        word = spellings.first
      else
        own = {}
        spellings.each do |spelling|
          candidates = defined_by_bare.fetch(bare_spelling.(spelling), [])
                                      .select { |candidate| slugify(candidate) == slug }
          own[spelling] = candidates.include?(spelling) ? spelling : candidates.sort.first
        end
        missing = spellings.reject { |spelling| own[spelling] }
        matched = own.values.compact.uniq
        if missing.empty? && matched.size == 1
          word = matched.first
          spellings.each do |spelling|
            if own[spelling] != spelling
              $stderr.puts %Q{\nglossary: "#{spelling}" uses the dictionary spelling "#{word}"}
            end
          end
        else
          if spellings.size > 1
            $stderr.puts %Q{\nglossary: spellings #{spellings.map { |spelling| %Q{"#{spelling}"} }.join(', ')} share the ID "valsi-#{slug}" but do not all match the same dictionary word; no entry emitted}
          end
          missing.each do |spelling|
            $stderr.puts %Q{\n"NO JBOVLASTE DEFINITION FOUND FOR WORD "#{spelling}"}
          end
          next
        end
      end
      unless word
        spellings.each do |spelling|
          $stderr.puts %Q{\n"NO JBOVLASTE DEFINITION FOUND FOR WORD "#{spelling}"}
        end
        next
      end
      $stderr.print "#{word} "
      if ! initial_letter
        # The Lojban words in this introduction are plain foreignphrase, not
        # valsi: a valsi links to its glossary entry, and a partial build
        # (cll_build -s or -t) has no entry for a word its chapters never use.
        gfh.puts %q{
<glossary>
<title>Lojban Words Glossary</title>
<para>All definitions in this glossary are brief and unofficial.
Only the published dictionary is a truly official reference for word
definitions.  These definitions are here simply as a quick reference.
</para>
<para>Many of the definitions repeat the official word lists word for
word, and those lists use the terms of the first edition of this book.
In particular, they say <quote>mass</quote> for what this book calls a
group: the <foreignphrase xml:lang="jbo">gunma</foreignphrase> that
<foreignphrase xml:lang="jbo">loi</foreignphrase>,
<foreignphrase xml:lang="jbo">lei</foreignphrase>, and
<foreignphrase xml:lang="jbo">lai</foreignphrase> refer to.
</para>

<!-- THIS FILE IS AUTOGENERATED.  DO NOT EDIT OR CHECK IN! -->

        }
      end

      #puts "#{word}\t#{slug}"

      new_initial_letter=slug.chars.first.upcase

      if initial_letter != new_initial_letter
        if initial_letter
          gfh.puts "</glossdiv>"
        end
        gfh.puts "<glossdiv><title>#{new_initial_letter}</title>"
        initial_letter=new_initial_letter
      end

      definition=nil
      examples=[]
      if opts[:testing]
        definition="placeholder definition"
      else
        definition=jbovlaste_tree.xpath(%Q{//valsi[@word="#{word}"]}).xpath(".//definition").text.strip.gsub(%r{\s+}, ' ')

        # Fix non-xml chars, *before* we add a bunch
        definition = coder.encode(definition, :basic)

        # Turn LaTeX stuff into xml: $1*10^{-2}$]
        definition.gsub!(%r(\$(1\*)?10\^{?([^}$]*)}?\$)){"<dbinlinemath>#{$1}10<superscript>#{$2}</superscript></dbinlinemath>"}

        # Turn LaTeX stuff into xml: $x_{1}= ; then we stop, and repeat
        # this until there's no matches
        olddef=''
        while olddef != definition
          olddef = definition.clone
          definition.gsub!(%r(\$([a-z]+)_{?([0-9]+)}?(=?)), '<dbinlinemath>\1<subscript>\2</subscript></dbinlinemath>\3$')
        end

        # Clean out the remains of the process above
        definition.gsub!(%r{\$\$},'')

        # puts "#{word}, #{definition}"

        if definition =~ %r{\$|\\}
          $stderr.puts "UNHANDLED LATEX in definition for #{word}: #{definition}"
        end

        if definition =~ %r{^\s*$}
          definition=nil
          $stderr.puts %Q{\n"NO JBOVLASTE DEFINITION FOUND FOR WORD "#{word}"}
        end
        jbovlaste_tree.xpath(%Q{//valsi[@word="#{word}"]}).xpath(".//examples/example").each do |example|
          source = Nokogiri::XML.parse(example.to_s).xpath("//source").text.strip
          translation = Nokogiri::XML.parse(example.to_s).xpath(%Q{//target[@language="English"]/translation}).text.strip
          examples.push("<para>#{source} — #{translation}</para>")
        end
      end
      if examples.length() > 0
        examples = "\n  #{examples.join("\n  ")}"
      else
        examples=""
      end
      mp3file = File.expand_path(File.dirname(__FILE__)+"/../assets/media/vreji/#{slug}.mp3")
      sance_button=""
      if File.file?(mp3file)
        sance_button="<guibutton>#{slug}</guibutton>"
      end
      if definition
        gfh.puts %Q{
<glossentry xml:id="valsi-#{slug}">
<glossterm>#{word}#{sance_button}</glossterm>
<glossdef>
  <para>#{definition}</para>#{examples}
</glossdef>
</glossentry>
        }
      end
    end
    $stderr.puts

    find_lojban_words( tree ).select { |x| x.attributes['valid'].to_s == 'maybe' }.sort { |a,b| slugify(a.text.to_s).downcase <=> slugify(b.text.to_s).downcase }.map { |x| x.text.to_s }.uniq.each do |word|
      $stderr.puts "\nvalid='maybe' found for word #{word}"
    end

    if initial_letter
      gfh.puts %q{

</glossdiv>
</glossary>

      }
    end
  end
  File.rename(glossfile + ".tmp", glossfile)
end

puts File.read(glossfile)
