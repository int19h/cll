#!/usr/bin/env ruby
# Check the Pages workflow's direct action pins and token permissions.
require 'yaml'

path = File.expand_path('../.github/workflows/pages.yml', __dir__)
text = File.read(path)
workflow = YAML.safe_load(text)
errors = []
errors << 'Top-level permissions must be empty.' unless workflow['permissions'] == {}
expected = {
  'build' => { 'contents' => 'write' },
  'deploy' => { 'pages' => 'write', 'id-token' => 'write' }
}
expected.each do |name, permissions|
  job = workflow.fetch('jobs').fetch(name)
  errors << "#{name} has the wrong permissions." unless job['permissions'] == permissions
  job.fetch('steps').each do |step|
    reference = step['uses']
    next if reference.nil? || reference.start_with?('./')
    unless reference.match?(/\A[^@]+@[0-9a-f]{40}\z/)
      errors << "#{name} uses an unpinned action: #{reference}"
    end
    if reference.start_with?('actions/upload-pages-artifact@', 'actions/deploy-pages@')
      line = text.lines.find { |candidate| candidate.include?(reference) }
      unless line&.match?(/# v[0-9]+\.[0-9]+\.[0-9]+\s*$/)
        errors << "#{reference} needs a release-version comment."
      end
    end
  end
end
# The cache key in scripts/build-versions.sh carries a toolchain field so a
# toolchain change invalidates cached archives (issue #312). It must match
# the runners that produce the archives.
toolchain = File.read(File.expand_path('../scripts/build-versions.sh', __dir__))[/^toolchain="(ubuntu-\d+\.\d+)"$/, 1]
errors << 'build-versions.sh must pin a toolchain="ubuntu-NN.NN" cache field.' if toolchain.nil?
{
  'pages.yml' => path,
  'site-tools.yml' => File.expand_path('../.github/workflows/site-tools.yml', __dir__)
}.each do |name, workflow_path|
  YAML.safe_load(File.read(workflow_path)).fetch('jobs').each do |job, body|
    errors << "#{name} #{job} must run on #{toolchain}." unless body['runs-on'] == toolchain
  end
end

# Prince must be the Ubuntu 26.04 build, hash-checked before install.
# The hash is the amd64 one from Dockerfile on main (issue #312).
prince = workflow.fetch('jobs').fetch('build').fetch('steps').find { |step| step['name'] == 'Install Prince (PDF renderer)' }
prince_run = prince && prince['run']
prince_deb = 'prince_16.2-1_ubuntu26.04_amd64.deb'
prince_sha = '40b31c21895956a277c2849b7609a377c5fae5c3554c8c0a712e71535633fd68'
if prince_run.nil?
  errors << 'pages.yml needs an Install Prince (PDF renderer) step.'
else
  errors << 'Prince must install the Ubuntu 26.04 build.' unless prince_run.include?(prince_deb) && !prince_run.include?('ubuntu24.04')
  errors << 'Prince must pin the SHA-256 from Dockerfile on main.' unless prince_run.include?("#{prince_sha}  #{prince_deb}")
  check_at = prince_run.index('sha256sum -c -')
  install_at = prince_run.index('apt-get install')
  errors << 'Prince hash must be checked before install.' if check_at.nil? || install_at.nil? || check_at > install_at
end
abort errors.join("\n") unless errors.empty?
puts 'Pages workflow: direct actions are pinned, each job has its required permissions, runners match the cache toolchain, and Prince is hash-checked.'
