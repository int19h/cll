require_relative 'lint-index-types'

source = "<chapter>\n  <indexterm type=\"general\"/>\n  <indexterm type=\"lojban-word\" significance=\"preferred\"/>\n" \
         "  <indexterm type=\"generlojban-wordal\"/>\n  <indexterm type=\"pro-sumti\"/>\n  <indexterm/>\n</chapter>\n"
errors = index_type_errors(source, 'fixture.xml')
abort errors.inspect unless errors == [
  'fixture.xml:4: indexterm type "generlojban-wordal" has no index (expected general or lojban-word)',
  'fixture.xml:5: indexterm type "pro-sumti" has no index (expected general or lojban-word)',
  'fixture.xml:6: indexterm type missing has no index (expected general or lojban-word)'
]
puts 'index type lint: accepted general and lojban-word; rejected the typo, pro-sumti, and a missing type'
