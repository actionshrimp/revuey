-- Checking out a stack layer in the current worktree (`gS`, `:RevueySwitch`, `]s`/`[s` with
-- stack.switch_on_navigate): the decision logic and messages (unit), then real git repositories
-- (the --stack and --remote-stack fixtures) opened headlessly.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')

local state_dir = h.tmpdir('switch-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local view = require('revuey.view')
local switch = require('revuey.switch')
local git = require('revuey.git')
-- switch notices stay out of the test output (tests that check them capture them)
vim.notify = function() end

-- ---------------------------------------------------------------------------
-- Unit: decisions
-- ---------------------------------------------------------------------------

h.test('plan: a local layer is switched to; already on it is a no-op; detached at it attaches', function()
  local p = switch.plan({ layer = { name = 'stack/math' }, current = 'stack/cart', locals = { ['stack/math'] = '' } })
  h.eq({ kind = 'switch', branch = 'stack/math', args = { 'switch', 'stack/math' } }, p)
  p = switch.plan({ layer = { name = 'stack/cart', is_head = true }, current = 'stack/cart', locals = {} })
  h.eq({ kind = 'noop', branch = 'stack/cart' }, p)
  h.eq('revuey: already on stack/cart', switch.msg.noop(p))
  p = switch.plan({ layer = { name = 'stack/ui', is_head = true, detached = true }, current = nil, locals = {} })
  h.eq({ kind = 'switch', branch = 'stack/ui', attach = true, args = { 'switch', 'stack/ui' } }, p)
end)

h.test('plan: a remote layer with a local branch tracking it switches to that branch (same name first)', function()
  local locals = { ['stack/cart'] = 'origin/stack/cart', ['aaa-copy'] = 'origin/stack/cart', other = 'origin/other' }
  local p = switch.plan({ layer = { name = 'origin/stack/cart', remote = true }, short = 'stack/cart', current = nil, locals = locals })
  h.eq({ kind = 'switch', branch = 'stack/cart', ref = 'origin/stack/cart', args = { 'switch', 'stack/cart' } }, p)
  -- only another name tracks it
  locals['stack/cart'] = nil
  p = switch.plan({ layer = { name = 'origin/stack/cart', remote = true }, short = 'stack/cart', locals = locals })
  h.eq('aaa-copy', p.branch)
  -- already on a branch tracking it
  p = switch.plan({ layer = { name = 'origin/stack/cart', remote = true }, short = 'stack/cart', current = 'aaa-copy', locals = locals })
  h.eq({ kind = 'noop', branch = 'aaa-copy', ref = 'origin/stack/cart' }, p)
  h.eq('revuey: already on aaa-copy (tracks origin/stack/cart)', switch.msg.noop(p))
end)

h.test('plan: a remote layer whose name is taken by an unrelated local branch is a conflict', function()
  local p = switch.plan({
    layer = { name = 'origin/stack/cart', remote = true }, short = 'stack/cart', current = 'main',
    locals = { main = 'origin/main', ['stack/cart'] = 'origin/old' },
  })
  h.eq({ kind = 'conflict', branch = 'stack/cart', ref = 'origin/stack/cart', upstream = 'origin/old' }, p)
  local prompt, items = switch.msg.conflict(p)
  h.eq('A local branch stack/cart already exists and tracks origin/old, not origin/stack/cart. revuey will not change it.', prompt)
  h.eq({ 'Switch to the local stack/cart anyway', 'Cancel' }, items)
  p.upstream = ''
  prompt = switch.msg.conflict(p)
  h.eq('A local branch stack/cart already exists and tracks no remote branch, not origin/stack/cart. revuey will not change it.', prompt)
  h.eq({ kind = 'switch', branch = 'stack/cart', args = { 'switch', 'stack/cart' } }, switch.anyway(p, 'main'))
  h.eq('noop', switch.anyway(p, 'stack/cart').kind)
end)

h.test('plan: a remote layer with no local branch is created with --track (detached or not)', function()
  for _, current in ipairs({ 'main', false }) do
    local p = switch.plan({
      layer = { name = 'upstream/feat/x', remote = true }, short = 'feat/x', current = current or nil,
      locals = { main = 'origin/main' },
    })
    h.eq({ kind = 'track', branch = 'feat/x', ref = 'upstream/feat/x', args = { 'switch', '--track', 'upstream/feat/x' } }, p)
    h.eq('revuey: created feat/x tracking upstream/feat/x, and switched to it', switch.msg.done(p))
  end
end)

h.test('status parsing: tracked changes (staged, unstaged, renames) and untracked files; ignored left out', function()
  local out = table.concat({ ' M src/a.ts', 'A  src/new.ts', 'R  src/to.ts', 'src/from.ts', '?? notes.txt', '!! dist/x.js', 'D  gone.ts', '' }, '\0')
  h.eq({ tracked = { 'src/a.ts', 'src/new.ts', 'src/to.ts', 'gone.ts' }, untracked = { 'notes.txt' } }, switch.parse_status(out))
  h.eq({ tracked = {}, untracked = {} }, switch.parse_status(''))
end)

h.test('worktree list parsing: branch -> path; detached and bare worktrees have none', function()
  local out = table.concat({
    'worktree /repo', 'HEAD 1111', 'branch refs/heads/stack/cart', '',
    'worktree /repo-wt', 'HEAD 2222', 'branch refs/heads/stack/ui', '',
    'worktree /repo-detached', 'HEAD 3333', 'detached', '',
  }, '\n')
  h.eq({ ['stack/cart'] = '/repo', ['stack/ui'] = '/repo-wt' }, switch.parse_worktrees(out))
end)

h.test('messages: dirty, untracked, another worktree, agent, navigate', function()
  h.eq('revuey: not switching to stack/math: uncommitted changes in a.ts, b.ts, c.ts and 2 more. Commit or stash them first (revuey never stashes).',
    switch.msg.dirty('stack/math', { 'a.ts', 'b.ts', 'c.ts', 'd.ts', 'e.ts' }))
  h.eq('revuey: not switching to stack/ui: it has files at the paths of untracked or ignored src/x.ts. Move or remove them first.',
    switch.msg.untracked('stack/ui', { 'src/x.ts' }))
  h.eq('revuey: not switching: stack/ui is checked out in another worktree, at /tmp/wt', switch.msg.elsewhere('stack/ui', '/tmp/wt'))
  local prompt, items = switch.msg.agent('stack/math')
  h.eq('An agent is connected to this review. Switching the worktree to stack/math changes the files it may be working on.', prompt)
  h.eq({ 'Switch to stack/math', 'Cancel' }, items)
  h.eq('revuey: showing stack/ui, branch not switched: not switching to stack/ui: uncommitted changes in a.ts. Commit or stash them first (revuey never stashes).',
    switch.msg.navigate('stack/ui', switch.msg.dirty('stack/ui', { 'a.ts' })))
  h.eq('revuey: switched to stack/cart (tracks origin/stack/cart); stack/cart is not at origin/stack/cart\'s commit',
    switch.msg.done({ kind = 'switch', branch = 'stack/cart', ref = 'origin/stack/cart' }, "stack/cart is not at origin/stack/cart's commit"))
end)

h.test('collisions: anything on disk where the switch adds a file, or a file in place of its directory', function()
  local disk = { ['new.ts'] = 'file', ['dir'] = 'directory', ['blocker'] = 'file', ['kept'] = 'directory' }
  local function kind(p)
    return disk[p]
  end
  local changes = {
    { 'A', 'new.ts' }, -- untracked or ignored file at an added path
    { 'A', 'dir' }, -- an untracked directory where a file goes
    { 'A', 'blocker/x.ts' }, -- a file where the target has a directory
    { 'A', 'kept' }, { 'D', 'kept/old.ts' }, -- a tracked directory replaced by a file: git's job
    { 'A', 'fine/y.ts' }, { 'M', 'other.ts' },
  }
  h.eq({ 'blocker', 'dir', 'new.ts' }, switch.collisions(changes, kind))
  h.eq({}, switch.collisions({ { 'A', 'a/b/c.ts' } }, function() end))
end)

h.test('parent setting: only above a remote layer whose parent was inferred, never the bottom, never itself', function()
  local layers = {
    { name = 'origin/stack/math', remote = true, source = 'inferred', parent = 'origin/main' },
    { name = 'origin/stack/cart', remote = true, source = 'inferred', parent = 'origin/stack/math' },
    { name = 'stack/ui', source = 'inferred', parent = 'origin/stack/cart' },
  }
  h.eq('origin/stack/math', switch.parent_setting(layers, 2, { kind = 'track', branch = 'stack/cart', ref = 'origin/stack/cart' }))
  h.eq(nil, switch.parent_setting(layers, 1, { kind = 'track', branch = 'stack/math', ref = 'origin/stack/math' }), 'bottom: trunk')
  h.eq('origin/stack/cart', switch.parent_setting(layers, 3, { kind = 'switch', branch = 'stack/ui' }))
  -- the switch-anyway to an unrelated local branch of that name
  h.eq(nil, switch.parent_setting(layers, 2, { kind = 'switch', branch = 'stack/cart' }))
  -- already said by a revuey or Graphite setting
  layers[3].source = 'graphite'
  h.eq(nil, switch.parent_setting(layers, 3, { kind = 'switch', branch = 'stack/ui' }))
  -- a local layer below: inferred anyway
  local own = { { name = 'feat-a', source = 'config', parent = 'origin/x' }, { name = 'feat-b', source = 'inferred', parent = 'feat-a' } }
  h.eq(nil, switch.parent_setting(own, 2, { kind = 'switch', branch = 'feat-b' }))
  -- never itself
  h.eq(nil, switch.parent_setting({ { name = 'x', remote = true }, { name = 'y', remote = true, source = 'inferred', parent = 'x' } }, 2,
    { kind = 'track', branch = 'x', ref = 'y' }))
end)

h.test('messages: unsaved buffers, busy, hook', function()
  h.eq('revuey: not switching to stack/math: unsaved changes in buffers for src/a.ts. Write or discard them first.', switch.msg.unsaved('stack/math', { 'src/a.ts' }))
  h.eq('revuey: a switch is already running; this one is dropped', switch.msg.busy())
  h.eq('revuey: switched to stack/math, but git reported an error (a hook?): hookfail', switch.msg.hook('stack/math', 'hookfail'))
end)

-- ---------------------------------------------------------------------------
-- Integration: real git
-- ---------------------------------------------------------------------------
-- Every test builds its own fixture, so they run in any order.

local fixture_n = 0
local function fixture(kind, name)
  fixture_n = fixture_n + 1
  local d = h.tmpdir(name .. '-' .. fixture_n)
  vim.fn.delete(d, 'rf')
  local res = vim.system({ h.root .. '/scripts/make-fixture.sh', kind, d }, { text = true }):wait()
  assert(res.code == 0, res.stderr)
  return kind == '--remote-stack' and d .. '/review' or d
end

local function open(dir)
  if view.session then
    view.close()
  end
  return h.open_review({ cwd = dir, base = '' })
end

local function names(s)
  return vim.tbl_map(function(l)
    return l.name
  end, s.review.stack and s.review.stack.layers or {})
end

local function head_layer(s)
  for _, l in ipairs(s.review.stack and s.review.stack.layers or {}) do
    if l.is_head then
      return l.name
    end
  end
end

local function branch(dir)
  return git.current_branch(dir)
end

local function config(dir, key)
  return vim.trim(vim.system({ 'git', 'config', key }, { cwd = dir, text = true }):wait().stdout or '')
end

---Wait until the review shows `name` as its checked-out layer and is idle.
local function wait_head(s, name)
  h.ok(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope and head_layer(s) == name
  end, 10), 'HEAD layer did not become ' .. name .. ' (is ' .. tostring((head_layer(s))) .. ')')
