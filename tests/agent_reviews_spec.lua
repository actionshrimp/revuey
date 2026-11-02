-- Review runs, tags and the agent reviews view (ai_review.lua runs, tags.lua, ai_reviews_view.lua,
-- `bin/revuey tag` / `findings` / `import-review --tag` / `comment --tag`). Real git repos, real
-- `bin/revuey` subprocesses, the fake `claude`. Several runs of one scope kept side by side (a
-- fresh session and the connected agent with a skill), a re-run replacing only its own untouched
-- findings and dropping a run left without any; a version 1 record read as one run; tags: the
-- defaults from the skill or run, cleaning, the CLI (add, remove, list and filter), surviving a
-- concurrent accept in the UI; the view: grouping, counts, filters, the run keys with their
-- confirmations, <CR>, ]] / [[, live redraws; the panel's line.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
local msgs = {}
vim.notify = function(msg, level)
  msgs[#msgs + 1] = { msg = msg, level = level }
end

local log = h.tmpdir('agent-reviews-claude') .. '/calls.ndjson'
h.use_fake_claude(log)

local state_dir = h.tmpdir('agent-reviews-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local config = require('revuey.config')
local view = require('revuey.view')
local arv = require('revuey.ai_review_view')
local ai_review = require('revuey.ai_review')
local comments = require('revuey.comments')
local cv = require('revuey.comments_view')
local rv = require('revuey.ai_reviews_view')
local tags = require('revuey.tags')
local link = require('revuey.agent_link')
local requests = require('revuey.requests')
local sessions = require('revuey.sessions')

local lines = {}
for i = 1, 40 do
  lines[#lines + 1] = 'line ' .. i
end
local long = table.concat(lines, '\n') .. '\n'
local repo = h.repo('agent-reviews', {
  ['m.txt'] = long,
  ['.claude/skills/fixture-sec/SKILL.md'] = '---\nname: fixture-sec\ndescription: d\n---\nLook for unchecked input.\n',
}, {
  ['m.txt'] = (long:gsub('line 20\n', 'twenty\n'):gsub('line 30\n', 'thirty\n')),
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

local answers = {}
vim.ui.select = function(items, _, cb)
  local a = table.remove(answers, 1)
  if type(a) == 'function' then
    return cb(a(items))
  end
  cb(a and vim.tbl_contains(items, a) and a or nil)
end
vim.ui.input = function(_, cb)
  cb(table.remove(answers, 1))
end
local function answer(...)
  answers = { ... }
end

local s

local function idle()
  assert(h.settle(function()
    return not s.refreshing and not s.pending and not s.pending_scope
  end, 10000), 'refresh did not finish')
end

local function wait_jobs()
  assert(vim.wait(20000, function()
    return next(arv.jobs) == nil
  end, 20), 'the AI review job did not finish')
  idle()
end

local function open()
  if view.session then
    view.close()
  end
  s = h.open_review({ cwd = repo, base = '' })
  return s
end

local function findings()
  local out = {}
  for _, c in pairs(cv.sync_store(s).comments) do
    if not c.deleted and c.ai then
      out[#out + 1] = c
    end
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  return out
end

local function by_title(title)
  for _, c in ipairs(findings()) do
    if c.ai.title == title then
      return c
    end
  end
end

local function diff_hash()
  return vim.json.decode(run({ 'hunks', '--json' }).stdout).diff
end

local function review_doc(extra)
  return vim.tbl_extend('force', {
    diff = diff_hash(),
    summary = 'Thirty and twenty are spelled out.\nMore detail on a second line.',
    verdict = 'comment',
    findings = {
      { hunk = 'h1', line = 5, severity = 'major', title = 'Twenty is a word', body = 'Use digits.' },
      { hunk = 'h2', line = 5, severity = 'minor', title = 'Thirty is a word', body = 'Use digits here too.' },
    },
  }, extra or {})
end

local function fake_agent()
  return sessions.write_watcher(s.link.bases, { pid = vim.fn.getpid(), session = s.link.id, worktree = s.review.root,
    started_at = sessions.now_ms(), heartbeat_at = sessions.now_ms(), name = 'claude', mode = 'messages' })
end

---The connected agent reviews with the skill: a request, taken and imported by the CLI.
local function agent_run(extra, import_args)
  local wp = fake_agent()
  link.poll(s)
  assert(s.link and s.link.connected, 'agent not connected')
  config.options.ai.review_by = 'agent'
  answer()
  view.ai_review_command(true, 'fixture-sec')
  config.options.ai.review_by = 'ask'
  local list = requests.list({ state_dir })
  local req = list[#list]
  assert(req and req.kind == 'review' and req.status == 'pending', vim.inspect(req))
  local p = run({ 'hunks', '--prompt', '--request', req.id })
  assert(p.code == 0, p.stderr)
  local args = { 'import-review', '--request', req.id }
  vim.list_extend(args, import_args or {})
  args[#args + 1] = '-'
  local r = run(args, { stdin = vim.json.encode(review_doc(extra)) })
  assert(r.code == 0, r.stderr)
  assert(vim.wait(10000, function()
    return next(arv.jobs) == nil
  end, 20), 'the request did not end')
  idle()
  sessions.remove(wp)
  link.poll(s)
  return r, req
end

---The view's lines at a roomy width (the headless screen is 80 cells: the buffer's lines are cut).
local function vtext()
  return table.concat(rv.texts(s, 160), '\n')
end

local function vrow(needle)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(s.arlist.buf, 0, -1, false)) do
    if l:find(needle, 1, true) then
      return i
    end
  end
  error('no line with ' .. needle .. ' in\n' .. table.concat(vim.api.nvim_buf_get_lines(s.arlist.buf, 0, -1, false), '\n'))
end

local function feed(k)
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
end

local function vkeys(k, needle)
  vim.api.nvim_set_current_win(s.arlist.win)
  if needle then
    vim.api.nvim_win_set_cursor(s.arlist.win, { vrow(needle), 0 })
  end
  feed(k)
end

local function cursor_line()
  return vim.api.nvim_get_current_line()
end

local function panel()
  return table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
end

-- ---------------------------------------------------------------------------
-- Tags (pure)
-- ---------------------------------------------------------------------------

h.test('tags: cleaned to a short restricted form; defaults from the skill, else the run; set, removed, merged per tag', function()
  h.eq('pass-1', tags.clean('  #Pass 1 '))
  h.eq('a.b_c-d', tags.clean('a.b_c-d'))
  h.eq('x-y', tags.clean('x/y\n'))
  h.eq(nil, tags.clean('!!!'))
  h.eq(nil, tags.clean('é'))
  h.eq(tags.MAX_LEN, #tags.clean(string.rep('a', 60)))
  h.eq({ { 'a', 'b' }, { '%%' } }, { tags.clean_list({ 'A', 'b', 'a', '%%' }) })
  h.eq({ 'x', 'y' }, (tags.clean_list('x, y')))
  local c = { id = 'c1', created_at = 10, author = { kind = 'ai', name = 'claude' }, ai = { run = { name = 'claude', skill = 'Fixture Sec' } } }
  h.eq({ 'fixture-sec' }, tags.defaults(c), 'the skill')
  h.eq({ 'claude' }, tags.defaults({ author = { kind = 'ai', name = 'claude' }, ai = { run = { name = 'claude' } } }), 'the run')
  h.eq({ 'gpt' }, tags.defaults({ author = { kind = 'ai', name = 'gpt' }, ai = {} }), 'from before runs: the author')
  h.eq({}, tags.defaults({ author = { kind = 'agent', name = 'claude' } }), 'an agent comment')
  local t1 = tags.apply(c, { 'pass' }, true, 20)
  h.eq({ 'fixture-sec', 'pass' }, tags.of(t1))
  h.eq(true, tags.touched(t1), 'set after it was made')
  h.eq(false, tags.touched(tags.apply(c, { 'pass' }, true, 10)), 'set when it was made (an import)')
  local t2 = tags.apply(t1, { 'fixture-sec' }, false, 30)
  h.eq({ 'pass' }, tags.of(t2), 'a default removed')
  h.eq({ 'fixture-sec', 'pass' }, tags.of(tags.apply(t2, { 'fixture-sec' }, true, 40)), 'and back')
  local _, changed = tags.apply(t2, { 'pass' }, true, 50)
  h.eq(false, changed, 'already there')
  h.eq({ 'b', 'c' }, tags.of(tags.replace(t1, { 'b', 'c' }, 60)))
  local many = {}
  for i = 1, tags.MAX_TAGS + 1 do
    many[i] = 't' .. i
  end
  local none, err = tags.apply(c, many, true, 70)
  h.eq(nil, none)
  h.ok(err:find('at most'), err)
  -- per tag the newest entry: a removal elsewhere beats an older add, an add beats an older removal
  h.eq({ a = { at = 5, off = true }, b = { at = 9 } }, tags.merge({ a = { at = 1 }, b = { at = 9 } }, { a = { at = 5, off = true }, b = { at = 2, off = true } }))
end)

h.test('comments.merge: a tag added by the CLI survives an accept made at the same time in the UI', function()
  local base = comments.new(comments.file_anchor('m.txt'), '**T**', { author = { kind = 'ai', name = 'claude' }, now = 100 })
  base.ai = { title = 'T', severity = 'nit', run = { name = 'claude' } }
  local cli = tags.apply(base, { 'pass' }, true, 200)
  cli.updated_at = 200
  local ui = vim.deepcopy(base)
  ui.status, ui.author, ui.updated_at = 'accepted', { kind = 'user' }, 300
  local m = comments.merge(ui, cli, true)
  h.eq({ 'accepted', { 'claude', 'pass' } }, { m.status, tags.of(m) })
  h.eq({ 'accepted', { 'claude', 'pass' } }, { comments.merge(cli, ui).status, tags.of(comments.merge(cli, ui)) })
end)

-- ---------------------------------------------------------------------------
-- Runs
-- ---------------------------------------------------------------------------

h.test('migration: a version 1 record is read as one run; findings from before runs belong to it; the next run keeps it', function()
  local dir = h.tmpdir('agent-reviews-migrate')
  local cpath = dir .. '/x.comments.json'
  local rpath = ai_review.record_path(cpath)
  ai_review.save_record(rpath, { kind = 'revuey-ai-review', version = 1, id = 'old1', author = { kind = 'ai', name = 'claude' },
    summary = 'Old summary.', verdict = 'approve', findings = 1, imported = 1, dropped = 0, skipped = 0, replaced = 0,
    generator = { provider = 'claude', model = 'm1', generated_at = 1000 } })
  local runs = ai_review.read_runs(rpath)
  h.eq(1, #runs)
  h.eq({ 'old1', true, 'claude', 'claude', 'm1', 1000000 }, { runs[1].id, runs[1].migrated, runs[1].run.name, runs[1].run.provider, runs[1].run.model, runs[1].finished_at })
  h.eq('Old summary.', ai_review.read_record(rpath).summary)
  -- a finding from before runs (no ai.run, an older review id): the migrated record's
  local old = comments.new(comments.file_anchor('m.txt'), '**Old**', { author = { kind = 'ai', name = 'claude' } })
  old.ai = { review = 'older0', title = 'Old', severity = 'nit' }
  local g = ai_review.groups(runs, { old })
  h.eq(1, #g)
  h.eq({ 'old1', 1, 1 }, { g[1].id, #g[1].findings, g[1].counts.untriaged })
  h.eq({ 'claude' }, tags.of(old))
  -- a new run: the file becomes a list of both (the old one has a live finding)
  ai_review.add_run(rpath, { id = 'new1', run = { name = 'claude', provider = 'claude' }, summary = 'New.', verdict = 'comment', finished_at = 2000000, generator = {} },
    ai_review.live_runs({ comments = { [old.id] = old } }))
  local data = vim.json.decode(table.concat(vim.fn.readfile(rpath), '\n'))
  h.eq({ 'revuey-ai-reviews', 2, 2 }, { data.kind, data.version, #data.runs })
  h.eq({ 'old1', 'new1' }, vim.tbl_map(function(r)
    return r.id
  end, ai_review.read_runs(rpath)))
  -- the old finding gone, a later run of the same reviewer drops it
  ai_review.add_run(rpath, { id = 'new2', run = { name = 'claude', provider = 'claude' }, summary = 'Newer.', verdict = 'comment', finished_at = 3000000, generator = {} }, {})
  h.eq({ 'new2' }, vim.tbl_map(function(r)
    return r.id
  end, ai_review.read_runs(rpath)))
end)

h.test('a tag never wins the comment: CLI loads, the UI accepts and saves, the CLI saves a tag; both stay', function()
  local dir = h.tmpdir('agent-reviews-race')
  local path = dir .. '/x.comments.json'
  local st = comments.load(path)
  local c = comments.new(comments.file_anchor('m.txt'), '**T**', { author = { kind = 'ai', name = 'claude' }, now = 100 })
  c.ai = { title = 'T', severity = 'nit', run = { name = 'claude' }, review = 'r1' }
  comments.put(st, c, 100)
  comments.save(st)
  local cli = comments.load(path) -- the CLI loads
  local ui = comments.load(path)
  h.ok(ai_review.accept(ui, c.id, 300))
  comments.save(ui) -- the UI accepts and saves
  -- the CLI tags what it loaded (as `bin/revuey tag` does) and saves, later
  comments.put_tags(cli, tags.apply(comments.get(cli, c.id), { 'x' }, true, 400))
  comments.save(cli)
  local d = comments.read(path).comments[c.id]
  h.eq({ 'accepted', { 'claude', 'x' } }, { d.status, tags.of(d) })
  -- and the other way round: a dismiss after the tag was saved
  local ui2 = comments.load(path)
  local cli2 = comments.load(path)
  comments.put_tags(cli2, tags.apply(comments.get(cli2, c.id), { 'y' }, true, 500))
  comments.save(cli2)
  local cur = vim.deepcopy(comments.get(ui2, c.id))
  cur.body = 'edited'
  comments.put(ui2, cur, 600)
  comments.save(ui2)
  d = comments.read(path).comments[c.id]
  h.eq({ 'edited', { 'claude', 'x', 'y' } }, { d.body, tags.of(d) })
end)

h.test('a re-run\'s replacement never deletes a finding tagged meanwhile (the import did not see the tag)', function()
  local f = { id = 'f1', created_at = 100, updated_at = 100, status = 'saved', author = { kind = 'ai', name = 'claude' }, ai = { run = { name = 'claude' } } }
  local tomb = { id = 'f1', deleted = true, deleted_at = 200, updated_at = 101, replaced = true }
  local tagged = tags.apply(f, { 'keep' }, true, 150)
  h.eq(tagged, comments.merge(tomb, tagged))
  h.eq(tagged, comments.merge(tagged, tomb))
  h.eq(tomb, comments.merge(tomb, f), 'untagged: replaced')
  local plain = { id = 'f1', deleted = true, deleted_at = 200, updated_at = 101 }
  h.eq(plain, comments.merge(plain, tagged), 'a user\'s delete still wins')
end)

h.test('migration survives the rewrite: findings from before runs stay with the old record after other runs', function()
  local dir = h.tmpdir('agent-reviews-migrate2')
  local rpath = dir .. '/x.ai-review.json'
  ai_review.save_record(rpath, { kind = 'revuey-ai-review', version = 1, id = 'old1', author = { kind = 'ai', name = 'claude' },
    summary = 'S', verdict = 'approve', generator = { provider = 'claude', generated_at = 1 } })
  local old = { id = 'f1', created_at = 5, status = 'saved', author = { kind = 'ai', name = 'claude' }, ai = { review = 'older0', title = 'x' } }
  local live = ai_review.live_runs({ comments = { f1 = old } })
  -- another reviewer's run: the file is rewritten as version 2
  ai_review.add_run(rpath, { id = 'a1', run = { name = 'claude', provider = 'agent', agent = 'claude' }, finished_at = 2000, generator = {} }, live)
  h.eq(true, vim.json.decode(table.concat(vim.fn.readfile(rpath), '\n')).runs[1].legacy)
  local g = ai_review.groups(ai_review.read_runs(rpath), { old })
  local by = {}
  for _, x in ipairs(g) do
    by[x.id] = x
  end
  h.ok(by.old1 and by.old1.record and #by.old1.findings == 1, vim.inspect(g))
  -- a later run of the old record's identity: it stays while its finding lives
  ai_review.add_run(rpath, { id = 'n2', run = { name = 'claude', provider = 'claude' }, finished_at = 3000, generator = {} }, live)
  h.eq({ 'old1', 'a1', 'n2' }, vim.tbl_map(function(r)
    return r.id
  end, ai_review.read_runs(rpath)))
  g = ai_review.groups(ai_review.read_runs(rpath), { old })
  h.ok(vim.iter(g):any(function(x)
    return x.id == 'old1' and #x.findings == 1
  end), vim.inspect(g))
  -- its finding gone: the next such run drops it
  ai_review.add_run(rpath, { id = 'n3', run = { name = 'claude', provider = 'claude' }, finished_at = 4000, generator = {} }, {})
  h.eq({ 'a1', 'n3' }, vim.tbl_map(function(r)
    return r.id
  end, ai_review.read_runs(rpath)))
end)

h.test('the cap drops the oldest runs nothing points at, never one with live findings', function()
  local list = {}
  for i = 1, 35 do
    list[i] = { id = 'r' .. i, run = { name = 'n' .. i }, finished_at = i }
  end
  local out = ai_review.prune_runs(list, { r1 = true, r2 = true })
  local ids = vim.tbl_map(function(r)
    return r.id
  end, out)
  h.eq(ai_review.MAX_RUNS, #out)
  h.eq({ 'r1', 'r2', 'r8' }, { ids[1], ids[2], ids[3] }, 'r3..r7 went first')
  local all = {}
  for i = 1, 35 do
    all['r' .. i] = true
  end
  h.eq(35, #ai_review.prune_runs(list, all), 'every run has live findings: over the cap')
  local none = ai_review.prune_runs(list, {})
  h.eq({ ai_review.MAX_RUNS, 'r35' }, { #none, none[#none].id }, 'the newest stays')
end)

h.test('two runs side by side: a fresh session and the connected agent with a skill; default tags; --tag on import', function()
  open()
  answer()
  view.ai_review_command(true)
  wait_jobs()
  local fresh = findings()
  h.eq(2, #fresh, vim.inspect(fresh))
  h.eq({ 'claude' }, tags.of(fresh[1]), 'a fresh run without a skill: its name')
  local r = agent_run(nil, { '--tag', 'Pass 1' })
  h.ok(r.stdout:find('run %x+, tagged #pass%-1: list its findings with `.-findings %-%-run %x+`'), r.stdout)
  h.eq(4, #findings(), 'the agent and a fresh run never replace each other')
  local tw = by_title('Twenty is a word')
  h.eq({ 'fixture-sec', 'pass-1' }, tags.of(tw), 'the skill, and the import\'s tag')
  local runs = arv.runs(s)
  h.eq(2, #runs)
  h.eq({ 'claude', 'agent' }, { runs[1].run.provider, runs[2].run.provider })
  h.eq({ 'fixture-sec', 'claude' }, { runs[2].run.skill, ai_review.run_who(runs[2].run):match('^(%w+)') })
  h.eq(tw.ai.review, runs[2].id)
  -- the panel: the latest, how many runs, the view's key
  h.ok(vim.wait(5000, function()
    return panel():find(' 2 runs · gA by run', 1, true) ~= nil
  end, 20), panel())
end)

h.test('re-runs: only the same reviewer\'s untouched findings go; a run left without findings is dropped', function()
  -- accept one of the fresh run's findings: it stays, and so does its run
  local first = vim.tbl_filter(function(c)
    return c.ai.run.provider == 'claude'
  end, findings())
  h.eq(2, #first)
  local store = cv.sync_store(s)
  h.ok(ai_review.accept(store, first[1].id))
  comments.save(store)
  local first_run = first[1].ai.review
  answer()
  view.ai_review_command(true)
  wait_jobs()
  local runs = arv.runs(s)
  h.eq(3, #runs, vim.inspect(vim.tbl_map(function(x)
    return x.id
  end, runs)))
  h.eq(first_run, runs[1].id, 'kept: its accepted finding')
  h.ok(comments.get(cv.sync_store(s), first[1].id), 'the accepted one stays')
  h.eq(nil, comments.get(cv.sync_store(s), first[2].id), 'the untouched one was replaced')
  h.eq(2, #vim.tbl_filter(function(c)
    return c.ai.run.provider == 'agent'
  end, findings()), 'the agent\'s stay')
  -- again: the middle fresh run has nothing left, it is dropped
  local middle = runs[3].id
  answer()
  view.ai_review_command(true)
  wait_jobs()
  local ids = vim.tbl_map(function(x)
    return x.id
  end, arv.runs(s))
  h.eq(3, #ids)
  h.ok(not vim.tbl_contains(ids, middle), vim.inspect(ids))
  h.ok(vim.tbl_contains(ids, first_run), vim.inspect(ids))
end)

-- ---------------------------------------------------------------------------
-- The CLI
-- ---------------------------------------------------------------------------

h.test('findings lists the runs and their findings with ids; --run, --tag, --status, --json filter them', function()
  local r = run({ 'findings' })
  h.eq(0, r.code, r.stderr)
  local out = r.stdout
  h.ok(out:find('run %x+ · claude %(connected%) · skill fixture%-sec · comment · [%d%- :]+ · 2 untriaged, 0 accepted, 0 dismissed'), out)
  h.ok(out:find('\n  Thirty and twenty are spelled out.\n', 1, true), out)
  local tw = by_title('Twenty is a word')
  h.ok(out:find(tw.id .. '  untriaged major    m.txt:20  Twenty is a word  #fixture-sec #pass-1', 1, true), out)
  h.ok(out:find('1 accepted', 1, true), out)
  local j = vim.json.decode(run({ 'findings', '--json' }).stdout)
  h.eq(3, #j.runs)
  -- newest first: the last fresh run, the agent's, the first fresh run (its accepted finding)
  h.eq({ 'claude', 'agent', 'claude' }, { j.runs[1].provider, j.runs[2].provider, j.runs[3].provider })
  h.eq({ 'claude (connected)', 'fixture-sec', 'comment' }, { j.runs[2].who, j.runs[2].skill, j.runs[2].verdict })
  local agent_run_id = j.runs[2].id
  r = run({ 'findings', '--run', agent_run_id:sub(-6), '--json' })
  h.eq(0, r.code, r.stderr)
  h.eq({ 1, 2 }, { #vim.json.decode(r.stdout).runs, #vim.json.decode(r.stdout).runs[1].findings })
  h.eq(1, run({ 'findings', '--run', 'nope' }).code)
  r = run({ 'findings', '--status', 'accepted', '--json' })
  local acc = vim.json.decode(r.stdout).runs
  h.eq({ 1, 'accepted' }, { #acc, acc[1].findings[1].status })
  h.eq(2, run({ 'findings', '--status', 'maybe' }).code)
  r = run({ 'findings', '--tag', 'pass-1', '--json' })
  h.eq(2, #vim.json.decode(r.stdout).runs[1].findings)
  h.eq(1, #vim.json.decode(r.stdout).runs)
end)

h.test('tag adds and removes (any unique part of the id); bad tags are refused; the running review shows it', function()
  local tw = by_title('Twenty is a word')
  local r = run({ 'tag', tw.id:sub(-10), 'Security', 'naming' })
  h.eq(0, r.code, r.stderr)
  h.eq(tw.id .. ' tagged: #fixture-sec #naming #pass-1 #security\n', r.stdout)
  r = run({ 'tag', '--remove', tw.id, 'naming', 'fixture-sec' })
  h.eq(0, r.code, r.stderr)
  h.eq(tw.id .. ' tagged: #pass-1 #security\n', r.stdout)
  r = run({ 'tag', tw.id, 'security' })
  h.ok(r.stdout:find('unchanged', 1, true), r.stdout)
  r = run({ 'tag', tw.id, '!!' })
  h.eq(2, r.code)
  h.ok(r.stderr:find('not a tag: !!', 1, true), r.stderr)
  h.eq(2, run({ 'tag', tw.id }).code)
  -- the review reads the file again
  h.ok(vim.wait(5000, function()
    local c = comments.get(cv.sync_store(s), tw.id)
    return c and tags.has(c, 'security')
  end, 20), 'the review did not see the tag')
  h.eq(1, #vim.json.decode(run({ 'findings', '--tag', 'security', '--json' }).stdout).runs)
end)

h.test('a tag from the CLI survives an accept made meanwhile in the UI (merged on save)', function()
  local th = by_title('Thirty is a word')
  local store = cv.sync_store(s)
  -- the UI's copy is from before the tag
  local r = run({ 'tag', th.id, 'concurrent' })
  h.eq(0, r.code, r.stderr)
  local cur = store.comments[th.id]
  h.ok(not tags.has(cur, 'concurrent'), 'not reloaded yet')
  local c = vim.deepcopy(cur)
  c.status, c.author = 'accepted', { kind = 'user' }
  c.ai.accepted_at = comments.now_ms()
  comments.put(store, c)
  comments.save(store)
  local disk = comments.read(store.path).comments[th.id]
  h.eq('accepted', disk.status)
  h.ok(tags.has(disk, 'concurrent'), vim.inspect(disk.tags))
end)

h.test('comment --tag tags an agent comment on creation', function()
  local r = run({ 'comment', '--path', 'new.txt', '--line', '1', '--tag', 'pass-1', '--tag', 'Docs', 'Why a new file?' })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('\ntagged #pass%-1 #docs\n$'), r.stdout)
  local id = r.stdout:match('^(%S+)\n')
  h.ok(vim.wait(5000, function()
    local c = comments.get(cv.sync_store(s), id)
    return c and tags.has(c, 'docs')
  end, 20), 'not shown')
  h.eq({ 'docs', 'pass-1' }, tags.of(comments.get(cv.sync_store(s), id)))
  h.eq(1, run({ 'comment', '--path', 'new.txt', '--line', '1', '--tag', '##', 'x' }).code == 2 and 1 or 0)
end)

-- ---------------------------------------------------------------------------
-- The view
-- ---------------------------------------------------------------------------

h.test('the view: runs newest first with who, skill, verdict, summary and counts; their findings; the agent\'s comments', function()
  idle()
  -- room for the view's lines: the panel narrow
  vim.api.nvim_win_set_width(s.panel_win, 4)
  feed('gA')
  h.ok(s.arlist ~= nil, 'gA opens it')
  local t = vtext()
  -- the last fresh run found the accepted finding again: skipped, one new finding
  h.ok(t:find('^ 3 runs · 5 findings: 3 untriaged · 2 accepted · 0 dismissed'), t)
  local f = t:find(' ▍claude · claude-fake-1  just now  ✗ request changes\n ▍ A fake review summary.\n ▍ 1 untriaged · 0 accepted · 0 dismissed · 1 dropped\n', 1, true)
  local a = t:find(' ▍claude (connected) · skill fixture-sec  just now  ● comment\n', 1, true)
  local f2 = t:find(' ▍claude · claude-fake-1', a or 1, true)
  local cm = t:find(' ▍Comments from agent (agent)', 1, true)
  h.ok(f and a and f2 and cm and f < a and a < f2 and f2 < cm, 'newest first, the agent\'s comments last\n' .. t)
  h.ok(t:find(' ▍ Thirty and twenty are spelled out.\n', 1, true), 'the summary\'s first line\n' .. t)
  h.ok(t:find(' ▍ 1 untriaged · 1 accepted · 0 dismissed\n', 1, true), t)
  h.ok(t:find('   major    Twenty is a word%s+m%.txt:20%s+untriaged  #pass%-1 #security\n'), t)
  h.ok(t:find('   minor    Thirty is a word%s+m%.txt:30%s+accepted   #fixture%-sec #concurrent #pass%-1\n'), t)
  h.ok(t:find('   comment  Why a new file%?%s+new%.txt:1%s+untriaged  #docs #pass%-1'), t)
  h.ok(t:find('   major    First line looks wrong%s+m%.txt:17%s+accepted   #claude'), t)
  -- the panel and the winbar while it is open
  h.ok(panel():find(' AI reviews', 1, true), panel())
  vim.api.nvim_win_set_cursor(s.arlist.win, { vrow('Twenty is a word'), 0 })
  vim.g.statusline_winid = s.diff_win
  local wb = vim.api.nvim_eval_statusline(view.winbar(), { winid = s.diff_win, use_winbar = true, maxwidth = 300 }).str
  h.ok(wb:find('<CR> show · ca accept', 1, true), wb)
  vim.api.nvim_win_set_cursor(s.arlist.win, { vrow('claude (connected)'), 0 })
  wb = vim.api.nvim_eval_statusline(view.winbar(), { winid = s.diff_win, use_winbar = true, maxwidth = 300 }).str
  h.ok(wb:find('<CR> only this run · cA accept all · cN dismiss all', 1, true), wb)
end)

h.test('the view: ]] / [[ between runs, ]c / [c between findings; cz shows a finding in full', function()
  vim.api.nvim_set_current_win(s.arlist.win)
  vim.api.nvim_win_set_cursor(s.arlist.win, { 1, 0 })
  feed(']]')
  h.ok(cursor_line():find('claude · claude-fake-1', 1, true), cursor_line())
  feed(']]')
  h.ok(cursor_line():find('claude (connected)', 1, true), cursor_line())
  feed(']]')
  h.ok(cursor_line():find('claude · claude-fake-1', 1, true), cursor_line())
  feed(']]')
  h.ok(cursor_line():find('Comments from agent', 1, true), cursor_line())
  feed(']]')
  h.ok(cursor_line():find('Comments from agent', 1, true), 'past the last: stays')
  feed('2[[')
  h.ok(cursor_line():find('claude (connected)', 1, true), 'a count\n' .. cursor_line())
  feed(']c')
  h.ok(cursor_line():find('Twenty is a word', 1, true), cursor_line())
  feed(']c')
  h.ok(cursor_line():find('Thirty is a word', 1, true), cursor_line())
  feed('[c')
  h.ok(cursor_line():find('Twenty is a word', 1, true), cursor_line())
  feed('cz')
  h.ok(vtext():find('│ Use digits.', 1, true), vtext())
  h.ok(cursor_line():find('Twenty is a word', 1, true), 'the cursor stays on it')
  feed('cz')
  h.ok(not vtext():find('│ Use digits.', 1, true), vtext())
end)

h.test('the view: filters by tag (t), status, severity and run (<CR> on a run); shown in the header; F clears', function()
  answer('security')
  vkeys('t')
  local t = vtext()
  h.ok(t:find('\n Only #security  f filter  F clear\n', 1, true), t)
  h.ok(t:find('Twenty is a word', 1, true) and not t:find('Thirty is a word', 1, true) and not t:find('Why a new file', 1, true), t)
  h.ok(not t:find('claude · claude-fake-1', 1, true), 'runs without a match are left out\n' .. t)
  -- the comments view honours the tag filter too
  feed('cl')
  h.ok(s.clist and not s.arlist, 'cl switches to the comments view')
  local ct = table.concat(vim.api.nvim_buf_get_lines(s.clist.buf, 0, -1, false), '\n')
  h.ok(ct:find(' Only #security (1)', 1, true) and not ct:find('Thirty', 1, true), ct)
  h.ok(ct:find('#pass-1 #security', 1, true), 'tags on the thread\'s line\n' .. ct)
  feed('F')
  ct = table.concat(vim.api.nvim_buf_get_lines(s.clist.buf, 0, -1, false), '\n')
  h.ok(ct:find('Thirty', 1, true), ct)
  feed('gA')
  h.ok(s.arlist and not s.clist, 'gA from the comments view')
  answer('status', 'accepted')
  vkeys('f')
  t = vtext()
  h.ok(t:find(' Only accepted', 1, true) and t:find('Thirty is a word', 1, true) and not t:find('Twenty is a word', 1, true), t)
  answer('severity', 'major')
  vkeys('f')
  t = vtext()
  h.ok(t:find(' Only accepted · major', 1, true) and t:find('First line looks wrong', 1, true) and not t:find('Thirty is a word', 1, true), t)
  answer('tag', 'docs')
  vkeys('f')
  h.ok(vtext():find('No finding passes the filter', 1, true), vtext())
  vkeys('F')
  h.ok(vtext():find('Thirty is a word', 1, true) and vtext():find('Why a new file', 1, true), 'F clears')
  vkeys('<CR>', 'claude (connected)')
  t = vtext()
  h.ok(t:find(' Only run claude (connected) · skill fixture-sec', 1, true) and not t:find('claude-fake-1', 1, true), t)
  h.ok(cursor_line():find('claude (connected)', 1, true), 'the cursor stays on the run')
  feed('<CR>')
  h.ok(vtext():find('claude-fake-1', 1, true), 'again: every run')
end)

h.test('the view: <CR> on a finding shows it in the diff; gA and q come back', function()
  vkeys('<CR>', 'Twenty is a word')
  h.eq(nil, s.arlist)
  local id = by_title('Twenty is a word').id
  h.eq(s.cm.jump[id], vim.api.nvim_win_get_cursor(s.diff_win)[1])
  h.eq(s.diff_win, vim.api.nvim_get_current_win())
  feed('gA')
  h.ok(cursor_line():find('Twenty is a word', 1, true), 'it remembers the finding\n' .. cursor_line())
  feed('q')
  h.eq(nil, s.arlist)
  h.eq(s.diff_win, vim.api.nvim_get_current_win())
  -- the panel's AI review block opens it
  local row
  for r in pairs(s.panel_ai_rows or {}) do
    row = row and math.min(row, r) or r
  end
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_win_set_cursor(s.panel_win, { row, 0 })
  feed('<CR>')
  h.ok(s.arlist ~= nil, 'the panel\'s <CR>')
end)

h.test('the view: ct tags a finding, and on a run every finding of it; ca / cn act on the finding under the cursor', function()
  answer('pass-1 security reviewed')
  vkeys('ct', 'Twenty is a word')
  h.ok(tags.has(by_title('Twenty is a word'), 'reviewed'))
  h.ok(vtext():find('Twenty is a word.-#pass%-1 #reviewed #security\n'), vtext())
  h.ok(cursor_line():find('Twenty is a word', 1, true), cursor_line())
  answer('+batch')
  vkeys('ct', 'claude (connected)')
  h.ok(tags.has(by_title('Twenty is a word'), 'batch') and tags.has(by_title('Thirty is a word'), 'batch'))
  h.ok(tags.has(by_title('Twenty is a word'), 'reviewed'), 'a + adds, the others stay')
  -- :RevueyTag in the view
  vim.api.nvim_win_set_cursor(s.arlist.win, { vrow('Twenty is a word'), 0 })
  vim.cmd('RevueyTag -batch extra')
  h.eq({ 'extra', 'pass-1', 'reviewed', 'security' }, tags.of(by_title('Twenty is a word')))
  -- the events say so
  local ev = table.concat(vim.fn.readfile(comments.events_path_for(s.review.state._path)), '\n')
  h.ok(ev:find('"kind":"tagged"', 1, true), 'a tagged event')
  vkeys('cn', 'Twenty is a word')
  h.eq('dismissed', by_title('Twenty is a word').status)
  h.ok(cursor_line():find('Twenty is a word', 1, true) and cursor_line():find('dismissed', 1, true), cursor_line())
  feed('cn')
  h.eq('saved', by_title('Twenty is a word').status, 'restored')
end)

h.test('the view: cA / cN accept or dismiss a run\'s untriaged findings, asking first; cD deletes the run', function()
  local asked = {}
  local orig = rv.confirm
  local say = false
  rv.confirm = function(msg, what)
    asked[#asked + 1] = { msg = msg, what = what }
    return say
  end
  -- the latest fresh run (the first run shown): one untriaged finding
  local fresh_row = vrow('claude · claude-fake-1')
  vim.api.nvim_win_set_cursor(s.arlist.win, { fresh_row, 0 })
  feed('cA')
  h.eq(1, #asked)
  h.ok(asked[1].msg:find('accept 1 untriaged finding of claude · claude-fake-1?', 1, true), asked[1].msg)
  h.eq('Accept', asked[1].what)
  local latest = arv.runs(s)[#arv.runs(s)]
  local function of_run(id)
    return vim.tbl_filter(function(c)
      return c.ai.review == id
    end, findings())
  end
  h.eq({ 'saved' }, vim.tbl_map(function(c)
    return c.status
  end, of_run(latest.id)), 'said no: nothing changed')
  say = true
  feed('cN')
  h.eq({ 'dismissed' }, vim.tbl_map(function(c)
    return c.status
  end, of_run(latest.id)))
  h.ok(vtext():find(' ▍ 0 untriaged · 0 accepted · 1 dismissed', 1, true), vtext())
  feed('cA')
  h.ok(msgs[#msgs].msg:find('nothing untriaged in this run', 1, true), msgs[#msgs].msg)
  -- on a finding of the agent's run: its run
  vim.api.nvim_win_set_cursor(s.arlist.win, { vrow('Twenty is a word'), 0 })
  feed('cA')
  h.ok(asked[#asked].msg:find('accept 1 untriaged finding of claude (connected)', 1, true), asked[#asked].msg)
  h.eq('accepted', by_title('Twenty is a word').status)
  -- delete the fresh run: its dismissed findings go, the record too
  local n_runs = #arv.runs(s)
  say = false
  vim.api.nvim_win_set_cursor(s.arlist.win, { vrow('claude · claude-fake-1'), 0 })
  feed('cD')
  h.eq('revuey: delete claude · claude-fake-1: 1 dismissed finding deleted and not added again?', asked[#asked].msg)
  h.eq(n_runs, #arv.runs(s), 'said no')
  say = true
  feed('cD')
  h.eq(0, #of_run(latest.id))
  h.ok(vim.wait(5000, function()
    return #arv.runs(s) == n_runs - 1
  end, 20), 'the run record stays')
  -- the agent's run: its accepted findings stay as your comments
  vim.api.nvim_win_set_cursor(s.arlist.win, { vrow('claude (connected)'), 0 })
  feed('cD')
  h.eq('revuey: delete claude (connected) · skill fixture-sec: 2 accepted findings kept as your comments, under no run?', asked[#asked].msg)
  local tw, th = by_title('Twenty is a word'), by_title('Thirty is a word')
  h.ok(tw and th, 'accepted: kept')
  h.eq({ true, nil, 'accepted' }, { tw.ai.detached, tw.ai.review, tw.status })
  -- under no run: no group of a gone record that nothing could clear
  h.ok(not vtext():find('run record gone', 1, true) and not vtext():find('Twenty is a word', 1, true), vtext())
  local ct = table.concat(require('revuey.comments_list').texts(s, 160), '\n')
  h.ok(ct:find('Twenty is a word', 1, true), 'still in the comments view\n' .. ct)
  -- the dismissed finding of the deleted fresh run is not added again by the next fresh run
  answer()
  view.ai_review_command(true)
  wait_jobs()
  h.eq(nil, by_title('File-level nit'), 'a dismissal survives cD')
  rv.confirm = orig
end)

h.test('live: an import and a tag from the CLI redraw the open view', function()
  h.ok(s.arlist ~= nil)
  local r = run({ 'import-review', '--name', 'codex', '--tag', 'pass-2', '-' }, { stdin = vim.json.encode(review_doc({
    summary = 'A second opinion.', findings = { { hunk = 'h2', line = 5, severity = 'critical', title = 'Thirty again', body = 'Really.' } } })) })
  h.eq(0, r.code, r.stderr)
  h.ok(vim.wait(5000, function()
    local t = vtext()
    return t:find(' ▍codex', 1, true) ~= nil and t:find(' ▍ A second opinion.', 1, true) ~= nil
      and t:find('critical Thirty again', 1, true) ~= nil
  end, 20), vtext())
  local id = by_title('Thirty again').id
  h.eq(0, run({ 'tag', id, 'hot' }).code)
  h.ok(vim.wait(5000, function()
    return vtext():find('#codex #hot #pass-2', 1, true) ~= nil
  end, 20), vtext())
  feed('q')
end)

h.test('cD on an untriaged finding forgets it: a later run finds it again; one accepted elsewhere meanwhile is kept', function()
  local asked = {}
  local orig = rv.confirm
  if not s.arlist then
    feed('gA')
  end
  local r = run({ 'import-review', '--name', 'gemma', '-' }, { stdin = vim.json.encode(review_doc({
    summary = 'Two notes.', findings = {
      { hunk = 'h2', line = 5, severity = 'nit', title = 'Thirty once more', body = 'Hm.' },
      { hunk = 'h1', line = 5, severity = 'nit', title = 'Twenty once more', body = 'Hm.' },
    } })) })
  h.eq(0, r.code, r.stderr)
  h.ok(vim.wait(5000, function()
    return table.concat(vim.api.nvim_buf_get_lines(s.arlist.buf, 0, -1, false), '\n'):find(' ▍gemma', 1, true) ~= nil
  end, 20), vtext())
  local other = by_title('Twenty once more')
  rv.confirm = function(msg)
    asked[#asked + 1] = msg
    -- meanwhile, another instance accepts one
    local st = comments.load(cv.sync_store(s).path)
    assert(ai_review.accept(st, other.id))
    comments.save(st)
    return true
  end
  vim.api.nvim_win_set_cursor(s.arlist.win, { vrow('gemma'), 0 })
  feed('cD')
  rv.confirm = orig
  h.eq('revuey: delete gemma: 2 untriaged findings deleted (a later run may find them again)?', asked[1])
  h.eq(nil, by_title('Thirty once more'))
  local kept = by_title('Twenty once more')
  h.ok(kept and kept.status == 'accepted' and kept.ai.detached, 'accepted meanwhile: kept\n' .. vim.inspect(kept))
  r = run({ 'import-review', '--name', 'gemma', '-' }, { stdin = vim.json.encode(review_doc({
    summary = 'Again.', findings = { { hunk = 'h2', line = 5, severity = 'nit', title = 'Thirty once more', body = 'Hm.' } } })) })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('imported 1 finding', 1, true), r.stdout)
  h.ok(vim.wait(5000, function()
    return by_title('Thirty once more') ~= nil
  end, 20), 'forgotten: found again')
  feed('q')
end)

h.test('a finding tagged after the import is touched: the same reviewer\'s re-run leaves it', function()
  local doc = review_doc({ summary = 'Tagging.', findings = {
    { hunk = 'h1', line = 6, severity = 'nit', title = 'Tagged one', body = 'a' },
    { hunk = 'h1', line = 7, severity = 'nit', title = 'Untagged one', body = 'b' },
  } })
  h.eq(0, run({ 'import-review', '--name', 'tagger', '-' }, { stdin = vim.json.encode(doc) }).code)
  h.ok(vim.wait(5000, function()
    return by_title('Tagged one') ~= nil
  end, 20))
  local t, u = by_title('Tagged one'), by_title('Untagged one')
  h.eq(1, cv.set_tags(s, { t.id }, { add = { 'keep' } }))
  h.eq(true, tags.touched(comments.get(cv.sync_store(s), t.id)))
  local r = run({ 'import-review', '--name', 'tagger', '-' }, { stdin = vim.json.encode(doc) })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('1 untriaged finding of the previous review replaced', 1, true), r.stdout)
  h.ok(vim.wait(5000, function()
    return comments.get(cv.sync_store(s), u.id) == nil
  end, 20), 'the untagged one was replaced')
  local after = comments.get(cv.sync_store(s), t.id)
  h.ok(after and tags.has(after, 'keep'), 'tagged: not replaced')
  h.eq(1, #vim.tbl_filter(function(c)
    return c.ai.title == 'Tagged one'
  end, findings()), 'not added twice')
end)

h.test('the UI tag input changes only what was edited: a tag added elsewhere meanwhile stays; bad words are refused', function()
  local t = by_title('Thirty once more')
  local real_input = vim.ui.input
  vim.ui.input = function(o, cb)
    h.eq('gemma', o.default, 'the tags it shows')
    -- the CLI tags it while the input is open
    assert(run({ 'tag', t.id, 'cli-side' }).code == 0)
    cb(o.default .. ' mine')
  end
  cv.ask_tags(s, { t.id })
  local now = comments.get(cv.sync_store(s), t.id)
  h.ok(tags.has(now, 'mine') and tags.has(now, 'cli-side'), vim.inspect(tags.of(now)))
  local before = tags.of(now)
  vim.ui.input = function(o, cb)
    cb(o.default .. ' !!')
  end
  msgs = {}
  cv.ask_tags(s, { t.id })
  h.eq(before, tags.of(comments.get(cv.sync_store(s), t.id)))
  h.ok(msgs[#msgs].msg:find('not a tag: !!', 1, true), vim.inspect(msgs))
  vim.ui.input = real_input
end)

h.run()
