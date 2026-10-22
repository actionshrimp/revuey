-- Integration: the shell side of comments. `bin/revuey comments` (Markdown and JSON, scopes),
-- `bin/revuey watch` as a subprocess following comments made in this Neovim (one line per event,
-- across rotation, --json, --since, clean exit on SIGTERM), and `bin/revuey reply` showing up
-- live in the running review.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
vim.notify = function() end
vim.o.columns, vim.o.lines = 160, 50

local state_dir = h.tmpdir('cli-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local comments = require('revuey.comments')
local cv = require('revuey.comments_view')
local editor = require('revuey.comment_editor')

local lines = {}
for i = 1, 40 do
  lines[#lines + 1] = 'line ' .. i
end
local long = table.concat(lines, '\n') .. '\n'
local repo = h.repo('cli', { ['m.txt'] = long }, { ['m.txt'] = (long:gsub('line 20\n', 'twenty\n')) })
local s = h.open_review({ cwd = repo })

local BIN = h.root .. '/bin/revuey'
local ENV = { REVUEY_STATE_DIR = state_dir, REVUEY_NVIM = vim.v.progpath }

local function run(args, stdin)
  local cmd = { BIN }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { cwd = repo, env = ENV, text = true, stdin = stdin }):wait(20000)
end

local function row_of(kind, lnum)
  for row, e in ipairs(s.layout.map) do
    if e.path == 'm.txt' and e.kind == kind and (kind == 'del' and e.old_lnum or e.new_lnum) == lnum then
      return row
    end
  end
end

local function comment(row, text)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  cv.add(s, row, row)
  local st = editor.current
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, vim.split(text, '\n'))
  editor.save(st)
end

local function by_body(body)
  for _, c in pairs(s.cm.store.comments) do
    if not c.deleted and c.body == body then
      return c
    end
  end
end

local watchers = {}

---Start `bin/revuey watch` and wait until it is following the feed.
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

local function wait_out(w, pat)
  return vim.wait(10000, function()
    return w.out:find(pat, 1, true) ~= nil
  end, 20)
end

