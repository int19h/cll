require 'digest'
require 'fileutils'
require 'open3'

module MathJaxPackages
  DEFAULT_BUILD_DIR = File.expand_path('../build', __dir__)
  MANIFESTS = %w[package.json package-lock.json].map { |file| File.join(__dir__, 'weasyprint', file) }.freeze
  CONVERTERS = %w[glossary-mathml.cjs weasyprint/mathjax.cjs].map { |file| File.join(__dir__, file) }.freeze
  ENTRY_POINTS = %w[@mathjax/src/cjs/mathjax.js @mathjax/mathjax-newcm-font/cjs/chtml.js].freeze
  INPUT_FILES = [__FILE__, *MANIFESTS, *CONVERTERS].freeze

  def self.matching_install?(directory)
    ENTRY_POINTS.all? { |file| File.file?(File.join(directory, 'node_modules', file)) } &&
      MANIFESTS.all? do |file|
        installed = File.join(directory, File.basename(file))
        File.file?(installed) && FileUtils.compare_file(file, installed)
      end
  end

  def self.explicit_directory
    supplied = ENV['CLL_MATHJAX_DIR']
    return if supplied.nil? || supplied.empty?

    path = File.expand_path(supplied)
    missing = ENTRY_POINTS.find { |file| !File.file?(File.join(path, 'node_modules', file)) }
    if missing
      raise "Invalid CLL_MATHJAX_DIR #{path.inspect}: missing MathJax entry point node_modules/#{missing}."
    end
    probe = <<~JS
      try {
        for (const file of process.argv.slice(1)) require(file);
      } catch (error) {
        console.error(error.message);
        process.exitCode = 1;
      }
    JS
    begin
      _, error, status = Open3.capture3({'CLL_MATHJAX_DIR' => path}, 'node', '-e', probe, *CONVERTERS)
    rescue Errno::ENOENT
      raise "Invalid CLL_MATHJAX_DIR #{path.inspect}: Node.js is required to load MathJax."
    end
    raise "Invalid CLL_MATHJAX_DIR #{path.inspect}: could not load the pinned MathJax packages. #{error.strip}" unless status.success?

    path
  end

  def self.directory(build_dir = DEFAULT_BUILD_DIR)
    supplied = explicit_directory
    return supplied if supplied

    build_dir = File.expand_path(build_dir)
    key = Digest::SHA256.hexdigest(MANIFESTS.map { |file| Digest::SHA256.file(file).hexdigest }.join)
    [build_dir, DEFAULT_BUILD_DIR].uniq.each do |root|
      keyed = File.join(root, 'glossary-mathjax', key)
      return keyed if File.file?(File.join(keyed, '.complete')) && matching_install?(keyed)

      # Older native WeasyPrint installers put both npm manifests beside the venv.
      legacy = File.join(root, 'weasyprint-tools')
      return legacy if matching_install?(legacy)
    end

    cache = File.join(build_dir, 'glossary-mathjax')
    install = File.join(cache, key)
    ready = File.join(install, '.complete')

    FileUtils.mkdir_p(install)
    File.open(File.join(install, '.lock'), 'a') do |lock|
      lock.flock(File::LOCK_EX)
      unless File.file?(ready) && matching_install?(install)
        File.unlink(ready) if File.exist?(ready)
        FileUtils.cp(MANIFESTS, install)
        warn 'Installing pinned MathJax.'
        ok = system('npm', 'ci', '--prefix', install, '--cache', File.join(cache, 'npm-cache'),
                    '--ignore-scripts', '--no-audit', '--no-fund', out: $stderr)
        raise 'Could not install the pinned MathJax packages.' unless ok && matching_install?(install)

        File.write(ready, '')
      end
    end
    install
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby scripts/mathjax_packages.rb [BUILD_DIR]' if ARGV.size > 1
  begin
    puts MathJaxPackages.directory(*ARGV)
  rescue RuntimeError => e
    abort e.message
  end
end
