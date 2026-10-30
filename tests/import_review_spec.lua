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
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }):wait().code == 0)
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
