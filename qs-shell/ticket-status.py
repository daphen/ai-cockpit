import concurrent.futures
import datetime
import json
import os
import shlex
import re
import subprocess
import sys

REMOTE = r'''
import json, pathlib, re, subprocess, sys
out = {}
for s in json.loads(sys.argv[1]):
    try:
        def git(*args):
            return subprocess.check_output(['git', '-C', s['cwd'], *args], text=True, timeout=8).strip()
        origin = git('remote', 'get-url', 'origin')
        repo = re.search(r'github.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$', origin).group(1)
        row = {'branch': git('branch', '--show-current'), 'head': git('rev-parse', 'HEAD'), 'repo': repo}
        path = pathlib.Path(s['cwd']) / '.plans' / ((s.get('plan') or s['name'].upper()) + '.progress.json')
        doc = path.with_name(path.name.replace('.progress.json', '.md'))
        heading = doc.read_text().split('\n', 1)[0] if doc.exists() else ''
        if heading.startswith('# '):
            row['title'] = re.sub(r'^[A-Z]+-\d+\s+[—-]\s+', '', heading[2:]).strip()
        if path.exists():
            plan = json.loads(path.read_text())
            flow = plan.get('flow', [])
            row['plan'] = {k: plan.get(k) for k in ('phase', 'branch', 'updated_at', 'blocker')}
            row['plan'].update(done=sum(step.get('status') == 'done' for step in flow), total=len(flow))
        out[s['name']] = row
    except Exception as e:
        out[s['name']] = {'error': str(e)}
print(json.dumps(out))
'''

REVIEWS = '''query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviews(last:100){nodes{state body commit{oid} author{login __typename}}} comments(last:50){nodes{author{login} body}} reviewThreads(first:100){nodes{isResolved isOutdated} pageInfo{hasNextPage}}}}}'''
FIELDS = 'number,url,state,isDraft,headRefOid,mergeStateStatus,reviewDecision,statusCheckRollup'


def run(args, timeout=25):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=timeout)


def error_text(error):
    if isinstance(error, subprocess.TimeoutExpired):
        return 'Status check timed out'
    if isinstance(error, subprocess.CalledProcessError):
        return (error.stderr or 'Status command failed').strip()
    return str(error)


