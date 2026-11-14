require 'nokogiri'
require 'yaml'
# require 'byebug'

mydir=File.expand_path(File.dirname(__FILE__))
require "#{mydir}/util.rb"
require "#{mydir}/html_format.rb"
require "#{mydir}/html_whitespace_guard.rb"

page_path = ARGV[0].to_s
page_name = ARGV[1].to_s
page_name = page_path if page_name.empty?

begin
  $document = Nokogiri::XML(File.open(page_path)) do |config|
    config.default_xml
    config.strict
    config.options = Nokogiri::XML::ParseOptions::DTDLOAD   # Needed for the external DTD to be loaded
  end
rescue Nokogiri::XML::SyntaxError => error
  warn "#{page_name}: parse error on the original side: #{error.message.to_s.strip}"
  $stderr.flush
  exit! 1
end

# Drop stuff we don't want, because display: none makes epub sad
$document.css('.glossary h3').remove
$document.css('.whole-index h3').remove

mode = ENV.fetch('CLL_HTML_FORMAT', 'pretty')
unless %w[pretty none].include?(mode)
  warn "CLL_HTML_FORMAT must be pretty or none, not #{mode}"
  $stderr.flush
  exit! 1
end

if mode == 'none'
  print HtmlFormat.write($document)
else
  # The writer would insert a Content-Type meta at save time. Put it in the
  # tree first so both writes, and a second format, see the same element.
  HtmlFormat.ensure_content_type_meta!($document)
  before = HtmlFormat.write($document)
  HtmlFormat.format!($document)
  after = HtmlFormat.write($document)
  begin
    HtmlWhitespaceGuard.compare!(before, after, name: page_name)
  rescue HtmlWhitespaceGuard::Unsafe => error
    warn error.message
    $stderr.flush
    exit! 1
  end
  print after
end
$stdout.flush
exit! 0
