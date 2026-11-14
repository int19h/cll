#!/usr/bin/env ruby
# frozen_string_literal: true

# Fixture checks for the polyglot comparer and for serialize_page.
# Run from anywhere. Exits 1 on failure.

require 'fileutils'
require 'nokogiri'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
require File.join(ROOT, 'scripts/util.rb')

XHTML = 'http://www.w3.org/1999/xhtml'

def check(condition, message)
  return if condition
  warn "FAIL: #{message}"
  exit 1
end

def page(body)
  head = '<head><title>T</title><meta http-equiv="Content-Type" content="text/html; charset=utf-8" /></head>'
  "<!DOCTYPE html>\n<html xmlns=\"#{XHTML}\" lang=\"en\" xml:lang=\"en\">#{head}<body>#{body}</body></html>\n"
end

def write_page(dir, name, text)
  path = File.join(dir, name)
  File.write(path, text)
  path
end

def run_checker(*args)
  Open3.capture2e('ruby', File.join(ROOT, 'scripts/check-html-polyglot.rb'), *args)
end

Dir.mktmpdir('cll-polyglot-') do |dir|
  good = write_page(dir, 'good.html', page('<p>Hello <a id="x"></a></p>'))
  out, status = run_checker(good)
  check(status.success?, "a matching page failed:\n#{out}")
  check(out.include?('files=1 bad=0'), out)

  broken = write_page(dir, 'broken.html', page('<p>Hello <a id="x"/></p>'))
  out, status = run_checker(broken)
  check(!status.success?, 'a self-closed anchor was accepted')
  check(out.include?('tree_equal=false'), out)
  File.delete(broken)

  write_page(dir, 'cll-weasyprint.html', '<not-xml')
  out, status = run_checker(dir)
  check(status.success?, "the working copy was checked:\n#{out}")
  check(out.include?('files=1 bad=0'), out)

  _out, status = run_checker
  check(status.exitstatus == 2, "missing arguments exited #{status.exitstatus}")
end

document = Nokogiri::XML(page('<p>coi</p><br /><a id="x"></a>'))
online = serialize_page(document, mode: :html)
check(online.start_with?("<!DOCTYPE html>\n"), online.lines.first)
check(!online.include?('<?xml'), 'online page has an XML declaration')
check(online.include?('http-equiv="Content-Type"'), 'online page dropped the content type')
check(online.include?('<br />'), online)
check(online.include?('<a id="x"></a>'), online)

epub_doc = Nokogiri::XML(page('<p>coi</p>'))
epub_doc.root.add_namespace_definition('epub', 'http://www.idpf.org/2007/ops')
packed = serialize_page(epub_doc, mode: :epub)
check(packed.start_with?("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n"), packed.lines.first(2).join)
check(!packed.include?('http-equiv'), 'ePub page kept a content-type meta')
check(packed.include?('xmlns:epub='), packed)

puts 'test-check-html-polyglot: ok'