def status(workspace):
    checked = datetime.datetime.now(datetime.timezone.utc).strftime('%H:%M UTC')
    details = ['Checked ' + checked]
    chips = []
    label, tone = 'Status unknown', 'muted'
    extra = {}
    if workspace.get('error'):
        return dict(label=label, tone=tone, chips=[], details='Workspace status unavailable: ' + workspace['error'])
    plan = workspace.get('plan', {})
    phase = plan.get('phase', '')
    if plan:
        current_plan = plan.get('branch') == workspace['branch']
        chips.append(dict(label=('Plan ' + phase) if current_plan else 'Plan stale'))
        details += [f"Plan: {phase}; {plan['done']}/{plan['total']} steps complete",
                    'Plan branch: ' + str(plan.get('branch', 'unknown'))]
        if not current_plan:
            phase = ''
        if plan.get('blocker'):
            details.append('Plan blocker: ' + str(plan['blocker']))
    try:
        prs = json.loads(run(['gh', 'pr', 'list', '--repo', workspace['repo'], '--head', workspace['branch'],
                              '--state', 'all', '--limit', '1', '--json', FIELDS]))
        if not prs:
            if phase == 'blocked': label, tone = 'Blocked', 'error'
            elif phase == 'reconciled': label, tone = 'PR needed', 'accent'
            elif phase == 'implementing':
                label = 'Reconcile needed' if plan['total'] and plan['done'] == plan['total'] else 'Implementing'
                tone = 'accent'
            elif phase == 'planned': label, tone = 'Implementation needed', 'accent'
            else: label = 'No PR'
            return dict(label=label, tone=tone, chips=chips, details='\n'.join(details))
        pr = prs[0]
        chips.insert(0, dict(label='PR #' + str(pr['number']), url=pr['url']))
        details += ['Branch: ' + workspace['branch'], 'PR head: ' + pr['headRefOid'][:10]]
        if pr['state'] != 'OPEN':
            merged = pr['state'] == 'MERGED'
            return dict(label='Merged' if merged else 'PR closed', tone='success' if merged else 'muted', chips=chips,
                        details='\n'.join(details), **(dict(action='reap') if merged else {}))
        owner, repo = workspace['repo'].split('/')
        review = json.loads(run(['gh', 'api', 'graphql', '-f', 'query=' + REVIEWS, '-f', 'owner=' + owner,
                                 '-f', 'repo=' + repo, '-F', 'number=' + str(pr['number'])]))['data']['repository']['pullRequest']
        head_reviews = [r for r in review['reviews']['nodes'] if r['commit']['oid'] == pr['headRefOid']]
        claude = any(r['author'] and r['author']['login'] == 'claude' and r['body'].strip() and 'configured for manual code reviews' not in r['body']
                     for r in head_reviews)
        if not claude:
            runs = json.loads(run(['gh', 'api', f"repos/{workspace['repo']}/commits/{pr['headRefOid']}/check-runs?check_name=Claude%20Code%20Review"]))['check_runs']
            claude = any(r['app'] and r['app']['slug'] == 'claude' and r['status'] == 'completed' and r['conclusion'] in ('success', 'neutral')
                         and re.search(r'"normal":\s*0\b', (r['output'] or {}).get('text') or '') for r in runs)
        latest = {r['author']['login']: r for r in head_reviews if r['author']}
        human = any(r['state'] == 'APPROVED' and r['author']['__typename'] == 'User' for r in latest.values())
        gate = next((m.group(1).strip() for c in reversed(review['comments']['nodes'])
                     if c['author'] and c['author']['login'] == 'lovable-pr-classification' and '<!-- pr-classification-status -->' in c['body']
                     for m in [re.search(r'^Action: (.+)$', c['body'], re.M)] if m), None)
        claude_gate = bool(gate) and re.fullmatch(r'pending claude\[bot\] LGTM', gate) is not None
        threads = review['reviewThreads']
        unresolved = sum(not t['isResolved'] and not t['isOutdated'] for t in threads['nodes'])
        checks = pr['statusCheckRollup'] or []
        def result(check): return check.get('conclusion') or check.get('state') or check.get('status')
        failed = [c.get('name') or c.get('context') for c in checks if result(c) in ('FAILURE', 'ERROR', 'TIMED_OUT', 'ACTION_REQUIRED')]
        cancelled = [c.get('name') or c.get('context') for c in checks if result(c) == 'CANCELLED']
        pending = any(result(c) not in ('SUCCESS', 'SKIPPED', 'NEUTRAL', 'CANCELLED') for c in checks) and not failed
        chips.insert(1, dict(label='CI failing' if failed else 'CI running' if pending else 'CI cancelled' if cancelled else 'Checks complete' if checks else 'CI unknown', tone='error' if failed or cancelled and not pending else 'muted'))
        details += ['CI: ' + (', '.join(failed) if failed else 'running / incomplete' if pending else 'cancelled: ' + ', '.join(cancelled) if cancelled else 'checks complete' if checks else 'unknown'),
                    'Claude review on PR head: ' + ('recorded' if claude else 'not recorded'),
                    'Human approval on PR head: ' + ('recorded' if human else 'not required' if claude_gate else 'not recorded'),
                    'GitHub approval gate: ' + ('Claude LGTM, then bot auto-approves; no human needed' if claude_gate and pr['reviewDecision'] == 'REVIEW_REQUIRED'
                                                else 'bot: ' + gate if gate and pr['reviewDecision'] == 'REVIEW_REQUIRED' else str(pr['reviewDecision'] or 'unknown')),
                    'Unresolved review threads: ' + str(unresolved) + (' (partial)' if threads['pageInfo']['hasNextPage'] else '')]
        if workspace['head'] != pr['headRefOid']:
            return dict(label='Local / PR head differ', tone='accent', chips=chips, details='\n'.join(details),
                        action='sync', localHead=workspace['head'], prHead=pr['headRefOid'], branch=workspace['branch'], pr=pr['number'])
        if pr['mergeStateStatus'] == 'DIRTY': label, tone = 'Merge conflict', 'error'
        elif 'stale-merge-gate' in failed: label, tone = 'Update branch', 'error'
        elif failed: label, tone = 'CI failing', 'error'
        elif pr['reviewDecision'] == 'CHANGES_REQUESTED' or unresolved: label, tone = 'Review findings', 'error'
        elif phase == 'blocked': label, tone = 'Blocked', 'error'
        elif pending: label, tone = 'CI running', 'accent'
        elif cancelled: label, tone = 'CI cancelled', 'error'
        elif pr['isDraft']: label, tone = 'Draft PR', 'muted'
        elif not claude:
            label, tone = 'Claude review needed', 'accent'
            extra = dict(action='claude-review', pr=pr['number'], repo=workspace['repo'])
        elif pr['reviewDecision'] == 'REVIEW_REQUIRED' and gate: label, tone = 'Claude LGTM needed' if claude_gate else gate[0].upper() + gate[1:], 'accent'
        elif pr['reviewDecision'] == 'REVIEW_REQUIRED': label, tone = 'Human review needed', 'accent'
        elif threads['pageInfo']['hasNextPage']: label, tone = 'Review status unknown', 'muted'
        elif checks and pr['reviewDecision'] == 'APPROVED' and pr['mergeStateStatus'] == 'CLEAN': label, tone = 'Ready to merge', 'success'
        else: label, tone = 'PR open', 'muted'
    except (subprocess.SubprocessError, ValueError, KeyError, TypeError) as e:
        text = error_text(e)
        label, tone = ('GitHub sign-in needed', 'error') if 'HTTP 401' in text or 'gh auth login' in text else ('Status unknown', 'muted')
        details.append('GitHub status unavailable: ' + text)
    return dict(label=label, tone=tone, chips=chips, details='\n'.join(details), **extra)


def main():
    sessions = json.loads(sys.argv[1])
    user = os.getenv('COCKPIT_VM_USER') or os.getenv('HEIDR_VM_USER') or 'david_karlsson_lovable_dev'
    vm = os.getenv('COCKPIT_VM') or os.getenv('HEIDR_VM') or 'dev-heidr-2a39'
    host = os.getenv('COCKPIT_VM_HOST') or os.getenv('HEIDR_VM_HOST') or vm + '.workstation.lovable.net'
    try:
        command = 'python3 -c ' + shlex.quote(REMOTE) + ' ' + shlex.quote(json.dumps(sessions))
        workspaces = json.loads(run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', user + '@' + host, command], timeout=45))
    except (subprocess.SubprocessError, ValueError) as e:
        workspaces = {s['name']: {'error': error_text(e)} for s in sessions}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        values = list(pool.map(status, [workspaces[s['name']] for s in sessions]))
    for session, value in zip(sessions, values):
        if workspaces[session['name']].get('title'):
            value['title'] = workspaces[session['name']]['title']
        value['checkedAt'] = int(datetime.datetime.now(datetime.timezone.utc).timestamp() * 1000)
    print(json.dumps(dict(zip([s['name'] for s in sessions], values))))


if __name__ == '__main__':
    main()
