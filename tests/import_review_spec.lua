-- Integration (real git repos, real `bin/revuey` subprocesses): `bin/revuey hunks` and
-- `bin/revuey import-review`, the way for an outside agent or tool to produce an AI review in
-- revuey's format. Hunk ids with numbered lines (text, --json, --prompt) and the diff hash; the
-- schema; importing from a file and stdin with no review running (placed when the review opens),
-- bad anchors dropped and counted, a stale diff hash and broken input refused, the reviewer's
-- earlier untouched findings replaced; and findings appearing live in a running review with its
-- panel showing the verdict.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
vim.notify = function() end

local state_dir = h.tmpdir('import-review-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local comments = require('revuey.comments')
local ai_review = require('revuey.ai_review')

local lines = {}
for i = 1, 40 do
  lines[#lines + 1] = 'line ' .. i
end
local long = table.concat(lines, '\n') .. '\n'
local repo = h.repo('import-review', { ['m.txt'] = long }, {
  ['m.txt'] = (long:gsub('line 20\n', 'twenty\n')),
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

local function file(doc)
  local p = h.tmpdir('import-review-docs') .. '/' .. vim.fn.sha256(vim.json.encode(doc)):sub(1, 8) .. '.json'
  vim.fn.writefile({ type(doc) == 'string' and doc or vim.json.encode(doc) }, p)
  return p
end

---All AI findings in the state dir: title -> {c, path}.
local function on_disk()
  local found = {}
  for name, t in vim.fs.dir(state_dir) do
    if t == 'file' and name:match('%.comments%.json$') then
      local path = vim.fs.joinpath(state_dir, name)
      for _, c in pairs(comments.load(path, { readonly = true }).comments) do
        if not c.deleted and c.ai then
          found[c.ai.title] = { c = c, path = path }
        end
      end
    end
  end
  return found
end

local hunks -- from `hunks --json`

h.test('hunks: ids, numbered lines and the diff hash; --json; --prompt; import-review --schema', function()
  local r = run({ 'hunks' })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('# Hunks of feat vs main (working tree): 2', 1, true), r.stdout)
  local diff = r.stdout:match('Diff: (%x+)')
  h.ok(diff, r.stdout)
  h.ok(r.stdout:find('\n@@ h1 m.txt @@\n@@ -17,7 +17,7 @@ line 16\n1| line 17\n', 1, true), r.stdout)
  h.ok(r.stdout:find('\n4|-line 20\n5|+twenty\n', 1, true), r.stdout)
  h.ok(r.stdout:find('\n@@ h2 new.txt @@\n', 1, true), r.stdout)
  h.ok(not r.stdout:find('# Code Reviewer', 1, true), 'the diff only')
  local j = run({ 'hunks', '--json' })
  h.eq(0, j.code, j.stderr)
  local data = vim.json.decode(j.stdout)
  h.eq(diff, data.diff)
  h.eq({ 'h1', 'm.txt' }, { data.hunks[1].id, data.hunks[1].path })
  h.eq('+twenty', data.hunks[1].lines[5])
  h.eq('feat', data.review.branch)
  hunks = data.hunks
  local p = run({ 'hunks', '--prompt' })
  h.eq(0, p.code, p.stderr)
  h.ok(p.stdout:find('# Code Reviewer', 1, true) and p.stdout:find('import-review --schema', 1, true), p.stdout)
  h.ok(p.stdout:find('"diff": "' .. diff .. '"', 1, true), p.stdout)
  local sc = run({ 'import-review', '--schema' })
  h.eq(0, sc.code, sc.stderr)
  h.eq({ 'summary', 'verdict', 'findings' }, vim.json.decode(sc.stdout).required)
end)

h.test('import-review with no review running: findings stored as AI comments; bad anchors reported; placed when opened', function()
  local diff = vim.json.decode(run({ 'hunks', '--json' }).stdout).diff
  local doc = {
    summary = 'An outside review.',
    verdict = 'request_changes',
    diff = diff,
    findings = {
      { hunk = 'h1', line = 5, severity = 'major', title = 'Twenty', body = 'Spell it as a number.' },
      { hunk = 'h1', line = 4, severity = 'minor', title = 'Deleted', body = 'Old line.' },
      { hunk = 'h2', severity = 'nit', title = 'Whole file', body = 'Needed?' },
      { hunk = 'h9', line = 1, severity = 'minor', title = 'Ghost', body = 'x' },
      { hunk = 'h1', line = 40, severity = 'minor', title = 'Far', body = 'x' },
    },
  }
  local r = run({ 'import-review', '--name', 'outside', file(doc) })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('imported 3 findings (verdict: request changes) into feat vs main, working tree (no review running', 1, true), r.stdout)
  h.ok(r.stdout:find('2 dropped (1 unknown hunk, 1 line outside its hunk)', 1, true), r.stdout)
  local f = on_disk()
  h.eq({ kind = 'ai', name = 'outside' }, f.Twenty.c.author)
  h.eq({ 'new', 20 }, { f.Twenty.c.anchor.side, f.Twenty.c.anchor.start_line })
  h.eq({ 'old', 20 }, { f.Deleted.c.anchor.side, f.Deleted.c.anchor.start_line })
  h.eq(true, f['Whole file'].c.file_level)
  local rec = ai_review.read_record(ai_review.record_path(f.Twenty.path))
  h.eq({ 'An outside review.', 'request_changes', 'import' }, { rec.summary, rec.verdict, rec.generator.provider })
  -- the review revuey opens here shows them where they belong, with the verdict in the panel
  local s = h.open_review({ cwd = repo, base = '' })
  local p = s.cm.place[f.Twenty.c.id]
  h.eq({ false, 20 }, { p.outdated, p.start_line })
  local panel = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  h.ok(panel:find(' AI review', 1, true) and panel:find('3 to triage · 2 dropped', 1, true), panel)
  require('revuey').close()
end)

h.test('refused: a stale diff hash, broken JSON, a missing file, usage errors; nothing stored', function()
  local before = vim.tbl_count(on_disk())
  local r = run({ 'import-review', file({ summary = 's', verdict = 'approve', diff = 'abc123', findings = { { hunk = 'h1', line = 1, severity = 'nit', title = 'stale', body = 'x' } } }) })
  h.eq(1, r.code)
  h.ok(r.stderr:find('made for another diff', 1, true) and r.stderr:find('revuey hunks', 1, true), r.stderr)
  r = run({ 'import-review', file('not json at all') })
  h.eq(1, r.code)
  h.ok(r.stderr:find('not valid JSON', 1, true), r.stderr)
  r = run({ 'import-review', '/nonexistent/review.json' })
  h.eq(1, r.code)
  h.ok(r.stderr:find('cannot read', 1, true), r.stderr)
  h.eq(2, run({ 'import-review' }).code)
  h.eq(2, run({ 'import-review', 'a', 'b' }).code)
  h.eq(1, run({ 'import-review', '-' }, { stdin = '  ' }).code, 'empty stdin')
  h.eq(before, vim.tbl_count(on_disk()))
end)

h.test('re-import from stdin by the same reviewer replaces its untouched findings; others stay', function()
  local doc = { summary = 'Again.', verdict = 'comment', findings = { { hunk = 'h1', line = 5, severity = 'minor', title = 'Second pass', body = 'x' } } }
  local r = run({ 'import-review', '--name', 'outside', '-' }, { stdin = vim.json.encode(doc) })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('3 untriaged findings of the previous review replaced', 1, true), r.stdout)
  local f = on_disk()
  h.ok(f['Second pass'] and not f.Twenty, vim.inspect(vim.tbl_keys(f)))
  -- another reviewer (REVUEY_AGENT_NAME) adds its own
  r = run({ 'import-review', '-' }, { stdin = vim.json.encode({ summary = '', verdict = 'approve', findings = { { hunk = 'h2', severity = 'nit', title = 'By agent', body = 'x' } } }), env = vim.tbl_extend('force', ENV, { REVUEY_AGENT_NAME = 'claude-code' }) })
  h.eq(0, r.code, r.stderr)
  f = on_disk()
  h.ok(f['Second pass'] and f['By agent'], vim.inspect(vim.tbl_keys(f)))
  h.eq('claude-code', f['By agent'].c.author.name)
end)

h.test('a review running: imported findings appear in it live', function()
  local s = h.open_review({ cwd = repo, base = '' })
  local r = run({ 'import-review', '-' }, { stdin = vim.json.encode({ summary = 'Live one.', verdict = 'approve', findings = { { hunk = 'h1', line = 5, severity = 'critical', title = 'Live finding', body = 'x' } } }) })
  h.eq(0, r.code, r.stderr)
  h.ok(r.stdout:find('session ' .. vim.uv.os_getpid(), 1, true), r.stdout)
  h.ok(vim.wait(5000, function()
    for _, c in pairs(s.cm.store.comments) do
      if not c.deleted and c.ai and c.ai.title == 'Live finding' and s.cm.place[c.id] then
        return true
      end
    end
  end, 20), 'shown live')
  h.ok(vim.wait(5000, function()
    local panel = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
    return panel:find('Live one.', 1, true) ~= nil
  end, 20), 'the panel shows the new record')
  require('revuey').close()
end)

h.test('hunks --prompt in the full-stack scope tags each hunk with its branch (no review running, and a live one)', function()
  local d = h.tmpdir('import-review-stack')
  vim.fn.delete(d, 'rf')
  assert(h.make_fixture('--stack', d).code == 0)
  local function hunks_prompt()
    local r = vim.system({ BIN, 'hunks', '--prompt' }, { cwd = d, env = ENV, text = true }):wait(20000)
    h.eq(0, r.code, r.stderr)
    return r.stdout
  end
  -- the last review of the worktree was the full stack
  local s = h.open_review({ cwd = d, base = '', scope = 'full' })
  h.eq({ kind = 'full' }, s.scope)
  local live = hunks_prompt()
  require('revuey').close()
  local closed = hunks_prompt()
  for _, out in ipairs({ live, closed }) do
    h.ok(out:find('This review covers a whole stack of 3 branches', 1, true), out)
    h.ok(out:find('\n@@ h1 [^\n]* @@ %[stack/'), out)
  end
end)

-- ---------------------------------------------------------------------------
-- Right after a switch: the `switched` line goes out before the review has loaded the new layer
-- ---------------------------------------------------------------------------

-- long enough that a wait never times out in these tests: an output that names the new layer
-- shows that the command waited for the review
local WAIT_ENV = vim.tbl_extend('force', ENV, { REVUEY_CATCH_UP_MS = '120000' })

local function stack_fixture(name)
  local d = h.tmpdir(name)
  vim.fn.delete(d, 'rf')
  assert(h.make_fixture('--stack', d).code == 0)
  return d
end

---Check `to` out the way gS does, without the refresh that follows: the branch, and the
---`switched` event revuey tells the agent with (agent_link.tell_switch).
---`o.told`: the event names that branch instead; `o.at`: its time.
local function switch_untold(d, s, to, o)
  o = o or {}
  h.git(d, 'switch', '-q', to)
  local told = o.told or to
  local ev = comments.switch_event(comments.review_info(s.review), {
    session = s.link.id,
    worktree = d,
    from = s.review.branch,
    to = told,
    layer = told,
  }, o.at)
  assert(comments.append_event(s.cm.events, ev))
end

---Start `bin/revuey <args>` in `d`; returns a table that gets `stderr` as it comes and `done`
---(the result) at the end.
local function start(d, args, o)
  o = o or {}
  local p = { stderr = '', started = vim.uv.now() }
  local cmd = { BIN }
  vim.list_extend(cmd, args)
  vim.system(cmd, {
    cwd = d,
    env = o.env or WAIT_ENV,
    text = true,
    stdin = o.stdin,
    stderr = function(_, data)
      if data then
        p.stderr = p.stderr .. data
      end
    end,
  }, function(r)
    p.ms = vim.uv.now() - p.started
    p.done = r
  end)
  return p
end

local function until_done(p)
  vim.wait(60000, function()
    return p.done ~= nil
  end, 20)
  h.ok(p.done, 'finished; stderr: ' .. p.stderr)
  h.eq(0, p.done.code, p.stderr)
  return p.done.stdout
end

---Wait for the command to say it waits for the review (then it is in the loop).
local function until_waiting(p, to)
  local line = 'waiting for the review to show ' .. to
  vim.wait(60000, function()
    return p.stderr:find(line, 1, true) ~= nil or p.done ~= nil
  end, 20)
  h.ok(p.stderr:find(line, 1, true), 'waits; stderr: ' .. p.stderr .. ' stdout: ' .. (p.done and p.done.stdout or ''))
end

local function follow(to)
  require('revuey.view').refresh({ scope = { kind = 'layer', head = true, branch = to }, force = true })
end

h.test('after a switched event, hunks, comment and import-review wait for the review to show the new layer', function()
  local d = stack_fixture('import-review-switch')
  local s = h.open_review({ cwd = d, base = '' })
  h.eq('stack/cart', s.review.branch)
  -- hunks: stack/ui's own diff, not stack/cart's (nor stack/cart's against stack/ui's files)
  switch_untold(d, s, 'stack/ui')
  local p = start(d, { 'hunks' })
  until_waiting(p, 'stack/ui')
  follow('stack/ui')
  local out = until_done(p)
  h.ok(out:find('# Hunks of stack/ui vs stack/cart (working tree): 3', 1, true), out)
  -- comment: src/math.ts is changed by stack/math only
  switch_untold(d, s, 'stack/math')
  p = start(d, { 'comment', '--path', 'src/math.ts', '--file', 'a note' })
  until_waiting(p, 'stack/math')
  follow('stack/math')
  out = until_done(p)
  h.ok(out:find('commented on src/math.ts (file) in stack/math vs main', 1, true), out)
  -- import-review: into stack/ui's review
  switch_untold(d, s, 'stack/ui')
  local doc = vim.json.encode({
    summary = 's',
    verdict = 'comment',
    findings = { { hunk = 'h2', severity = 'minor', title = 'About Total', body = 'b' } },
  })
  p = start(d, { 'import-review', '--name', 'pass', '-' }, { stdin = doc })
  until_waiting(p, 'stack/ui')
  follow('stack/ui')
  out = until_done(p)
  h.ok(out:find('imported 1 finding %(verdict: [^)]*%) into stack/ui vs stack/cart'), out)
  require('revuey').close()
end)

h.test('no wait: plain and full-stack reviews, and a branch checked out outside revuey', function()
  local function quick(d, want)
    local p = start(d, { 'hunks' })
    local out = until_done(p)
    h.ok(not p.stderr:find('waiting', 1, true), p.stderr)
    h.ok(p.ms < 30000, ('took %d ms'):format(p.ms))
    h.ok(out:find(want, 1, true), out)
  end
  h.open_review({ cwd = repo })
  quick(repo, '# Hunks of feat vs main')
  require('revuey').close()
  local d = stack_fixture('import-review-nowait')
  h.open_review({ cwd = d, base = '', scope = 'full' })
  quick(d, '# Hunks of full stack vs main')
  require('revuey').close()
  -- the user checks a branch out in a terminal: no event, so nothing to wait for; the review
  -- shows its layer until it refreshes
  h.open_review({ cwd = d, base = '' })
  h.git(d, 'switch', '-q', 'stack/ui')
  quick(d, '# Hunks of stack/cart vs stack/math')
  require('revuey').close()
end)

h.test('no wait for a switched event older than the review\'s last change, to another branch, or too old', function()
  local d = stack_fixture('import-review-no-wait-events')
  local s = h.open_review({ cwd = d, base = '' })
  local function quick(env)
    local p = start(d, { 'hunks' }, { env = env })
    local out = until_done(p)
    h.ok(not p.stderr:find('waiting', 1, true), p.stderr)
    -- the review has not refreshed: it still shows its layer
    h.ok(out:find('# Hunks of stack/cart vs stack/math', 1, true), out)
  end
  -- (a) the entry changed after the event: the review already followed it
  h.ok(s.link.changed_at, 'the entry records its last change')
  switch_untold(d, s, 'stack/ui', { at = s.link.changed_at - 1000 })
  quick()
  -- (b) the newest event is to another branch than the one checked out
  switch_untold(d, s, 'stack/ui', { told = 'stack/math' })
  quick()
  -- (c) to this branch, but older than the catch-up time
  switch_untold(d, s, 'stack/ui')
  quick(vim.tbl_extend('force', ENV, { REVUEY_CATCH_UP_MS = '1' }))
  require('revuey').close()
end)

h.test('the wait ends when the review closes, or when its entry changes in any way', function()
  local d = stack_fixture('import-review-wait-ends')
  local s = h.open_review({ cwd = d, base = '' })
  switch_untold(d, s, 'stack/ui')
  local p = start(d, { 'hunks' })
  until_waiting(p, 'stack/ui')
  require('revuey').close()
  -- no review running: what revuey opens here, the layer checked out
  local out = until_done(p)
  h.ok(p.stderr:find('the review closed', 1, true), p.stderr)
  h.ok(out:find('# Hunks of stack/ui vs stack/cart', 1, true), out)
  -- a refresh that lands on no branch (checked_out = nil) ends it too
  s = h.open_review({ cwd = d, base = '' })
  h.eq('stack/ui', s.review.branch)
  switch_untold(d, s, 'stack/math')
  p = start(d, { 'hunks' })
  until_waiting(p, 'stack/math')
  h.git(d, 'switch', '-q', '--detach', 'stack/math')
  require('revuey.view').refresh({ force = true })
  until_done(p)
  h.ok(not p.stderr:find('still shows', 1, true), 'ended by the change, not the timeout: ' .. p.stderr)
  require('revuey').close()
end)

h.test('a PR lookup landing during the wait does not end it; stack waits too', function()
  local link = require('revuey.agent_link')
  local fv = require('revuey.forge_view')
  local d = stack_fixture('import-review-wait-pr')
  local s = h.open_review({ cwd = d, base = '' })
  switch_untold(d, s, 'stack/ui')
  local changed = s.link.changed_at
  local p = start(d, { 'hunks' })
  local q = start(d, { 'stack', '--json' })
  until_waiting(p, 'stack/ui')
  until_waiting(q, 'stack/ui')
  -- the PR of a layer arrives (forge lookups answer whenever they do): the entry is rewritten
  -- with it, but that is not the review following the switch
  local real = fv.pr
  fv.pr = function(_, name)
    if name == 'stack/math' then
      return { number = 12, title = 'Add math', url = 'https://github.com/o/r/pull/12', state = 'OPEN' }
    end
  end
  link.update(s)
  link.update(s, true)
  local e = require('revuey.sessions').list({ vim.fn.fnamemodify(s.link.path, ':h:h') })[1]
  h.eq(12, e and e.stack and e.stack.layers[1].pr and e.stack.layers[1].pr.number, vim.inspect(e))
  h.eq(changed, s.link.changed_at, 'a PR is not a change of the review')
  vim.wait(1500, function()
    return p.done ~= nil or q.done ~= nil
  end, 50)
  h.eq(nil, p.done, 'hunks still waits')
  h.eq(nil, q.done, 'stack still waits')
  follow('stack/ui')
  local out = until_done(p)
  h.ok(out:find('# Hunks of stack/ui vs stack/cart', 1, true), out)
  local st = vim.json.decode(until_done(q))
  h.eq(3, st.viewed)
  h.eq('stack/ui', st.checked_out)
  h.eq(nil, st.review_checked_out)
  h.eq(12, st.layers[1].pr.number)
  fv.pr = real
  require('revuey').close()
end)

h.test('stack: a parent amended without restacking: the base the review diffs from, and the note', function()
  local d = stack_fixture('import-review-stack-diverged')
  h.git(d, 'switch', '-q', 'stack/math')
  vim.fn.writefile({ 'amended' }, d .. '/amended.txt')
  h.git(d, 'add', 'amended.txt')
  h.git(d, 'commit', '-q', '--amend', '--no-edit')
  h.git(d, 'switch', '-q', 'stack/cart')
  local s = h.open_review({ cwd = d, base = '' })
  h.eq('stack/cart', s.review.branch)
  local r = vim.system({ BIN, 'stack', '--json' }, { cwd = d, env = ENV, text = true }):wait(20000)
  h.eq(0, r.code, r.stderr)
  local st = vim.json.decode(r.stdout)
  local math_tip = vim.trim(vim.fn.system({ 'git', '-C', d, 'rev-parse', 'stack/math' }))
  h.ok(st.layers[2].parent_rev ~= math_tip, 'diffed from the parent\'s old tip')
  h.eq(s.review.merge_base, st.layers[2].base)
  -- the review's files of stack/cart: amended.txt (only in the new stack/math) is not one
  h.eq(2, st.layers[2].stats.files)
  local kinds = vim.tbl_map(function(n)
    return n.kind
  end, st.notes)
  h.ok(vim.tbl_contains(kinds, 'not_restacked'), vim.inspect(st.notes))
  r = vim.system({ BIN, 'stack' }, { cwd = d, env = ENV, text = true }):wait(20000)
  h.ok(r.stdout:find('git diff ' .. s.review.merge_base:sub(1, 10) .. '..', 1, true), r.stdout)
  h.ok(r.stdout:find('\nnote: ', 1, true), r.stdout)
  require('revuey').close()
end)

h.test('hunks --stat and --path: the file list, and some files\' hunks with the whole review\'s ids and hash', function()
  local d = stack_fixture('import-review-stat')
  require('revuey').close()
  local function run_in(args)
    local r = vim.system(vim.list_extend({ BIN }, args), { cwd = d, env = ENV, text = true }):wait(20000)
    return r
  end
  local full = run_in({ 'hunks' })
  h.eq(0, full.code, full.stderr)
  local diff = full.stdout:match('Diff: (%x+)')
  local st = run_in({ 'hunks', '--stat' })
  h.eq(0, st.code, st.stderr)
  h.ok(st.stdout:find('# Files of stack/cart vs stack/math (working tree): 2, hunks: 2\nDiff: ' .. diff .. '\n\n', 1, true), st.stdout)
  h.ok(st.stdout:find('\nsrc/cart.ts [added] (+20 -0): h1\nsrc/index.ts (+3 -2): h2\n', 1, true), st.stdout)
  h.ok(not st.stdout:find('@@', 1, true), 'no diff: ' .. st.stdout)
  local sj = vim.json.decode(run_in({ 'hunks', '--stat', '--json' }).stdout)
  h.eq(diff, sj.diff)
  h.eq({ 'src/index.ts', 3, 2, { 'h2' } }, { sj.files[2].path, sj.files[2].added, sj.files[2].removed, sj.files[2].hunks })
  local one = run_in({ 'hunks', '--path', 'src/index.ts' })
  h.eq(0, one.code, one.stderr)
  h.ok(one.stdout:find('# Hunks of stack/cart vs stack/math (working tree): 1 of 2\nDiff: ' .. diff, 1, true), one.stdout)
  h.ok(one.stdout:find('\n@@ h2 src/index.ts @@\n', 1, true), one.stdout)
  h.ok(not one.stdout:find('@@ h1', 1, true), one.stdout)
  h.ok(one.stdout:find('Only the hunks of the files asked for', 1, true), one.stdout)
  local two = run_in({ 'hunks', '--path', 'src/index.ts', '--path=./src/cart.ts', '--json' })
  h.eq(0, two.code, two.stderr)
  h.eq({ 'h1', 'h2' }, vim.tbl_map(function(x)
    return x.id
  end, vim.json.decode(two.stdout).hunks))
  local bad = run_in({ 'hunks', '--path', 'src/math.ts' })
  h.eq(1, bad.code)
  h.ok(bad.stderr:find('src/math.ts is not a changed file in this review', 1, true), bad.stderr)
  local both = run_in({ 'hunks', '--prompt', '--stat' })
  h.eq(2, both.code)
end)

h.test('hunks follow the review\'s file order: folders (the default), or git\'s with panel_folders = false', function()
  local d = h.repo('import-review-order', {}, { ['a-b/x.txt'] = 'x\n', ['a/b/y.txt'] = 'y\n', ['a/z.txt'] = 'z\n' })
  local function order()
    local r = vim.system({ BIN, 'hunks', '--json' }, { cwd = d, env = ENV, text = true }):wait(20000)
    h.eq(0, r.code, r.stderr)
    return vim.tbl_map(function(hk)
      return hk.path
    end, vim.json.decode(r.stdout).hunks)
  end
  local folders, flat = { 'a/z.txt', 'a/b/y.txt', 'a-b/x.txt' }, { 'a-b/x.txt', 'a/b/y.txt', 'a/z.txt' }
  -- live: the review's own load record; closed: the worktree's last-review record
  require('revuey').setup({ state_dir = state_dir, lsp_warmup = false, panel_folders = false })
  local s = h.open_review({ cwd = d, base = '' })
  h.eq(flat, vim.tbl_map(function(f)
    return f.path
  end, s.review.files))
  h.eq(flat, order())
  require('revuey').close()
  h.eq(flat, order())
  require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
  h.open_review({ cwd = d, base = '' })
  h.eq(folders, order())
  require('revuey').close()
  h.eq(folders, order())
end)

h.run()
