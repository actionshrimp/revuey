local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local state = require('revuey.state')

local dir = h.tmpdir('state')

h.test('toggle persists and reloads', function()
  local st = state.load(dir, '/repo', 'feat', 'main')
  local f = { status = 'M', old_blob = 'aaa', new_blob = 'bbb' }
  local key = state.content_key(f)
  h.eq(false, state.is_reviewed(st, 'src/a.ts', key))
  h.eq(true, state.toggle(st, 'src/a.ts', key))
  local st2 = state.load(dir, '/repo', 'feat', 'main')
  h.eq(true, state.is_reviewed(st2, 'src/a.ts', key))
  h.eq(false, state.toggle(st2, 'src/a.ts', key))
  h.eq(false, state.is_reviewed(state.load(dir, '/repo', 'feat', 'main'), 'src/a.ts', key))
end)

h.test('mark invalidates when file content changes', function()
  local st = state.load(dir, '/repo', 'feat2', 'main')
  local v1 = state.content_key({ status = 'M', old_blob = 'aaa', new_blob = 'bbb' })
  local v2 = state.content_key({ status = 'M', old_blob = 'aaa', new_blob = 'ccc' })
  state.toggle(st, 'x.ts', v1)
  local st2 = state.load(dir, '/repo', 'feat2', 'main')
  h.eq(true, state.is_reviewed(st2, 'x.ts', v1))
  h.eq(false, state.is_reviewed(st2, 'x.ts', v2))
  -- toggling the changed version marks it reviewed again
  h.eq(true, state.toggle(st2, 'x.ts', v2))
end)

h.test('keys are separated by repo, branch and base', function()
  local a = state.file_for(dir, '/repo', 'feat', 'main')
  h.ok(a ~= state.file_for(dir, '/repo', 'feat', 'develop'))
  h.ok(a ~= state.file_for(dir, '/repo', 'other', 'main'))
  h.ok(a ~= state.file_for(dir, '/repo2', 'feat', 'main'))
  local st = state.load(dir, '/repo', 'feat', 'develop')
  h.eq(vim.empty_dict(), st.files)
  h.ok(vim.startswith(vim.fs.basename(a), 'repo-feat-main-'))
end)

h.test('deleted files use old blob; corrupt file is ignored', function()
  h.eq('deleted:aaa', state.content_key({ status = 'D', old_blob = 'aaa' }))
  local st = state.load(dir, '/repo', 'corrupt', 'main')
  local fd = assert(io.open(st._path, 'w'))
  fd:write('{not json')
  fd:close()
  h.eq({}, state.load(dir, '/repo', 'corrupt', 'main').files)
end)

