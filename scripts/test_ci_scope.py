import json
import os
import subprocess
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
import ci_scope


class ScopeTests(unittest.TestCase):
    def test_server_change_does_not_release_mac(self):
        self.assertEqual(ci_scope.affected(['server/src/video_trim.rs']),
            dict(server=True, python=True, shared=False, macos=False, ios=False))

    def test_shared_change_checks_both_clients(self):
        result = ci_scope.affected(['shared/Sources/KeepsAPI/Models.swift'])
        self.assertTrue(all(result[key] for key in ('shared', 'macos', 'ios')))
        self.assertFalse(result['server'])

    def test_docs_only_and_workflow_changes(self):
        self.assertFalse(any(ci_scope.affected(['README.md', 'docs/ARCHITECTURE.md']).values()))
        self.assertTrue(all(ci_scope.affected(['.github/workflows/ci.yml']).values()))
        self.assertTrue(all(ci_scope.affected(['scripts/testflight.sh']).values()))

    def test_rename_covers_removed_and_added_paths(self):
        result = ci_scope.affected(['macos/old.swift', 'ios/new.swift'])
        self.assertTrue(result['macos'] and result['ios'])

    def test_push_uses_successful_baseline_not_event_before(self):
        with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo', GITHUB_RUN_NUMBER='20'), \
             patch.object(ci_scope, 'command', return_value=json.dumps({'workflow_runs': [
                 {'run_number': 21, 'head_sha': 'newer'},
                 {'run_number': 17, 'head_sha': 'last-passing'}]})) as command:
            self.assertEqual(ci_scope.baseline({'before': 'failed-or-cancelled'}, 'push'), 'last-passing')
            self.assertIn('status=success', command.call_args.args[-1])

    def test_first_run_and_manual_run_check_everything(self):
        with patch.dict(os.environ, GITHUB_REPOSITORY='owner/repo', GITHUB_RUN_NUMBER='1'), \
             patch.object(ci_scope, 'command', return_value='{"workflow_runs":[]}'):
            self.assertIsNone(ci_scope.baseline({}, 'push'))
        self.assertIsNone(ci_scope.baseline({}, 'workflow_dispatch'))

    def test_cancelled_mac_change_is_included_with_next_server_push(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', '-C', directory, *args], text=True).strip()
            def commit(message):
                git('add', '.')
                git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', message)
                return git('rev-parse', 'HEAD')
            git('init', '-q')
            (root / 'README.md').write_text('fixture')
            base = commit('passing')
            (root / 'macos').mkdir()
            (root / 'macos/player.swift').write_text('player change')
            commit('cancelled mac run')
            (root / 'server').mkdir()
            (root / 'server/video.rs').write_text('server change')
            commit('next push')
            event = root / 'event.json'
            event.write_text('{}')
            output = root / 'output'
            real_output = subprocess.check_output
            def in_repository(args, **kwargs):
                return real_output(args, cwd=directory, **kwargs)
            with patch.dict(os.environ, GITHUB_EVENT_PATH=str(event), GITHUB_EVENT_NAME='push', GITHUB_OUTPUT=str(output)), \
                 patch.object(ci_scope, 'baseline', return_value=base), \
                 patch.object(ci_scope.subprocess, 'check_output', side_effect=in_repository):
                ci_scope.main()
            values = dict(line.split('=') for line in output.read_text().splitlines())
            self.assertEqual(values, dict(server='true', python='true', shared='false', macos='true', ios='false'))

    def test_pr_uses_merge_base(self):
        event = {'pull_request': {'base': {'sha': 'base'}, 'head': {'sha': 'head'}}}
        with patch.object(ci_scope, 'command', return_value='ancestor') as command:
            self.assertEqual(ci_scope.baseline(event, 'pull_request'), 'ancestor')
            command.assert_called_once_with('git', 'merge-base', 'base', 'head')


if __name__ == '__main__':
    unittest.main()
