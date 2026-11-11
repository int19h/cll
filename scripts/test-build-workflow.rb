#!/usr/bin/env ruby
# Check direct action pins, least permissions, and preview/partial-output wiring.
require 'yaml'
root = File.expand_path('..', __dir__)
path = ARGV[0] || File.join(root, '.github/workflows/build.yml')
text = File.read(path)
workflow = YAML.safe_load(text)
errors = []
check = ->(condition, message) { errors << message unless condition }
check.call(workflow['permissions'] == {}, 'Top-level permissions must be empty.')
expected = {
  'build' => { 'contents' => 'read', 'actions' => 'read', 'pages' => 'read' },
  'deploy' => { 'contents' => 'read', 'pages' => 'write', 'id-token' => 'write' }
}
expected.each do |name, permissions|
  job = workflow.fetch('jobs').fetch(name)
  check.call(job['permissions'] == permissions, "#{name} has the wrong permissions.")
  check.call(job['timeout-minutes'].is_a?(Integer) && job['timeout-minutes'] > 0, "#{name} needs a timeout.")
  job.fetch('steps').each do |step|
    reference = step['uses']
    next if reference.nil?
    check.call(reference.match?(/\A[^@]+@[0-9a-f]{40}\z/), "#{name} uses an unpinned action: #{reference}")
    if reference.start_with?('actions/upload-', 'actions/deploy-pages@')
      line = text.lines.find { |candidate| candidate.include?(reference) }
      check.call(line&.match?(/# v[0-9]+\.[0-9]+\.[0-9]+\s*$/), "#{reference} needs a release-version comment.")
    end
    if reference.start_with?('actions/upload-')
      check.call(step.fetch('with')['retention-days'] == 14, "#{step['name']} needs 14-day retention.")
    end
  end
end
jobs = workflow.fetch('jobs')
build = jobs.fetch('build')
deploy = jobs.fetch('deploy')
steps = build.fetch('steps')
guard = steps.find { |s| s['id'] == 'guard' }
check.call(guard && guard.fetch('env')['GH_TOKEN'] == '${{ github.token }}', 'Early guard must receive the job token.')
check.call(build.fetch('outputs')['preview'] == '${{ steps.branch_rules.outputs.preview }}', 'Build must export the environment eligibility result.')
check.call(steps.index(guard) < steps.index(steps.find { |s| s['id'] == 'ready' }), 'Early guard must run before building.')
rules = steps.find { |s| s['id'] == 'branch_rules' }
check.call(rules && rules['if'] == "steps.guard.outputs.preview == 'true'" && rules.fetch('env')['GH_TOKEN'] == '${{ github.token }}', 'Environment check must require the release guard and job token.')
check.call(rules['run'] == 'python3 scripts/check-preview-branch-rules.py' && steps.index(guard) < steps.index(rules) && steps.index(rules) < steps.index(steps.find { |s| s['id'] == 'ready' }), 'Environment rules must be checked before building.')
check.call(deploy['needs'] == 'build' && deploy['if'] == "needs.build.outputs.preview == 'true'", 'Deployment must require the guarded successful build.')
check.call(deploy.fetch('concurrency') == {'group' => 'book-pages-preview', 'cancel-in-progress' => false}, 'Preview must serialize without joining the release concurrency group.')
check.call(deploy.fetch('environment')['name'] == 'github-pages', 'Deployment must use the protected environment.')
late, action, link = deploy.fetch('steps')
check.call(deploy['steps'].length == 3 && late['id'] == 'late_guard', 'Inline late guard must immediately precede deployment.')
check.call(late.fetch('env')['GH_TOKEN'] == '${{ github.token }}', 'Late guard must receive the job token.')
check.call(late['run'].include?('urllib.request') && !late['run'].include?('bash scripts/'), 'Late guard must use inline API code, never branch scripts.')
check.call(action['uses'].start_with?('actions/deploy-pages@') && action['if'] == "steps.late_guard.outputs.deploy == 'true'", 'Deploy action must require the late guard.')
check.call(link['if'] == "steps.deployment.outcome == 'success'", 'Only a successful deployment can produce a preview link.')
check.call(deploy['steps'].none? { |s| s['uses']&.start_with?('actions/checkout@') }, 'Deployment must not check out branch code.')
upload = steps.find { |s| s['name'] == 'Upload Pages preview' }
check.call(upload['if'] == "${{ success() && steps.guard.outputs.preview == 'true' && steps.branch_rules.outputs.preview == 'true' && steps.build_html.outcome == 'success' }}", 'Pages upload must require the early guard and successful HTML/job.')
%w[html epub pdf pdf-weasyprint pdf-typst pdf-context].each do |fmt|
  id = 'build_' + fmt.tr('-', '_')
  step = steps.find { |s| s['id'] == id }
  check.call(step && step['continue-on-error'] == true, "#{fmt} failure must not discard other formats.")
  check.call(step['if'] == "${{ !cancelled() && steps.ready.outcome == 'success' && contains(format(' {0} ', steps.formats.outputs.list), ' #{fmt} ') }}", "#{fmt} must require successful prerequisites and exact selection.")
  artifact = steps.find { |s| s['name'] == "Upload #{fmt}" }
  check.call(artifact['if'] == "${{ !cancelled() && steps.#{id}.outcome == 'success' }}", "#{fmt} upload must survive another format's failure.")
end
prince = steps.find { |s| s['name'] == 'Install Prince (PDF renderer)' }['run']
sha = File.read(File.join(root, 'Dockerfile'))[/amd64\) prince_sha256=([0-9a-f]{64})/, 1]
check.call(sha && prince.include?(sha + '  prince_16.2-1_ubuntu24.04_amd64.deb') && prince.index('sha256sum -c -') < prince.index('sudo apt-get install'), 'Prince must match the Dockerfile hash before installation.')
abort errors.join("\n") unless errors.empty?
puts 'Build workflow: direct pins, permissions, retention, timeouts, and guard/partial-output wiring pass.'
