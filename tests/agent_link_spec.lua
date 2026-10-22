-- Integration: the link between a running review and a coding-agent session. The session
-- registry (`bin/revuey sessions` with zero, one and several sessions; scope switches; removal on
-- close), sending (`<C-a>` in the editor, `cs` on a comment, `ga` on a selection), `bin/revuey
-- watch --messages` (catch-up when started after a send, live lines when started before, --json,
-- clean exit on SIGTERM), presence in the panel header, `reply` marking a message answered in
-- the running review, `ack` stopping re-delivery, `show`, `inbox`, and `install-skill` into a
-- temporary HOME.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local msgs = {}
vim.notify = function(msg, level)
  msgs[#msgs + 1] = { msg = msg, level = level }
end
vim.o.columns, vim.o.lines = 160, 50

local state_dir = h.tmpdir('link-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local comments = require('revuey.comments')
local sessions = require('revuey.sessions')
local cv = require('revuey.comments_view')
local editor = require('revuey.comment_editor')
local link = require('revuey.agent_link')
local view = require('revuey.view')

local lines = {}
for i = 1, 40 do
  lines[#lines + 1] = 'line ' .. i
end
local long = table.concat(lines, '\n') .. '\n'
local repo = h.repo('link', { ['m.txt'] = long }, {
  ['m.txt'] = (long:gsub('line 20\n', 'twenty\n'):gsub('line 30\n', 'thirty\n')),
})
local lonely = h.repo('link-lonely', { ['a.txt'] = 'a\n' }, { ['a.txt'] = 'b\n' })

local BIN = h.root .. '/bin/revuey'
local ENV = { REVUEY_STATE_DIR = state_dir, REVUEY_NVIM = vim.v.progpath }
local ME = tostring(vim.uv.os_getpid())

local function run(args, o)
  o = o or {}
  local cmd = { BIN }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { cwd = o.cwd or repo, env = o.env or ENV, text = true, stdin = o.stdin }):wait(20000)
end

local watchers = {}

---Start `bin/revuey watch` and wait until it is following the feed.
local function watch(args, cwd)
  local w = { out = '', err = '' }
  watchers[#watchers + 1] = w
  local cmd = { BIN, 'watch' }
  vim.list_extend(cmd, args or {})
  w.proc = vim.system(cmd, {
    cwd = cwd or repo,
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

local s

local function idle()
  assert(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
  end, 10), 'refresh did not finish')
end

local function keys(k)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
  idle()
end

local function row_of(kind, lnum, path)
  for row, e in ipairs(s.layout.map) do
    if e.path == (path or 'm.txt') and e.kind == kind and (kind == 'del' and e.old_lnum or e.new_lnum) == lnum then
      return row
    end
  end
  error(('no %s row %d'):format(kind, lnum))
end

local function vlines(row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, cv.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, l in ipairs(m[4].virt_lines or {}) do
      local t = {}
      for _, c in ipairs(l) do
        t[#t + 1] = c[1]
      end
      out[#out + 1] = table.concat(t)
    end
  end
  return table.concat(out, '\n')
end

local function by_body(body)
  for _, c in pairs(s.cm.store.comments) do
    if not c.deleted and c.body == body then
      return c
    end
  end
end

local function events()
  local fd = io.open(s.cm.events)
  if not fd then
    return {}
  end
  local evs = comments.decode_events(fd:read('*a'))
  fd:close()
  return evs
end

local function last_sent()
  local evs = events()
  for i = #evs, 1, -1 do
    if evs[i].kind == 'sent' then
      return evs[i]
    end
  end
end

---Comment on `row` with gc and save it with <C-s>.
local function add(row, text)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys('gc')
  local st = editor.current
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, vim.split(text, '\n'))
  vim.api.nvim_feedkeys(vim.keycode('<C-s>'), 'mtx', false)
  return by_body(text)
end

local function connected()
  link.poll(s)
  return s.link and s.link.connected
end

local function header()
  return vim.wo[s.panel_win].winbar
end

h.test('sessions: none in a repo without a review; inbox and watch still work there', function()
  local r = run({ 'sessions' }, { cwd = lonely })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('no revuey sessions', 1, true), r.stdout)
  h.eq('[]', vim.trim(run({ 'sessions', '--json' }, { cwd = lonely }).stdout))
  local i = run({ 'inbox' }, { cwd = lonely })
  h.eq(0, i.code, i.stderr)
  h.ok(i.stdout:find('no unacknowledged messages', 1, true), i.stdout)
  -- an agent may connect first: watch waits for a review to start
  local w = watch({ '--messages' }, lonely)
  h.ok(w.err:find('no revuey session', 1, true), w.err)
  h.eq(0, stop(w).code, w.err)
end)

h.test('sessions: the running review is registered in the worktree git dir, invisible to git status', function()
  s = h.open_review({ cwd = repo })
  local r = run({ 'sessions' })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find(ME, 1, true), r.stdout)
  h.ok(r.stdout:find('feat', 1, true), r.stdout)
  h.ok(r.stdout:find('○ no agent', 1, true), r.stdout)
  local list = vim.json.decode(run({ 'sessions', '--json' }).stdout)
  h.eq(1, #list)
  local e = list[1]
  h.eq(ME, e.id)
  h.eq(vim.uv.os_getpid(), e.pid)
  h.eq(s.review.root, e.worktree)
  h.eq('feat', e.branch)
  h.eq(s.cm.events, e.events)
  h.eq(s.cm.path, e.comments)
  h.eq(vim.v.servername, e.server)
  h.eq(false, e.agent_connected)
  h.ok(e.scope_key and e.scope_key ~= '', vim.inspect(e))
  h.ok(e.started_at > 0)
  local gd = vim.uv.fs_realpath(repo .. '/.git')
  h.ok(vim.uv.fs_stat(gd .. '/revuey/sessions/' .. ME .. '.json'), 'registry file in the git dir')
  h.eq('', h.git(repo, 'status', '--porcelain'))
  h.ok(header():find('○ no agent', 1, true), header())
end)

h.test('sessions: several are listed, and watch asks which one', function()
  local other = vim.system({ 'sleep', '120' })
  local base = sessions.bases(repo)[1]
  local common = sessions.common_dir(repo)
  sessions.register({ base }, { pid = other.pid, worktree = s.review.root, common_dir = common, branch = 'feat', scope = { kind = 'branch' }, started_at = 1 })
  -- a review of another repo, registered in the shared state dir
  local elsewhere = vim.system({ 'sleep', '120' })
  sessions.register({ state_dir }, { pid = elsewhere.pid, worktree = '/some/other/repo', common_dir = '/some/other/repo/.git', branch = 'x', scope = { kind = 'branch' }, started_at = 1 })
  local r = run({ 'sessions' })
  h.ok(r.stdout:find(ME, 1, true) and r.stdout:find(tostring(other.pid), 1, true), r.stdout)
  h.eq(2, #vim.json.decode(run({ 'sessions', '--json' }).stdout))
  local w = run({ 'watch', '--messages' })
  h.eq(2, w.code)
  h.ok(w.stderr:find('--session', 1, true), w.stderr)
  h.ok(w.stderr:find(ME, 1, true) and w.stderr:find(tostring(other.pid), 1, true), w.stderr)
  -- --all from another worktree of the repo lists them too
  local wt = h.tmpdir('link-wt')
  vim.fn.delete(wt, 'rf')
  h.git(repo, 'worktree', 'add', '-q', wt, '-b', 'other')
  h.eq('[]', vim.trim(run({ 'sessions', '--json' }, { cwd = wt }).stdout))
  h.eq(2, #vim.json.decode(run({ 'sessions', '--json', '--all' }, { cwd = wt }).stdout), 'not the other repo')
  other:kill('sigkill')
  other:wait()
  elsewhere:kill('sigkill')
  elsewhere:wait()
  h.eq(1, #vim.json.decode(run({ 'sessions', '--json' }).stdout), 'the dead one is cleaned up')
end)

h.test('<C-a> in the editor saves the comment, marks it sent and appends a sent event (queued: no agent)', function()
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of('add', 20), 0 })
  keys('gc')
  local st = editor.current
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { 'Why twenty?', 'More detail.' })
  msgs = {}
  vim.api.nvim_feedkeys(vim.keycode('<C-a>'), 'mtx', false)
  h.eq(true, st.done)
  local c = by_body('Why twenty?\nMore detail.')
  h.ok(c, 'saved')
  h.eq('saved', c.status)
  h.ok(c.sent_at, 'marked sent')
  h.eq('sent', comments.delivery(c))
  h.ok(msgs[#msgs].msg:find('queued: no agent connected', 1, true), vim.inspect(msgs))
  local ev = last_sent()
  h.eq(c.id, ev.comment_id)
  h.eq(c.sent_at, ev.sent_at)
  h.eq('Why twenty?\nMore detail.', ev.message)
  h.eq({ path = 'm.txt', side = 'new', start_line = 20, end_line = 20 }, {
    path = ev.anchor.path,
    side = ev.anchor.side,
    start_line = ev.anchor.start_line,
    end_line = ev.anchor.end_line,
  })
  h.eq({ '+twenty' }, ev.snippet)
  h.eq(s.review.root, ev.review.repo)
  h.eq('feat', ev.review.branch)
  h.eq('main', ev.review.base)
  h.eq('branch', ev.review.scope)
  h.eq(ME, ev.session)
  h.ok(vlines(row_of('add', 20)):find('queued: no agent connected', 1, true), vlines(row_of('add', 20)))
end)

local live -- the watcher started before the next sends

h.test('watch --messages started after a send gets the catch-up; the panel shows the agent', function()
  live = watch({ '--messages' })
  local c = by_body('Why twenty?\nMore detail.')
  h.ok(wait_out(live, 'revuey message ' .. c.id), live.out .. live.err)
  local line = vim.split(vim.trim(live.out), '\n')[1]
  h.eq(
    ('revuey message %s m.txt:20 (new) [feat]: Why twenty?  (%s show %s for full context)'):format(c.id, BIN, c.id),
    line
  )
  h.ok(live.err:find('session ' .. ME, 1, true), live.err)
  h.ok(vim.wait(10000, connected, 50), 'presence did not flip on')
  h.ok(header():find('● agent connected', 1, true), header())
  -- the watch recorded the delivery; the review picks it up
  h.ok(vim.wait(5000, function()
    return vlines(row_of('add', 20)):find('sent → agent', 1, true) ~= nil
  end, 20), vlines(row_of('add', 20)))
  h.eq(true, vim.json.decode(run({ 'sessions', '--json' }).stdout)[1].agent_connected)
  -- the full event with --json
  -- printed once: a watch started now (Monitor re-armed) does not print it again ...
  local again = watch({ '--messages' })
  vim.wait(1500)
  h.eq('', again.out)
  h.eq(0, stop(again).code)
  h.eq('delivered', comments.delivery(comments.get(s.cm.store, c.id)))
  -- ... unless asked to replay; --json gives the full event
  local j = watch({ '--messages', '--json', '--replay' })
  h.ok(wait_out(j, '"kind":"sent"'), j.out)
  local ev = comments.decode_events(j.out)[1]
  h.eq(c.id, ev.comment_id)
  h.eq({ '+twenty' }, ev.snippet)
  h.eq('Why twenty?\nMore detail.', ev.message)
  h.eq(0, stop(j).code)
end)

h.test('cs sends an existing comment; a running watch prints it live (and nothing else)', function()
  local c = add(row_of('add', 30), 'Is thirty right?')
  h.eq(nil, c.sent_at)
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of('add', 30), 0 })
  msgs = {}
  keys('cs')
  c = by_body('Is thirty right?')
  h.eq('sent', comments.delivery(c))
  h.ok(msgs[#msgs].msg:find('sent to the agent', 1, true), vim.inspect(msgs))
  h.ok(wait_out(live, 'revuey message ' .. c.id .. ' m.txt:30 (new) [feat]: Is thirty right?'), live.out)
  -- plain comment events are not messages
  h.eq(nil, live.out:find('Is thirty right?.*Is thirty right?'), live.out)
  h.eq(2, #vim.split(vim.trim(live.out), '\n'), live.out)
end)

h.test('ga on a selection opens the ask editor; <C-a> sends it', function()
  local first, last = row_of('ctx', 17), row_of('ctx', 18)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { first, 0 })
  vim.api.nvim_feedkeys('V', 'nx', false)
  vim.api.nvim_win_set_cursor(s.diff_win, { last, 0 })
  keys('ga')
  local st = editor.current
  h.ok(st and not st.done, 'editor open')
  h.ok(st.opts.title:find('Ask', 1, true), st.opts.title)
  h.ok(st.opts.title:find('m.txt:17-18 (new)', 1, true), st.opts.title)
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { 'What do these do?' })
  vim.api.nvim_feedkeys(vim.keycode('<C-a>'), 'mtx', false)
  h.eq(true, st.done)
  local c = by_body('What do these do?')
  h.eq('sent', comments.delivery(c))
  h.eq({ ' line 17', ' line 18' }, last_sent().snippet)
  h.ok(wait_out(live, 'revuey message ' .. c.id .. ' m.txt:17-18 (new) [feat]: What do these do?'), live.out)
end)

h.test('reply marks the message answered; the running review shows it in the thread', function()
  local c = by_body('Why twenty?\nMore detail.')
  local r = run({ 'reply', c.id, 'Because the spec says so.' })
  h.eq(0, r.code, r.stderr)
  h.ok(vim.wait(5000, function()
    return comments.delivery(comments.get(s.cm.store, c.id)) == 'answered'
  end, 20), 'answered in the running review')
  local row = row_of('add', 20)
  h.ok(vim.wait(5000, function()
    return vlines(row):find('Because the spec says so.', 1, true) ~= nil
  end, 20), vlines(row))
  h.ok(vlines(row):find('answered', 1, true), vlines(row))
  h.eq(nil, vlines(row):find('sent → agent', 1, true), vlines(row))
  h.ok(comments.get(s.cm.store, c.id).answered_at, 'answered_at stored')
  -- the agent's own reply is not a message
  vim.wait(500)
  h.eq(nil, live.out:find('Because the spec', 1, true), live.out)
end)

h.test('show prints the message with its code and thread in Markdown', function()
  local c = by_body('Why twenty?\nMore detail.')
  local r = run({ 'show', c.id:sub(-7) })
  h.eq(0, r.code, r.stderr)
  local out = r.stdout
  for _, want in ipairs({
    '# Message ' .. c.id,
    'm.txt:20 (new)',
    'Branch: feat',
    'Base: main',
    '```diff\n+twenty\n```',
    'Why twenty?\nMore detail.',
    'Because the spec says so.',
    'reply ' .. c.id,
    'ack ' .. c.id,
  }) do
    h.ok(out:find(want, 1, true), 'missing ' .. want .. ' in\n' .. out)
  end
  h.eq(1, run({ 'show', 'nope' }).code)
end)

h.test('ack stops re-delivery: a new watch and inbox only list what is left', function()
  local acked = by_body('Is thirty right?')
  local left = by_body('What do these do?')
  local r = run({ 'ack', acked.id })
  h.eq(0, r.code, r.stderr)
  h.ok(vim.wait(5000, function()
    return comments.delivery(comments.get(s.cm.store, acked.id)) == 'seen'
  end, 20))
  h.ok(vim.wait(5000, function()
    return vlines(row_of('add', 30)):find('seen by agent', 1, true) ~= nil
  end, 20), vlines(row_of('add', 30)))
  -- delivered and not handled: a new watch leaves it alone, --replay and inbox list it
  local w = watch({ '--messages', '--replay' })
  h.ok(wait_out(w, 'revuey message ' .. left.id), w.out)
  vim.wait(500)
  h.eq(1, #vim.split(vim.trim(w.out), '\n'), w.out)
  h.eq(0, stop(w).code)
  local i = run({ 'inbox' })
  h.eq(0, i.code, i.stderr)
  h.eq(1, #vim.split(vim.trim(i.stdout), '\n'), i.stdout)
  h.ok(i.stdout:find('revuey message ' .. left.id, 1, true), i.stdout)
  h.ok(i.stdout:find('(delivered, not handled)', 1, true), i.stdout)
  local ij = vim.json.decode(run({ 'inbox', '--json' }).stdout)
  h.eq(1, #ij)
  h.eq(left.id, ij[1].comment_id)
  h.eq('sent', ij[1].kind)
  h.eq(true, ij[1].delivered)
  h.eq(1, run({ 'ack', 'nope' }).code)
  -- a comment never sent has nothing to acknowledge
  local plain = add(row_of('ctx', 19), 'just a note')
  local r2 = run({ 'ack', plain.id })
  h.eq(1, r2.code)
  h.ok(r2.stderr:find('never sent', 1, true), r2.stderr)
end)

h.test('presence flips off when watch stops (SIGTERM, exit 0, watcher removed)', function()
  h.eq(0, stop(live).code, live.err)
  h.eq(nil, live.err:find('deadly', 1, true), live.err)
  h.ok(vim.wait(10000, function()
    return not connected()
  end, 50), 'presence did not flip off')
  h.ok(header():find('○ no agent', 1, true), header())
  local base = sessions.bases(repo)[1]
  h.eq({}, sessions.watchers({ base }))
  -- markers follow delivery, not presence: a delivered message does not go back to "queued"
  local row = row_of('ctx', 18)
  h.ok(vlines(row):find('sent → agent', 1, true), vlines(row))
  h.eq(nil, vlines(row):find('queued', 1, true), vlines(row))
end)

h.test('ids: an ambiguous short id lists the candidates', function()
  local st = s.cm.store
  for _, id in ipairs({ 'abcabc0000000001', 'abcabc0000000002' }) do
    comments.put(st, comments.new({ path = 'm.txt', side = 'new', start_line = 2, end_line = 2 }, 'twin ' .. id, { id = id }))
  end
  comments.save(st)
  local r = run({ 'show', 'abcabc' })
  h.eq(1, r.code)
  h.ok(r.stderr:find('ambiguous', 1, true), r.stderr)
  h.ok(r.stderr:find('abcabc0000000001', 1, true) and r.stderr:find('abcabc0000000002', 1, true), r.stderr)
  h.eq(0, run({ 'show', 'abcabc0000000002' }).code)
end)

-- Review: with two reviews of one worktree, a watcher of one printed the other's messages, so
-- two agents acted on them.
h.test('two sessions: each watcher gets its own review\'s messages; a gone review\'s go to anyone', function()
  local other = vim.system({ 'sleep', '120' })
  local B = tostring(other.pid)
  local base = sessions.bases(repo)[1]
  local reg = sessions.register({ base }, {
    pid = other.pid,
    worktree = s.review.root,
    common_dir = sessions.common_dir(repo),
    branch = 'feat',
    scope = { kind = 'branch' },
    state_dir = state_dir,
    started_at = 1,
  })
  -- keep B alive in the registry while the test runs
  local keep = vim.uv.new_timer()
  keep:start(1000, 1000, vim.schedule_wrap(function()
    sessions.register({ base }, { pid = other.pid, worktree = s.review.root, branch = 'feat', scope = { kind = 'branch' }, state_dir = state_dir, started_at = 1 })
  end))
  local function send_from_b(body, row)
    local c = add(row, body)
    local sent = comments.mark_sent(s.cm.store, c.id, { session = B })
    comments.save(s.cm.store)
    comments.append_event(s.cm.events, comments.sent_event(sent, cv.review_info(s)))
    return sent
  end
  local wa = watch({ '--messages', '--session', ME })
  local m1 = send_from_b('from B, one', row_of('ctx', 21))
  vim.wait(2000)
  h.eq(nil, wa.out:find(m1.id, 1, true), wa.out)
  local wb = watch({ '--messages', '--session', B })
  h.ok(wait_out(wb, 'revuey message ' .. m1.id), wb.out)
  h.eq(0, stop(wb).code)
  -- B's own message while B lives and nobody watches it: still not A's
  local m2 = send_from_b('from B, two', row_of('ctx', 22))
  vim.wait(2000)
  h.eq(nil, wa.out:find(m2.id, 1, true), wa.out)
  -- this review's messages do reach A
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of('ctx', 19), 0 })
  keys('cs')
  h.ok(wait_out(wa, 'revuey message ' .. by_body('just a note').id), wa.out)
  -- B is gone (it crashed): its undelivered message is now anyone's; the delivered one is not repeated
  keep:stop()
  keep:close()
  other:kill('sigkill')
  other:wait()
  h.ok(wait_out(wa, 'revuey message ' .. m2.id), wa.out)
  h.eq(nil, wa.out:find(m1.id, 1, true), wa.out)
  h.eq(0, stop(wa).code)
  sessions.remove(reg)
end)

-- Review: a send whose comments save was deferred by a busy lock appended its event first, so
-- `show` and `reply` could not find the comment yet.
h.test('a sent event waits for the deferred comments save', function()
  local c = add(row_of('ctx', 23), 'while locked')
  local function sent_events()
    local n = 0
    for _, ev in ipairs(events()) do
      if ev.kind == 'sent' and ev.comment_id == c.id then
        n = n + 1
      end
    end
    return n
  end
  local lockf = s.cm.path .. '.lock'
  local fd = assert(io.open(lockf, 'w'))
  fd:write(('%d %s %d\n'):format(vim.uv.os_getpid(), vim.uv.os_gethostname(), os.time()))
  fd:close()
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of('ctx', 23), 0 })
  keys('cs')
  h.ok(require('revuey.lock').pending(s.cm.path), 'the save was deferred')
  vim.wait(500)
  h.eq(0, sent_events(), 'no event before the comment is on disk')
  os.remove(lockf)
  h.ok(vim.wait(10000, function()
    return sent_events() == 1
  end, 50), 'the event follows the save')
  h.ok(comments.get(comments.load(s.cm.path), c.id).sent_at, 'on disk with sent_at')
end)

h.test('install-skill: symlinks the skill into $HOME/.claude/skills; asks before overwriting', function()
  local home = h.tmpdir('link-home')
  local env = vim.tbl_extend('force', ENV, { HOME = home })
  local r = run({ 'install-skill' }, { env = env, cwd = home })
  h.eq(0, r.code, r.stderr)
  local dest = home .. '/.claude/skills/revuey'
  h.eq(h.root .. '/skill/revuey', vim.uv.fs_readlink(dest))
  h.ok(vim.uv.fs_stat(dest .. '/SKILL.md'), 'SKILL.md reachable')
  -- again: already installed
  r = run({ 'install-skill' }, { env = env, cwd = home })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('already installed', 1, true), r.stdout)
  -- a copy over the link: refused without --force (no terminal to ask on), done with it
  r = run({ 'install-skill', '--copy' }, { env = env, cwd = home, stdin = '' })
  h.eq(1, r.code)
  h.ok(r.stderr:find('--force', 1, true), r.stderr)
  r = run({ 'install-skill', '--copy', '--force' }, { env = env, cwd = home })
  h.eq(0, r.code, r.stderr)
  h.eq(nil, vim.uv.fs_readlink(dest))
  h.ok(vim.uv.fs_stat(dest .. '/SKILL.md'), 'copied')
  h.eq(BIN, vim.trim(table.concat(vim.fn.readfile(dest .. '/.revuey-bin'), '\n')))
  -- the copied wrapper runs this checkout's bin/revuey
  local res = vim.system({ dest .. '/revuey', 'sessions', '--json' }, { cwd = repo, env = env, text = true }):wait(20000)
  h.eq(0, res.code, res.stderr)
  h.eq(1, #vim.json.decode(res.stdout))
  -- an interactive "no" keeps what is there
  r = run({ 'install-skill' }, { env = vim.tbl_extend('force', env, { REVUEY_ASSUME_TTY = '1' }), cwd = home, stdin = 'n\n' })
  h.eq(1, r.code)
  h.eq(nil, vim.uv.fs_readlink(dest))
  -- --force never deletes a directory: it is moved aside
  vim.fn.writefile({ 'mine' }, dest .. '/NOTES.md')
  r = run({ 'install-skill', '--force' }, { env = env, cwd = home })
  h.eq(0, r.code, r.stderr)
  h.eq(h.root .. '/skill/revuey', vim.uv.fs_readlink(dest))
  local baks = vim.fn.glob(dest .. '.bak-*', false, true)
  h.eq(1, #baks, vim.inspect(vim.fn.readdir(vim.fs.dirname(dest))) .. r.stderr)
  h.ok(vim.uv.fs_stat(baks[1] .. '/NOTES.md'), 'the old directory is kept')
  h.ok(r.stderr:find('moved the existing', 1, true), r.stderr)
  -- the same checkout through a symlinked path is the same install; a worktree-looking path warns
  local alias = h.tmpdir('link-alias') .. '/.claude/worktrees/x'
  vim.fn.mkdir(vim.fs.dirname(alias), 'p')
  vim.uv.fs_symlink(h.root, alias)
  r = run({ 'install-skill' }, { env = vim.tbl_extend('force', env, { REVUEY_PLUGIN_DIR = alias }), cwd = home })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('already installed', 1, true), r.stdout)
  h.ok(r.stderr:find('looks temporary', 1, true), r.stderr)
end)

h.test('switching stack layers updates the registry; closing the review removes it', function()
  local stack = h.tmpdir('link-stack')
  vim.fn.delete(stack, 'rf')
  h.eq(0, vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', stack }):wait().code)
  local ready
  require('revuey').open({ cwd = stack, on_ready = function(x)
    ready = x
  end })
  h.ok(vim.wait(10000, function()
    return ready ~= nil
  end, 10), 'stack review did not open')
  s = ready
  h.eq(nil, vim.uv.fs_stat(vim.uv.fs_realpath(repo .. '/.git') .. '/revuey/sessions/' .. ME .. '.json'), 'the first review was closed')
  local function entry()
    return vim.json.decode(run({ 'sessions', '--json' }, { cwd = stack }).stdout)[1]
  end
  local e1 = entry()
  h.eq('stack/cart', e1.branch)
  h.eq('layer', e1.scope.kind)
  keys(']s')
  h.ok(vim.wait(10000, function()
    local e = entry()
    return e and e.branch == 'stack/ui'
  end, 50), vim.inspect(entry()))
  local e2 = entry()
  h.ok(e2.scope_key ~= e1.scope_key, 'scope key changed')
  h.eq(s.cm.events, e2.events)
  keys('gs')
  h.ok(vim.wait(10000, function()
    return entry().scope.kind == 'full'
  end, 50), vim.inspect(entry()))
  view.close({ keep_nvim = true })
  h.eq('[]', vim.trim(run({ 'sessions', '--json' }, { cwd = stack }).stdout))
end)

-- whatever failed above, leave no watcher behind
h.test('no watcher is left running', function()
  local left = 0
  for _, w in ipairs(watchers) do
    if w.proc and not w.proc:is_closing() then
      left = left + 1
      pcall(w.proc.kill, w.proc, 'sigterm')
      pcall(w.proc.wait, w.proc, 3000)
    end
  end
  h.eq(0, left)
end)

h.run()