end

local function idle(s)
  h.ok(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
  end, 10), 'refresh did not finish')
end

local function scope(s, index)
  view.set_scope({ kind = 'layer', index = index })
  idle(s)
end

local function refresh(s)
  view.refresh({ force = true })
  idle(s)
end

local function panel_text(s)
  return table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
end

---Run fn with vim.ui.select answering `choice` (an index, or nil to cancel); returns the prompts.
local function with_select(choice, fn)
  local prompts = {}
  local orig = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    prompts[#prompts + 1] = { prompt = opts.prompt, items = items }
    cb(choice and items[choice] or nil, choice)
  end
  local ok, err = pcall(fn)
  vim.ui.select = orig
  assert(ok, err)
  return prompts
end

---Call view.switch_layer and wait for it to finish (on_done), returning its result and the
---messages shown. With `head`, also wait for the review to show that layer checked out.
local function do_switch(index, o, head)
  local done
  local msgs, restore = h.capture_notify()
  view.switch_layer(index, vim.tbl_extend('force', o or {}, {
    on_done = function(ok, msg)
      done = { ok = ok, msg = msg }
    end,
  }))
  local finished = vim.wait(10000, function()
    return done ~= nil
  end, 10)
  restore()
  h.ok(finished, 'switch did not finish')
  if head and done.ok then
    wait_head(view.session, head)
  end
  return done, msgs
end

local function file_named(s, path)
  for i, f in ipairs(s.review.files) do
    if f.path == path then
      return f, i
    end
  end
end

local function row_of_layer(s, index)
  for r, i in pairs(s.panel_layers) do
    if i == index then
      return r
    end
  end
end

-- local stacks (stack/math <- stack/cart (checked out) <- stack/ui)

h.test('gS on a lower local layer switches the worktree to it: @ moves, working tree, scope and cursor kept', function()
  local dir = fixture('--stack', 'local')
  local s = open(dir)
  h.eq({ 'stack/math', 'stack/cart', 'stack/ui' }, names(s))
  h.eq('stack/cart', head_layer(s))
  scope(s, 1)
  h.eq(true, s.review.mode_locked)
  vim.api.nvim_win_set_cursor(s.diff_win, { 4, 0 })
  -- gS in the panel on the stack/math row
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_win_set_cursor(s.panel_win, { row_of_layer(s, 1), 0 })
  local msgs, restore = h.capture_notify()
  vim.api.nvim_feedkeys('gS', 'mtx', false)
  wait_head(s, 'stack/math')
  restore()
  h.eq('stack/math', branch(dir))
  h.eq('revuey: switched to stack/math', msgs[1] and msgs[1].msg, vim.inspect(msgs))
  h.eq({ kind = 'layer', index = 1 }, s.scope)
  h.eq('worktree', s.review.mode)
  h.eq(false, s.review.mode_locked)
  h.eq(4, vim.api.nvim_win_get_cursor(s.diff_win)[1], 'cursor kept')
  local text = panel_text(s)
  h.ok(text:find('▶@ stack/math', 1, true), text)
  h.ok(text:find('   stack/cart', 1, true), text)
  h.ok(text:find('gS check out layer', 1, true), text)
  h.eq('', config(dir, 'branch.stack/math.revueyParent'), 'no parent setting between local layers')
  -- uncommitted work now belongs to stack/math
  h.write(dir, 'src/math.ts', '// edited\n')
  refresh(s)
  h.ok(file_named(s, 'src/math.ts').uncommitted, 'math.ts has the uncommitted marker')
  -- already on it: a no-op with a message
  local done, m2 = do_switch(1)
  h.eq(false, done.ok)
  h.eq('revuey: already on stack/math', m2[1].msg)
  view.close()
end)

h.test('the panel hint under a layer row says what gS does, only while the panel has focus', function()
  local s = open(fixture('--stack', 'hint'))
  local ns = vim.api.nvim_get_namespaces()['revuey.panel.hint']
  vim.api.nvim_set_current_win(s.panel_win)
  local function hint_at(i)
    vim.api.nvim_win_set_cursor(s.panel_win, { row_of_layer(s, i), 0 })
    require('revuey.panel').update_hint(s)
    local marks = vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, 0, -1, { details = true })
    return marks[1] and marks[1][4].virt_lines[1][1][1] or nil
  end
  h.eq('     gS check out stack/math here', hint_at(1))
  h.eq(nil, hint_at(2), 'nothing on the checked-out layer')
  vim.api.nvim_set_current_win(s.diff_win)
  require('revuey.panel').update_hint(s)
  h.eq({}, vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, 0, -1, {}))
  view.close()
