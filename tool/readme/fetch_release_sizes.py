"""Windows download sizes of other SSH clients, read from their latest public GitHub release.

  python -I fetch_release_sizes.py owner/repo [owner/repo...]

Prints one JSON line per repository with the tag, the release date and every Windows asset, so the
figures used in the README charts can be checked against the source.
"""

import json
import sys
import urllib.request

SKIP = ('.blockmap', '.yml', '.sha256', '.sig', '.txt')

for repo in sys.argv[1:]:
    request = urllib.request.Request(
        f'https://api.github.com/repos/{repo}/releases/latest',
        headers={'Accept': 'application/vnd.github+json', 'User-Agent': 'sshairy-readme'},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            release = json.load(response)
    except Exception as error:  # report and keep going; one missing repository should not hide the others
        print(json.dumps({'repo': repo, 'error': str(error)}))
        continue
    assets = [
        {'name': a['name'], 'mib': round(a['size'] / 2**20, 1)}
        for a in release.get('assets', [])
        if any(k in a['name'].lower() for k in ('win', '.exe', '.msi')) and not a['name'].endswith(SKIP)
    ]
    print(json.dumps({'repo': repo, 'tag': release.get('tag_name'), 'published': release.get('published_at'), 'assets': assets}))
