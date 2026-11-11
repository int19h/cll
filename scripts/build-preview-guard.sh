#!/bin/bash
# Authenticated, read-only API checks also work in private repositories.
# Keep the Python body identical to the inline late guard in build.yml.
set -euo pipefail
python3 - <<'PYTHON'
import json
import os
import re
import sys
import urllib.error
import urllib.request


def check_preview():
    policy = os.environ.get('BUILD_PAGES_PREVIEW') or 'auto'
    if policy == 'deny':
        return 'Preview skipped: BUILD_PAGES_PREVIEW=deny.'
    if policy != 'auto':
        raise ValueError('Invalid BUILD_PAGES_PREVIEW: use auto or deny.')
    token = os.environ['GH_TOKEN']
    if not token:
        raise ValueError('The preview guard requires the job token.')
    base = os.environ['GITHUB_API_URL'].rstrip('/') + '/repos/' + os.environ['GITHUB_REPOSITORY']

    def get(path, missing=False):
        request = urllib.request.Request(base + path, headers={
            'Authorization': 'Bearer ' + token,
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
        })
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if missing and error.code == 404:
                return None
            raise RuntimeError('GitHub API lookup failed for ' + path + ': HTTP ' + str(error.code)) from None

    # Confirm repository access before interpreting resource-level 404s.
    repository = get('')
    if not isinstance(repository.get('has_pages'), bool):
        raise ValueError('The repository response lacks has_pages.')
    site = get('/pages', missing=True)
    if site is None and repository['has_pages']:
        raise ValueError('Pages lookup returned 404 for an enabled site.')
    branch = get('/branches/pages', missing=True)
    if branch is not None:
        commit = branch['commit']['sha']
        if not re.fullmatch('[0-9a-f]{40}', commit):
            raise ValueError('The pages branch response has an invalid commit.')
        # Inspect the exact branch commit returned by the live lookup.
        marker = get('/contents/pages/versions.tsv?ref=' + commit, missing=True)
        if marker is not None:
            return 'Preview skipped: pages branch contains pages/versions.tsv (published book site). See the fork setup instructions.'
    if site is None:
        return 'Preview skipped: Pages is not enabled. Set Settings > Pages > Source to GitHub Actions.'
    if site.get('build_type') == 'legacy':
        return 'Preview skipped: Pages does not use GitHub Actions. Set Settings > Pages > Source to GitHub Actions.'
    if site.get('build_type') != 'workflow':
        raise ValueError('Pages lookup returned an unknown build_type.')
    return 'Preview allowed: no release manifest and Pages uses GitHub Actions.'


try:
    print(check_preview())
except Exception as error:
    sys.exit('Preview guard failed: ' + str(error))
PYTHON