end)

h.test('a dirty worktree is refused (files named); a plain untracked file is carried over', function()
  local dir = fixture('--stack', 'dirty')
  local s = open(dir)
  h.write(dir, 'src/math.ts', 'dirty\n')
  local done, msgs = do_switch(1)
  h.eq(false, done.ok)
  h.eq(vim.log.levels.ERROR, msgs[1].level)
  h.eq('revuey: not switching to stack/math: uncommitted changes in src/math.ts. Commit or stash them first (revuey never stashes).', msgs[1].msg)
  h.eq('stack/cart', branch(dir))
  h.git(dir, 'checkout', '-q', '--', 'src/math.ts')
  -- staged only counts too
  h.write(dir, 'src/new.ts', 'x\n')
  h.git(dir, 'add', 'src/new.ts')
  done = do_switch(1)
  h.eq(false, done.ok)
  h.ok(done.msg:find('uncommitted changes in src/new.ts', 1, true), done.msg)
  h.git(dir, 'rm', '-q', '--cached', 'src/new.ts')
  -- untracked and not in the target: allowed, and kept
  done = do_switch(1, nil, 'stack/math')
  h.eq(true, done.ok, done.msg)
  h.eq('stack/math', branch(dir))
  h.ok(vim.uv.fs_stat(dir .. '/src/new.ts'), 'untracked file kept')
  view.close()
end)

