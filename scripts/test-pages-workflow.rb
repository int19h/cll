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
abort errors.join("\n") unless errors.empty?
puts 'Pages workflow: direct actions are pinned and each job has its required permissions.'
