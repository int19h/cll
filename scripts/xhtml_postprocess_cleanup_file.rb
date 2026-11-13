require 'nokogiri'
require 'yaml'
# require 'byebug'

mydir=File.expand_path(File.dirname(__FILE__))
require "#{mydir}/util.rb"
require "#{mydir}/html_format.rb"
require "#{mydir}/html_whitespace_guard.rb"

$document = Nokogiri::XML(File.open ARGV[0]) do |config|
  config.default_xml
  config.strict
  config.options = Nokogiri::XML::ParseOptions::DTDLOAD   # Needed for the external DTD to be loaded
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

# The shell passes the page path after the temporary file. One-argument
# callers still name the file they passed.
page_name = ARGV[1].to_s
page_name = ARGV[0].to_s if page_name.empty?

if mode == 'none'
  print HtmlFormat.write($document)
else
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
