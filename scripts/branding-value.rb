# Read one literal .env assignment and print it escaped for an XML text node.
# Never evaluate shell syntax, and split only at the first equals sign.
require 'cgi'

key, path = ARGV
abort "usage: #{$PROGRAM_NAME} NAME FILE" unless key && path

values = {}
File.foreach(path).with_index(1) do |line, number|
  line = line.strip
  next if line.empty? || line.start_with?('#')
  match = /\A([A-Za-z_][A-Za-z_0-9]*)\s*=(.*)\z/.match(line)
  abort "#{path}:#{number}: expected NAME=value" unless match
  name, value = match.captures
  value = value.strip
  if value.start_with?("'", '"')
    abort "#{path}:#{number}: unmatched quote" unless value.length >= 2 && value[-1] == value[0]
    value = value[1...-1]
  end
  values[name] = value
end
print CGI.escapeHTML(values.fetch(key, ''))
