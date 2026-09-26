#!/usr/bin/env ruby
# Branding for the ePub, taken from .env so that no template names the book.
#
#   epub_branding.rb fill  < template > file   replaces REPLACETITLE,
#                                              REPLACEFILEAS, REPLACEPUBLISHER,
#                                              REPLACEREVISER
#   epub_branding.rb cover > cover.svg         writes a plain cover image
#
# The values come from the environment variables TITLE, PUBLISHER, REVISER,
# and AUTHOR. scripts/build_epub.sh reads all but AUTHOR from .env, like
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

BACKGROUND = "#3f9b0b"   # grass green
OUTLINE = "#1f4d06"      # separates the white shapes of the logo

# The Lojban logo, as on the cover of the first edition: two linked rings over
# a cross of four arrows, in white. The drawing is centered on (cx, cy), and
# the logo is about 330 by 210 units before scaling. The left ring lies over
# the right one at the top crossing, and under it at the bottom crossing.
def logo(cx, cy, scale)
  l, v, w, h, k = 162, 100, 7, 20, 30   # arm lengths, shaft, head width, head length
  pts = [[w, -w], [w, -(v - k)], [h, -(v - k)], [0, -v], [-h, -(v - k)], [-w, -(v - k)],
         [-w, -w], [-(l - k), -w], [-(l - k), -h], [-l, 0], [-(l - k), h], [-(l - k), w],
         [-w, w], [-w, v - k], [-h, v - k], [0, v], [h, v - k], [w, v - k],
         [w, w], [l - k, w], [l - k, h], [l, 0], [l - k, -h], [l - k, -w]]
  cross = pts.map { |x, y| "#{x},#{y}" }.join(" ")
  r, d = 57, 37.5                       # ring radius, half the distance of the centers
  ring = lambda do |x, extra = ""|
    %(<circle cx="#{x}" cy="0" r="#{r}" fill="none" stroke="#{OUTLINE}" stroke-width="20"#{extra}/>) +
      %(<circle cx="#{x}" cy="0" r="#{r}" fill="none" stroke="#ffffff" stroke-width="13"#{extra}/>)
  end
  <<~LOGO.chomp
    <g transform="translate(#{cx} #{cy}) scale(#{scale})">
        <clipPath id="lower-half"><rect x="-200" y="20" width="400" height="200"/></clipPath>
        <polygon points="#{cross}" fill="#ffffff" stroke="#{OUTLINE}" stroke-width="4" stroke-linejoin="miter"/>
        #{ring.call(d)}
        #{ring.call(-d)}
        #{ring.call(d, ' clip-path="url(#lower-half)"')}
      </g>
  LOGO
end

case ARGV[0]
when "fill"
  title = need("TITLE")
  out = STDIN.read
  out = out.gsub("REPLACETITLE", xml_escape(title))
           .gsub("REPLACEFILEAS", xml_escape(file_as(title)))
           .gsub("REPLACEPUBLISHER", xml_escape(need("PUBLISHER")))
           .gsub("REPLACEREVISER", xml_escape(need("REVISER")))
  print out
when "cover"
  title = wrap(need("TITLE"), 12)
  author = need("AUTHOR")
  body = []
  body += text_lines(title, 420, 180, 150, ' font-weight="bold"')
  by_y = 420 + title.length * 180 + 200
  body += text_lines(["by"], by_y, 0, 80, ' font-style="italic" font-weight="bold"')
  body += text_lines([author], by_y + 110, 0, 90, ' font-style="italic" font-weight="bold"')
  body += text_lines(["revised by #{need("REVISER")}"], by_y + 230, 0, 70, ' font-style="italic"')
  puts <<~SVG
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="1600" height="2500" viewBox="0 0 1600 2500">
      <title>#{xml_escape(need("TITLE"))}</title>
      <rect width="1600" height="2500" fill="#{BACKGROUND}"/>
      <g fill="#ffffff" font-family="serif" text-anchor="middle">
    #{body.join("\n")}
      </g>
    #{logo(800, 2050, 1.5)}
    </svg>
  SVG
else
  abort "usage: epub_branding.rb fill|cover"
end