h.test('untracked or ignored files where the switch writes are refused by name; a file in place of a directory too', function()
  local dir = fixture('--stack', 'collide')
  local s = open(dir)
  -- stack/ui adds src/components/Total.tsx
  h.write(dir, 'src/components/Total.tsx', 'mine\n')
  local done = do_switch(3)
  h.eq(false, done.ok)
  h.eq('revuey: not switching to stack/ui: it has files at the paths of untracked or ignored src/components/Total.tsx. Move or remove them first.', done.msg)
  -- ignored: git would overwrite it silently
  h.write(dir, '.git/info/exclude', 'src/components/Total.tsx\n')
  done = do_switch(3)
  h.eq(false, done.ok)
  h.ok(done.msg:find('untracked or ignored src/components/Total.tsx', 1, true), done.msg)
  h.eq('mine', vim.fn.readfile(dir .. '/src/components/Total.tsx')[1])
  h.write(dir, '.git/info/exclude', '\n')
  -- a file where the target has a directory
  vim.fn.delete(dir .. '/src/components', 'rf')
  h.write(dir, 'src/components', 'a file\n')
  done = do_switch(3)
  h.eq(false, done.ok)
  h.ok(done.msg:find('untracked or ignored src/components.', 1, true), done.msg)
  vim.fn.delete(dir .. '/src/components')
  h.eq('stack/cart', branch(dir))
  h.eq(true, do_switch(3, nil, 'stack/ui').ok)
  h.eq('stack/ui', head_layer(s))
  view.close()
end)

h.test('unsaved buffers of files in the worktree are refused by name', function()
  local dir = fixture('--stack', 'unsaved')
  local s = open(dir)
  vim.cmd('tabnew ' .. vim.fn.fnameescape(dir .. '/src/cart.ts'))
  local b = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(b, 0, 0, false, { '// my unsaved edit' })
  vim.cmd('tabprevious')
  local done = do_switch(1)
  h.eq(false, done.ok)
  h.eq('revuey: not switching to stack/math: unsaved changes in buffers for src/cart.ts. Write or discard them first.', done.msg)
  h.eq('stack/cart', branch(dir))
  vim.api.nvim_buf_delete(b, { force = true })
  h.eq(true, do_switch(1, nil, 'stack/math').ok)
  h.eq('stack/math', head_layer(s))
  view.close()
end)

h.test('a branch checked out in another worktree: refused with that worktree\'s path', function()
  local dir = fixture('--stack', 'elsewhere')
  open(dir)
  local wt = h.tmpdir('switch-wt') .. '/ui'
  h.git(dir, 'worktree', 'add', '-q', wt, 'stack/ui')
  local done = do_switch(3)
  h.eq(false, done.ok)
  h.ok(done.msg:find('stack/ui is checked out in another worktree, at ', 1, true) and done.msg:find('switch-wt/ui', 1, true), done.msg)
  h.eq('stack/cart', branch(dir))
  view.close()
end)

h.test('a failing post-checkout hook: HEAD moved, so the switch completes with a warning', function()
  local dir = fixture('--stack', 'hook')
  local s = open(dir)
  h.write(dir, '.git/hooks/post-checkout', '#!/bin/sh\necho hookfail >&2\nexit 1\n')
  vim.uv.fs_chmod(dir .. '/.git/hooks/post-checkout', 493)
  local done, msgs = do_switch(1, nil, 'stack/math')
  h.eq(true, done.ok, done.msg)
  h.eq('stack/math', branch(dir))
  h.eq(vim.log.levels.WARN, msgs[1].level)
  h.ok(msgs[1].msg:find('switched to stack/math, but git reported an error', 1, true) and msgs[1].msg:find('hookfail', 1, true), msgs[1].msg)
  h.eq('stack/math', head_layer(s))
  view.close()
end)