-- Regression (finding 8): an undecodable state file is backed up, not silently overwritten.
h.test('corrupt state file is backed up before being replaced', function()
  local d = h.tmpdir('state-corrupt')
  local st = state.load(d, '/repo', 'b', 'main')
  local fd = assert(io.open(st._path, 'w'))
  fd:write('{oops')
  fd:close()
  local st2 = state.load(d, '/repo', 'b', 'main')
  state.toggle(st2, 'a.ts', 'k')
  local backups = vim.fn.glob(st._path .. '.corrupt-*', false, true)
  h.eq(1, #backups)
  local bfd = assert(io.open(backups[1], 'r'))
  h.eq('{oops', bfd:read('*a'))
  bfd:close()
end)

-- Regression (finding 8): two instances of the same review merge their changes on save.
h.test('concurrent instances merge on save', function()
  local d = h.tmpdir('state-concurrent')
  local seed = state.load(d, '/repo', 'b', 'main')
  state.toggle(seed, 'gone.ts', 'k0')
  local a = state.load(d, '/repo', 'b', 'main')
  local b = state.load(d, '/repo', 'b', 'main')
  state.toggle(a, 'a.ts', 'k1')
  state.toggle(a, 'gone.ts', 'k0') -- unmark in instance a
  state.toggle(b, 'b.ts', 'k2')
  local c = state.load(d, '/repo', 'b', 'main')
  h.eq(true, state.is_reviewed(c, 'a.ts', 'k1'))
  h.eq(true, state.is_reviewed(c, 'b.ts', 'k2'))
  h.eq(false, state.is_reviewed(c, 'gone.ts', 'k0'), 'b must not resurrect a mark that a removed')
  -- b's in-memory view is refreshed with a's change after its save
  h.eq(true, state.is_reviewed(b, 'a.ts', 'k1'))
end)

h.test('base names are normalised across remotes', function()
  h.eq('main', state.normalize_base('origin/main', { 'origin', 'upstream' }))
  h.eq('dev', state.normalize_base('refs/remotes/upstream/dev', { 'origin', 'upstream' }))
  h.eq('main', state.normalize_base('refs/heads/main', {}))
  h.eq('feature/x', state.normalize_base('feature/x', { 'origin' }))
  h.eq(state.file_for(dir, '/r', 'b', 'main'), state.file_for(dir, '/r', 'b', state.normalize_base('origin/main', { 'origin' })))
end)

-- Regression (review 2, low 4): two corruptions within one second keep both backups.
h.test('corrupt backups made in the same second do not overwrite each other', function()
  local d = h.tmpdir('state-corrupt2')
  local path = state.file_for(d, '/repo', 'b', 'main')
  for i = 1, 2 do
    local fd = assert(io.open(path, 'w'))
    fd:write('{bad' .. i)
    fd:close()
    state.load(d, '/repo', 'b', 'main')
  end
  h.eq(2, #vim.fn.glob(path .. '.corrupt-*', false, true))
end)

-- Regression (review 2, low 3): a failed write leaves existing state intact and keeps pending changes.
h.test('failed save keeps good state and pending changes', function()
  local d = h.tmpdir('state-ro')
  local st = state.load(d, '/repo', 'b', 'main')
  state.toggle(st, 'a.ts', 'k1')
  local before = table.concat(vim.fn.readfile(st._path), '\n')
  vim.uv.fs_chmod(d, tonumber('555', 8))
  state.set_reviewed(st, 'b.ts', 'k2', true)
  local ok = pcall(state.save, st)
  vim.uv.fs_chmod(d, tonumber('755', 8))
  h.eq(false, ok)
  h.eq(before, table.concat(vim.fn.readfile(st._path), '\n'))
  h.ok(st._changes['b.ts'], 'pending change kept for retry')
  state.save(st)
  h.eq(true, state.is_reviewed(state.load(d, '/repo', 'b', 'main'), 'b.ts', 'k2'))
end)

-- Regression (review 2, merge): a stale instance's unmark of an old version must not delete
-- another instance's mark of a newer version.
h.test('stale unmark does not delete a newer mark', function()
  local d = h.tmpdir('state-stale')
  local a = state.load(d, '/repo', 'b', 'main')
  state.toggle(a, 'x.ts', 'v1') -- a marks v1
  local b = state.load(d, '/repo', 'b', 'main')
  state.set_reviewed(b, 'x.ts', 'v2', true) -- file changed; b marks v2
  state.save(b)
  state.toggle(a, 'x.ts', 'v1') -- stale a unmarks v1
  local c = state.load(d, '/repo', 'b', 'main')
  h.eq(true, state.is_reviewed(c, 'x.ts', 'v2'))
end)

-- Regression (comments review): read, merge and rename were not locked, so of several processes
-- saving at once only the last rename survived.
h.test('saves from many processes at once keep every mark (lock around read-merge-rename)', function()
  local d = h.tmpdir('state-parallel')
  local script = d .. '/mark.lua'
  vim.fn.writefile({
    ('vim.opt.rtp:prepend(%q)'):format(h.root),
    'local state = require("revuey.state")',
    'local i = _G.arg[1]',
    ('local st = state.load(%q, "/repo", "b", "main")'):format(d),
    'state.set_unit(st, "k" .. i, "p" .. i, true)',
    'state.save(st)',
  }, script)
  local procs = {}
  for i = 1, 12 do
    procs[i] = vim.system({ vim.v.progpath, '--clean', '--headless', '-l', script, tostring(i) })
  end
  for i = 1, 12 do
    h.eq(0, procs[i]:wait(30000).code)
  end
  local st = state.load(d, '/repo', 'b', 'main')
  for i = 1, 12 do
    h.ok(state.unit_marked(st, 'k' .. i), 'mark ' .. i .. ' lost')
  end
end)

h.test('default_dir honours $REVUEY_STATE_DIR (as the CLI does)', function()
  local saved = vim.env.REVUEY_STATE_DIR
  vim.env.REVUEY_STATE_DIR = '/tmp/revuey-elsewhere'
  h.eq('/tmp/revuey-elsewhere', state.default_dir())
  vim.env.REVUEY_STATE_DIR = ''
  h.eq(vim.fs.joinpath(vim.fn.stdpath('data'), 'revuey'), state.default_dir())
  vim.env.REVUEY_STATE_DIR = saved
end)

h.run()
