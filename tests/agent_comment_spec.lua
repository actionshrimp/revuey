-- `bin/revuey comment`: a coding agent leaves a new comment in the review. Unit: argument
-- checks. Integration (real git repos, real `bin/revuey` subprocesses): new-side, old-side,
-- context and file-level comments with no review running (placed, and their unit filled in,
-- when the review is opened), paths and lines outside the diff rejected, the comment appearing
-- live in a running review with re-anchoring storing its unit, never echoed back to the agent
-- by `watch`/`inbox`, two reviews and --session, a detached HEAD's review scope, the user's
-- config (default_branch, uncommitted, state_dir) taken from the worktree's last review, and
-- renamed, deleted, binary, large, CRLF and no-newline files.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local msgs = {}
vim.notify = function(msg, level)
  msgs[#msgs + 1] = { msg = msg, level = level }
end
vim.o.columns, vim.o.lines = 160, 50

local state_dir = h.tmpdir('agent-comment-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local comments = require('revuey.comments')
local sessions = require('revuey.sessions')
local cv = require('revuey.comments_view')
local cli = require('revuey.cli')

local lines = {}
for i = 1, 40 do
  lines[#lines + 1] = 'line ' .. i
end
local long = table.concat(lines, '\n') .. '\n'
local repo = h.repo('agent-comment', { ['m.txt'] = long, ['keep.txt'] = 'same\n' }, {
  ['m.txt'] = (long:gsub('line 20\n', 'twenty\n')),
  ['new.txt'] = 'brand new file\nwith two lines\n',
})

local BIN = h.root .. '/bin/revuey'
local ENV = { REVUEY_STATE_DIR = state_dir, REVUEY_NVIM = vim.v.progpath }
local ME = tostring(vim.uv.os_getpid())

local function run(args, o)
  o = o or {}
  local cmd = { BIN }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { cwd = o.cwd or repo, env = o.env or ENV, text = true, stdin = o.stdin }):wait(20000)
end

---The comment id printed by `comment` (first line).
local function id_of(res)
  return vim.split(res.stdout, '\n')[1]
end

---All comments files in a dir: { [comment id] = {comment, path} }.
local function on_disk(dir)
  local found = {}
  for name, t in vim.fs.dir(dir or state_dir) do
    if t == 'file' and name:match('%.comments%.json$') then
      local path = vim.fs.joinpath(dir or state_dir, name)
      local st = comments.load(path, { readonly = true })
      for id, c in pairs(st.comments) do
        found[id] = { c = c, path = path, review = st.review }
      end
    end
  end
  return found
end

local function events_of(cpath)
  local fd = io.open((cpath:gsub('%.comments%.json$', '.events.jsonl')))
  if not fd then
    return {}
  end
  local evs = comments.decode_events(fd:read('*a'))
  fd:close()
  return evs
end

local s

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

-- ---------------------------------------------------------------------------
-- Unit: arguments
-- ---------------------------------------------------------------------------

h.test('comment_args: lines, ranges, sides, file level and the errors', function()
  local function args(list)
    local o, pos = cli.parse(list)
    return cli.comment_args(o, pos)
  end
  h.eq({ path = 'a.ts', side = 'new', start_line = 3, end_line = 3, text = 'hi' }, args({ '--path', 'a.ts', '--line', '3', 'hi' }))
  h.eq({ path = 'a.ts', side = 'old', start_line = 3, end_line = 5, text = '-' }, args({ '--path=a.ts', '--line=3', '--end', '5', '--side', 'old', '-' }))
  h.eq({ path = 'a.ts', text = 'whole' }, args({ '--path', 'a.ts', '--file', 'whole' }))
  -- text after `--`, or starting with dashes once the options are over
  h.eq('--flag-like', args({ '--path', 'a.ts', '--line', '1', '--', '--flag-like' }).text)
  h.eq('-- see above', args({ '--path', 'a.ts', '--line', '1', '-- see above' }).text)
  h.eq('ünïcödé ✓ 日本', args({ '--path', 'a.ts', '--line', '1', 'ünïcödé ✓ 日本' }).text)
  local function bad(list, pat)
    local a, err = args(list)
    h.eq(nil, a, vim.inspect(list))
    h.ok(err and err:find(pat, 1, true), tostring(err))
  end
  bad({ '--line', '3', 'x' }, '--path')
  bad({ '--path', 'a.ts', 'x' }, '--line N')
  bad({ '--path', 'a.ts', '--line', '3' }, 'needs a text')
  bad({ '--path', 'a.ts', '--line', '3', 'two', 'words' }, 'one text')
  bad({ '--path', 'a.ts', '--file', '--line', '3', 'x' }, '--file comments on the whole file')
  bad({ '--path', 'a.ts', '--line', '0', 'x' }, '--line needs a line number')
  bad({ '--path', 'a.ts', '--line', '3.5', 'x' }, '--line needs a line number')
  bad({ '--path', 'a.ts', '--line', 'ten', 'x' }, '--line needs a line number')
  bad({ '--path', 'a.ts', '--line', '9', '--end', '3', 'x' }, '--end 3 is before --line 9')
  bad({ '--path', 'a.ts', '--line', '1', '--end', '201', 'x' }, 'too large a range (at most 200)')
  bad({ '--path', 'a.ts', '--line', '1', '--side', 'left', 'x' }, '--side is new')
  h.ok(args({ '--path', 'a.ts', '--line', '1', '--end', '200', 'x' }), 'exactly the maximum')
end)

h.test('repo_path: ./x, absolute paths inside the worktree, paths from a subdirectory', function()
  h.eq('m.txt', cli.repo_path(repo, repo, './m.txt'))
  h.eq('m.txt', cli.repo_path(repo, repo, repo .. '/m.txt'))
  h.eq('sub/a.txt', cli.repo_path(repo, repo .. '/sub', 'a.txt'))
  h.eq('m.txt', cli.repo_path(repo, repo, 'm.txt'))
end)

-- ---------------------------------------------------------------------------
-- No review running
-- ---------------------------------------------------------------------------

local ids = {}

h.test('no review running: new-side, old-side, context and file-level comments are stored as agent comments', function()
  h.eq('[]', vim.trim(run({ 'sessions', '--json' }).stdout))
  local r = run({ 'comment', '--path', 'm.txt', '--line', '20', 'Why twenty?' })
  h.eq(0, r.code, r.stderr)
  ids.new = id_of(r)
  h.ok(ids.new:match('^%x+$'), r.stdout)
  h.ok(r.stdout:find('commented on m.txt:20 (new) in feat', 1, true), r.stdout)
  h.ok(r.stdout:find('no review running', 1, true), r.stdout)
  -- a deleted line on the old side, from stdin, unicode
  r = run({ 'comment', '--path', 'm.txt', '--line', '20', '--side', 'old', '-' }, { stdin = 'Dropped line 20 — on purpose? ✓\nSecond line.\n' })
  h.eq(0, r.code, r.stderr)
  ids.old = id_of(r)
  h.ok(r.stdout:find('m.txt:20 (old)', 1, true), r.stdout)
  -- a context line, a range
  r = run({ 'comment', '--path', './m.txt', '--line', '17', '--end', '18', '--', '-- context note' })
  h.eq(0, r.code, r.stderr)
  ids.ctx = id_of(r)
  h.ok(r.stdout:find('m.txt:17-18 (new)', 1, true), r.stdout)
  -- the whole file
  r = run({ 'comment', '--path', 'new.txt', '--file', 'Is this file needed?' })
  h.eq(0, r.code, r.stderr)
  ids.file = id_of(r)
  h.ok(r.stdout:find('commented on new.txt (file)', 1, true), r.stdout)

  local disk = on_disk()
  local c = disk[ids.new].c
  h.eq({ kind = 'agent', name = 'agent' }, c.author)
  h.eq('saved', c.status)
  h.eq(false, c.in_review)
  h.eq('Why twenty?', c.body)
  h.eq({ 'm.txt', 'new', 20, 20 }, { c.anchor.path, c.anchor.side, c.anchor.start_line, c.anchor.end_line })
  h.eq({ '+twenty' }, c.anchor.snippet)
  h.eq(16, #c.anchor.context_hash)
  h.eq(nil, c.anchor.unit_key, 'left for the UI')
  h.eq(nil, c.anchor.hunk_key)
  h.eq('feat', disk[ids.new].review.branch)
  h.eq(vim.uv.fs_realpath(repo), vim.uv.fs_realpath(disk[ids.new].review.repo))
  local o = disk[ids.old].c
  h.eq({ 'old', { '-line 20' } }, { o.anchor.side, o.anchor.snippet })
  h.eq('Dropped line 20 — on purpose? ✓\nSecond line.', o.body)
  h.eq('-- context note', disk[ids.ctx].c.body)
  h.eq({ ' line 17', ' line 18' }, disk[ids.ctx].c.anchor.snippet)
  h.eq(true, disk[ids.file].c.file_level)
  -- one created event each, by the agent
  local evs = events_of(disk[ids.new].path)
  local created = {}
  for _, ev in ipairs(evs) do
    if ev.kind == 'created' then
      created[ev.comment_id] = ev
    end
  end
  for _, id in pairs(ids) do
    h.ok(created[id], 'created event for ' .. id)
    h.eq('agent', created[id].author.kind)
  end
  -- the agent's own comments are not messages for it
  local inbox = run({ 'inbox' })
  h.eq(0, inbox.code, inbox.stderr)
  h.eq('no unacknowledged messages', vim.trim(inbox.stdout))
end)

h.test('rejected: a path the review does not change, lines outside the hunks, usage errors', function()
  local r = run({ 'comment', '--path', 'keep.txt', '--line', '1', 'x' })
  h.eq(1, r.code)
  h.ok(r.stderr:find('keep.txt is not a changed file in this review', 1, true), r.stderr)
  h.ok(r.stderr:find('m.txt', 1, true) and r.stderr:find('new.txt', 1, true), r.stderr)
  r = run({ 'comment', '--path', 'm.txt', '--line', '5', 'x' })
  h.eq(1, r.code)
  h.ok(r.stderr:find('m.txt:5 (new) is not in the diff', 1, true), r.stderr)
  h.ok(r.stderr:find('Nearest hunk: new 17-23', 1, true), r.stderr)
  h.ok(r.stderr:find('--file', 1, true), r.stderr)
  -- a range that leaves the hunk
  r = run({ 'comment', '--path', 'm.txt', '--line', '22', '--end', '25', 'x' })
  h.eq(1, r.code)
  h.ok(r.stderr:find('m.txt:22-25 (new) is not in the diff', 1, true), r.stderr)
  -- an added file has no old side
  r = run({ 'comment', '--path', 'new.txt', '--line', '1', '--side', 'old', 'x' })
  h.eq(1, r.code)
  h.ok(r.stderr:find('no old side', 1, true), r.stderr)
  h.eq(2, run({ 'comment', '--path', 'm.txt', 'x' }).code)
  h.eq(2, run({ 'comment', '--path', 'm.txt', '--line', '3', '--end', '1', 'x' }).code)
  h.eq(1, run({ 'comment', '--path', 'm.txt', '--line', '20', '' }).code, 'empty text')
  -- nothing was stored by any of them
  local n = 0
  for _ in pairs(on_disk()) do
    n = n + 1
  end
  h.eq(4, n)
end)

h.test('opening the review afterwards places them, and stores their unit and hunk', function()
  s = h.open_review({ cwd = repo, base = '' })
  local p = s.cm.place
  h.eq({ false, 20 }, { p[ids.new].outdated, p[ids.new].start_line })
  h.eq({ false, 20 }, { p[ids.old].outdated, p[ids.old].start_line })
  h.eq({ false, 17, 18 }, { p[ids.ctx].outdated, p[ids.ctx].start_line, p[ids.ctx].end_line })
  h.eq('file', p[ids.file].how)
  -- shown where a UI comment on the same rows would be, labelled as the agent's
  h.ok(vlines(row_of('add', 20)):find('Why twenty?', 1, true), vlines(row_of('add', 20)))
  h.ok(vlines(row_of('add', 20)):find('╭─ agent', 1, true), vlines(row_of('add', 20)))
  local hl
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, cv.ns, { row_of('add', 20) - 1, 0 }, { row_of('add', 20) - 1, -1 }, { details = true })) do
    for _, ch in ipairs((m[4].virt_lines or {})[1] or {}) do
      if ch[1] == 'agent' then
        hl = ch[2]
      end
    end
  end
  h.eq('RevueyCommentAgent', hl, 'the author stands out as an agent')
  h.ok(vlines(row_of('del', 20)):find('Dropped line 20', 1, true), vlines(row_of('del', 20)))
  h.ok(vlines(row_of('ctx', 18)):find('-- context note', 1, true), vlines(row_of('ctx', 18)))
  local disk = on_disk()
  for _, k in ipairs({ 'new', 'old', 'ctx' }) do
    local a = disk[ids[k]].c.anchor
    h.ok(a.unit_key and a.hunk_key, k .. ': ' .. vim.inspect(a))
    h.ok(a.hunk_line and a.unit_line, k .. ' offsets: ' .. vim.inspect(a))
  end
  h.eq(nil, disk[ids.file].c.anchor.unit_key, 'file-level: nothing to resolve')
  -- the comments list says who wrote them
  local found = false
  for _, l in ipairs(cv.list_lines(s)) do
    if l.text:find('Why twenty?', 1, true) and l.text:find('by agent', 1, true) then
      found = true
    end
  end
  h.ok(found, vim.inspect(cv.list_lines(s)))
end)

-- ---------------------------------------------------------------------------
-- A review running
-- ---------------------------------------------------------------------------

local watchers = {}

local function watch(args)
  local w = { out = '', err = '' }
  watchers[#watchers + 1] = w
  local cmd = { BIN, 'watch' }
  vim.list_extend(cmd, args or {})
  w.proc = vim.system(cmd, {
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

local function stop(w)
  w.proc:kill('sigterm')
  return w.proc:wait(5000)
end

h.test('live: a comment appears in the running review at once; re-anchoring stores its unit', function()
  local w_msgs = watch({ '--messages' })
  local w_events = watch()
  local w_all = watch({ '--all' })
  msgs = {}
  local r = run({ 'comment', '--path', 'm.txt', '--line', '21', 'Live one' })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('session ' .. ME, 1, true), r.stdout)
  local id = id_of(r)
  h.ok(vim.wait(5000, function()
    return vlines(row_of('ctx', 21)):find('Live one', 1, true) ~= nil
  end, 20), vlines(row_of('ctx', 21)))
  h.ok(vlines(row_of('ctx', 21)):find('╭─ agent', 1, true), vlines(row_of('ctx', 21)))
  -- the live reload stored the unit its placement found (only for comments without one)
  h.ok(vim.wait(5000, function()
    local c = on_disk()[id]
    return c and c.c.anchor.unit_key ~= nil
  end, 20), 'unit_key not stored')
  local a = on_disk()[id].c.anchor
  h.eq(s.cm.place[id].unit.key, a.unit_key)
  h.ok(a.hunk_key and a.hunk_line and a.unit_line, vim.inspect(a))
  local told = false
  for _, m in ipairs(msgs) do
    told = told or m.msg:find('the agent commented on m.txt:21', 1, true) ~= nil
  end
  h.ok(told, vim.inspect(msgs))
  -- not echoed back to the agent: no message, no event line (only with --all)
  h.ok(vim.wait(5000, function()
    return w_all.out:find('Live one', 1, true) ~= nil
  end, 20), w_all.out)
  vim.wait(500)
  h.eq(nil, w_msgs.out:find('Live one', 1, true), w_msgs.out)
  h.eq(nil, w_events.out:find('Live one', 1, true), w_events.out)
  h.eq('no unacknowledged messages', vim.trim(run({ 'inbox', '--session', ME }).stdout))
  for _, w in ipairs({ w_msgs, w_events, w_all }) do
    h.eq(0, stop(w).code, w.err)
  end
end)

h.test('two reviews running: --session picks one; without it the command asks', function()
  -- a second review of this worktree (committed mode, its own state dir), live: a pid and a socket
  local other_dir = h.tmpdir('agent-comment-other')
  local proc = vim.system({ 'sleep', '120' })
  local sock = h.tmpdir('agent-comment-sock-' .. proc.pid) .. '/s'
  local listener = vim.uv.new_pipe(false)
  assert(listener:bind(sock))
  assert(listener:listen(16, function() end))
  local mine = vim.json.decode(run({ 'sessions', '--json' }).stdout)[1]
  local cpath = other_dir .. '/other.comments.json'
  local entry = vim.tbl_extend('force', mine, {
    pid = proc.pid,
    id = tostring(proc.pid),
    server = sock,
    state_dir = other_dir,
    comments = cpath,
    events = other_dir .. '/other.events.jsonl',
    mode = 'committed',
    load = vim.tbl_extend('force', mine.load, { mode = 'committed' }),
    started_at = mine.started_at + 1,
  })
  entry.agent_connected = nil
  sessions.register({ sessions.bases(repo)[1] }, entry)
  local r = run({ 'comment', '--path', 'm.txt', '--line', '20', 'which review?' })
  h.eq(2, r.code)
  h.ok(r.stderr:find('--session', 1, true) and r.stderr:find(ME, 1, true) and r.stderr:find(entry.id, 1, true), r.stderr)
  r = run({ 'comment', '--session', entry.id, '--path', 'm.txt', '--line', '20', 'for the other review' })
  h.eq(0, r.code, r.stderr)
  local id = id_of(r)
  local st = comments.load(cpath, { readonly = true })
  h.ok(comments.get(st, id), 'in the other review file')
  h.eq('committed', st.review.mode)
  h.eq(nil, on_disk()[id], 'not in this review')
  h.ok(#events_of(cpath) == 1, 'its own events file')
  r = run({ 'comment', '--session', ME, '--path', 'm.txt', '--line', '19', 'for this review' })
  h.eq(0, r.code, r.stderr)
  h.ok(comments.get(comments.load(s.cm.path, { readonly = true }), id_of(r)))
  proc:kill('sigkill')
  proc:wait()
  listener:close()
end)

-- ---------------------------------------------------------------------------
-- Detached HEAD, no review running
-- ---------------------------------------------------------------------------

h.test('detached HEAD with no review running: the comment lands in the scope revuey opens there', function()
  -- a stack main <- feat <- top, checked out detached at top: revuey reviews the layer `top`
  local d = h.repo('agent-comment-detached', { ['a.txt'] = long, ['b.txt'] = long }, { ['a.txt'] = (long:gsub('line 5\n', 'five\n')) })
  h.git(d, 'checkout', '-q', '-b', 'top')
  h.write(d, 'b.txt', (long:gsub('line 10\n', 'ten\n')))
  h.git(d, 'commit', '-q', '-am', 'top')
  h.git(d, 'checkout', '-q', '--detach', 'top')
  h.eq('[]', vim.trim(run({ 'sessions', '--json' }, { cwd = d }).stdout))
  -- only the layer's own changes: a.txt belongs to the layer below
  local bad = run({ 'comment', '--path', 'a.txt', '--line', '5', 'x' }, { cwd = d })
  h.eq(1, bad.code)
  h.ok(bad.stderr:find('a.txt is not a changed file in this review', 1, true), bad.stderr)
  local r = run({ 'comment', '--path', 'b.txt', '--line', '10', 'detached note' }, { cwd = d })
  h.eq(0, r.code, r.stderr)
  local id = id_of(r)
  h.ok(r.stdout:find('b.txt:10 (new) in top', 1, true), r.stdout)
  -- the review revuey opens there finds it in its own comments file, placed
  s = h.open_review({ cwd = d, base = '' })
  h.eq('top', s.review.branch)
  h.ok(comments.get(s.cm.store, id), 'in the opened review: ' .. s.cm.path)
  h.eq(false, s.cm.place[id].outdated)
  h.eq(10, s.cm.place[id].start_line)
end)

-- ---------------------------------------------------------------------------
-- The user's config with no review running (the CLI runs with --clean): the last review of the
-- worktree recorded it
-- ---------------------------------------------------------------------------

---Open a review of `cwd` with config `cfg` (state_dir defaults to the spec's) and close it again:
---as if the user ran revuey there earlier.
local function opened_once(cwd, cfg)
  require('revuey').close()
  require('revuey').setup(vim.tbl_extend('force', { state_dir = state_dir, lsp_warmup = false }, cfg or {}))
  s = h.open_review({ cwd = cwd, base = '' })
  require('revuey').close()
  h.eq('[]', vim.trim(run({ 'sessions', '--json' }, { cwd = cwd }).stdout), 'no review running')
end

---The review the user opens next (same config), with comment `id` in it.
local function reopen(cwd, cfg)
  require('revuey').setup(vim.tbl_extend('force', { state_dir = state_dir, lsp_warmup = false }, cfg or {}))
  s = h.open_review({ cwd = cwd, base = '' })
  return s
end

local function placed(id)
  h.ok(comments.get(s.cm.store, id), 'comment ' .. id .. ' is in ' .. s.cm.path)
  local p = s.cm.place[id]
  h.eq(false, p.outdated, vim.inspect(p))
  return p
end

h.test('no review running, default_branch = develop: the comment goes to the develop review and is checked against it', function()
  local d = h.repo('agent-comment-develop', { ['a.txt'] = long }, {})
  h.git(d, 'checkout', '-q', '-b', 'develop', 'main')
  h.write(d, 'b.txt', long)
  h.git(d, 'add', '-A')
  h.git(d, 'commit', '-q', '-m', 'develop')
  h.git(d, 'checkout', '-q', '-b', 'feat3')
  h.write(d, 'a.txt', (long:gsub('line 5\n', 'five\n')))
  h.git(d, 'commit', '-q', '-am', 'feat3')
  local cfg = { default_branch = 'develop' }
  opened_once(d, cfg)
  local r = run({ 'comment', '--path', 'a.txt', '--line', '5', 'develop note' }, { cwd = d })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('a.txt:5 (new) in feat3 vs develop, working tree', 1, true), r.stdout)
  -- b.txt differs from main only: not in the develop review
  local bad = run({ 'comment', '--path', 'b.txt', '--file', 'x' }, { cwd = d })
  h.eq(1, bad.code)
  h.ok(bad.stderr:find('b.txt is not a changed file', 1, true), bad.stderr)
  reopen(d, cfg)
  h.eq('develop', s.review.base)
  h.eq(5, placed(id_of(r)).start_line)
  require('revuey').close()
end)

h.test('no review running, uncommitted = false with a dirty tree: checked against the committed diff', function()
  local d = h.repo('agent-comment-committed', { ['a.txt'] = long }, { ['a.txt'] = (long:gsub('line 5\n', 'five\n')) })
  h.write(d, 'a.txt', (long:gsub('line 5\n', 'five\n'):gsub('line 30\n', 'thirty, not committed\n')))
  local cfg = { uncommitted = false }
  opened_once(d, cfg)
  local bad = run({ 'comment', '--path', 'a.txt', '--line', '30', 'x' }, { cwd = d })
  h.eq(1, bad.code)
  h.ok(bad.stderr:find('a.txt:30 (new) is not in the diff', 1, true), bad.stderr)
  local r = run({ 'comment', '--path', 'a.txt', '--line', '5', 'committed note' }, { cwd = d })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('vs main, committed', 1, true), r.stdout)
  reopen(d, cfg)
  h.eq('committed', s.review.mode)
  h.eq(5, placed(id_of(r)).start_line)
  require('revuey').close()
end)

h.test('no review running, a custom state_dir: the comment goes to that state dir', function()
  local d = h.repo('agent-comment-statedir', { ['a.txt'] = long }, { ['a.txt'] = (long:gsub('line 5\n', 'five\n')) })
  local custom = h.tmpdir('agent-comment-custom-state')
  local cfg = { state_dir = custom }
  opened_once(d, cfg)
  local r = run({ 'comment', '--path', 'a.txt', '--line', '5', 'custom dir note' }, { cwd = d })
  h.eq(0, r.code, r.stderr)
  h.ok(on_disk(custom)[id_of(r)], 'in the custom state dir')
  h.eq(nil, on_disk()[id_of(r)], 'not in $REVUEY_STATE_DIR')
  reopen(d, cfg)
  placed(id_of(r))
  require('revuey').close()
end)

h.test('files: renames (both sides, old path named), deleted, binary and large ones, CRLF, no newline at EOF', function()
  local words = {}
  for i = 1, 60 do
    words[#words + 1] = 'content row number ' .. i .. ' with words alpha beta'
  end
  words = table.concat(words, '\n') .. '\n'
  local crlf = (long:gsub('\n', '\r\n'))
  local big = string.rep('a fairly long line of text to make a large file\n', 26000) -- > 1 MB
  local d = h.repo('agent-comment-files', {
    ['old.txt'] = words,
    ['gone.txt'] = long,
    ['bin.dat'] = 'a\0b',
    ['crlf.txt'] = crlf,
    ['nonl.txt'] = 'a\nb\nc',
    ['big.txt'] = big,
  }, {
    ['old.txt'] = false,
    ['new_name.txt'] = (words:gsub('row number 30 ', 'ROW 30 ')),
    ['gone.txt'] = false,
    ['bin.dat'] = 'a\0c',
    ['crlf.txt'] = (crlf:gsub('line 10\r\n', 'ten\r\n')),
    ['nonl.txt'] = 'a\nb\nC',
    ['big.txt'] = big .. 'one more\n',
  })
  require('revuey').close()
  require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
  local function c(args, text)
    local a = { 'comment' }
    vim.list_extend(a, args)
    a[#a + 1] = text
    return run(a, { cwd = d })
  end
  local ok = {}
  local function good(args, text)
    local r = c(args, text)
    h.eq(0, r.code, text .. ': ' .. r.stderr)
    ok[#ok + 1] = { id = id_of(r), text = text }
    return r
  end
  local function refused(args, pat)
    local r = c(args, 'x')
    h.eq(1, r.code, vim.inspect(args) .. r.stdout)
    h.ok(r.stderr:find(pat, 1, true), r.stderr)
  end
  good({ '--path', 'new_name.txt', '--line', '30' }, 'renamed, new side')
  good({ '--path', 'new_name.txt', '--line', '30', '--side', 'old' }, 'renamed, old side')
  refused({ '--path', 'old.txt', '--line', '30', '--side', 'old' }, 'old.txt was renamed to new_name.txt in this review: use --path new_name.txt')
  refused({ '--path', 'gone.txt', '--line', '3' }, 'no new side')
  good({ '--path', 'gone.txt', '--line', '3', '--side', 'old' }, 'deleted file, old side')
  refused({ '--path', 'bin.dat', '--line', '1' }, 'no text diff')
  good({ '--path', 'bin.dat', '--file' }, 'binary, whole file')
  refused({ '--path', 'big.txt', '--line', '26001' }, 'no text diff')
  good({ '--path', 'big.txt', '--file' }, 'large, whole file')
  good({ '--path', 'crlf.txt', '--line', '10' }, 'crlf')
  refused({ '--path', 'crlf.txt', '--line', '14' }, 'Nearest hunk: new 7-13')
  good({ '--path', 'nonl.txt', '--line', '3' }, 'no newline at EOF')
  refused({ '--path', 'nonl.txt', '--line', '4' }, 'nonl.txt:4 (new) is not in the diff')
  reopen(d)
  for _, x in ipairs(ok) do
    local p = s.cm.place[x.id]
    h.ok(p and not p.outdated, x.text .. ': ' .. vim.inspect(p))
  end
  require('revuey').close()
end)

h.test('live review with uncommitted changes and context_lines = 8: its own diff decides', function()
  local many = {}
  for i = 1, 60 do
    many[#many + 1] = 'line ' .. i
  end
  many = table.concat(many, '\n') .. '\n'
  local d = h.repo('agent-comment-wide', { ['a.txt'] = many }, { ['a.txt'] = (many:gsub('line 20\n', 'twenty\n')) })
  h.write(d, 'a.txt', (many:gsub('line 20\n', 'twenty\n'):gsub('line 45\n', 'forty-five, not committed\n')))
  require('revuey').close()
  require('revuey').setup({ state_dir = state_dir, lsp_warmup = false, context_lines = 8 })
  s = h.open_review({ cwd = d, base = '' })
  local r1 = run({ 'comment', '--path', 'a.txt', '--line', '45', 'uncommitted line' }, { cwd = d })
  h.eq(0, r1.code, r1.stderr)
  h.ok(r1.stdout:find('working tree, session ' .. ME, 1, true), r1.stdout)
  -- line 12 is only in the diff with 8 lines of context
  local r2 = run({ 'comment', '--path', 'a.txt', '--line', '12', 'wide context' }, { cwd = d })
  h.eq(0, r2.code, r2.stderr)
  for _, id in ipairs({ id_of(r1), id_of(r2) }) do
    h.ok(vim.wait(5000, function()
      return s.cm.place[id] ~= nil and not s.cm.place[id].outdated
    end, 20), id .. ' placed live')
  end
  require('revuey').close()
  require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
end)

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
