#!/usr/bin/env python3
"""Skip only a demonstrably disallowed literal environment rule.

GitHub remains authoritative for patterns and protected-branch policies.
An absent environment or unreadable/unknown state must never cause a skip.
"""
import json
import os
import re
import urllib.error
import urllib.request


def check():
    kind = os.environ.get('GITHUB_REF_TYPE')
    name = os.environ.get('GITHUB_REF_NAME')
    ref = os.environ.get('GITHUB_REF')
    if kind not in ('branch', 'tag') or not name or not ref:
        raise ValueError('The workflow ref is unknown.')
    base = os.environ['GITHUB_API_URL'].rstrip('/') + '/repos/' + os.environ['GITHUB_REPOSITORY']
    token = os.environ['GH_TOKEN']
    if not token:
        raise ValueError('The job token is unavailable.')

    def get(path):
        request = urllib.request.Request(base + path, headers={
            'Authorization': 'Bearer ' + token,
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
        })
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError('GitHub API lookup failed for ' + path + ': HTTP ' + str(error.code) + '.') from None

    environment = get('/environments/github-pages')
    if 'deployment_branch_policy' not in environment:
        raise ValueError('The environment response lacks its deployment policy.')
    mode = environment['deployment_branch_policy']
    if mode is None:
        return True, 'Preview environment has no branch/tag restrictions.'
    if not isinstance(mode, dict):
        raise ValueError('The environment policy mode is unknown.')
    if mode.get('protected_branches') is True:
        raise ValueError('GitHub must evaluate the protected-branches policy, including its no-protected-branches and tag exceptions.')
    if mode.get('protected_branches') is not False or mode.get('custom_branch_policies') is not True:
        raise ValueError('The environment policy mode is unknown.')
    result = get('/environments/github-pages/deployment-branch-policies?per_page=100')
    policies = result.get('branch_policies')
    count = result.get('total_count')
    if not isinstance(policies, list) or type(count) is not int or count < 1 or count != len(policies):
        raise ValueError('The policy list is empty, incomplete, or paginated.')
    for policy in policies:
        if not isinstance(policy, dict) or policy.get('type') not in ('branch', 'tag') or not isinstance(policy.get('name'), str):
            raise ValueError('A deployment rule has an unknown type or name.')
    names = [policy['name'] for policy in policies if policy['type'] == kind]
    # Accept either representation conservatively; a possible match must not
    # become an early skip. GitHub decides final eligibility at deployment.
    if name in names or ref in names:
        return True, 'Preview environment has a literal rule for this ' + kind + '.'
    folded = name.casefold()
    if any(pattern.casefold() in (folded, ref.casefold()) for pattern in names):
        raise ValueError('A deployment rule differs from this ' + kind + ' only in letter case, so GitHub must decide.')
    if any(not re.fullmatch(r'[A-Za-z0-9_./-]+', pattern) for pattern in names):
        raise ValueError('GitHub must evaluate wildcard, escaped, or other nonliteral patterns.')
    return False, 'Preview skipped: ' + kind + ' ' + repr(name) + ' is not allowed by the github-pages environment deployment rules. Add it in Settings > Environments > github-pages, then run the workflow again.'


def main():
    warning = False
    try:
        allowed, note = check()
    except Exception as error:
        allowed = True
        warning = True
        note = 'Preview environment eligibility is unknown: ' + str(error).rstrip('.') + '. Continuing to GitHub\'s deploy-time check.'
    # Ref names cannot contain newlines; sanitize diagnostic exceptions too.
    note = note.replace('\r', ' ').replace('\n', ' ')
    print(('::warning::' if warning else '') + note)
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(note + '\n')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('preview=' + str(allowed).lower() + '\n')


if __name__ == '__main__':
    main()
