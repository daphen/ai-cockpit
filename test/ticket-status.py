import json
import os
import pathlib
import subprocess
import tempfile
import unittest

PROVIDER = pathlib.Path(__file__).resolve().parents[1] / 'qs-shell/ticket-status.py'


class TicketStatus(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cockpit-ticket-status-')
        self.addCleanup(self.temp.cleanup)
        root = pathlib.Path(self.temp.name)
        for name in ('ssh', 'gh'):
            command = root / name
            command.write_text('''#!/usr/bin/env python3
import json, os, sys
if os.path.basename(sys.argv[0]) == 'ssh':
    print(os.environ['WORKSPACE'])
elif os.environ.get('GH_FAIL') == '1':
    print('GitHub unavailable', file=sys.stderr); sys.exit(1)
elif os.environ.get('GH_FAIL') == 'auth':
    print('HTTP 401: Requires authentication (https://api.github.com/graphql)', file=sys.stderr); sys.exit(1)
elif sys.argv[1] == 'pr':
    print(os.environ['PR'])
elif 'check-runs' in sys.argv[2]:
    print(os.environ.get('RUNS', '{"check_runs": []}'))
else:
    print(os.environ['REVIEWS'])
''')
            command.chmod(0o755)
        self.env = dict(os.environ, PATH=self.temp.name + ':' + os.environ['PATH'])
        self.workspace = {'every-42': {'branch': 'daphen/every-42-amended', 'repo': 'lovablelabs/lovable', 'head': 'new',
                         'plan': {'phase': 'reconciled', 'branch': 'daphen/every-42-amended', 'done': 2, 'total': 2}}}
        self.pr = {'number': 42, 'url': 'https://github.com/lovablelabs/lovable/pull/42', 'state': 'OPEN', 'isDraft': False,
                   'headRefOid': 'new', 'mergeStateStatus': 'CLEAN', 'reviewDecision': 'APPROVED',
                   'statusCheckRollup': [{'name': 'test', 'conclusion': 'SUCCESS'}]}
        self.review = {'reviews': {'nodes': [
            {'state': 'COMMENTED', 'body': '**Code review found no issues**', 'commit': {'oid': 'new'}, 'author': {'login': 'claude', '__typename': 'Bot'}},
            {'state': 'APPROVED', 'body': '', 'commit': {'oid': 'new'}, 'author': {'login': 'human', '__typename': 'User'}},
        ]}, 'comments': {'nodes': []}, 'reviewThreads': {'nodes': [], 'pageInfo': {'hasNextPage': False}}}

    def check_status(self, prs=None):
        env = dict(self.env, WORKSPACE=json.dumps(self.workspace), PR=json.dumps([self.pr] if prs is None else prs),
                   REVIEWS=json.dumps({'data': {'repository': {'pullRequest': self.review}}}))
        result = subprocess.run(['python3', str(PROVIDER), json.dumps([{'name': 'every-42', 'cwd': '/vm/checkout'}])],
                                env=env, capture_output=True, text=True, check=True, timeout=10)
        return json.loads(result.stdout)['every-42']

    def test_ready_requires_current_head_evidence(self):
        self.assertEqual(self.check_status()['label'], 'Ready to merge')
        self.assertNotIn('action', self.check_status())
        claude = self.review['reviews']['nodes'][0]
        for body in ['## Claude Code Review\n\nThis repository is configured for manual code reviews. Comment `@claude review`', '']:
            claude['body'] = body
            needed = self.check_status()
            self.assertEqual(needed['label'], 'Claude review needed', body)
            self.assertEqual((needed['action'], needed['pr'], needed['repo']), ('claude-review', 42, 'lovablelabs/lovable'))
        claude['body'] = 'LGTM.'
        claude['commit']['oid'] = 'old'
        self.assertEqual(self.check_status()['label'], 'Claude review needed')
        def carried(conclusion, text):
            return json.dumps({'check_runs': [{'app': {'slug': 'claude'}, 'status': 'completed', 'conclusion': conclusion,
                                               'output': {'title': 'Code review skipped — no new changes', 'text': text}}]})
        clean = '<!-- bughunter-severity: {"nit":1,"normal":0,"pre_existing":0} -->'
        self.env['RUNS'] = carried('neutral', clean)
        self.review['reviews']['nodes'][1]['commit']['oid'] = 'old'
        self.assertEqual(self.check_status()['label'], 'Ready to merge', 'carried-over clean Claude check on the head')
        self.env['RUNS'] = carried('neutral', clean.replace('"normal":0', '"normal":2'))
        self.assertEqual(self.check_status()['label'], 'Claude review needed')
        self.env['RUNS'] = carried('neutral', '')
        self.assertEqual(self.check_status()['label'], 'Claude review needed')
        del self.env['RUNS']

    def test_failures_running_and_review_gates(self):
        self.pr['statusCheckRollup'][0]['conclusion'] = 'FAILURE'
        self.assertEqual(self.check_status()['label'], 'CI failing')
        self.pr['statusCheckRollup'][0] = {'name': 'build', 'status': 'IN_PROGRESS'}
        self.assertEqual(self.check_status()['label'], 'CI running')
        self.pr['statusCheckRollup'] = [{'name': 'build', 'conclusion': 'SUCCESS'}, {'name': 'e2e', 'conclusion': 'CANCELLED'}]
        cancelled = self.check_status()
        self.assertEqual(cancelled['label'], 'CI cancelled')
        self.assertIn('CI: cancelled: e2e', cancelled['details'])
        self.pr['statusCheckRollup'] = [{'context': 'stale-merge-gate', 'state': 'FAILURE'}]
        self.assertEqual(self.check_status()['label'], 'Update branch')
        self.pr['statusCheckRollup'] = [{'name': 'build', 'conclusion': 'SUCCESS'}]
        self.pr['reviewDecision'] = 'REVIEW_REQUIRED'
        self.assertEqual(self.check_status()['label'], 'Human review needed')
        self.review['comments']['nodes'] = [
            {'author': {'login': 'someone'}, 'body': '<!-- pr-classification-status -->\nAction: fake'},
            {'author': {'login': 'lovable-pr-classification'}, 'body': '<!-- pr-classification-status -->\nRisk: medium\nAction: pending claude[bot] LGTM\nReason: x'}]
        self.review['reviews']['nodes'][1]['state'] = 'COMMENTED'
        gated = self.check_status()
        self.assertEqual(gated['label'], 'Claude LGTM needed')
        self.assertIn('GitHub approval gate: Claude LGTM, then bot auto-approves; no human needed', gated['details'])
        self.assertIn('Human approval on PR head: not required', gated['details'])
        self.review['comments']['nodes'][1]['body'] = '<!-- pr-classification-status -->\nAction: pending human review from @infra'
        gated = self.check_status()
        self.assertEqual(gated['label'], 'Pending human review from @infra')
        self.assertIn('GitHub approval gate: bot: pending human review from @infra', gated['details'])
        self.assertIn('Human approval on PR head: not recorded', gated['details'])
        self.review['reviewThreads']['nodes'] = [{'isResolved': False, 'isOutdated': False}]
        self.assertEqual(self.check_status()['label'], 'Review findings')

    def test_mismatch_stale_plan_and_merged(self):
        self.workspace['every-42']['head'] = 'unpushed'
        differ = self.check_status()
        self.assertEqual((differ['label'], differ['action'], differ['localHead'], differ['prHead']), ('Local / PR head differ', 'sync', 'unpushed', 'new'))
        self.workspace['every-42']['plan']['branch'] = 'old-branch'
        self.assertIn({'label': 'Plan stale'}, self.check_status()['chips'])
        self.pr['state'] = 'MERGED'
        self.assertEqual((self.check_status()['label'], self.check_status()['action']), ('Merged', 'reap'))
        self.pr['state'] = 'CLOSED'
        self.assertNotIn('action', self.check_status())

    def test_missing_pr_and_source_failure_are_not_green(self):
        self.assertEqual(self.check_status([])['label'], 'PR needed')
        self.env['GH_FAIL'] = '1'
        self.assertEqual(self.check_status()['label'], 'Status unknown')
        self.env['GH_FAIL'] = 'auth'
        expired = self.check_status()
        self.assertEqual((expired['label'], expired['tone']), ('GitHub sign-in needed', 'error'))
        self.workspace = {'every-42': {'error': 'Workspace disconnected'}}
        self.assertEqual(self.check_status()['label'], 'Status unknown')


if __name__ == '__main__':
    unittest.main()
