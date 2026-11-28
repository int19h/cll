require 'digest'
require 'fileutils'

module MathJaxPackages
  MANIFESTS = %w[package.json package-lock.json].map { |file| File.join(__dir__, 'weasyprint', file) }.freeze
  ENTRY_POINTS = %w[@mathjax/src/cjs/mathjax.js @mathjax/mathjax-newcm-font/cjs/chtml.js].freeze
  INPUT_FILES = [__FILE__, *MANIFESTS].freeze

  def self.matching_install?(directory)
    ENTRY_POINTS.all? { |file| File.file?(File.join(directory, 'node_modules', file)) } &&
      MANIFESTS.all? do |file|
        installed = File.join(directory, File.basename(file))
        File.file?(installed) && FileUtils.compare_file(file, installed)
      end
  end

  def self.directory(build_dir)
    supplied = ENV['CLL_MATHJAX_DIR']
    return File.expand_path(supplied) if supplied && !supplied.empty?

    cache = File.expand_path('glossary-mathjax', build_dir)
    key = Digest::SHA256.hexdigest(MANIFESTS.map { |file| Digest::SHA256.file(file).hexdigest }.join)
    install = File.join(cache, key)
    ready = File.join(install, '.complete')
    return install if File.file?(ready) && matching_install?(install)

    # Older native WeasyPrint installers put both npm manifests beside the venv.
    legacy = File.expand_path('weasyprint-tools', build_dir)
    return legacy if matching_install?(legacy)

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
  abort 'Usage: ruby scripts/mathjax_packages.rb BUILD_DIR' unless ARGV.size == 1
  puts MathJaxPackages.directory(ARGV.first)
end
