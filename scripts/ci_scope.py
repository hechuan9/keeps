#!/usr/bin/env python3
"""Select checks since the last successful CI so cancelled pushes remain covered."""
import json
import os
import subprocess
from pathlib import Path

GROUPS = ('server', 'python', 'shared', 'macos', 'ios')


def affected(paths):
    selected = set()
    for path in paths:
        if path.endswith('.md') or path.startswith('docs/'):
            continue
        if path.startswith('server/') or path.startswith('deploy/'):
            selected.update(('server', 'python'))
        elif path.startswith('control_plane/'):
            selected.add('python')
        elif path.startswith('shared/'):
            selected.update(('shared', 'macos', 'ios'))
        elif path.startswith('macos/'):
            selected.add('macos')
        elif path.startswith('ios/'):
            selected.add('ios')
        else:
            selected.update(GROUPS)
    return {group: group in selected for group in GROUPS}


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def baseline(event, event_name):
    if event_name == 'pull_request':
        return command('git', 'merge-base', event['pull_request']['base']['sha'],
                       event['pull_request']['head']['sha'])
    if event_name != 'push':
        return None
    repository = os.environ['GITHUB_REPOSITORY']
    current = int(os.environ['GITHUB_RUN_NUMBER'])
    # The immediately preceding push may have been cancelled or failed.
    payload = json.loads(command('gh', 'api',
        f'repos/{repository}/actions/workflows/ci.yml/runs?branch=main&event=push&status=success&per_page=100'))
    for run in payload['workflow_runs']:
        if run['run_number'] < current:
            return run['head_sha']
    return None


def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    base = baseline(event, os.environ['GITHUB_EVENT_NAME'])
    if base:
        # Include both sides of renames so moving code out of a package still tests it.
        paths = subprocess.check_output(['git', 'diff', '--name-only', '--no-renames', '-z', base, 'HEAD']).decode().split('\0')
        result = affected(path for path in paths if path)
    else:
        result = dict.fromkeys(GROUPS, True)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for group, enabled in result.items():
            output.write(f'{group}={str(enabled).lower()}\n')
    print(json.dumps({'base': base, 'checks': result}))


if __name__ == '__main__':
    main()
