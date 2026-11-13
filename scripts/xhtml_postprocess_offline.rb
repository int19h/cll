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

# A reference the browser would load from this folder, or nil when it would not.
def local_path(ref)
  return nil if ref.nil? || ref.empty?
  return nil if ref =~ %r{\A([a-z][a-z0-9+.-]*:|//|#)}i
  path = ref.sub(/[?#].*\z/, '').sub(%r{\A\./}, '')
  path.empty? ? nil : path
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
    doc.css('link[rel~="stylesheet"][href], link[rel~="icon"][href]').each do |node|
      refs << local_path(node['href'])
    end
    doc.css('script[src]').each { |node| refs << local_path(node['src']) }
    doc.css('img[src]').each { |node| refs << local_path(node['src']) }
  end
  refs.delete(nil)

  resolved = Set.new
  refs.each do |ref|
    path = resolve_path('.', ref)
    fail!("path escapes the book folder: #{ref}") if path.nil?
    resolved << path
  end
  refs = resolved

  refs.select { |ref| ref.end_with?('.css') && File.file?(ref) }.each do |css|
    base = File.dirname(css)
    File.read(css, encoding: 'UTF-8').scan(/url\(\s*["']?([^"')]+)["']?\s*\)/).flatten.each do |url|
      relative = local_path(url)
      next unless relative
      path = resolve_path(base, relative)
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
  build = Digest::SHA256.hexdigest(JSON.generate([entries, lazy, template]))[0, 16]
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
