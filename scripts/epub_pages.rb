#!/usr/bin/env ruby
# frozen_string_literal: true

# Rewrite ePub content pages into the HTML5 contract (issue #209).
# The navigation document is not an argument. The stylesheet writes it.

require 'nokogiri'
require_relative 'util'

XHTML = 'http://www.w3.org/1999/xhtml'
EPUB_NS = 'http://www.idpf.org/2007/ops'
PARSE = Nokogiri::XML::ParseOptions::STRICT | Nokogiri::XML::ParseOptions::NONET

def fail!(message)
  warn message
  exit 1
end

fail!('usage: ruby scripts/epub_pages.rb PAGE.html ...') if ARGV.empty?

ARGV.each do |path|
  begin
    document = Nokogiri::XML(File.read(path)) { |config| config.options = PARSE }
  rescue Nokogiri::XML::SyntaxError => error
    fail!("#{path}: #{error.message.to_s.strip}")
  end
  document.xpath('//*[local-name()="script"]').each(&:remove)
  html = document.at_xpath('/h:html', 'h' => XHTML)
  fail!("#{path}: page has no html element") unless html
  html.add_namespace_definition('epub', EPUB_NS)
  body = document.at_xpath('/h:html/h:body', 'h' => XHTML)
  fail!("#{path}: page has no body element") unless body
  classes = body['class'].to_s.split
  classes << 'epub' unless classes.include?('epub')
  body['class'] = classes.join(' ')
  # xhtml5 turns the HTML border attribute into "border: 1", which is not
  # valid CSS. The ePub stylesheet draws the old inset rules instead.
  document.xpath('//h:table', 'h' => XHTML).each do |table|
    style = table['style']
    next if style.nil?
    cleaned = style.gsub(/border\s*:\s*1\s*(?:;|(?=\s|$))/, '').strip
    if cleaned.empty?
      table.remove_attribute('style')
    elsif cleaned != style
      table['style'] = cleaned
    end
  end
  listed = document.xpath('//h:dl|//h:dt|//h:dd', 'h' => XHTML).to_a
  listed.each do |node|
    old_name = node.name
    node.name = old_name == 'dl' ? 'ul' : 'li'
    current = node['class']
    node['class'] = current.nil? || current.empty? ? old_name : "#{old_name} #{current}"
  end
  File.write(path, serialize_page(document, mode: :epub))
end
