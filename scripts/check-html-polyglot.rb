#!/usr/bin/env ruby
# frozen_string_literal: true

# Compare the XML tree of a page with the tree an HTML5 parser builds.
# A tbody wrapper is skipped on both sides, so a tbody the HTML parser
# inserts matches a tbody the stylesheet wrote. xmlns is ignored.

require 'nokogiri'

PARSE = Nokogiri::XML::ParseOptions::STRICT | Nokogiri::XML::ParseOptions::NONET

def fail_usage
  warn 'usage: ruby scripts/check-html-polyglot.rb FILE_OR_DIRECTORY...'
  exit 2
end

def pages_under(path)
  if File.file?(path)
    return [path]
  end
  return [] unless File.directory?(path)
  Dir.chdir(path) do
    Dir.glob('**/*.{html,xhtml}').sort.reject { |relative|
      # WeasyPrint writes this file with an HTML serializer for its own
      # parser. It is a working copy, not a contract page.
      File.basename(relative) == 'cll-weasyprint.html'
    }.map { |relative| File.join(path, relative) }
  end
end

def for_html5(text)
  text.sub(/\A(?:\uFEFF)?<\?xml.*?\?>\s*/m, '')
end

def namespace_declaration?(attr)
  # The HTML5 parser keeps xmlns:epub as an ordinary attribute name.
  # The XML parser reports the same declaration with the xmlns prefix.
  # Both are namespace declarations, which this comparison ignores.
  name = attr.name.to_s
  return true if name == 'xmlns' || name.start_with?('xmlns:')
  attr.namespace&.prefix == 'xmlns'
end

def attribute_text(node)
  node.attribute_nodes.reject { |attr|
    namespace_declaration?(attr)
  }.map { |attr|
    prefix = attr.namespace&.prefix
    key = prefix.nil? || prefix.empty? ? attr.name : "#{prefix}:#{attr.name}"
    [key, attr.value]
  }.sort.map { |key, value| "#{key}=#{value}" }.join('|')
end

def walk_children(node, out)
  node.children.each do |child|
    if child.element?
      record(child, out)
    elsif child.text? || child.cdata?
      text = child.content
      out << "T:#{text}" unless text.strip.empty?
    end
  end
end

def record(node, out)
  if node.name == 'tbody'
    walk_children(node, out)
    return
  end
  out << "<#{node.name} #{attribute_text(node)}>"
  walk_children(node, out)
  out << "</#{node.name}>"
end

def signature(node)
  out = []
  record(node, out) if node&.element?
  out
end

fail_usage if ARGV.empty?
files = ARGV.flat_map { |path| pages_under(path) }
if files.empty?
  warn 'no HTML pages'
  exit 1
end

bad = 0
files.each do |path|
  source = File.read(path)
  begin
    xml_doc = Nokogiri::XML(source) { |config| config.options = PARSE }
  rescue Nokogiri::XML::SyntaxError => error
    bad += 1
    warn "#{path}: XML parse error: #{error.message.to_s.strip}"
    next
  end
  html_doc = Nokogiri::HTML5.parse(for_html5(source), max_errors: 50)
  xml_sig = signature(xml_doc.root)
  html_sig = signature(html_doc.root)
  errors = html_doc.errors
  next if xml_sig == html_sig && errors.empty?
  bad += 1
  warn "#{path}: parse errors=#{errors.size} tree_equal=#{xml_sig == html_sig}"
  errors.first(5).each { |error| warn "  #{error.to_s.lines.first.to_s.strip}" }
  next if xml_sig == html_sig
  index = (0...[xml_sig.size, html_sig.size].min).find { |slot| xml_sig[slot] != html_sig[slot] }
  index ||= [xml_sig.size, html_sig.size].min
  warn "  first difference at #{index}:"
  warn "   xml : #{xml_sig[[index - 2, 0].max, 5].inspect[0, 400]}"
  warn "   html: #{html_sig[[index - 2, 0].max, 5].inspect[0, 400]}"
end
warn "files=#{files.size} bad=#{bad}"
exit(bad.zero? ? 0 : 1)