h.test('submodules: a pointer left behind by a switch never blocks the next one', function()
  local root = h.tmpdir('switch-sub')
  local lib, dir = root .. '/lib', root .. '/repo'
  vim.fn.mkdir(lib, 'p')
  vim.fn.mkdir(dir, 'p')
  h.git(lib, 'init', '-q', '-b', 'main')
  h.write(lib, 'l.txt', '1\n')
  h.git(lib, 'add', '.')
  h.git(lib, 'commit', '-qm', 'l1')
  h.write(lib, 'l.txt', '2\n')
  h.git(lib, 'commit', '-qam', 'l2')
  h.git(dir, 'init', '-q', '-b', 'main')
  h.write(dir, 'a.txt', 'a\n')
  h.git(dir, 'add', '.')
  h.git(dir, 'commit', '-qm', 'init')
  h.git(dir, 'switch', '-q', '-c', 's1')
  h.write(dir, 'x.txt', 'x\n')
  h.git(dir, 'add', '.')
  h.git(dir, 'commit', '-qm', 's1')
  h.git(dir, 'switch', '-q', '-c', 's2')
  h.git(dir, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', lib, 'sub')
  h.git(dir .. '/sub', 'checkout', '-q', 'HEAD~1')
  h.git(dir, 'add', '.')
  h.git(dir, 'commit', '-qm', 's2 adds sub@l1')
  h.git(dir, 'switch', '-q', '-c', 's3')
  h.git(dir .. '/sub', 'checkout', '-q', 'main')
  h.git(dir, 'add', 'sub')
  h.git(dir, 'commit', '-qm', 's3 bumps sub')
  local s = open(dir)
  h.eq({ 's1', 's2', 's3' }, names(s))
  h.eq(true, do_switch(2, nil, 's2').ok)
  h.ok(vim.system({ 'git', 'status', '--porcelain' }, { cwd = dir, text = true }):wait().stdout:find('M sub', 1, true),
    'the submodule pointer differs after the switch (git leaves submodule checkouts alone)')
  local done = do_switch(1, nil, 's1')
  h.eq(true, done.ok, done.msg)
  done = do_switch(3, nil, 's3')
  h.eq(true, done.ok, done.msg)
  h.eq('s3', branch(dir))
  view.close()
end)

h.test('an agent connected to the review: asks first; cancel keeps the branch; the answer is re-checked', function()
  local dir = fixture('--stack', 'agent')
  local s = open(dir)
  local sessions = require('revuey.sessions')
  sessions.write_watcher(s.link.bases, { pid = vim.fn.getpid(), session = s.link.id, worktree = s.review.root,
    started_at = sessions.now_ms(), heartbeat_at = sessions.now_ms() })
  local done
  local prompts = with_select(2, function()
    done = do_switch(1)
  end)
  h.eq(1, #prompts)
  h.eq('An agent is connected to this review. Switching the worktree to stack/math changes the files it may be working on.', prompts[1].prompt)
  h.eq(false, done.ok)
  h.eq('stack/cart', branch(dir))
  -- the worktree changed while the question was open: refused after the yes
  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb)
    h.write(dir, 'src/math.ts', 'edited meanwhile\n')
    cb(items[1], 1)
  end
  done = do_switch(1)
  vim.ui.select = orig
  h.eq(false, done.ok)
  h.ok(done.msg:find('uncommitted changes in src/math.ts', 1, true), done.msg)
  h.git(dir, 'checkout', '-q', '--', 'src/math.ts')
  prompts = with_select(1, function()
    done = do_switch(1, nil, 'stack/math')
  end)
  h.eq(1, #prompts)
  h.eq(true, done.ok)
  h.eq('stack/math', branch(dir))
  view.close()
end)

h.test('the session registry follows the checked-out branch; bin/revuey sessions shows it', function()
  local dir = fixture('--stack', 'registry')
  local s = open(dir)
  local function entry()
    local e = vim.json.decode(table.concat(vim.fn.readfile(s.link.path), '\n'))
    return e.checked_out, e.branch
  end
  h.eq({ 'stack/cart', 'stack/cart' }, { entry() })
  scope(s, 1)
  h.eq({ 'stack/cart', 'stack/math' }, { entry() }, 'viewing another layer: checked_out stays')
  local cli = vim.system({ h.root .. '/bin/revuey', 'sessions' }, {
    cwd = dir, text = true, env = { REVUEY_STATE_DIR = state_dir, REVUEY_NVIM = vim.v.progpath },
  }):wait()
  h.ok(cli.stdout:find('stack/math (stack layer, checked out: stack/cart)', 1, true), cli.stdout .. cli.stderr)
  h.eq(true, do_switch(1, nil, 'stack/math').ok)
  h.eq({ 'stack/math', 'stack/math' }, { entry() })
  view.close()
end)

h.test('hidden LSP buffers reload with the new files (or go); the user\'s buffers follow checktime', function()
  local dir = fixture('--stack', 'lsp')
  local s = open(dir)
  local lsp = require('revuey.lsp')
  -- on stack/cart: index.ts differs on stack/math
  local index = dir .. '/src/index.ts'
  local hidden = lsp.file_buffer(index)
  local before = vim.api.nvim_buf_get_lines(hidden, 0, -1, false)
  vim.uv.sleep(1100) -- distinct mtimes
  h.eq(true, do_switch(1, nil, 'stack/math').ok)
  local after = vim.api.nvim_buf_get_lines(hidden, 0, -1, false)
  h.eq(vim.fn.readfile(index), after, 'hidden buffer reloaded')
  h.ok(not vim.deep_equal(before, after), 'index.ts differs between the layers')
  h.eq(true, do_switch(3, nil, 'stack/ui').ok)
  -- a hidden buffer of a file the next branch does not have is dropped
  local total = dir .. '/src/components/Total.tsx'
  local hidden_total = lsp.file_buffer(total)
  h.ok(hidden_total and vim.api.nvim_buf_is_loaded(hidden_total))
  h.eq(true, do_switch(2, nil, 'stack/cart').ok)
  h.eq(nil, vim.uv.fs_stat(total))
  h.eq(false, vim.api.nvim_buf_is_valid(hidden_total))
  -- the user's own clean buffer: autoread reloads it
  vim.o.autoread = true
  local cart = dir .. '/src/cart.ts'
  vim.cmd('tabnew ' .. vim.fn.fnameescape(cart))
  local user = vim.api.nvim_get_current_buf()
  local before_user = vim.api.nvim_buf_get_lines(user, 0, -1, false)
  vim.cmd('tabprevious')
  vim.uv.sleep(1100)
  h.eq(true, do_switch(3, nil, 'stack/ui').ok)
  local after_user = vim.api.nvim_buf_get_lines(user, 0, -1, false)
  h.eq(vim.fn.readfile(cart), after_user, 'clean user buffer reloaded (autoread)')
  h.ok(not vim.deep_equal(before_user, after_user), 'cart.ts differs between the layers')
  vim.api.nvim_buf_delete(user, { force = true })
  h.eq('stack/ui', head_layer(s))
  view.close()
end)

h.test(':RevueySwitch [layer] switches by name; no argument: the viewed layer; unknown names are refused', function()
  local dir = fixture('--stack', 'command')
  local s = open(dir)
  local msgs, restore = h.capture_notify()
  vim.cmd('RevueySwitch stack/math')
  wait_head(s, 'stack/math')
  h.eq('stack/math', branch(dir))
  scope(s, 3)
  vim.cmd('RevueySwitch')
  wait_head(s, 'stack/ui')
  h.eq('stack/ui', branch(dir))
  h.eq({ kind = 'layer', index = 3 }, s.scope)
  vim.cmd('RevueySwitch nope')
  restore()
  h.eq('revuey: no layer nope in this stack', msgs[#msgs].msg)
  h.eq({ 'stack/math', 'stack/cart', 'stack/ui' }, vim.fn.getcompletion('RevueySwitch ', 'cmdline'))
  view.set_scope({ kind = 'full' })
  idle(s)
  msgs, restore = h.capture_notify()
  vim.cmd('RevueySwitch')
  restore()
  h.ok(msgs[1].msg:find('full stack is not a branch', 1, true), msgs[1].msg)
  view.close()
end)

---Press keys in the diff window with all notices captured; wait until `cond` (or the review is idle).
local function nav(s, k, cond)
  local msgs, restore = h.capture_notify()
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
  if cond then
    h.ok(vim.wait(10000, function()
      return cond(msgs)
    end, 10), 'condition not reached after ' .. k)
  end
  idle(s)
  restore()
  return msgs
end

h.test(']s / [s stay view-only by default; with switch_on_navigate they switch, and a refusal leaves the view moved', function()
  local dir = fixture('--stack', 'navigate')
  local s = open(dir)
  nav(s, ']s')
  h.eq(3, s.scope.index)
  h.eq('stack/cart', branch(dir), 'view only')
  require('revuey.config').options.stack.switch_on_navigate = true
  local ok, err = pcall(function()
    nav(s, '2[s', function()
      return head_layer(s) == 'stack/math'
    end)
    h.eq('stack/math', branch(dir))
    h.eq({ kind = 'layer', index = 1 }, s.scope)
    -- dirty: the view moves, the branch does not
    h.write(dir, 'src/math.ts', 'dirty\n')
    local msgs = nav(s, ']s', function(m)
      return #m > 0
    end)
    h.eq(2, s.scope.index)
    h.eq('stack/math', branch(dir))
    h.eq('revuey: showing stack/cart, branch not switched: not switching to stack/cart: uncommitted changes in src/math.ts. Commit or stash them first (revuey never stashes).', msgs[1].msg)
  end)
  require('revuey.config').options.stack.switch_on_navigate = false
  assert(ok, err)
  view.close()
end)

h.test('switch_on_navigate with an agent connected: asks once per review, not on every ]s', function()
  local dir = fixture('--stack', 'navigate-agent')
  local s = open(dir)
  local sessions = require('revuey.sessions')
  sessions.write_watcher(s.link.bases, { pid = vim.fn.getpid(), session = s.link.id, worktree = s.review.root,
    started_at = sessions.now_ms(), heartbeat_at = sessions.now_ms() })
  require('revuey.config').options.stack.switch_on_navigate = true
  local prompts
  local ok, err = pcall(function()
    prompts = with_select(1, function()
      nav(s, '[s', function()
        return head_layer(s) == 'stack/math'
      end)
      nav(s, ']s', function()
        return head_layer(s) == 'stack/cart'
      end)
      nav(s, ']s', function()
        return head_layer(s) == 'stack/ui'
      end)
    end)
  end)
  require('revuey.config').options.stack.switch_on_navigate = false
  assert(ok, err)
  h.eq(1, #prompts, 'one question for three switches')
  h.eq('stack/ui', branch(dir))
  -- gS still asks
  prompts = with_select(2, function()
    h.eq(false, do_switch(1).ok)
  end)
  h.eq(1, #prompts)
  view.close()
end)

h.test('one switch at a time: a second request while one runs is dropped with a message', function()
  local dir = fixture('--stack', 'busy')
  local s = open(dir)
  local results = {}
  local msgs, restore = h.capture_notify()
  view.switch_layer(1, { on_done = function(ok, m)
    results[#results + 1] = { ok = ok, msg = m }
  end })
  view.switch_layer(3, { on_done = function(ok, m)
    results[#results + 1] = { ok = ok, msg = m }
  end })
  h.ok(vim.wait(10000, function()
    return #results == 2
  end, 10))
  wait_head(s, 'stack/math')
  restore()
  h.eq({ ok = false, msg = 'revuey: a switch is already running; this one is dropped' }, results[1])
  h.eq(true, results[2].ok)
  h.eq('stack/math', branch(dir))
  h.ok(#msgs >= 2)
  -- and the guard is released: the next one runs
  h.eq(true, do_switch(3, nil, 'stack/ui').ok)
  view.close()
end)

-- someone else's stack: remote-tracking layers, HEAD detached at the top

h.test('gS on a remote-only layer creates a tracking branch; marks and comments carry over; the layer below stays', function()
  local dir = fixture('--remote-stack', 'remote')
  local s = open(dir)
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(s))
  scope(s, 2)
  h.eq('gS creates local branch stack/cart', require('revuey.panel').switch_hint(s.review.stack.layers[2]))
  local _, fi = file_named(s, 'src/cart.ts')
  view.toggle_reviewed(fi)
  local comments = require('revuey.comments')
  local store = comments.load(comments.path_for(s.review.state._path))
  local c = comments.new(comments.file_anchor('src/cart.ts'), 'remote layer comment')
  comments.put(store, c)
  comments.save(store)
  local state_path = s.review.state._path
  local done = do_switch(nil, nil, 'stack/cart')
  h.eq(true, done.ok, done.msg)
  h.eq('revuey: created stack/cart tracking origin/stack/cart, and switched to it', done.msg)
  h.eq('stack/cart', branch(dir))
  h.eq('origin/stack/cart', vim.trim(h.git(dir, 'rev-parse', '--abbrev-ref', 'stack/cart@{upstream}')))
  -- the layer below is kept by an explicit parent; layers above need a detached review
  h.eq('origin/stack/math', config(dir, 'branch.stack/cart.revueyParent'))
  h.eq({ 'origin/stack/math', 'stack/cart' }, names(s))
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  h.eq('worktree', s.review.mode)
  h.eq(state_path, s.review.state._path, 'same state file')
  h.eq(true, require('revuey.review').is_reviewed(s.review, (file_named(s, 'src/cart.ts'))))
  h.eq('remote layer comment', comments.load(comments.path_for(s.review.state._path)).comments[c.id].body)
  local text = panel_text(s)
  h.ok(text:find('▶@ stack/cart', 1, true) and text:find('origin/stack/math', 1, true), text)
  -- reopening on the branch keeps it
  s = open(dir)
  h.eq({ 'origin/stack/math', 'stack/cart' }, names(s))
  h.eq('stack/cart', head_layer(s))
  view.close()
end)

h.test('after gS and commits, stray remote refs on the line are never layers', function()
  local dir = fixture('--remote-stack', 'stray')
  local s = open(dir)
  h.eq(true, do_switch(2, nil, 'stack/cart').ok)
  h.write(dir, 'src/cart.ts', 'one\n')
  h.git(dir, 'commit', '-qam', 'c1')
  h.write(dir, 'src/cart.ts', 'two\n')
  h.git(dir, 'commit', '-qam', 'c2')
  refresh(s)
  -- the explicit parent keeps the layer below after commits
  h.eq({ 'origin/stack/math', 'stack/cart' }, names(s))
  -- a backup of the user's own commit
  h.git(dir, 'update-ref', 'refs/remotes/origin/wip-backup', 'HEAD~1')
  refresh(s)
  h.eq({ 'origin/stack/math', 'stack/cart' }, names(s), 'origin/wip-backup')
  h.git(dir, 'update-ref', '-d', 'refs/remotes/origin/wip-backup')
  -- pushed under another name, then committed again
  h.git(dir, 'push', '-q', 'origin', 'HEAD:refs/heads/dave/cart-fix')
  h.git(dir, 'fetch', '-q', 'origin')
  h.write(dir, 'src/cart.ts', 'three\n')
  h.git(dir, 'commit', '-qam', 'c3')
  refresh(s)
  h.eq({ 'origin/stack/math', 'stack/cart' }, names(s), 'origin/dave/cart-fix')
  -- a colleague's branch started from the user's work
  h.git(dir, 'remote', 'add', 'colleague', vim.fs.dirname(dir) .. '/upstream.git')
  h.git(dir, 'push', '-q', 'colleague', 'HEAD~2:refs/heads/start')
  h.git(dir, 'fetch', '-q', 'colleague')
  refresh(s)
  h.eq({ 'origin/stack/math', 'stack/cart' }, names(s), 'colleague/start')
  view.close()
end)

h.test('no self-parent: switching around your own stack never writes a setting naming the branch itself', function()
  local root = h.tmpdir('switch-own')
  local up, dir = root .. '/up.git', root .. '/me'
  vim.fn.mkdir(dir, 'p')
  h.git(root, 'init', '-q', '--bare', up)
  h.git(dir, 'init', '-q', '-b', 'main')
  h.write(dir, 'a.txt', 'a\n')
  h.git(dir, 'add', '.')
  h.git(dir, 'commit', '-qm', 'init')
  h.git(dir, 'remote', 'add', 'origin', up)
  h.git(dir, 'push', '-q', 'origin', 'main')
  h.git(dir, 'fetch', '-q', 'origin')
  h.git(dir, 'remote', 'set-head', 'origin', 'main')
  h.git(dir, 'switch', '-q', '-c', 'colleague')
  h.write(dir, 'c.txt', 'c\n')
  h.git(dir, 'add', '.')
  h.git(dir, 'commit', '-qm', 'colleague')
  h.git(dir, 'push', '-q', 'origin', 'colleague')
  h.git(dir, 'fetch', '-q')
  h.git(dir, 'switch', '-q', 'main')
  h.git(dir, 'branch', '-qD', 'colleague')
  h.git(dir, 'switch', '-q', '--no-track', '-c', 'feat-a', 'origin/colleague')
  h.write(dir, 'fa.txt', '1\n')
  h.git(dir, 'add', '.')
  h.git(dir, 'commit', '-qm', 'fa1')
  h.git(dir, 'config', 'branch.feat-a.revueyParent', 'origin/colleague')
  h.git(dir, 'switch', '-q', '-c', 'feat-b')
  h.write(dir, 'fb.txt', '1\n')
  h.git(dir, 'add', '.')
  h.git(dir, 'commit', '-qm', 'fb1')
  h.write(dir, 'fb.txt', '2\n')
  h.git(dir, 'commit', '-qam', 'fb2')
  local s = open(dir)
  h.eq({ 'origin/colleague', 'feat-a', 'feat-b' }, names(s))
  h.eq(true, do_switch(2, nil, 'feat-a').ok)
  h.eq('origin/colleague', config(dir, 'branch.feat-a.revueyParent'), 'the existing setting is kept')
  h.eq(true, do_switch(3, nil, 'feat-b').ok)
  h.eq('', config(dir, 'branch.feat-b.revueyParent'))
  h.git(dir, 'update-ref', 'refs/remotes/origin/wip-backup', 'feat-b~1')
  refresh(s)
  h.eq({ 'origin/colleague', 'feat-a', 'feat-b' }, names(s))
  view.close()
end)

h.test('the parent setting goes with the branch: deleted and recreated under the same name, nothing is left', function()
  local dir = fixture('--remote-stack', 'reuse')
  local s = open(dir)
  h.eq(true, do_switch(2, nil, 'stack/cart').ok)
  h.eq('origin/stack/math', config(dir, 'branch.stack/cart.revueyParent'))
  view.close()
  h.git(dir, 'switch', '-q', '--detach', 'origin/stack/ui')
  h.git(dir, 'branch', '-q', '-D', 'stack/cart')
  h.eq('', config(dir, 'branch.stack/cart.revueyParent'))
  -- a new, unrelated stack/cart
  h.git(dir, 'switch', '-q', '-c', 'stack/cart', 'origin/main')
  h.write(dir, 'z.txt', 'z\n')
  h.git(dir, 'add', '.')
  h.git(dir, 'commit', '-qm', 'z')
  s = open(dir)
  h.eq(nil, s.review.stack, 'no stack: nothing names origin/stack/math')
  view.close()
end)

h.test('a parent the user set is never overwritten; a different suggestion is only a note', function()
  local dir = fixture('--remote-stack', 'user-parent')
  -- a local stack/cart with a commit of its own (off the line), and the user's own parent setting
  h.git(dir, 'switch', '-q', '--track', 'origin/stack/cart')
  h.write(dir, 'mine.txt', 'mine\n')
  h.git(dir, 'add', '.')
  h.git(dir, 'commit', '-qm', 'mine')
  h.git(dir, 'switch', '-q', '--detach', 'origin/stack/ui')
  h.git(dir, 'config', 'branch.stack/cart.revueyParent', 'main')
  local s = open(dir)
  -- detached: the remote layer (whose parent counts as inferred) is shown, not the local branch
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(s))
  local done, msgs = do_switch(2)
  h.eq(true, done.ok, done.msg)
  idle(s)
  h.eq('stack/cart', branch(dir))
  h.eq('main', config(dir, 'branch.stack/cart.revueyParent'), 'kept')
  h.eq(nil, s.review.stack, 'the user\'s parent (trunk) applies: no stack')
  local note
  for _, m in ipairs(msgs) do
    if m.msg:find('stack parent', 1, true) then
      note = m.msg
    end
  end
  h.eq('revuey: kept your stack parent of stack/cart (main); this stack has origin/stack/math below it', note)
  -- the same setting again: nothing to say
  h.git(dir, 'config', 'branch.stack/cart.revueyParent', 'origin/stack/math')
  h.git(dir, 'switch', '-q', '--detach', 'origin/stack/ui')
  s = open(dir)
  done, msgs = do_switch(2, nil, 'stack/cart')
  h.eq(true, done.ok, done.msg)
  h.eq('origin/stack/math', config(dir, 'branch.stack/cart.revueyParent'))
  for _, m in ipairs(msgs) do
    h.ok(not m.msg:find('parent', 1, true), m.msg)
  end
  view.close()
end)

h.test('the parent is only recorded when it is an ancestor of the branch (a local copy behind a restack is left alone)', function()
  local dir = fixture('--remote-stack', 'not-ancestor')
  -- a local stack/cart tracking origin/stack/cart, but not built on origin/stack/math
  h.git(dir, 'branch', '-q', '--no-track', 'stack/cart', 'origin/main')
  h.git(dir, 'branch', '-q', '--set-upstream-to=origin/stack/cart', 'stack/cart')
  local s = open(dir)
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(s))
  h.eq('stack/cart', s.review.stack.layers[2].local_copy)
  local done = do_switch(2)
  h.eq(true, done.ok, done.msg)
  h.eq('stack/cart', branch(dir))
  h.eq('', config(dir, 'branch.stack/cart.revueyParent'))
  view.close()
end)

h.test('a parent setting naming a remote branch that is gone: a note says so, with how to clear it', function()
  local dir = fixture('--remote-stack', 'parent-gone')
  local s = open(dir)
  h.eq(true, do_switch(2, nil, 'stack/cart').ok)
  h.eq('origin/stack/math', config(dir, 'branch.stack/cart.revueyParent'))
  h.git(dir, 'update-ref', '-d', 'refs/remotes/origin/stack/math')
  refresh(s)
  h.eq(nil, s.review.stack)
  local found
  for _, n in ipairs(s.review.notes or {}) do
    if n.kind == 'unknown_parent' and n.branch == 'stack/cart' and n.parent == 'origin/stack/math' then
      found = n
    end
  end
  h.ok(found, vim.inspect(s.review.notes))
  h.ok(found.text:find(':RevueyStackParent --clear', 1, true), found.text)
  local text = panel_text(s)
  h.ok(text:find('stack/cart: parent origin/stack/math', 1, true), text)
  view.close()
end)

h.test('a remote layer whose local name is taken by an unrelated branch: asks; cancel, or switch to it untouched', function()
  local dir = fixture('--remote-stack', 'conflict')
  h.git(dir, 'branch', '-q', '--no-track', 'stack/cart', 'origin/main')
  local tip = vim.trim(h.git(dir, 'rev-parse', 'stack/cart'))
  local s = open(dir)
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(s))
  h.eq('gS: a local stack/cart exists; asks first', require('revuey.panel').switch_hint(s.review.stack.layers[2]))
  local done
  local prompts = with_select(2, function()
    done = do_switch(2)
  end)
  h.eq('A local branch stack/cart already exists and tracks no remote branch, not origin/stack/cart. revuey will not change it.', prompts[1].prompt)
  h.eq(false, done.ok)
  h.eq(nil, branch(dir), 'still detached')
  with_select(1, function()
    done = do_switch(2)
  end)
  h.eq(true, done.ok, done.msg)
  h.eq('stack/cart', branch(dir))
  h.eq(tip, vim.trim(h.git(dir, 'rev-parse', 'stack/cart')), 'the local branch is not moved')
  h.eq('', config(dir, 'branch.stack/cart.merge'))
  h.eq('', config(dir, 'branch.stack/cart.revueyParent'), 'no parent setting for an unrelated branch')
  view.close()
end)

h.test('a remote layer with a local branch tracking it (off the line) switches to that branch', function()
  local dir = fixture('--remote-stack', 'tracking')
  -- a local copy of stack/cart that moved on: not on the line, so origin/stack/cart is the layer
  h.git(dir, 'branch', '-q', '--track', 'mycart', 'origin/stack/cart')
  h.git(dir, 'switch', '-q', 'mycart')
  h.write(dir, 'extra.txt', 'x\n')
  h.git(dir, 'add', 'extra.txt')
  h.git(dir, 'commit', '-q', '-m', 'extra')
  h.git(dir, 'switch', '-q', '--detach', 'origin/stack/ui')
  local s = open(dir)
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(s))
  h.eq('mycart', s.review.stack.layers[2].local_copy)
  h.eq('gS switch to mycart (tracks it)', require('revuey.panel').switch_hint(s.review.stack.layers[2]))
  local done = do_switch(2)
  h.eq(true, done.ok, done.msg)
  h.eq("revuey: switched to mycart (tracks origin/stack/cart); mycart is not at origin/stack/cart's commit", done.msg)
  h.eq('mycart', branch(dir))
  h.eq('origin/stack/math', config(dir, 'branch.mycart.revueyParent'))
  view.close()
end)

h.run()
