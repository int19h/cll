#!/usr/bin/env ruby
# Write sw.js for one HTML book folder.
# The worker stores the pages and the files they use, so the book can be read offline.
# Usage: xhtml_postprocess_offline.rb [--budget BYTES] [--verify] BOOK_FOLDER TEMPLATE

require 'digest'
require 'json'
require 'nokogiri'
require 'optparse'
require 'set'

LAZY_PATTERNS = [%r{\Aassets/fonts/noto-cjk-}].freeze
DEFAULT_BUDGET = 20 * 1024 * 1024
SAFE_NAME = %r{\A[A-Za-z0-9._/-]+\z}
PLACEHOLDERS = %w[@BUILD@ @PRECACHE@ @LAZY@].freeze

def fail!(message)
  warn message
  exit 1
end

# :external is another site or a fragment. :root starts with "/". A string is a relative path.
def classify_ref(ref)
  return nil if ref.nil? || ref.empty?
  return :external if ref =~ %r{\A(?:[a-z][a-z0-9+.-]*:|//|#)}i
  return :root if ref.start_with?('/')
  path = ref.sub(/[?#].*\z/, '').sub(%r{\A\./}, '')
  path.empty? ? nil : path
end

def strip_css_comments(text)
  text.gsub(%r{/\*.*?\*/}m, '')
end

def add_local(ref, where, into)
  kind = classify_ref(ref)
  return if kind.nil? || kind == :external
  fail!("root-relative reference in #{where}: #{ref}") if kind == :root
  into << kind
end

# style attributes and <style> blocks are not read. A reference there stops the build.
def reject_unread_style(text, where)
  cleaned = strip_css_comments(text)
  return unless cleaned =~ /url\s*\(/i || cleaned =~ /@import\s*['"]/
  fail!("unread style reference in #{where}")
end

def reject_unread_html(doc, page)
  doc.css('[srcset]').each do |node|
    value = node['srcset'].to_s
    fail!("unread srcset in #{page}: #{value}") unless value.strip.empty?
  end
  doc.css('source[src], source[srcset]').each do |_node|
    fail!("unread source element in #{page}")
  end
  doc.css('object[data]').each do |node|
    fail!("unread object element in #{page}: #{node['data']}")
  end
  doc.css('embed[src]').each do |node|
    fail!("unread embed element in #{page}: #{node['src']}")
  end
  doc.css('[style]').each do |node|
    reject_unread_style(node['style'].to_s, "#{page} style attribute")
  end
  doc.css('style').each do |node|
    reject_unread_style(node.text.to_s, "#{page} style element")
  end
end

# Resolve a path relative to a file in the book folder. nil means the path escapes the folder.
def resolve_path(base, relative)
  combined = base.nil? || base == '.' ? relative : File.join(base, relative)
  parts = []
  combined.split('/').each do |part|
    next if part.empty? || part == '.'
    if part == '..'
      return nil if parts.empty?
      parts.pop
    else
      parts << part
    end
  end
  result = parts.join('/')
  result.empty? ? nil : result
end

options = { budget: DEFAULT_BUDGET, verify: false }
parser = OptionParser.new do |opts|
  opts.banner = 'Usage: xhtml_postprocess_offline.rb [--budget BYTES] [--verify] BOOK_FOLDER TEMPLATE'
  opts.on('--budget BYTES', Integer, 'Maximum precache size in bytes (default 20 MiB)') do |bytes|
    options[:budget] = bytes
  end
  opts.on('--verify', 'Compare the existing sw.js and write nothing') do
    options[:verify] = true
  end
end
begin
  parser.parse!
rescue OptionParser::ParseError => error
  fail!(error.message)
end
fail!(parser.banner) unless ARGV.length == 2

folder = File.expand_path(ARGV[0])
template_path = File.expand_path(ARGV[1])
fail!("not a directory: #{folder}") unless File.directory?(folder)
fail!("template not found: #{template_path}") unless File.file?(template_path)
template = File.read(template_path, encoding: 'UTF-8')
PLACEHOLDERS.each do |token|
  fail!("template lacks #{token}") unless template.include?(token)
end

Dir.chdir(folder) do
  pages = Dir.glob('*.html').sort
  refs = Set.new
  pages.each do |page|
    doc = Nokogiri::HTML(File.read(page, encoding: 'UTF-8'))
    reject_unread_html(doc, page)
    doc.css('link[rel~="stylesheet"][href], link[rel~="icon"][href]').each do |node|
      add_local(node['href'], page, refs)
    end
    doc.css('script[src]').each { |node| add_local(node['src'], page, refs) }
    doc.css('img[src]').each { |node| add_local(node['src'], page, refs) }
  end

  resolved = Set.new
  refs.each do |ref|
    path = resolve_path('.', ref)
    fail!("path escapes the book folder: #{ref}") if path.nil?
    resolved << path
  end
  refs = resolved

  refs.select { |ref| ref.end_with?('.css') && File.file?(ref) }.each do |css|
    base = File.dirname(css)
    cleaned = strip_css_comments(File.read(css, encoding: 'UTF-8'))
    fail!("unread @import in #{css}") if cleaned =~ /@import\s*['"]/
    cleaned.scan(/url\(\s*["']?([^"')]+)["']?\s*\)/).flatten.each do |url|
      kind = classify_ref(url)
      next if kind.nil? || kind == :external
      fail!("root-relative reference in #{css}: #{url}") if kind == :root
      path = resolve_path(base, kind)
      fail!("path escapes the book folder: #{url} from #{css}") if path.nil?
      refs << path
    end
  end

  missing = refs.reject { |ref| File.file?(ref) }
  fail!("missing: #{missing.to_a.join(', ')}") unless missing.empty?

  lazy, eager = refs.partition { |ref| LAZY_PATTERNS.any? { |pattern| ref =~ pattern } }
  precache = (pages + eager).uniq.sort
  lazy = lazy.sort
  unsafe = (precache + lazy).grep_v(SAFE_NAME)
  fail!("names need escaping: #{unsafe.join(', ')}") unless unsafe.empty?

  size = precache.sum { |file| File.size(file) }
  if size > options[:budget]
    fail!("precache is #{size} bytes, over the budget of #{options[:budget]} bytes")
  end

  entries = precache.map { |file| [file, 'sha256-' + Digest::SHA256.file(file).base64digest] }
  # The worker stores lazy paths only. Their bytes still belong to the build id.
  lazy_entries = lazy.map { |file| [file, 'sha256-' + Digest::SHA256.file(file).base64digest] }
  build = Digest::SHA256.hexdigest(JSON.generate([entries, lazy_entries, template]))[0, 16]
  out = template.sub('@BUILD@') { build }
                .sub('@PRECACHE@') { "[\n" + entries.map { |entry| JSON.generate(entry) }.join(",\n") + "\n]" }
                .sub('@LAZY@') { JSON.generate(lazy) }
  PLACEHOLDERS.each do |token|
    fail!("template still contains #{token}") if out.include?(token)
  end

  if options[:verify]
    current = File.file?('sw.js') ? File.read('sw.js', encoding: 'UTF-8') : nil
    fail!('sw.js does not match this book folder') unless current == out
  else
    temp = "sw.js.tmp.#{Process.pid}"
    begin
      File.write(temp, out)
      File.rename(temp, 'sw.js')
    ensure
      File.delete(temp) if File.exist?(temp)
    end
  end
  puts "offline: build #{build}, #{pages.size} pages, #{precache.size} files, #{size} bytes, #{lazy.size} lazy"
end
