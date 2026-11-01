-- Integration (real git repos, real `bin/revuey` subprocesses, the fake `claude`): the connected
-- agent and the guide. `bin/revuey guide` (none, a guide, stale), `guide --prompt` (the agent's
-- instructions, the diff, the hash), `import-guide` (valid, invalid, stale, bad hunk refs);
-- choosing who writes a guide in the review (asked only with an agent connected; ai.guide_by
-- agent/fresh skip the question; a fresh session with another model passes --model and
-- --effort); the request (its event, the watch --messages and inbox lines, taken, imported and
-- shown in the running review with the agent in the meta line), withdrawing it, and a request
-- nobody takes.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local msgs = {}
vim.notify = function(msg, level)
  msgs[#msgs + 1] = { msg = msg, level = level }
end

local log = h.tmpdir('agent-guide-claude') .. '/calls.ndjson'
h.use_fake_claude(log)

local state_dir = h.tmpdir('agent-guide-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local config = require('revuey.config')
local view = require('revuey.view')
local gv = require('revuey.guide_view')
local link = require('revuey.agent_link')
local requests = require('revuey.requests')

local lines = {}
for i = 1, 40 do
  lines[#lines + 1] = 'line ' .. i
end
local long = table.concat(lines, '\n') .. '\n'
local changed = (long:gsub('line 20\n', 'twenty\n'))
local repo = h.repo('agent-guide', { ['m.txt'] = long }, {
  ['m.txt'] = changed,
  ['new.txt'] = 'brand new file\nwith two lines\n',
})

local BIN = h.root .. '/bin/revuey'
local ENV = { REVUEY_STATE_DIR = state_dir, REVUEY_NVIM = vim.v.progpath }

local function run(args, o)
  o = o or {}
  local cmd = { BIN }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { cwd = repo, env = o.env or ENV, text = true, stdin = o.stdin }):wait(20000)
end

local function calls()
  local out = {}
  local fd = io.open(log, 'r')
  if not fd then
    return out
  end
  for l in fd:lines() do
    out[#out + 1] = vim.json.decode(l)
  end
  fd:close()
  return out
end

local function arg_value(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then
      return argv[i + 1]
    end
  end
end

-- vim.ui.select / vim.ui.input answered from a queue (by label); every question is recorded
local asked, answers = {}, {}
vim.ui.select = function(items, opts, cb)
  asked[#asked + 1] = { items = items, prompt = opts and opts.prompt }
  local a = table.remove(answers, 1)
  cb(a and vim.tbl_contains(items, a) and a or nil)
end
vim.ui.input = function(opts, cb)
  asked[#asked + 1] = { input = true, prompt = opts and opts.prompt }
  cb(table.remove(answers, 1))
end
local function answer(...)
  asked, answers = {}, { ... }
end

local watchers = {}

---Start `bin/revuey watch --messages --name claude` and wait until it follows the feed.
local function watch()
  local w = { out = '', err = '' }
  watchers[#watchers + 1] = w
  w.proc = vim.system({ BIN, 'watch', '--messages', '--name', 'claude' }, {
    cwd = repo,
    env = ENV,
    text = true,
    stdout = function(_, data)
      if data then
        w.out = w.out .. data
      end
    end,
    stderr = function(_, data)
      if data then
        w.err = w.err .. data
      end
    end,
  })
  assert(vim.wait(10000, function()
    return w.err:find('watching', 1, true) ~= nil
  end, 20), 'watch did not start: ' .. w.err)
  return w
end

local function wait_out(w, pat)
  return vim.wait(10000, function()
    return w.out:find(pat, 1, true) ~= nil
  end, 20)
end

local function stop(w)
  w.proc:kill('sigterm')
  return w.proc:wait(5000)
end

h.teardown(function()
  for _, w in ipairs(watchers) do
    if not w.proc:is_closing() then
      pcall(stop, w)
    end
  end
end)

local function guide_doc(diff, extra)
  return vim.tbl_extend('force', {
    diff = diff,
    title = 'Twenty as a word, and a new file',
    summary = 'Line 20 is spelled out, and a small file is added.',
    sections = {
      {
        title = 'The number',
        overview = 'Line 20 becomes a word, as we discussed.',
        hunks = { { id = 'h1', note = 'the only change here' } },
        line_notes = { { hunk = 'h1', line = 5, text = 'Possible issue: a reader may parse this as a number.' } },
      },
      { title = 'A new file', overview = 'Two lines of text.', hunks = { { id = 'h2' } } },
    },
    unplaced = {},
  }, extra or {})
end

local function diff_hash()
  return vim.json.decode(run({ 'hunks', '--json' }).stdout).diff
end

local function guides_dir()
  return state_dir .. '/guides'
end

local function clear_guides()
  vim.fn.delete(guides_dir(), 'rf')
end

local s

local function idle()
  assert(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
  end, 10), 'refresh did not finish')
end

local function text()
  return table.concat(vim.api.nvim_buf_get_lines(s.diff_buf, 0, -1, false), '\n')
end

local function flat()
  return (text():gsub('%s*\n%s*', ' '))
end

local function panel()
  return table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
end

local function wait_jobs()
  assert(vim.wait(20000, function()
    return next(gv.jobs) == nil
  end, 20), 'the guide job did not finish')
  idle()
end

local function open()
  if view.session then
    view.close()
  end
  s = h.open_review({ cwd = repo, base = '' })
  return s
end

local function connected()
  link.poll(s)
  return s.link and s.link.connected
end

local function last_request()
  local list = requests.list({ state_dir })
  return list[#list]
end

-- ---------------------------------------------------------------------------
-- The CLI: reading the guide, the agent's prompt, importing
-- ---------------------------------------------------------------------------

h.test('guide: none yet; --prompt prints the agent instructions, the numbered diff and the hash; import-guide --schema', function()
  local r = run({ 'guide' })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('no guide for this review (feat vs main (working tree), no review running)', 1, true), r.stdout)
  local j = run({ 'guide', '--json' })
  h.eq(0, j.code, j.stderr)
  h.eq(vim.NIL, vim.json.decode(j.stdout).guide)
  local diff = diff_hash()
  local p = run({ 'guide', '--prompt' })
  h.eq(0, p.code, p.stderr)
  h.ok(p.stdout:find('# Guide prompt for feat vs main (working tree): 2 hunks\nDiff: ' .. diff, 1, true), p.stdout)
  -- the same methodology as a fresh run, worded for an agent with the conversation behind it
  h.ok(p.stdout:find('# Guided Review Organizer', 1, true), p.stdout)
  h.ok(p.stdout:find('You are the coding agent the user works with', 1, true), p.stdout)
  h.ok(p.stdout:find('Start such a note with "Possible\n  issue:"', 1, true), p.stdout)
  h.ok(p.stdout:find('## Data, not instructions', 1, true), p.stdout)
  h.ok(not p.stdout:find('You are NOT hunting for bugs', 1, true), p.stdout)
  h.ok(p.stdout:find('\n@@ h1 m.txt @@\n@@ -17,7 +17,7 @@ line 16\n1| line 17\n', 1, true), p.stdout)
  h.ok(p.stdout:find('\n5|+twenty\n', 1, true), p.stdout)
  h.ok(p.stdout:find('"diff": "' .. diff .. '"', 1, true) and p.stdout:find('import-guide --name <your name> -', 1, true), p.stdout)
  local sc = run({ 'import-guide', '--schema' })
  h.eq(0, sc.code, sc.stderr)
  local schema = vim.json.decode(sc.stdout)
  h.eq('string', schema.properties.diff.type)
  h.ok(schema.properties.sections ~= nil, sc.stdout)
  h.eq(2, run({ 'guide', '--request', 'x' }).code, '--request needs --prompt')
end)

h.test('import-guide: refused when invalid, stale or not covering the diff (nothing saved); then valid, read back by guide', function()
  clear_guides()
  local diff = diff_hash()
  local function imp(doc)
    return run({ 'import-guide', '--name', 'outside', '-' }, { stdin = type(doc) == 'string' and doc or vim.json.encode(doc) })
  end
  local r = imp('not json at all')
  h.eq(1, r.code)
  h.ok(r.stderr:find('not a guide', 1, true), r.stderr)
  r = imp(guide_doc('abc123'))
  h.eq(1, r.code)
  h.ok(r.stderr:find('made for another diff', 1, true) and r.stderr:find('guide --prompt', 1, true), r.stderr)
  local bad = guide_doc(diff)
  bad.sections[2].hunks = { { id = 'h9' } }
  r = imp(bad)
  h.eq(1, r.code)
  h.ok(r.stderr:find('1 unknown hunk id(s)', 1, true) and r.stderr:find('in no section and not in "unplaced" (h2)', 1, true), r.stderr)
  bad = guide_doc(diff)
  bad.sections[2].hunks = { { id = 'h1' } }
  r = imp(bad)
  h.eq(1, r.code)
  h.ok(r.stderr:find('listed twice', 1, true), r.stderr)
  h.eq(1, imp({ title = 'x', sections = {} }).code, 'no sections')
  h.eq(nil, vim.uv.fs_stat(guides_dir()), 'nothing saved')
  -- valid (a note on a line the hunk lacks is dropped and reported, as for fresh runs)
  local doc = guide_doc(diff)
  table.insert(doc.sections[1].line_notes, { hunk = 'h1', line = 40, text = 'past the hunk' })
  r = imp(doc)
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('imported the guide (2 sections, 1 line note) into feat vs main, working tree (no review running', 1, true), r.stdout)
  h.ok(r.stdout:find('line notes dropped: 1', 1, true), r.stdout)
  local g = run({ 'guide' })
  h.eq(0, g.code, g.stderr)
  local out = g.stdout
  h.ok(out:find('# Guide: Twenty as a word, and a new file', 1, true), out)
  h.ok(out:find('Generated by outside (connected)', 1, true), out)
  h.ok(out:find('Up to date', 1, true), out)
  h.ok(out:find('Line 20 is spelled out', 1, true), out)
  h.ok(out:find('## 1. The number\n\nLine 20 becomes a word, as we discussed.\n\nHunks: h1 m.txt\n- h1: the only change here\nLine notes:\n- h1:5 (new): Possible issue: a reader may parse this as a number.', 1, true), out)
  h.ok(out:find('## 2. A new file', 1, true) and out:find('Hunks: h2 new.txt', 1, true), out)
  local jj = vim.json.decode(run({ 'guide', '--json' }).stdout)
  h.eq({ false, 'outside (connected)', 'h1', 5 }, { jj.stale, jj.generated_by, jj.sections[1].hunks[1].id, jj.sections[1].line_notes[1].line })
end)

h.test('guide: stale after the diff changes (new hunks listed, the text may describe code that is gone)', function()
  local l = vim.split(changed, '\n')
  l[5] = 'five'
  vim.fn.writefile(l, repo .. '/m.txt', 'b')
  local g = run({ 'guide' })
  h.eq(0, g.code, g.stderr)
  h.ok(g.stdout:find('Stale: the diff changed since this guide was generated (1 new hunk(s), in "Not in guide")', 1, true), g.stdout)
  h.ok(g.stdout:find('Not in guide', 1, true), g.stdout)
  h.eq(true, vim.json.decode(run({ 'guide', '--json' }).stdout).stale)
  vim.fn.writefile(vim.split(changed, '\n'), repo .. '/m.txt', 'b')
  h.ok(run({ 'guide' }).stdout:find('Up to date', 1, true))
end)

-- ---------------------------------------------------------------------------
-- In the review: who writes the guide
-- ---------------------------------------------------------------------------

h.test('no agent connected: gG and :RevueyGuide! work as before (no question about who writes it)', function()
  clear_guides()
  vim.fn.delete(log)
  open()
  h.eq(false, connected())
  answer('Generate a guide')
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys(vim.keycode('gG'), 'mtx', false)
  h.eq(1, #asked)
  h.eq({ 'Generate a guide', 'Cancel' }, asked[1].items)
  wait_jobs()
  h.eq(1, #calls())
  -- ai.guide_by = 'agent' with nobody connected: a fresh run all the same, without asking
  config.options.ai.guide_by = 'agent'
  answer()
  view.guide_command(true)
  wait_jobs()
  h.eq(0, #asked)
  h.eq(2, #calls())
  config.options.ai.guide_by = 'ask'
  h.ok(not text():find('connected', 1, true), 'the meta line names the model')
  h.ok(text():find('claude-fake-1', 1, true), text())
end)

local live

h.test('agent connected: the choice; the request line, inbox, --prompt takes it, import-guide shows it in the review', function()
  clear_guides()
  vim.fn.delete(log)
  open()
  live = watch()
  h.ok(vim.wait(10000, connected, 50), 'presence did not flip on')
  h.eq('claude', link.agent_name(s))
  answer('Ask claude (connected)')
  view.guide_command(false) -- gG with no guide
  h.eq({ 'Ask claude (connected)', 'Fresh session (default model)', 'Fresh session with another model…', 'Cancel' }, asked[1].items)
  h.eq('No AI guide for this review yet. Generate one with:', asked[1].prompt)
  h.eq('guide', s.view_mode)
  local req = last_request()
  h.ok(req, 'a request file')
  h.eq({ 'guide', 'pending', 'feat', 'claude', tostring(vim.uv.os_getpid()) }, { req.kind, req.status, req.label, req.agent, req.session })
  h.eq(0, #calls(), 'no fresh run')
  -- the placeholder and the panel wait for the agent
  h.ok(flat():find('Asked claude, the connected agent, to write a guide for 2 hunks.', 1, true), text())
  h.ok(flat():find(':RevueyGuide cancel withdraws the request', 1, true), text())
  h.ok(gv.status_text(s):find('waiting for claude %d+s'), gv.status_text(s))
  h.ok(s.panel_status_row ~= nil, panel())
  -- the watch prints one actionable line
  local line = ('revuey request %s guide [feat]: the user asked you to write the guide for this review (%s guide --prompt --request %s)'):format(req.id, BIN, req.id)
  h.ok(wait_out(live, line), live.out .. live.err)
  h.ok(vim.wait(5000, function()
    return requests.read(req._path).delivered_at ~= nil
  end, 20), 'delivery recorded')
  -- inbox lists it until it is done
  local i = run({ 'inbox' })
  h.eq(0, i.code, i.stderr)
  h.ok(i.stdout:find(line .. '  (delivered, not handled)', 1, true), i.stdout)
  -- the agent takes it: the review says it is writing
  local p = run({ 'guide', '--prompt', '--request', req.id:sub(-8) })
  h.eq(0, p.code, p.stderr)
  h.ok(p.stdout:find(', request ' .. req.id, 1, true) and p.stdout:find('import-guide --request ' .. req.id .. ' --name <your name> -', 1, true), p.stdout)
  h.eq('acked', requests.read(req._path).status)
  h.ok(vim.wait(5000, function()
    return (gv.status_text(s) or ''):find('claude is writing the guide', 1, true) ~= nil
  end, 20), tostring(gv.status_text(s)))
  h.ok(run({ 'inbox' }).stdout:find('(started, not imported yet)', 1, true))
  -- a bad document is refused and the request stays open; a good one is shown at once
  local bad = guide_doc(p.stdout:match('Diff: (%x+)'))
  bad.sections[2] = nil
  local r = run({ 'import-guide', '--request', req.id, '-' }, { stdin = vim.json.encode(bad) })
  h.eq(1, r.code)
  h.ok(r.stderr:find('does not cover the diff', 1, true), r.stderr)
  h.eq('acked', requests.read(req._path).status)
  r = run({ 'import-guide', '--request', req.id, '-' }, { stdin = vim.json.encode(guide_doc(p.stdout:match('Diff: (%x+)'))) })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('; the review shows it', 1, true), r.stdout)
  h.eq('done', requests.read(req._path).status)
  h.ok(vim.wait(10000, function()
    return next(gv.jobs) == nil and s.guide and s.guide.resolved ~= nil
  end, 20), 'the review did not load the imported guide')
  idle()
  h.eq('Twenty as a word, and a new file', s.guide.resolved.title)
  h.ok(text():find('claude (connected)', 1, true), text())
  local notes = gv.note_rows(s)
  h.eq({ 1, 'Possible issue: a reader may parse this as a number.' }, { #notes, notes[1] and notes[1].text })
  h.ok(vim.iter(msgs):any(function(m)
    return m.msg:find('guide ready from claude (2 sections', 1, true) ~= nil
  end), vim.inspect(msgs))
  h.ok(run({ 'guide' }).stdout:find('Generated by claude (connected)', 1, true))
  h.ok(not run({ 'inbox' }).stdout:find('revuey request', 1, true), 'done: no longer listed')
  -- a done request cannot be cancelled into the guide's way
  h.eq(false, gv.cancel(s))
end)

h.test('regenerate (gR) with the agent, then cancel: the watch is told, import-guide refuses, the old guide stays', function()
  answer('Ask claude (connected)')
  view.regenerate_guide()
  h.eq('Regenerate the AI guide with:', asked[1].prompt)
  local req = last_request()
  h.eq('pending', req.status)
  h.ok(wait_out(live, 'revuey request ' .. req.id .. ' guide'), live.out)
  -- the old guide stays on screen with the status line while it waits
  h.ok(text():find('Twenty as a word', 1, true), text())
  -- gR again while waiting: keep waiting (nothing changes)
  answer('Keep waiting for claude')
  view.regenerate_guide()
  h.eq('Keep waiting for claude', asked[1].items[1])
  h.ok(gv.job(s) and gv.job(s).agent, 'still waiting')
  view.guide_command(false, 'cancel')
  h.eq(nil, gv.job(s))
  h.eq('cancelled', requests.read(req._path).status)
  h.ok(wait_out(live, ('revuey request %s cancelled [feat]: the user withdrew the guide request'):format(req.id)), live.out)
  local r = run({ 'import-guide', '--request', req.id, '-' }, { stdin = vim.json.encode(guide_doc(diff_hash(), { title = 'Too late' })) })
  h.eq(1, r.code)
  h.ok(r.stderr:find('was cancelled by the user', 1, true), r.stderr)
  h.eq(1, run({ 'guide', '--prompt', '--request', req.id }).code)
  idle()
  h.eq('Twenty as a word, and a new file', s.guide.resolved.title)
end)

h.test('a fresh session with another model passes --model and --effort to claude', function()
  vim.fn.delete(log)
  answer('Fresh session with another model…', 'sonnet', 'high')
  view.regenerate_guide()
  h.eq({ 'opus', 'sonnet', 'haiku', 'Other model…' }, asked[2].items)
  wait_jobs()
  local c = calls()
  h.eq(1, #c)
  h.eq({ 'sonnet', 'high' }, { arg_value(c[1].argv, '--model'), arg_value(c[1].argv, '--effort') })
  -- a model typed in, default effort
  answer('Fresh session with another model…', 'Other model…', 'claude-custom-9', 'Default effort')
  view.guide_command(true)
  wait_jobs()
  c = calls()
  h.eq({ 'claude-custom-9', nil }, { arg_value(c[2].argv, '--model'), arg_value(c[2].argv, '--effort') })
  h.ok(not text():find('claude (connected)', 1, true), 'a fresh run names its model')
end)

h.test('ai.guide_by = agent / fresh: no question about who writes it', function()
  config.options.ai.guide_by = 'fresh'
  vim.fn.delete(log)
  answer()
  view.guide_command(true)
  h.eq(0, #asked)
  wait_jobs()
  h.eq(1, #calls())
  config.options.ai.guide_by = 'agent'
  answer()
  view.guide_command(true)
  h.eq(0, #asked)
  local req = last_request()
  h.eq('pending', req.status)
  h.ok(gv.job(s).agent, 'asked the agent')
  view.guide_command(false, 'cancel')
  config.options.ai.guide_by = 'ask'
end)

local sessions = require('revuey.sessions')
local wpath

h.test('a watch started after the request catches up on it, once; --replay again; a cancelled one is not caught up', function()
  stop(live)
  h.ok(vim.wait(10000, function()
    return not connected()
  end, 50), 'presence did not flip off')
  -- an agent that is connected but never looks (a watcher record that keeps its heartbeat)
  wpath = sessions.write_watcher(s.link.bases, { pid = vim.fn.getpid(), session = s.link.id, worktree = s.review.root,
    started_at = sessions.now_ms(), heartbeat_at = sessions.now_ms(), name = 'claude' })
  h.ok(connected(), 'connected')
  config.options.ai.guide_by = 'agent'
  view.guide_command(true)
  config.options.ai.guide_by = 'ask'
  local req = last_request()
  h.eq('pending', req.status)
  local w = watch()
  h.ok(wait_out(w, 'revuey request ' .. req.id .. ' guide [feat]'), w.out .. w.err)
  h.eq(0, stop(w).code)
  local again = watch()
  vim.wait(1500)
  h.eq('', again.out)
  h.eq(0, stop(again).code)
  local out = ''
  local replay = vim.system({ BIN, 'watch', '--messages', '--replay', '--json' }, {
    cwd = repo,
    env = ENV,
    text = true,
    stdout = function(_, data)
      out = out .. (data or '')
    end,
  })
  h.ok(vim.wait(10000, function()
    return out:find('\n', 1, true) ~= nil
  end, 20), 'replay printed nothing')
  replay:kill('sigterm')
  replay:wait(5000)
  local ev = vim.json.decode(vim.split(vim.trim(out), '\n')[1])
  h.eq({ 'request', req.id, 'guide', 'pending' }, { ev.kind, ev.request_id, ev.request_kind, ev.status })
  view.guide_command(false, 'cancel')
  local after = watch()
  vim.wait(1500)
  h.eq('', after.out, 'cancelled: nothing to catch up')
  h.eq(0, stop(after).code)
  h.ok(not run({ 'inbox' }).stdout:find('revuey request', 1, true), 'cancelled: not in inbox')
end)

h.test('a request nobody takes: shown as not picked up; gR withdraws it and runs a fresh session', function()
  h.ok(connected(), 'connected')
  local before = gv.AGENT_ACK_MS
  gv.AGENT_ACK_MS = 300
  msgs = {}
  answer('Ask claude (connected)')
  view.regenerate_guide()
  local req = last_request()
  h.ok(vim.wait(5000, function()
    return (gv.status_text(s) or ''):find('has not picked it up', 1, true) ~= nil
  end, 20), tostring(gv.status_text(s)))
  h.ok(vim.iter(msgs):any(function(m)
    return m.msg:find('claude has not picked up the guide request yet', 1, true) ~= nil and m.level == vim.log.levels.WARN
  end), vim.inspect(msgs))
  vim.fn.delete(log)
  answer('Cancel the request and run a fresh session')
  view.guide_command(true)
  h.eq('claude was asked for the guide.', asked[1].prompt)
  wait_jobs()
  h.eq('cancelled', requests.read(req._path).status)
  h.eq(1, #calls(), 'the fresh run')
  gv.AGENT_ACK_MS = before
  sessions.remove(wpath)
  view.close()
end)

h.run()
