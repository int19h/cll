require 'htmlentities'
require 'json'
require 'open3'
require_relative 'mathjax_packages'

module GlossaryMathML
  CONVERTER = File.join(__dir__, 'glossary-mathml.cjs')
  INPUT_FILES = [__FILE__, CONVERTER, *MathJaxPackages::INPUT_FILES].freeze
  # An escaped character consumes its backslash, so \$ stays in the
  # current run and \\ before a delimiter does not escape that delimiter.
  TOKENS = /(\\.|[$](?:\\.|[^$\\])*[$]|[$])/m

  # The dictionary uses these abbreviations as single labels. In TeX an
  # unbraced subscript base is only the preceding character. Group the
  # known labels here, without resolving them to this entry's places.
  GROUPED_BASES = {
    "ce'oi" => %w[bridi],
    'cinctu' => %w[ci ct],
    'fagyfesti' => %w[fa fe],
    'nalbrablo' => %w[ba bl],
    'nilkla' => %w[ni],
    "nunji'a" => %w[nu],
    'nunkalte' => %w[nu],
    'nunpinxe' => %w[nu],
    "nunte'a" => %w[nu],
    "nunterji'a" => %w[nu],
    "pi'egre" => %w[pa pl],
    "ro'inre'o" => %w[re ro],
    "rokre'o" => %w[re ro],
    'xagmau' => %w[xa],
    'xaskemcakcurnu' => %w[cu]
  }.freeze

  # Dictionary corrections for #358. The last two fragments are suffixes
  # attached to the word "klama" in the surrounding notes prose.
  TEX_CORRECTIONS = {
    'cmatce' => {'x1=c1=m1' => 'x_1=c_1=m_1', 'x2=c2' => 'x_2=c_2', 'x3=c3' => 'x_3=c_3'},
    "pi'egre" => {'pl_1=pa1' => 'pl_1=pa_1'},
    'zernerkla' => {'_3' => '{}_3', '_5' => '{}_5'}
  }.freeze

  def self.correct_tex(word, tex)
    tex = TEX_CORRECTIONS.fetch(word, {}).fetch(tex, tex)
    bases = GROUPED_BASES[word]
    return tex unless bases

    tex.gsub(/(?<![a-z\\])(?:#{Regexp.union(bases)})(?=_)/) { |base| "{#{base}}" }
  end

  def self.render(definitions, build_dir:)
    coder = HTMLEntities.new
    inputs = []
    pieces = definitions.map do |word, text|
      text.split(TOKENS).map do |part|
        next coder.encode(part, :basic) unless part.start_with?('$')

        raise "#{word}: unmatched dollar in glossary text: #{text}" if part == '$'

        inputs.push(word: word, tex: correct_tex(word, part[1...-1])).size - 1
      end
    end
    math = []
    unless inputs.empty?
      env = {'CLL_MATHJAX_DIR' => MathJaxPackages.directory(build_dir)}
      stdout, stderr, status = Open3.capture3(env, 'node', CONVERTER, stdin_data: JSON.generate(inputs))
      raise "Glossary TeX conversion failed:\n#{stderr}" unless status.success?

      math = JSON.parse(stdout)
    end
    pieces.map do |parts|
      parts.map do |part|
        next part if part.is_a?(String)

        "<inlineequation role='mmlinlinemath'>#{math.fetch(part)}</inlineequation>"
      end.join
    end
  end
end
