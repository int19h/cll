# scripts/merge.sh builds only the general and lojban-word indexes.
# Any other indexterm type, including a missing type, reaches no index.

ALLOWED_INDEX_TYPES = %w[general lojban-word].freeze

def index_type_errors(source, path)
  source.to_enum(:scan, /<indexterm\b([^>]*)>/).filter_map do
    match = Regexp.last_match
    attrs = match[1]
    type = attrs[/\btype="([^"]*)"/, 1]
    next if ALLOWED_INDEX_TYPES.include?(type)
    line = source.byteslice(0, match.begin(0)).count("\n") + 1
    shown = type.nil? ? 'missing' : type.inspect
    "#{path}:#{line}: indexterm type #{shown} has no index (expected general or lojban-word)"
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Usage: #{$PROGRAM_NAME} chapters/*.xml" if ARGV.empty?
  errors = ARGV.flat_map { |path| index_type_errors(File.read(path), path) }
  warn errors.join("\n") unless errors.empty?
  exit(errors.empty? ? 0 : 1)
end
