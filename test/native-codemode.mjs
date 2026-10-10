import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawn, execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { homedir, tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { once } from 'node:events'

const settingsPath = process.argv[2] || join(homedir(), '.pi/agent/settings.json')
const saved = readFileSync(settingsPath, 'utf8'), settings = JSON.parse(saved)
assert.deepEqual(settings.defaultTools, ['+codemode'])
assert.ok(settings.packages.includes('npm:pi-mcp-adapter'))
const prefix = execFileSync('npm', ['prefix', '-g'], { encoding: 'utf8' }).trim()
const manifestPath = realpathSync(process.argv[3] || join(homedir(), '.pi/agent/roles/manifest.json'))
const manifestText = readFileSync(manifestPath, 'utf8'), manifest = JSON.parse(manifestText)
const resource = value => value.startsWith('~/') ? join(homedir(), value.slice(2)) : resolve(dirname(manifestPath), value)
const root = mkdtempSync(join(tmpdir(), 'cockpit-native-codemode-')), requests = []
let code
const server = createServer(async (req, res) => {
  let input = ''; for await (const chunk of req) input += chunk
  const body = JSON.parse(input); requests.push(body)
  const enabled = body.tools.some(t => t.function?.name === 'codemode')
  const done = body.messages.some(m => m.role === 'tool') || !enabled
  const delta = done ? { role: 'assistant', content: 'fixture-done' } : {
    role: 'assistant', tool_calls: [{ index: 0, id: 'parent-call', type: 'function',
      function: { name: 'codemode', arguments: JSON.stringify({ code }) } }],
  }
  res.writeHead(200, { 'Content-Type': 'text/event-stream' })
  for (const [d, finish] of [[delta, null], [{}, done ? 'stop' : 'tool_calls']]) {
    res.write(`data: ${JSON.stringify({ id: 'fixture', object: 'chat.completion.chunk',
      model: 'fixture', choices: [{ index: 0, delta: d, finish_reason: finish }] })}\n\n`)
  }
  res.end('data: [DONE]\n\n')
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
try {
  for (const profile of ['coding', 'restricted', ...Object.keys(manifest.profiles)]) {
    const spec = manifest.profiles[profile], restricted = profile === 'restricted' || profile === 'lovable-watcher'
    const home = join(root, profile), agentDir = join(home, 'agent')
    const forbidden = spec ? '/proc/self/cockpit-codemode-forbidden' : join(home, 'forbidden.txt')
    code = `const reads=await Promise.all([tools.read({path:'one.txt'}),tools.read({path:'two.txt'})]);
text({reads:reads.map(x=>x.trim())});try{await tools.write({path:${JSON.stringify(forbidden)},content:'no'})}catch(e){text(e.message)}`
    if (spec) code += `;try{await tools.bash({command:'git push origin main'})}catch(e){text(e.message)}`
    mkdirSync(agentDir, { recursive: true })
    writeFileSync(join(agentDir, 'settings.json'), saved)
    writeFileSync(join(agentDir, 'models.json'), JSON.stringify({ providers: { fixture: {
      api: 'openai-completions', apiKey: 'fixture', baseUrl: `http://127.0.0.1:${server.address().port}/v1`,
      models: [{ id: 'fixture' }],
    } } }))
    writeFileSync(join(home, 'one.txt'), 'one\n'); writeFileSync(join(home, 'two.txt'), 'two\n')
    const extension = join(home, 'probe.ts')
    writeFileSync(extension, `export default function(pi) {
      pi.on('tool_call', e => ${!spec} && e.toolName === 'write' ? {block:true,reason:'fixture permission gate'} : undefined);
      pi.registerCommand('probe-tools', {handler:async (_args,ctx) => ctx.ui.notify(JSON.stringify(pi.getActiveTools()),'info')});
    }`)
    const child = spawn('pi', ['--mode', 'rpc', '--no-session', '--no-context-files',
      '--provider', 'fixture', '--model', 'fixture', '--thinking', 'off', '--extension', extension,
      ...(spec ? ['--no-extensions', '--no-skills', '--no-prompt-templates', '--tools', spec.tools.join(','),
        ...spec.extensions.flatMap(value => ['--extension', resource(value)])] :
        restricted ? ['--tools', 'read,bash,edit,write'] : [])], {
      cwd: home, env: { PATH: process.env.PATH, HOME: home, PI_CODING_AGENT_DIR: agentDir,
        PI_OFFLINE: '1', NPM_CONFIG_PREFIX: prefix, XDG_CONFIG_HOME: join(home, 'config'),
        XDG_CACHE_HOME: join(home, 'cache'), XDG_DATA_HOME: join(home, 'data'),
        ...(spec ? { COCKPIT_AGENT_PROFILE: profile, COCKPIT_AGENT_CWD: home, COCKPIT_ROLE_MANIFEST: manifestPath } : {}) },
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    let stderr = ''; child.stderr.on('data', b => { stderr += b })
    const events = [], waiters = [], exited = once(child, 'exit')
    const lines = createInterface({ input: child.stdout })
    lines.on('line', line => {
      const event = JSON.parse(line); events.push(event)
      for (const waiter of [...waiters]) if (waiter.matches(event)) waiter.resolve(event)
    })
    const send = message => child.stdin.write(JSON.stringify(message) + '\n')
    const wait = matches => new Promise((resolve, reject) => {
      const found = events.find(matches); if (found) return resolve(found)
      const timer = setTimeout(() => reject(new Error(`RPC timeout: ${stderr}\n${JSON.stringify(events)}`)), 20000)
      const waiter = { matches, resolve: event => {
        clearTimeout(timer); waiters.splice(waiters.indexOf(waiter), 1); resolve(event)
      } }; waiters.push(waiter)
    })
    try {
      send({ type: 'get_commands', id: 'commands' })
      const commands = await wait(e => e.id === 'commands')
      assert.ok(commands.success, JSON.stringify(commands))
      assert.equal(commands.data.commands.some(c => c.name === 'mcp'), profile !== 'lovable-watcher')
      send({ type: 'prompt', id: 'selection', message: '/probe-tools' })
      const notice = await wait(e => e.type === 'extension_ui_request' && e.method === 'notify' && e.message.startsWith('['))
      const active = JSON.parse(notice.message)
      if (spec) assert.deepEqual([...active].sort(), [...spec.tools].sort())
      else for (const name of ['read', 'bash', 'edit', 'write']) assert.ok(active.includes(name), name)
      assert.equal(active.includes('codemode'), !restricted)
      if (!restricted) assert.ok(active.includes('mcp'))
      const selection = await wait(e => e.id === 'selection')
      assert.equal(selection.data.disposition, 'handled')
      const before = requests.length
      send({ type: 'prompt', id: 'turn', message: 'Run the fixture.' })
      await wait(e => e.type === 'agent_end')
      assert.equal(requests.length - before, restricted ? 1 : 2)
      const starts = events.filter(e => e.type === 'tool_execution_start')
      if (restricted) assert.equal(starts.length, 0)
      else {
        assert.ok(starts.some(e => e.toolName === 'codemode' && e.toolCallId === 'parent-call'))
        const nested = starts.filter(e => e.parentToolCallId === 'parent-call')
        assert.deepEqual(nested.map(e => e.toolName).sort(), spec ? ['bash', 'read', 'read', 'write'] : ['read', 'read', 'write'])
        const ends = events.filter(e => e.type === 'tool_execution_end' && e.parentToolCallId === 'parent-call')
        assert.equal(ends.length, spec ? 4 : 3)
        assert.ok(ends.some(e => e.toolName === 'write' && e.isError))
        if (spec) assert.ok(ends.some(e => e.toolName === 'bash' && e.isError))
        const result = events.find(e => e.type === 'tool_execution_end' && e.toolName === 'codemode')
        const output = result.result.content.map(c => c.text || '').join('\n')
        assert.equal(result.isError, false, output)
        assert.ok(output.includes('{"reads":["one","two"]}'), output)
        assert.ok(output.includes(spec ? `${profile} may not write` : 'fixture permission gate'), output)
        if (spec) assert.match(output, /may not mutate GitHub|needs approval for this push/)
        const firstReadEnd = events.findIndex(e => e.type === 'tool_execution_end' && e.toolName === 'read')
        assert.ok(events.findIndex(e => e === nested[1]) < firstReadEnd, 'reads did not overlap')
      }
      assert.equal(existsSync(forbidden), false)
      child.stdin.end()
      const [status] = await exited; assert.equal(status, 0, stderr)
      console.log(`PASS: ${profile}: ${restricted ? 'Codemode excluded' : 'batching, nested permissions and adapter coexistence'}`)
    } finally {
      if (child.exitCode === null) { child.kill(); await exited }
      lines.close()
    }
  }
  console.log(`Verified settings SHA256 ${createHash('sha256').update(saved).digest('hex')}`)
  console.log(`Verified manifest SHA256 ${createHash('sha256').update(manifestText).digest('hex')}`)
  console.log('PASS: public RPC turns; no external model or MCP requests')
} finally {
  await new Promise(resolve => server.close(resolve))
  rmSync(root, { recursive: true, force: true })
}