h.test('watch: one line per comment event, flushed as it happens; SIGTERM exits cleanly', function()
  local w = watch()
  comment(row_of('add', 20), 'Should this be twenty?\nSecond line.')
  h.ok(wait_out(w, 'comment m.txt:20 (new): Should this be twenty?'), w.out .. w.err)
  local c = by_body('Should this be twenty?\nSecond line.')
  h.ok(w.out:find('#' .. c.id, 1, true), w.out)
  h.eq(1, #vim.split(vim.trim(w.out), '\n'), 'one line per event')
  -- resolve and delete events too
  vim.api.nvim_win_set_cursor(s.diff_win, { row_of('add', 20), 0 })
  cv.resolve(s)
  h.ok(wait_out(w, 'resolve m.txt:20 (new)'), w.out)
  w.proc:kill('sigterm')
  local res = w.proc:wait(5000)
  h.eq(0, res.code, w.err)
  h.eq(nil, w.err:find('deadly', 1, true), w.err)
  cv.resolve(s) -- reopen
end)

h.test('watch --json emits the full event; it follows the feed across rotation', function()
  local w = watch({ '--json' })
  local saved = comments.EVENTS_MAX
  comments.EVENTS_MAX = 200 -- every append rotates
  comment(row_of('del', 20), 'old side note')
  comment(row_of('ctx', 18), 'context note')
  comments.EVENTS_MAX = saved
  h.ok(wait_out(w, 'context note'), w.out)
  local evs = comments.decode_events(w.out)
  h.eq(2, #evs, w.out)
  h.eq('created', evs[1].kind)
  h.eq('old', evs[1].anchor.side)
  h.eq({ '-line 20' }, evs[1].snippet)
  h.eq('old side note', evs[1].body)
  h.eq('feat', evs[1].review.branch)
  h.eq(s.review.root, evs[1].review.repo)
  h.eq(' line 18', evs[2].snippet[1])
  w.proc:kill('sigterm')
  h.eq(0, w.proc:wait(5000).code)
end)

h.test('watch --since replays earlier events after that id', function()
  local all = {}
  for _, p in ipairs({ s.cm.events .. '.1', s.cm.events }) do
    local fd = io.open(p)
    if fd then
      vim.list_extend(all, comments.decode_events(fd:read('*a')))
      fd:close()
    end
  end
  local since
  for _, ev in ipairs(all) do
    if ev.body == 'old side note' then
      since = ev.id
    end
  end
  local w = watch({ '--since', since })
  h.ok(wait_out(w, 'context note'), w.out)
  h.eq(nil, w.out:find('old side note', 1, true), 'only events after the given id')
  w.proc:kill('sigterm')
  h.eq(0, w.proc:wait(5000).code)
  local w2 = watch({ '--since', 'all' })
  h.ok(wait_out(w2, 'context note'), w2.out)
  w2.proc:kill('sigterm')
  w2.proc:wait(5000)
end)

h.test('comments: Markdown for the current branch, --json, scopes', function()
  local res = run({ 'comments' })
  h.eq(0, res.code, res.stderr)
  h.ok(res.stdout:find('# Review comments: feat → main', 1, true), res.stdout)
  h.ok(res.stdout:find('## 1. m.txt:18 (new)', 1, true), res.stdout)
  h.ok(res.stdout:find('```diff\n-line 20\n```', 1, true), res.stdout)
  h.ok(res.stdout:find('Should this be twenty?\nSecond line.', 1, true), res.stdout)
  -- the same text as the export from the UI
  h.eq(cv.export(s, { 'z' }), res.stdout)
  local j = run({ 'comments', '--json' })
  local data = vim.json.decode(j.stdout)
  h.eq(3, #data.reviews[1].comments)
  h.eq('m.txt', data.reviews[1].comments[1].anchor.path)
  h.ok(run({ 'comments', '--scope', 'all' }).stdout:find('context note', 1, true))
  h.ok(run({ 'comments', '--scope', 'nope' }).stdout:find('No comments.', 1, true))
  h.eq(2, run({ 'comments', '--bogus' }).code)
end)

h.test('reply: an agent reply from the shell shows up live in the running review', function()
  local w = watch({ '--all' })
  local c = by_body('context note')
  local res = run({ 'reply', c.id:sub(-8), 'On it.' })
  h.eq(0, res.code, res.stderr)
  h.ok(res.stdout:find('replied to ' .. c.id, 1, true), res.stdout)
  local row = row_of('ctx', 18)
  local function vtext()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, cv.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      for _, l in ipairs(m[4].virt_lines or {}) do
        for _, ch in ipairs(l) do
          out[#out + 1] = ch[1]
        end
        out[#out + 1] = '\n'
      end
    end
    return table.concat(out)
  end
  h.ok(vim.wait(5000, function()
    return vtext():find('On it.', 1, true) ~= nil
  end, 20), vtext())
  h.ok(vtext():find('↳ agent', 1, true), vtext())
  h.eq({ kind = 'agent', name = 'agent' }, comments.get(s.cm.store, c.id).thread[1].author)
  h.ok(wait_out(w, 'reply m.txt:18 (new) from agent: On it.'), w.out)
  w.proc:kill('sigterm')
  w.proc:wait(5000)
  -- from stdin, with a name
  ENV.REVUEY_AGENT_NAME = 'claude'
  res = run({ 'reply', c.id, '-' }, 'Line one\nline two\n')
  ENV.REVUEY_AGENT_NAME = nil
  h.eq(0, res.code, res.stderr)
  h.ok(vim.wait(5000, function()
    local cc = comments.get(s.cm.store, c.id)
    return #cc.thread == 2
  end, 20))
  h.eq('Line one\nline two', comments.get(s.cm.store, c.id).thread[2].body)
  h.eq('claude', comments.get(s.cm.store, c.id).thread[2].author.name)
  -- errors
  h.eq(1, run({ 'reply', 'nope', 'x' }).code)
  h.eq(2, run({ 'reply' }).code)
end)

-- Regression (review): 20 parallel `reply` calls stored only 14 replies (no lock around
-- read-merge-rename), although all of them wrote their event and exited 0.
h.test('parallel replies from the shell and a concurrent UI save: every reply is kept', function()
  local c = by_body('context note')
  local before = #comments.get(s.cm.store, c.id).thread
  local fd = io.open(s.cm.events)
  local events_before = #comments.decode_events(fd:read('*a'))
  fd:close()
  local procs = {}
  for i = 1, 20 do
    procs[i] = vim.system({ BIN, 'reply', c.id, 'parallel reply ' .. i }, { cwd = repo, env = ENV, text = true })
  end
  -- meanwhile the UI saves comments of its own
  local ui = {}
  for i = 1, 5 do
    local x = comments.new({ path = 'm.txt', side = 'new', start_line = 30 + i, end_line = 30 + i }, 'ui note ' .. i)
    comments.put(s.cm.store, x)
    comments.save(s.cm.store)
    ui[#ui + 1] = x.id
  end
  for i = 1, 20 do
    local r = procs[i]:wait(30000)
    h.eq(0, r.code, r.stderr)
  end
  local disk = comments.load(s.cm.path)
  local bodies = {}
  for _, r in ipairs(comments.get(disk, c.id).thread) do
    bodies[r.body] = true
  end
  for i = 1, 20 do
    h.ok(bodies['parallel reply ' .. i], 'reply ' .. i .. ' lost')
  end
  h.eq(before + 20, #comments.get(disk, c.id).thread)
  for _, id in ipairs(ui) do
    h.ok(comments.get(disk, id), 'UI comment lost')
  end
  fd = io.open(s.cm.events)
  h.eq(events_before + 20, #comments.decode_events(fd:read('*a')), 'one event per reply')
  fd:close()
end)

-- Regression (review): option parsing went on after the positionals, so a reply text starting
-- with `--` failed with exit 2; `--` was not supported either.
h.test('reply: text starting with --, and -- ending the options', function()
  local c = by_body('context note')
  local r1 = run({ 'reply', c.id, '-- see above' })
  h.eq(0, r1.code, r1.stderr)
  local r2 = run({ 'reply', '--', c.id, '--flag-like text' })
  h.eq(0, r2.code, r2.stderr)
  local r3 = run({ 'reply', c.id, '--', '--after the separator' })
  h.eq(0, r3.code, r3.stderr)
  local disk = comments.get(comments.load(s.cm.path), c.id)
  local bodies = {}
  for _, r in ipairs(disk.thread) do
    bodies[r.body] = true
  end
  h.ok(bodies['-- see above'] and bodies['--flag-like text'] and bodies['--after the separator'], vim.inspect(bodies))
end)

h.test('comments is read-only: an unreadable comments file is reported, not moved aside', function()
  local bad = state_dir .. '/broken-0000.comments.json'
  vim.fn.writefile({ '{not json' }, bad)
  local r = run({ 'comments' })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stderr:find('broken-0000.comments.json', 1, true), r.stderr)
  h.ok(vim.uv.fs_stat(bad), 'left where it was')
  h.eq(0, #vim.fn.glob(bad .. '.corrupt-*', false, true))
  vim.fn.delete(bad)
end)

h.test('bin/revuey: an unknown subcommand prints usage and fails; a base still opens the UI', function()
  local function bin(args)
    local cmd = { BIN }
    vim.list_extend(cmd, args)
    return vim.system(cmd, { cwd = repo, env = { REVUEY_NVIM = 'false', REVUEY_STATE_DIR = state_dir }, text = true }):wait(10000)
  end
  local r = bin({ 'bogus' })
  h.eq(2, r.code)
  h.ok(r.stderr:find('unknown command bogus', 1, true), r.stderr)
  h.ok(r.stderr:find('usage', 1, true), r.stderr)
  -- a branch name, flags or nothing: the UI (here the stand-in `false`, exit 1)
  h.eq(1, bin({ 'main' }).code)
  h.eq(1, bin({ '--stack' }).code)
  h.eq(1, bin({}).code)
end)

h.test('reply waits for a live lock and then fails with one "revuey:" prefix', function()
  local c = by_body('context note')
  local fd = assert(io.open(s.cm.path .. '.lock', 'w'))
  fd:write(('%d %s %d\n'):format(vim.uv.os_getpid(), vim.uv.os_gethostname(), os.time()))
  fd:close()
  ENV.REVUEY_LOCK_TIMEOUT_MS = '300'
  local r = run({ 'reply', c.id, 'blocked' })
  ENV.REVUEY_LOCK_TIMEOUT_MS = nil
  os.remove(s.cm.path .. '.lock')
  h.eq(1, r.code)
  h.ok(r.stderr:find('^revuey: ') and not r.stderr:find('revuey: revuey:', 1, true), r.stderr)
  h.ok(r.stderr:find('pid ' .. vim.uv.os_getpid(), 1, true), r.stderr)
end)

h.test('watch stops by itself when whoever started it goes away', function()
  local marker = 'owner-gone-' .. vim.fn.getpid()
  local script = ('%s watch --scope %s >/dev/null 2>&1 & sleep 1; exit 0'):format(vim.fn.shellescape(BIN), marker)
  h.eq(0, vim.system({ 'bash', '-c', script }, { cwd = repo, env = ENV }):wait(10000).code)
  h.ok(vim.wait(5000, function()
    return vim.system({ 'pgrep', '-f', marker }):wait().code ~= 0
  end, 100), 'watch is still running')
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
