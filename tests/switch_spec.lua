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
  h.eq('revuey: not switching to stack/ui: it has files at the paths of untracked src/x.ts. Move or remove them first.',
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

-- ---------------------------------------------------------------------------
-- Integration: real git
-- ---------------------------------------------------------------------------

local function fixture(kind, name)
  local d = h.tmpdir(name)
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
  end, s.review.stack.layers)
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

---Wait until the review shows `name` as its checked-out layer and is idle.
local function wait_head(s, name)
  h.ok(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope and head_layer(s) == name
  end, 10), 'HEAD layer did not become ' .. name .. ' (is ' .. tostring(head_layer(s)) .. ')')
end

local function idle(s)
  h.ok(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
  end, 10), 'refresh did not finish')
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

---Call view.switch_layer and wait for it to finish (on_done), returning the messages shown.
local function do_switch(index, o)
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
  return done, msgs
end

local stack_dir = fixture('--stack', 'switch-local')

h.test('gS on a lower local layer switches the worktree to it: @ moves, working tree, scope and cursor kept', function()
  local s = open(stack_dir)
  h.eq({ 'stack/math', 'stack/cart', 'stack/ui' }, names(s))
  h.eq('stack/cart', head_layer(s))
  view.set_scope({ kind = 'layer', index = 1 })
  idle(s)
  h.eq(true, s.review.mode_locked)
  -- cursor somewhere in the layer
  vim.api.nvim_win_set_cursor(s.diff_win, { 4, 0 })
  -- gS in the panel on the stack/math row
  vim.api.nvim_set_current_win(s.panel_win)
  local row
  for r, i in pairs(s.panel_layers) do
    if i == 1 then
      row = r
    end
  end
  vim.api.nvim_win_set_cursor(s.panel_win, { row, 0 })
  local msgs, restore = h.capture_notify()
  vim.api.nvim_feedkeys('gS', 'mtx', false)
  wait_head(s, 'stack/math')
  restore()
  h.eq('stack/math', branch(stack_dir))
  h.ok(msgs[1] and msgs[1].msg == 'revuey: switched to stack/math', vim.inspect(msgs))
  h.eq({ kind = 'layer', index = 1 }, s.scope)
  h.eq('worktree', s.review.mode)
  h.eq(false, s.review.mode_locked)
  h.eq(4, vim.api.nvim_win_get_cursor(s.diff_win)[1], 'cursor kept')
  local text = panel_text(s)
  h.ok(text:find('▶@ stack/math', 1, true), text)
  h.ok(text:find('   stack/cart', 1, true), text)
  h.ok(text:find('gS check out layer', 1, true), text)
  -- uncommitted work now belongs to stack/math
  h.write(stack_dir, 'src/math.ts', vim.fn.readfile(stack_dir .. '/src/math.ts')[1] .. '\n// edited\n')
  view.refresh({ force = true })
  idle(s)
  local f
  for _, x in ipairs(s.review.files) do
    if x.path == 'src/math.ts' then
      f = x
    end
  end
  h.ok(f and f.uncommitted, 'math.ts has the uncommitted marker')
  h.git(stack_dir, 'checkout', '-q', '--', 'src/math.ts')
end)

h.test('already on it: a no-op with a message', function()
  local s = view.session
  local done, msgs = do_switch(1)
  h.eq(false, done.ok)
  h.eq('revuey: already on stack/math', msgs[1].msg)
  h.eq('stack/math', branch(stack_dir))
  h.eq('stack/math', head_layer(s))
end)

h.test('the panel hint under a layer row says what gS does, only while the panel has focus', function()
  local s = view.session
  vim.api.nvim_set_current_win(s.panel_win)
  local function hint_at(i)
    for r, idx in pairs(s.panel_layers) do
      if idx == i then
        vim.api.nvim_win_set_cursor(s.panel_win, { r, 0 })
      end
    end
    require('revuey.panel').update_hint(s)
    local ns = vim.api.nvim_get_namespaces()['revuey.panel.hint']
    local marks = vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, 0, -1, { details = true })
    return marks[1] and marks[1][4].virt_lines[1][1][1] or nil
  end
  h.eq('     gS check out stack/cart here', hint_at(2))
  h.eq(nil, hint_at(1), 'nothing on the checked-out layer')
  vim.api.nvim_set_current_win(s.diff_win)
  require('revuey.panel').update_hint(s)
  local ns = vim.api.nvim_get_namespaces()['revuey.panel.hint']
  h.eq({}, vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, 0, -1, {}))
