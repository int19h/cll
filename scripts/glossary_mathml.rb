require 'htmlentities'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'

module GlossaryMathML
  CONVERTER = File.join(__dir__, 'glossary-mathml.cjs')
  MANIFESTS = [
    File.join(__dir__, 'weasyprint/package.json'),
    File.join(__dir__, 'weasyprint/package-lock.json')
  ].freeze
  INPUT_FILES = [__FILE__, CONVERTER, *MANIFESTS].freeze
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

  def self.mathjax_dir(build_dir)
    supplied = ENV['CLL_MATHJAX_DIR']
    return File.expand_path(supplied) if supplied && !supplied.empty?

    cache = File.expand_path('glossary-mathjax', build_dir)
    key = Digest::SHA256.hexdigest(MANIFESTS.map { |file| Digest::SHA256.file(file).hexdigest }.join)
    install = File.join(cache, key)
    FileUtils.mkdir_p(install)
    File.open(File.join(install, '.lock'), 'a') do |lock|
      lock.flock(File::LOCK_EX)
      ready = File.join(install, '.complete')
      unless File.file?(ready) && File.file?(File.join(install, 'node_modules/@mathjax/src/cjs/mathjax.js'))
        File.unlink(ready) if File.exist?(ready)
        FileUtils.cp(MANIFESTS, install)
        warn 'Installing pinned MathJax for glossary math.'
        ok = system('npm', 'ci', '--prefix', install, '--cache', File.join(cache, 'npm-cache'),
                    '--ignore-scripts', '--no-audit', '--no-fund', out: $stderr)
        raise 'Could not install the pinned packages for glossary math.' unless ok

        File.write(ready, '')
      end
    end
    install
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
      env = {'CLL_MATHJAX_DIR' => mathjax_dir(build_dir)}
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
