#!/usr/bin/env ruby
# Branding for the ePub, taken from .env so that no template names the book.
#
#   epub_branding.rb fill  < template > file   replaces REPLACETITLE,
#                                              REPLACEFILEAS, REPLACEPUBLISHER
#   epub_branding.rb cover > cover.svg         writes a plain cover image
#
# The values come from the environment variables TITLE, PUBLISHER, and
# AUTHOR. scripts/build_epub.sh reads TITLE and PUBLISHER from .env, like
# scripts/merge.sh does for the title page.

def xml_escape(s)
  s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
end

def need(name)
  v = ENV[name].to_s.strip
  abort "epub_branding.rb: #{name} is empty" if v.empty?
  v
end

# "The Contemporary Lojban Language" -> "Contemporary Lojban Language, The"
def file_as(title)
  m = title.match(/\A(The|A|An) (.+)\z/)
  m ? "#{m[2]}, #{m[1]}" : title
end

# Greedy word wrap for the cover.
def wrap(text, width)
  lines = [""]
  text.split(/\s+/).each do |w|
    if lines.last.empty?
      lines[-1] = w
    elsif lines.last.length + 1 + w.length <= width
      lines[-1] += " " + w
    else
      lines << w
    end
  end
  lines
end

def text_lines(lines, y, step, size, extra = "")
  lines.each_with_index.map do |line, i|
    %(  <text x="800" y="#{y + i * step}" font-size="#{size}"#{extra}>#{xml_escape(line)}</text>)
  end
end

case ARGV[0]
when "fill"
  title = need("TITLE")
  out = STDIN.read
  out = out.gsub("REPLACETITLE", xml_escape(title))
           .gsub("REPLACEFILEAS", xml_escape(file_as(title)))
           .gsub("REPLACEPUBLISHER", xml_escape(need("PUBLISHER")))
  print out
when "cover"
  title = wrap(need("TITLE"), 12)
  # Break the publisher line after its commas first.
  publisher = need("PUBLISHER").split(/(?<=,)\s+/).flat_map { |part| wrap(part, 36) }
  author = need("AUTHOR")
  body = []
  body += text_lines(title, 420, 180, 150, ' font-weight="bold"')
  author_y = 420 + title.length * 180 + 250
  body += text_lines([author], author_y, 0, 90, ' font-style="italic"')
  body += text_lines(publisher, 2150, 90, 70)
  puts <<~SVG
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="1600" height="2500" viewBox="0 0 1600 2500">
      <title>#{xml_escape(need("TITLE"))}</title>
      <rect width="1600" height="2500" fill="#1d3557"/>
      <g fill="#ffffff" font-family="serif" text-anchor="middle">
    #{body.join("\n")}
      </g>
    </svg>
  SVG
else
  abort "usage: epub_branding.rb fill|cover"
end