end)

h.test('a dirty worktree is refused (files named); a plain untracked file is carried over', function()
  local s = view.session
  h.write(stack_dir, 'src/math.ts', 'dirty\n')
  local done, msgs = do_switch(2)
  h.eq(false, done.ok)
  h.eq(vim.log.levels.ERROR, msgs[1].level)
  h.eq('revuey: not switching to stack/cart: uncommitted changes in src/math.ts. Commit or stash them first (revuey never stashes).', msgs[1].msg)
  h.eq('stack/math', branch(stack_dir))
  h.git(stack_dir, 'checkout', '-q', '--', 'src/math.ts')
  -- staged only counts too
  h.write(stack_dir, 'src/new.ts', 'x\n')
  h.git(stack_dir, 'add', 'src/new.ts')
  done = do_switch(2)
  h.eq(false, done.ok)
  h.ok(done.msg:find('uncommitted changes in src/new.ts', 1, true), done.msg)
  h.git(stack_dir, 'rm', '-q', '--cached', 'src/new.ts')
  -- untracked and not in the target: allowed, and kept
  done = do_switch(2)
  h.eq(true, done.ok, done.msg)
  wait_head(s, 'stack/cart')
  h.eq('stack/cart', branch(stack_dir))
  h.ok(vim.uv.fs_stat(stack_dir .. '/src/new.ts'), 'untracked file kept')
end)

h.test('untracked files at paths the target has are refused, by name', function()
  local s = view.session
  -- stack/ui adds src/components/Total.tsx
  h.write(stack_dir, 'src/components/Total.tsx', 'mine\n')
  local done = do_switch(3)
  h.eq(false, done.ok)
  h.eq('revuey: not switching to stack/ui: it has files at the paths of untracked src/components/Total.tsx. Move or remove them first.', done.msg)
  h.eq('stack/cart', branch(stack_dir))
  vim.fn.delete(stack_dir .. '/src/components/Total.tsx')
  vim.fn.delete(stack_dir .. '/src/new.ts')
  h.eq('stack/cart', head_layer(s))
end)

h.test('a branch checked out in another worktree: refused with that worktree\'s path', function()
  local wt = h.tmpdir('switch-wt') .. '/ui'
  h.git(stack_dir, 'worktree', 'add', '-q', wt, 'stack/ui')
  local done = do_switch(3)
  h.eq(false, done.ok)
  h.ok(done.msg:find('stack/ui is checked out in another worktree, at ', 1, true) and done.msg:find('switch-wt/ui', 1, true), done.msg)
  h.eq('stack/cart', branch(stack_dir))
  h.git(stack_dir, 'worktree', 'remove', '--force', wt)
end)

