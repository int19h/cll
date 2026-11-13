#!/usr/bin/env ruby
# Check the ePub navigation document and the spine (issue #208).
# usage: check_epub_nav.rb PACKAGE_DIR SPINE_LIST [TITLE]
require 'nokogiri'

XHTML = 'http://www.w3.org/1999/xhtml'
OPS = 'http://www.idpf.org/2007/ops'
OPF = 'http://www.idpf.org/2007/opf'
NS = { 'h' => XHTML, 'epub' => OPS, 'opf' => OPF }

dir, list, title = ARGV
abort 'usage: check_epub_nav.rb PACKAGE_DIR SPINE_LIST [TITLE]' unless dir && list
$errors = []
def bad(message)
  $errors << message
end

def parse(path)
  Nokogiri::XML(File.read(path)) { |c| c.strict.nonet }
end

def text(node)
  node.text.gsub(/\s+/, ' ').strip
end

nav_doc = parse(File.join(dir, 'toc.xhtml'))
navs = nav_doc.xpath('//h:nav[@epub:type="toc"]', NS)
bad "toc.xhtml has #{navs.size} toc nav elements, not 1" unless navs.size == 1
nav = navs.first

# 1. Structure (EPUB 3.3, section 7.3).
lists = nav.xpath('h:ol', NS)
bad 'the nav element does not have exactly one ol child' unless lists.size == 1
nav.xpath('.//h:ol', NS).each do |ol|
  bad "an ol has a child that is not li (line #{ol.line})" unless ol.element_children.all? { |c| c.name == 'li' }
  bad "an ol has no li (line #{ol.line})" if ol.element_children.empty?
end
nav.xpath('.//h:li', NS).each do |li|
  names = li.element_children.map(&:name)
  bad "li at line #{li.line} has children #{names.inspect}" unless names == ['a'] || names == %w[a ol]
  bad "li at line #{li.line} has text outside its link" unless li.xpath('text()').all? { |t| t.text.strip.empty? }
end

entries = nav.xpath('.//h:a', NS).map do |a|
  { href: a['href'].to_s, text: text(a), depth: a.xpath('ancestor::h:ol', NS).size, line: a.line }
end
bad 'the nav has no entries' if entries.empty?
entries.each { |e| bad "entry at line #{e[:line]} has no text" if e[:text].empty? }
if title
  found = text(nav_doc.at_xpath('/h:html/h:head/h:title', NS))
  bad "title is #{found.inspect}, not #{title.inspect}" unless found == title
end

# 2. Every link names an existing file and, with a fragment, an existing id.
ids = Hash.new do |h, file|
  path = File.join(dir, file)
  h[file] = File.file?(path) ? parse(path).xpath('//@id').map(&:value) : nil
end
entries.each do |e|
  file, fragment = e[:href].split('#', 2)
  if file.to_s.empty? || file.include?('/') || file.include?(':')
    bad "entry at line #{e[:line]} has the link #{e[:href].inspect}, which is not a page of the book"
  elsif ids[file].nil?
    bad "entry at line #{e[:line]} links to the missing file #{file}"
  elsif fragment && !ids[file].include?(fragment)
    bad "entry at line #{e[:line]} links to the missing id #{fragment} in #{file}"
  end
end

# 3. Same entries, order and nesting as the table of contents that the reader sees.
index = parse(File.join(dir, 'index.html'))
toc = index.xpath('//h:div[@class="toc"]', NS)
bad "index.html has #{toc.size} div.toc elements, not 1" unless toc.size == 1
visible = toc.xpath('.//h:a', NS).map do |a|
  { href: a['href'].to_s, text: text(a),
    depth: a.xpath('ancestor::h:dl | ancestor::h:ul | ancestor::h:ol', NS).size - toc.first.xpath('ancestor::h:dl | ancestor::h:ul | ancestor::h:ol', NS).size }
end
bad "the nav has #{entries.size} entries, but index.html shows #{visible.size}" unless entries.size == visible.size
entries.zip(visible).each_with_index do |(e, v), i|
  next if v.nil?
  %i[href text depth].each do |key|
    next if e[key] == v[key]
    bad "entry #{i + 1}: nav #{key} #{e[key].inspect} differs from index.html #{v[key].inspect}"
  end
end

# 4. The spine lists each page once, in the order of the file list.
opf = parse(File.join(dir, 'content.opf'))
items = {}
opf.xpath('/opf:package/opf:manifest/opf:item', NS).each do |item|
  bad "manifest id #{item['id']} occurs twice" if items.key?(item['id'])
  items[item['id']] = item
end
spine = opf.xpath('/opf:package/opf:spine/opf:itemref', NS).map { |r| r['idref'] }
spine.group_by { |x| x }.each { |id, all| bad "spine names #{id} #{all.size} times" if all.size > 1 }
spine.each { |id| bad "spine names the unknown manifest id #{id}" unless items.key?(id) }
spine_files = spine.map { |id| items[id] && items[id]['href'] }.compact
expected = File.readlines(list, chomp: true).reject(&:empty?)
bad 'the file list is empty' if expected.empty?
unless spine_files == ['cover.html'] + expected
  bad 'the spine differs from cover.html plus the file list'
  ((['cover.html'] + expected) - spine_files).first(5).each { |f| bad "  not in the spine: #{f}" }
  (spine_files - ['cover.html'] - expected).first(5).each { |f| bad "  not in the file list: #{f}" }
end
pages = items.values.select { |i| i['media-type'] == 'application/xhtml+xml' && !i['properties'].to_s.split.include?('nav') }
(pages.map { |i| i['href'] } - spine_files).each { |f| bad "page #{f} is not in the spine" }

# 5. The nav follows the reading order (EPUB 3.3, section 7.4.2).
position = {}
spine_files.each_with_index { |f, i| position[f] = i }
last = -1
entries.each do |e|
  file = e[:href].split('#', 2).first
  now = position[file]
  if now.nil?
    bad "entry at line #{e[:line]} links to #{file}, which is not in the spine"
  elsif now < last
    bad "entry at line #{e[:line]} (#{e[:href]}) goes back in the reading order"
  else
    last = now
  end
end

if $errors.empty?
  puts "check_epub_nav: #{entries.size} entries, #{spine_files.size} spine items: correct"
else
  $errors.first(40).each { |e| warn "check_epub_nav: #{e}" }
  warn "check_epub_nav: #{$errors.size} problems"
  exit 1
end
