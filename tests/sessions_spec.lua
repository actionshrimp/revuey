-- Unit: the session link to coding agents. The session registry (sessions.lua: write, list,
-- stale cleanup, fallback when the git dir is not writable), watcher heartbeats and presence
-- freshness, and the comment side (comments.lua): delivery state of sent comments, merge of the
-- delivery timestamps, the `sent` event and catch-up selection (unacknowledged only).
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local sessions = require('revuey.sessions')
local comments = require('revuey.comments')

local host = vim.uv.os_gethostname()
local me = vim.uv.os_getpid()

---A pid that has just exited (its process is gone).
local function dead_pid()
  local p = vim.system({ 'true' })
  p:wait()
  return p.pid
end

local function entry(pid, extra)
  return vim.tbl_extend('force', {
    pid = pid,
    host = host,
    worktree = '/w/one',
    git_dir = '/w/one/.git',
    branch = 'feat',
    scope = { kind = 'branch', label = 'feat' },
    scope_key = 'one-feat-main-abc',
    events = '/state/one.events.jsonl',
    comments = '/state/one.comments.json',
    state_dir = '/state',
    server = 'localhost:6789', -- not a path: not checked
    started_at = 1000,
  }, extra or {})
end

h.test('registry: write, read back, update in place, remove', function()
  local base = h.tmpdir('reg-basic')
  local path = sessions.register({ base }, entry(me))
  h.eq(base .. '/sessions/' .. me .. '.json', path)
  local list = sessions.list({ base })
  h.eq(1, #list)
  local e = list[1]
  h.eq(tostring(me), e.id)
  h.eq('/w/one', e.worktree)
  h.eq('/w/one/.git', e.git_dir)
  h.eq('feat', e.branch)
  h.eq('one-feat-main-abc', e.scope_key)
  h.eq('/state/one.events.jsonl', e.events)
  h.eq('localhost:6789', e.server)
  h.eq(1000, e.started_at)
  h.eq(path, e._path)
  -- a scope switch rewrites the same file
  sessions.register({ base }, entry(me, { branch = 'stack/cart', scope_key = 'two' }))
  list = sessions.list({ base })
  h.eq(1, #list)
  h.eq('stack/cart', list[1].branch)
  h.eq('two', list[1].scope_key)
  -- no temp files left behind
  h.eq({ me .. '.json' }, vim.fn.readdir(base .. '/sessions'))
  sessions.remove(path)
  h.eq({}, sessions.list({ base }))
end)

h.test('registry: entries of dead processes are removed when listed; other hosts are kept', function()
  local base = h.tmpdir('reg-stale')
  local dead = dead_pid()
  sessions.register({ base }, entry(me))
  sessions.register({ base }, entry(dead))
  local other = entry(dead, { host = 'some-other-host' })
  other.id = 'remote-1'
  sessions.register({ base }, other)
  -- an unreadable entry is removed too
  vim.fn.writefile({ '{oops' }, base .. '/sessions/junk.json')
  local ids = vim.tbl_map(function(e)
    return e.id
  end, sessions.list({ base }))
  table.sort(ids)
  h.eq({ tostring(me), 'remote-1' }, ids)
  h.eq(nil, vim.uv.fs_stat(base .. '/sessions/' .. dead .. '.json'))
  h.eq(nil, vim.uv.fs_stat(base .. '/sessions/junk.json'))
end)

-- Review (ghost sessions): after a crash the pid may be reused, so a live pid is not enough.
-- Re-review: but a review that is only quiet (suspended with Ctrl-Z, blocked) is not dead.
h.test('registry: quiet reviews stay alive while their socket answers; ghosts are dead', function()
  local base = h.tmpdir('reg-ghost')
  local function age(p)
    local e = vim.json.decode(table.concat(vim.fn.readfile(p), '\n'))
    e.updated_at = sessions.now_ms() - sessions.STALE_MS - 1000
    vim.fn.writefile({ vim.json.encode(e) }, p)
  end
  -- quiet, and nothing to prove it is still the same Neovim (no socket path): dead
  local p = sessions.register({ base }, entry(me))
  h.eq(1, #sessions.list({ base }))
  age(p)
  h.eq({}, sessions.list({ base }))
  h.eq(nil, vim.uv.fs_stat(p), 'removed')
  -- quiet but its RPC socket still accepts connections (suspended, blocked): alive
  local dir = h.tmpdir('reg-quiet')
  local sock = dir .. '/s'
  local server = vim.uv.new_pipe(false)
  assert(server:bind(sock))
  assert(server:listen(16, function() end))
  p = sessions.register({ base }, entry(me, { server = sock }))
  age(p)
  h.eq(1, #sessions.list({ base }), 'a quiet review keeps its entry')
  -- quiet, and the socket file is left behind but nobody listens (crashed, pid reused): dead
  server:close()
  vim.wait(50)
  vim.fn.delete(sock)
  vim.fn.writefile({}, sock)
  h.eq({}, sessions.list({ base }))
  -- refreshed, but its socket is gone: dead
  p = sessions.register({ base }, entry(me, { server = dir .. '/gone' }))
  h.eq({}, sessions.list({ base }))
  -- a server address that is not a path (tcp) is not checked while the entry is refreshed
  sessions.register({ base }, entry(me, { server = '127.0.0.1:6666' }))
  h.eq(1, #sessions.list({ base }))
end)

h.test('registry: falls back to the next base when the first is not writable; filters by worktree', function()
  local root = h.tmpdir('reg-fallback')
  local ro = root .. '/ro'
  vim.fn.mkdir(ro, 'p')
  vim.uv.fs_chmod(ro, tonumber('555', 8))
  local fallback = root .. '/state'
  local path = sessions.register({ ro .. '/revuey', fallback }, entry(me))
  vim.uv.fs_chmod(ro, tonumber('755', 8))
  h.eq(fallback .. '/sessions/' .. me .. '.json', path)
  local e2 = entry(me, { worktree = '/w/two' })
  e2.id = 'second'
  sessions.register({ fallback }, e2)
  h.eq(2, #sessions.list({ ro .. '/revuey', fallback }))
  local one = sessions.list({ ro .. '/revuey', fallback }, { worktree = '/w/two' })
  h.eq(1, #one)
  h.eq('second', one[1].id)
end)

h.test('bases: the per-worktree git dir first, then the state dir', function()
  local repo = h.repo('reg-bases', { ['a.txt'] = 'a\n' })
  local b = sessions.bases(repo, '/some/state')
  local gd = vim.uv.fs_realpath(repo .. '/.git')
  h.eq({ gd .. '/revuey', '/some/state' }, b)
  -- a linked worktree has its own git dir
  local wt = h.tmpdir('reg-bases-wt')
  vim.fn.delete(wt, 'rf')
  h.git(repo, 'worktree', 'add', '-q', wt, '-b', 'other')
  local wb = sessions.bases(wt, '/some/state')
  h.eq(vim.uv.fs_realpath(repo .. '/.git/worktrees/' .. vim.fs.basename(wt)) .. '/revuey', wb[1])
  -- every worktree of the repo (for --all)
  local all = sessions.all_bases(wt, '/some/state')
  h.ok(vim.tbl_contains(all, gd .. '/revuey'), vim.inspect(all))
  h.ok(vim.tbl_contains(all, wb[1]), vim.inspect(all))
  h.ok(vim.tbl_contains(all, '/some/state'), vim.inspect(all))
  -- outside a repo: the state dir only
  h.eq({ '/some/state' }, sessions.bases(h.tmpdir('reg-norepo'), '/some/state'))
end)

h.test('presence: a watcher counts while its heartbeat is fresh and its process alive', function()
  local base = h.tmpdir('presence')
  local now = sessions.now_ms()
  local w = { pid = me, host = host, session = '42', worktree = '/w/one', started_at = now, heartbeat_at = now }
  h.eq(true, sessions.fresh(w, now + 1000))
  h.eq(true, sessions.fresh(w, now + sessions.FRESH_MS - 1))
  h.eq(false, sessions.fresh(w, now + sessions.FRESH_MS + 1))
  h.eq(false, sessions.fresh(vim.tbl_extend('force', w, { pid = dead_pid() }), now + 1000))
  h.eq(false, sessions.fresh(vim.tbl_extend('force', w, { heartbeat_at = 'x' }), now))
  -- written, listed, matched to a session (or, attached to no session yet, to its worktree)
  local path = sessions.write_watcher({ base }, w)
  h.eq(base .. '/watchers/' .. me .. '.json', path)
  h.eq(true, sessions.connected({ base }, { id = '42', worktree = '/w/one' }, now + 1000))
  h.eq(false, sessions.connected({ base }, { id = '43', worktree = '/w/one' }, now + 1000))
  h.eq(false, sessions.connected({ base }, { id = '42', worktree = '/w/one' }, now + sessions.FRESH_MS + 5))
  sessions.write_watcher({ base }, vim.tbl_extend('force', w, { session = vim.NIL }))
  h.eq(true, sessions.connected({ base }, { id = '43', worktree = '/w/one' }, now + 1000))
  h.eq(false, sessions.connected({ base }, { id = '43', worktree = '/w/two' }, now + 1000))
  -- dead watchers are removed when listed
  local dead = dead_pid()
  sessions.write_watcher({ base }, vim.tbl_extend('force', w, { pid = dead }))
  h.eq(1, #sessions.watchers({ base }))
  h.eq(nil, vim.uv.fs_stat(base .. '/watchers/' .. dead .. '.json'))
  sessions.remove(path)
  h.eq(false, sessions.connected({ base }, { id = '42', worktree = '/w/one' }, now + 1000))
end)

-- ---------------------------------------------------------------------------
-- Comments: delivery state, merge, the sent event, catch-up
-- ---------------------------------------------------------------------------

local A = { path = 'src/cart.ts', side = 'new', start_line = 12, end_line = 14, snippet = { '+a', '+b', ' c' } }

local function store()
  return { path = '/nowhere', review = {}, comments = {}, _dirty = {} }
end

h.test('delivery: sent until acknowledged, seen, answered by an agent reply; a re-send starts over', function()
  local st = store()
  local c = comments.new(A, 'Why 3?', { now = 100 })
  comments.put(st, c, 100)
  h.eq(nil, comments.delivery(c))
  c = comments.mark_sent(st, c.id, { now = 200 })
  h.eq(200, c.sent_at)
  h.eq('sent', comments.delivery(c))
  c = comments.ack(st, c.id, 300)
  h.eq('seen', comments.delivery(c))
  -- a user reply does not answer it; an agent reply does
  comments.reply(st, c.id, 'also this', { kind = 'user' }, 350)
  h.eq('seen', comments.delivery(comments.get(st, c.id)))
  comments.reply(st, c.id, 'Because.', { kind = 'agent' }, 400)
  h.eq('answered', comments.delivery(comments.get(st, c.id)))
  -- a follow-up sent later is unanswered again, and its message is the reply
  local r = comments.reply(st, c.id, 'And 4?', { kind = 'user' }, 500)
  c = comments.mark_sent(st, c.id, { now = 600, reply_id = r.id })
  h.eq('sent', comments.delivery(c))
  h.eq('And 4?', comments.message_text(c))
  h.eq('Why 3?', comments.message_text(comments.new(A, 'Why 3?')))
  c = comments.mark_answered(st, c.id, 700)
  h.eq('answered', comments.delivery(c))
end)

-- Review: re-arming Monitor re-delivered every unacknowledged message, so the agent acted twice.
h.test('delivery: delivered once printed; catch-up skips it, inbox still lists it; a re-send is new', function()
  local st = store()
  local c = comments.new(A, 'Why 3?', { now = 100 })
  comments.put(st, c, 100)
  c = comments.mark_sent(st, c.id, { now = 200, session = '42' })
  h.eq('42', c.sent_session)
  h.eq('sent', comments.delivery(c))
  h.eq(1, #comments.undelivered(st))
  c = comments.mark_delivered(st, c.id, 250)
  h.eq('delivered', comments.delivery(c))
  h.eq({}, comments.undelivered(st))
  h.eq(1, #comments.unacked(st), 'still waiting for an answer')
  -- a stale delivery stamp of an older send does not count for a newer one
  c = comments.mark_sent(st, c.id, { now = 260 })
  h.ok(c.sent_at > 250)
  h.eq('sent', comments.delivery(c))
  h.eq(nil, c.sent_session)
  h.eq(1, #comments.undelivered(st))
  c = comments.ack(st, c.id, 300)
  h.eq('seen', comments.delivery(c))
  h.eq({}, comments.unacked(st))
  -- merged by maximum like the others
  local a = vim.tbl_extend('force', vim.deepcopy(c), { delivered_at = 900, updated_at = 1 })
  h.eq(900, comments.merge(c, a, true).delivered_at)
end)

h.test('merge: delivery timestamps only move forward (an ack survives a concurrent edit)', function()
  local c = comments.new(A, 'Why?', { now = 100 })
  c.sent_at = 200
  local acked = vim.tbl_extend('force', vim.deepcopy(c), { acked_at = 300, updated_at = 300 })
  local edited = vim.tbl_extend('force', vim.deepcopy(c), { body = 'Why, really?', updated_at = 400 })
  local m = comments.merge(edited, acked, false)
  h.eq('Why, really?', m.body)
  h.eq(300, m.acked_at)
  h.eq('seen', comments.delivery(m))
  -- a newer send elsewhere (with its reply id) wins over an older one
  local resent = vim.tbl_extend('force', vim.deepcopy(c), { sent_at = 500, sent_reply = 'r1', updated_at = 250 })
  m = comments.merge(edited, resent, false)
  h.eq(500, m.sent_at)
  h.eq('r1', m.sent_reply)
  h.eq('Why, really?', m.body)
end)

h.test('sent event: full anchor, snippet, message, review context; one line for agents', function()
  local c = comments.new(A, 'Is `multiply` needed?\nSecond line.', { now = 100, id = '0000000006400abcde' })
  c.sent_at = 200
  local review = { repo = '/r', branch = 'stack/cart', base = 'stack/math', scope = 'layer', state_branch = 'stack/cart' }
  local ev = comments.sent_event(c, review, { session = '42' }, 250)
  h.eq('sent', ev.kind)
  h.eq(c.id, ev.comment_id)
  h.eq(A.path, ev.anchor.path)
  h.eq('new', ev.anchor.side)
  h.eq(12, ev.anchor.start_line)
  h.eq(14, ev.anchor.end_line)
  h.eq({ '+a', '+b', ' c' }, ev.snippet)
  h.eq('Is `multiply` needed?\nSecond line.', ev.body)
  h.eq('Is `multiply` needed?\nSecond line.', ev.message)
  h.eq('comment', ev.message_kind)
  h.eq(200, ev.sent_at)
  h.eq('42', ev.session)
  h.eq(review, ev.review)
  -- survives the JSON round trip of the feed
  local back = comments.decode_events(vim.json.encode(ev) .. '\n')[1]
  h.eq(ev, back)
  h.eq(c.id .. ':200', comments.message_key(back))
  h.eq(
    'revuey message ' .. c.id .. ' src/cart.ts:12-14 (new) [stack/cart]: Is `multiply` needed?  (revuey show ' .. c.id .. ' for full context)',
    comments.message_line(back, 'revuey')
  )
  -- a follow-up, a file-level comment, the full stack scope
  local f = comments.new({ path = 'README.md', side = 'new' }, 'Docs?', { now = 100 })
  f.sent_at = 300
  local full = comments.sent_event(f, { repo = '/r', branch = 'stack/ui', scope = 'full' }, { message = 'More?', message_kind = 'reply' })
  h.eq(
    'revuey message ' .. f.id .. ' README.md (file) [full stack] follow-up: More?  (/x/bin/revuey show ' .. f.id .. ' for full context)',
    comments.message_line(full, '/x/bin/revuey')
  )
end)

h.test('catch-up: unacknowledged sent comments only, oldest send first', function()
  local st = store()
  local function add(body, sent, acked, extra)
    local c = comments.new(A, body, { now = 10 })
    c.sent_at, c.acked_at = sent, acked
    for k, v in pairs(extra or {}) do
      c[k] = v
    end
    comments.put(st, c, 10)
    return c
  end
  add('never sent')
  local b = add('second', 300)
  local a = add('first', 200)
  add('acked', 200, 250)
  add('answered', 200, nil, { answered_at = 260 })
  add('resent after ack', 400, 250)
  local gone = add('deleted', 200)
  comments.delete(st, gone.id)
  local res = comments.unacked(st)
  h.eq({ 'first', 'second', 'resent after ack' }, vim.tbl_map(function(c)
    return c.body
  end, res))
  h.eq(a.id, res[1].id)
  h.eq(b.id, res[2].id)
end)

h.run()