h.test('an agent connected to the review: asks first; cancel keeps the branch', function()
  local s = view.session
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
  h.eq('stack/cart', branch(stack_dir))
  prompts = with_select(1, function()
    done = do_switch(1)
  end)
  h.eq(1, #prompts)
  h.eq(true, done.ok)
  wait_head(s, 'stack/math')
  h.eq('stack/math', branch(stack_dir))
  for _, p in ipairs(vim.fn.glob(s.link.bases[1] .. '/watchers/*.json', false, true)) do
    vim.fn.delete(p)
  end
  require('revuey.agent_link').poll(s)
end)

h.test('the session registry follows the checked-out branch', function()
  local s = view.session
  local function entry()
    local e = vim.json.decode(table.concat(vim.fn.readfile(s.link.path), '\n'))
    return e.checked_out, e.branch
  end
  h.eq({ 'stack/math', 'stack/math' }, { entry() })
  view.set_scope({ kind = 'layer', index = 2 })
  idle(s)
  h.eq({ 'stack/math', 'stack/cart' }, { entry() }, 'viewing another layer: checked_out stays')
  local done = do_switch(2)
  h.eq(true, done.ok)
  wait_head(s, 'stack/cart')
  h.eq({ 'stack/cart', 'stack/cart' }, { entry() })
end)

h.test('hidden LSP buffers reload with the new files; the user\'s buffers follow checktime', function()
  local s = view.session
  local lsp = require('revuey.lsp')
  -- on stack/cart: index.ts differs on stack/math
  local index = stack_dir .. '/src/index.ts'
  local hidden = lsp.file_buffer(index)
  local before = vim.api.nvim_buf_get_lines(hidden, 0, -1, false)
  vim.uv.sleep(1100) -- distinct mtimes
  local done = do_switch(1)
  h.eq(true, done.ok, done.msg)
  wait_head(s, 'stack/math')
  local after = vim.api.nvim_buf_get_lines(hidden, 0, -1, false)
  h.eq(vim.fn.readfile(index), after, 'hidden buffer reloaded')
  h.ok(not vim.deep_equal(before, after), 'index.ts differs between the layers')
  h.eq(true, do_switch(2).ok)
  wait_head(s, 'stack/cart')
  -- the user's own buffers: one clean (autoread reloads it), one modified (left alone)
  vim.o.autoread = true
  local cart = stack_dir .. '/src/cart.ts'
  vim.cmd('tabnew ' .. vim.fn.fnameescape(cart))
  local user = vim.api.nvim_get_current_buf()
  local before_user = vim.api.nvim_buf_get_lines(user, 0, -1, false)
  vim.cmd('badd ' .. vim.fn.fnameescape(stack_dir .. '/src/math.ts'))
  local modified = vim.fn.bufnr(stack_dir .. '/src/math.ts')
  vim.fn.bufload(modified)
  vim.api.nvim_buf_set_lines(modified, 0, -1, false, { 'my edit' })
  vim.cmd('tabprevious')
  vim.uv.sleep(1100)
  -- math.ts is modified in a buffer but not on disk: the worktree is clean, so the switch runs
  done = do_switch(3)
  h.eq(true, done.ok, done.msg)
  wait_head(s, 'stack/ui')
  local after_user = vim.api.nvim_buf_get_lines(user, 0, -1, false)
  h.eq(vim.fn.readfile(cart), after_user, 'clean user buffer reloaded (autoread)')
  h.ok(not vim.deep_equal(before_user, after_user), 'cart.ts differs between the layers')
  h.eq({ 'my edit' }, vim.api.nvim_buf_get_lines(modified, 0, -1, false), 'modified buffer untouched')
  vim.api.nvim_buf_delete(user, { force = true })
  vim.api.nvim_buf_delete(modified, { force = true })
end)

h.test('a hidden buffer of a file the new branch does not have is dropped', function()
  local s = view.session
  local lsp = require('revuey.lsp')
  local total = stack_dir .. '/src/components/Total.tsx'
  local hidden = lsp.file_buffer(total)
  h.ok(hidden and vim.api.nvim_buf_is_loaded(hidden))
  h.eq(true, do_switch(1).ok)
  wait_head(s, 'stack/math')
  h.eq(nil, vim.uv.fs_stat(total))
  h.eq(false, vim.api.nvim_buf_is_valid(hidden))
end)

h.test(':RevueySwitch [layer] switches by name; no argument: the viewed layer; unknown names are refused', function()
  local s = view.session
  vim.cmd('RevueySwitch stack/cart')
  wait_head(s, 'stack/cart')
  h.eq('stack/cart', branch(stack_dir))
  view.set_scope({ kind = 'layer', index = 3 })
  idle(s)
  vim.cmd('RevueySwitch')
  wait_head(s, 'stack/ui')
  h.eq('stack/ui', branch(stack_dir))
  h.eq({ kind = 'layer', index = 3 }, s.scope)
  local msgs, restore = h.capture_notify()
  vim.cmd('RevueySwitch nope')
  restore()
  h.eq('revuey: no layer nope in this stack', msgs[1].msg)
  h.eq({ 'stack/math', 'stack/cart', 'stack/ui' }, vim.fn.getcompletion('RevueySwitch ', 'cmdline'))
  view.set_scope({ kind = 'full' })
  idle(s)
  msgs, restore = h.capture_notify()
  vim.cmd('RevueySwitch')
  restore()
  h.ok(msgs[1].msg:find('full stack is not a branch', 1, true), msgs[1].msg)
end)

h.test(']s / [s stay view-only by default; with switch_on_navigate they switch, and a refusal leaves the view moved', function()
  local s = view.session
  view.set_scope({ kind = 'layer', index = 3 })
  idle(s)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys(vim.keycode('[s'), 'mtx', false)
  idle(s)
  h.eq(2, s.scope.index)
  h.eq('stack/ui', branch(stack_dir), 'view only')
  require('revuey.config').options.stack.switch_on_navigate = true
  vim.api.nvim_feedkeys(vim.keycode('[s'), 'mtx', false)
  wait_head(s, 'stack/math')
  h.eq('stack/math', branch(stack_dir))
  h.eq({ kind = 'layer', index = 1 }, s.scope)
  -- dirty: the view moves, the branch does not
  h.write(stack_dir, 'src/math.ts', 'dirty\n')
  local msgs, restore = h.capture_notify()
  vim.api.nvim_feedkeys(vim.keycode(']s'), 'mtx', false)
  h.ok(vim.wait(5000, function()
    return #msgs > 0
  end, 10))
  idle(s)
  restore()
  h.eq(2, s.scope.index)
  h.eq('stack/math', branch(stack_dir))
  h.eq('revuey: showing stack/cart, branch not switched: not switching to stack/cart: uncommitted changes in src/math.ts. Commit or stash them first (revuey never stashes).', msgs[1].msg)
  h.git(stack_dir, 'checkout', '-q', '--', 'src/math.ts')
  require('revuey.config').options.stack.switch_on_navigate = false
  view.close()
end)

-- someone else's stack: remote-tracking layers, HEAD detached at the top

h.test('gS on a remote-only layer creates a tracking branch; marks and comments carry over; the stack stays', function()
  local dir = fixture('--remote-stack', 'switch-remote')
  local s = open(dir)
  h.eq({ 'origin/stack/math', 'origin/stack/cart', 'origin/stack/ui' }, names(s))
  view.set_scope({ kind = 'layer', index = 2 })
  idle(s)
  -- the hint says a local branch will be created
  h.eq('gS creates local branch stack/cart', require('revuey.panel').switch_hint(s.review.stack.layers[2]))
  local fi
  for i, f in ipairs(s.review.files) do
    if f.path == 'src/cart.ts' then
      fi = i
    end
  end
  view.toggle_reviewed(fi)
  local comments = require('revuey.comments')
  local store = comments.load(comments.path_for(s.review.state._path))
  local c = comments.new(comments.file_anchor('src/cart.ts'), 'remote layer comment')
  comments.put(store, c)
  comments.save(store)
  local state_path = s.review.state._path
  local done = do_switch()
  h.eq(true, done.ok, done.msg)
  h.eq('revuey: created stack/cart tracking origin/stack/cart, and switched to it', done.msg)
  wait_head(s, 'stack/cart')
  h.eq('stack/cart', branch(dir))
  h.eq('origin/stack/cart', vim.trim(h.git(dir, 'rev-parse', '--abbrev-ref', 'stack/cart@{upstream}')))
  -- the other layers stay viewable: the stack is kept while attached
  h.eq({ 'origin/stack/math', 'stack/cart', 'origin/stack/ui' }, names(s))
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  h.eq('worktree', s.review.mode)
  h.eq(state_path, s.review.state._path, 'same state file')
  for i, f in ipairs(s.review.files) do
    if f.path == 'src/cart.ts' then
      h.eq(true, require('revuey.review').is_reviewed(s.review, s.review.files[i]))
    end
  end
  h.eq('remote layer comment', comments.load(comments.path_for(s.review.state._path)).comments[c.id].body)
  local text = panel_text(s)
  h.ok(text:find('▶@ stack/cart', 1, true), text)
  h.ok(text:find('origin/stack/ui', 1, true) and text:find('origin/stack/math', 1, true), text)
  -- the layers above and below still diff as before
  view.set_scope({ kind = 'layer', index = 3 })
  idle(s)
  h.eq('origin/stack/ui', s.review.branch)
  h.eq('stack/cart', s.review.base)
  -- reopening on the branch keeps the stack
  view.close()
  s = open(dir)
  h.eq({ 'origin/stack/math', 'stack/cart', 'origin/stack/ui' }, names(s))
  h.eq('stack/cart', head_layer(s))
  -- the top layer: the remote layer below stays too
  done = do_switch(3)
  h.eq(true, done.ok, done.msg)
  wait_head(s, 'stack/ui')
  h.eq({ 'origin/stack/math', 'stack/cart', 'stack/ui' }, names(s))
  -- the bottom layer too; then a commit on it: the layers above are "not restacked"
  done = do_switch(1)
  h.eq(true, done.ok, done.msg)
  wait_head(s, 'stack/math')
  h.eq({ 'stack/math', 'stack/cart', 'stack/ui' }, names(s))
  h.write(dir, 'src/math.ts', 'export const edited = 1;\n')
  h.git(dir, 'commit', '-q', '-am', 'edit math')
  view.refresh({ force = true })
  idle(s)
  h.eq({ 'stack/math', 'stack/cart', 'stack/ui' }, names(s))
  local kinds = vim.tbl_map(function(n)
    return n.kind .. ':' .. n.branch
  end, s.review.stack.notes)
  h.ok(vim.tbl_contains(kinds, 'not_restacked:stack/cart'), vim.inspect(kinds))
  view.close()
end)

h.test('a commit on a checked-out lower layer: the remote layer above stays, marked not restacked', function()
  local dir = fixture('--remote-stack', 'switch-edit')
  local s = open(dir)
  h.eq(true, do_switch(2).ok)
  wait_head(s, 'stack/cart')
  h.write(dir, 'src/cart.ts', 'export const edited = 1;\n')
  h.git(dir, 'commit', '-q', '-am', 'edit cart')
  view.refresh({ force = true })
  idle(s)
  h.eq({ 'origin/stack/math', 'stack/cart', 'origin/stack/ui' }, names(s))
  local kinds = vim.tbl_map(function(n)
    return n.kind .. ':' .. n.branch
  end, s.review.stack.notes)
  h.ok(vim.tbl_contains(kinds, 'not_restacked:origin/stack/ui'), vim.inspect(kinds))
  -- the layer above is still diffed from stack/cart's old tip: only its own commit
  view.set_scope({ kind = 'layer', index = 3 })
  idle(s)
  h.eq({ 'src/cart.ts', 'src/components/Total.tsx' }, vim.tbl_map(function(f)
    return f.path
  end, s.review.files))
  view.close()
end)

h.test('a remote layer whose local name is taken by an unrelated branch: asks; cancel, or switch to it untouched', function()
  local dir = fixture('--remote-stack', 'switch-conflict')
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
  prompts = with_select(1, function()
    done = do_switch(2)
  end)
  h.eq(true, done.ok, done.msg)
  h.eq('stack/cart', branch(dir))
  h.eq(tip, vim.trim(h.git(dir, 'rev-parse', 'stack/cart')), 'the local branch is not moved')
  h.eq('', vim.trim(vim.system({ 'git', 'config', 'branch.stack/cart.merge' }, { cwd = dir, text = true }):wait().stdout))
  view.close()
end)

h.test('a remote layer with a local branch tracking it (off the line) switches to that branch', function()
  local dir = fixture('--remote-stack', 'switch-tracking')
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
  view.close()
end)

h.run()
