-- Integration: stack reviews on the 3-layer fixture (scripts/make-fixture.sh --stack), opened
-- headlessly: layer switching, full scope, per-layer reviewed marks, working tree on HEAD only.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')

local state_dir = h.tmpdir('stack-view-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local view = require('revuey.view')

local function stack_fixture(name)
  local d = h.tmpdir(name)
  vim.fn.delete(d, 'rf')
  local res = vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }, { text = true }):wait()
  assert(res.code == 0, res.stderr)
  return d
end

local function open(dir, opts)
  if view.session then
    view.close()
  end
  local session
  require('revuey').open(vim.tbl_extend('force', { cwd = dir }, opts or {}, {
    on_ready = function(s)
      session = s
    end,
  }))
  vim.wait(10000, function()
    return session ~= nil
  end, 10)
  assert(session, 'review did not open')
  return session
end

local function idle(s)
  assert(
    vim.wait(10000, function()
      return not s.refreshing and not s.pending and not s.pending_scope
    end, 10),
    'refresh did not finish'
  )
end

local function paths(s)
  return vim.tbl_map(function(f)
    return f.path
  end, s.review.files)
end

local function file(s, path)
  for i, f in ipairs(s.review.files) do
    if f.path == path then
      return f, i
    end
  end
end

local function panel_text(s)
  return table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
end

local function keys(s, k)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
  idle(s)
end

local fx = stack_fixture('stack-view')

h.test(':Revuey (no args) opens at the HEAD layer with the stack shown', function()
  local s = open(fx)
  local st = s.review.stack
  h.ok(st, 'stack detected')
  h.eq({ 'stack/math', 'stack/cart', 'stack/ui' }, vim.tbl_map(function(l)
    return l.name
  end, st.layers))
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  h.eq('stack/cart', s.review.branch)
  h.eq('stack/math', s.review.base)
  h.eq({ 'src/cart.ts', 'src/index.ts' }, paths(s))
  h.eq('worktree', s.review.mode)
  local text = panel_text(s)
  h.ok(text:find('Stack: 3 layers on main', 1, true), text)
  h.ok(text:find('▶@ stack/cart', 1, true), text)
  h.ok(text:find('layer 2/3', 1, true), text)
end)

h.test('layer stats load in the background (commits, files, reviewed)', function()
  local s = view.session
  h.ok(vim.wait(5000, function()
    return s.review.stack.full_stats ~= nil
  end, 10))
  local st = s.review.stack
  h.eq({ commits = 1, files = 1, reviewed = 0 }, st.layers[1].stats)
  h.eq({ commits = 2, files = 2, reviewed = 0 }, st.layers[2].stats)
  h.eq({ commits = 1, files = 2, reviewed = 0 }, st.layers[3].stats)
  h.eq({ commits = 4, files = 4, reviewed = 0 }, st.full_stats)
end)

h.test(']s / [s move between layers; layers below/above HEAD are committed-only', function()
  local s = view.session
  keys(s, ']s')
  h.eq({ kind = 'layer', index = 3 }, s.scope)
  h.eq('stack/ui', s.review.branch)
  h.eq('stack/cart', s.review.base)
  h.eq({ 'src/cart.ts', 'src/components/Total.tsx' }, paths(s))
  h.eq(true, s.review.mode_locked)
  h.eq('committed', s.review.mode)
  h.ok(panel_text(s):find('committed only  (not HEAD)', 1, true), panel_text(s))
  local msgs, restore = h.capture_notify()
  keys(s, ']s')
  restore()
  h.eq(3, s.scope.index)
  h.ok(msgs[1] and msgs[1].msg:find('no layer above', 1, true), vim.inspect(msgs))
  keys(s, '2[s')
  h.eq('stack/math', s.review.branch)
  h.eq('main', s.review.base)
  h.eq({ 'src/math.ts' }, paths(s))
  -- cursor starts at the top of the new scope
  h.eq(1, vim.api.nvim_win_get_cursor(s.diff_win)[1])
end)

h.test('gs toggles full-stack scope (trunk merge-base to top) and back', function()
  local s = view.session
  keys(s, 'gs')
  h.eq({ kind = 'full' }, s.scope)
  h.eq('stack/ui', s.review.branch)
  h.eq('main', s.review.base)
  h.eq({ 'src/cart.ts', 'src/components/Total.tsx', 'src/index.ts', 'src/math.ts' }, paths(s))
  h.ok(panel_text(s):find('full stack (3 layers)', 1, true), panel_text(s))
  keys(s, 'gs')
  h.eq({ kind = 'layer', index = 1 }, s.scope, 'back to the last layer')
end)

h.test('<CR> on a layer row in the panel selects it', function()
  local s = view.session
  local row
  for r, l in pairs(s.panel_layers) do
    if l == 2 then
      row = r
    end
  end
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_win_set_cursor(s.panel_win, { row, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'mtx', false)
  idle(s)
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  h.eq('worktree', s.review.mode)
end)

h.test('reviewed marks are per layer', function()
  local s = view.session
  local _, fi = file(s, 'src/cart.ts')
  view.toggle_reviewed(fi)
  local _, ii = file(s, 'src/index.ts')
  view.toggle_reviewed(ii)
  h.ok(panel_text(s):find('✓ 2/2', 1, true), panel_text(s))
  keys(s, ']s')
  h.eq('stack/ui', s.review.branch)
  h.eq(false, require('revuey.review').is_reviewed(s.review, file(s, 'src/cart.ts')))
  keys(s, 'gs')
  -- index.ts has identical content in full scope, but full scope is its own review
  h.eq(false, require('revuey.review').is_reviewed(s.review, file(s, 'src/index.ts')))
  keys(s, 'gs')
  keys(s, '[s')
  h.eq('stack/cart', s.review.branch)
  h.eq(true, require('revuey.review').is_reviewed(s.review, file(s, 'src/cart.ts')))
  -- the state file is keyed by layer + parent
  h.eq(require('revuey.state').file_for(state_dir, s.review.root, 'stack/cart', 'stack/math'), s.review.state._path)
  h.ok(vim.wait(5000, function()
    return s.review.stack.layers[2].stats and s.review.stack.layers[2].stats.reviewed == 2
  end, 10), vim.inspect(s.review.stack.layers[2].stats))
  h.eq(0, s.review.stack.layers[3].stats.reviewed)
end)

h.test('working-tree changes appear only on the HEAD layer', function()
  local s = view.session
  local p = vim.fs.joinpath(fx, 'src/math.ts')
  local l = vim.fn.readfile(p)
  l[#l + 1] = '// uncommitted'
  vim.fn.writefile(l, p)
  h.write(fx, 'src/new.ts', 'export const n = 1;\n')
  view.refresh({ force = true })
  idle(s)
  h.eq('stack/cart', s.review.branch)
  h.eq({ 'src/cart.ts', 'src/index.ts', 'src/math.ts', 'src/new.ts' }, paths(s))
  h.eq(true, file(s, 'src/math.ts').uncommitted)
  keys(s, '[s')
  h.eq('stack/math', s.review.branch)
  h.eq({ 'src/math.ts' }, paths(s))
  h.eq(nil, file(s, 'src/math.ts').uncommitted)
  local msgs, restore = h.capture_notify()
  keys(s, 'gu')
  restore()
  h.eq('committed', s.review.mode)
  h.ok(msgs[1] and msgs[1].msg:find('committed-only', 1, true), vim.inspect(msgs))
  keys(s, 'gs')
  h.eq(nil, file(s, 'src/new.ts'), 'full scope is committed-only when HEAD is not the top')
  keys(s, 'gs')
  keys(s, ']s')
  h.eq('stack/cart', s.review.branch)
  h.eq('worktree', s.review.mode, 'the mode preference survives committed-only layers')
  vim.system({ 'git', 'checkout', '-q', '--', 'src/math.ts' }, { cwd = fx }):wait()
  vim.fn.delete(vim.fs.joinpath(fx, 'src/new.ts'))
end)

h.test('full scope includes the working tree when HEAD is the top layer', function()
  local d = stack_fixture('stack-view-top')
  h.git(d, 'checkout', '-q', 'stack/ui')
  h.write(d, 'src/new.ts', 'export const n = 1;\n')
  local s = open(d, { scope = 'full' })
  h.eq({ kind = 'full' }, s.scope)
  h.eq('worktree', s.review.mode)
  h.ok(file(s, 'src/new.ts'), vim.inspect(paths(s)))
  keys(s, '[s')
  h.eq('stack/ui', s.review.branch, 'from full scope [s goes to the top layer')
  h.eq('worktree', s.review.mode, 'the top is HEAD here')
  h.ok(file(s, 'src/new.ts'))
end)

h.test(':Revuey <base> keeps the single-branch review; --stack opens full scope', function()
  vim.cmd('cd ' .. vim.fn.fnameescape(fx))
  local s = open(fx, { base = 'main' })
  h.eq(nil, s.review.stack)
  h.eq('stack/cart', s.review.branch)
  h.eq({ 'src/cart.ts', 'src/index.ts', 'src/math.ts' }, paths(s))
  h.ok(not panel_text(s):find('Stack', 1, true))
  local s2 = open(fx, { base = 'main', scope = 'full' })
  h.eq({ kind = 'full' }, s2.scope)
  h.eq('stack/ui', s2.review.branch)
  h.eq({ 'src/cart.ts', 'src/components/Total.tsx', 'src/index.ts', 'src/math.ts' }, paths(s2))
end)

h.test('no stack: a lone branch opened without args is the plain review', function()
  local d = h.repo('stack-view-lone', { ['a.txt'] = '1\n' }, { ['a.txt'] = '2\n' })
  local s = open(d)
  h.eq(nil, s.review.stack)
  h.eq(nil, s.scope)
  h.eq('feat', s.review.branch)
  h.ok(not panel_text(s):find('Stack', 1, true))
  local msgs, restore = h.capture_notify()
  keys(s, ']s')
  restore()
  h.ok(msgs[1] and msgs[1].msg:find('no stack', 1, true), vim.inspect(msgs))
end)

h.test(':RevueyStackParent sets/clears the parent of the reviewed layer; no arg picks from a list', function()
  local s = open(fx)
  h.eq('stack/cart', s.review.branch)
  local _, restore_n = h.capture_notify()
  vim.cmd('RevueyStackParent main')
  idle(s)
  h.eq('main', vim.trim(h.git(fx, 'config', 'branch.stack/cart.revueyParent')))
  h.eq({ 'stack/cart', 'stack/ui' }, vim.tbl_map(function(l)
    return l.name
  end, s.review.stack.layers))
  h.eq('stack/cart', s.review.branch)
  h.eq('main', s.review.base)
  h.eq('config', s.review.stack.layers[1].source)
  -- no argument: vim.ui.select with trunk, branches and a clear entry
  local orig = vim.ui.select
  local seen
  vim.ui.select = function(items, opts, cb)
    seen = vim.tbl_map(opts.format_item, items)
    cb(items[#items])
  end
  vim.cmd('RevueyStackParent')
  vim.ui.select = orig
  idle(s)
  restore_n()
  h.eq('main  (trunk)', seen[1])
  h.eq('(clear override: detect automatically)', seen[#seen])
  h.ok(vim.tbl_contains(seen, 'stack/math') and not vim.tbl_contains(seen, 'stack/cart'), vim.inspect(seen))
  h.eq(3, #s.review.stack.layers)
  h.eq('stack/math', s.review.base)
  local msgs, restore = h.capture_notify()
  vim.cmd('RevueyStackParent nope')
  restore()
  h.ok(msgs[1].msg:find('no local branch nope', 1, true))
end)

h.test('refresh picks up a new branch in the stack and keeps the scope on the same layer', function()
  local s = view.session
  h.git(fx, 'branch', 'stack/cart-copy', 'stack/cart')
  view.refresh()
  idle(s)
  h.eq('stack/cart', s.review.branch)
  h.eq({ 'stack/cart-copy' }, s.review.stack.layers[2].also)
  h.ok(panel_text(s):find('stack/cart-copy also at stack/cart', 1, true), panel_text(s))
  h.git(fx, 'branch', '-D', 'stack/cart-copy')
end)

h.test('switching layers and back restores cursor and folds per scope', function()
  local s = open(fx)
  h.eq('stack/cart', s.review.branch)
  -- move into index.ts and fold cart.ts
  local _, ii = file(s, 'src/index.ts')
  local row = s.layout.files[ii].start_row + 3
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 2 })
  vim.cmd(s.layout.files[1].start_row .. 'foldclose')
  local text = s.layout.lines[row]
  keys(s, ']s')
  h.eq('stack/ui', s.review.branch)
  h.eq(1, vim.api.nvim_win_get_cursor(s.diff_win)[1], 'a scope seen for the first time starts at the top')
  vim.api.nvim_win_set_cursor(s.diff_win, { 3, 0 })
  keys(s, '[s')
  h.eq('stack/cart', s.review.branch)
  local cur = vim.api.nvim_win_get_cursor(s.diff_win)
  h.eq(text, s.layout.lines[cur[1]], 'back on the same line')
  h.eq(2, cur[2])
  h.ok(vim.fn.foldclosed(s.layout.files[1].start_row) ~= -1, 'cart.ts still folded')
  keys(s, ']s')
  h.eq(3, vim.api.nvim_win_get_cursor(s.diff_win)[1], 'stack/ui remembered too')
end)

h.test('go on a layer below the checkout opens the matching working-tree line', function()
  local d = stack_fixture('stack-view-go')
  h.git(d, 'checkout', '-q', 'stack/ui') -- ui adds an import above cart.ts's lines
  local s = open(d)
  keys(s, '[s')
  h.eq('stack/cart', s.review.branch)
  local row
  for r, e in ipairs(s.layout.map) do
    if e.kind == 'add' and s.layout.lines[r]:find('total(): number {', 1, true) then
      row = r
    end
  end
  h.eq(17, s.layout.map[row].new_lnum)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  view.open_file()
  h.eq(18, vim.api.nvim_win_get_cursor(0)[1])
  h.ok(vim.api.nvim_get_current_line():find('total(): number {', 1, true))
  view.close()
end)

h.test('wide-character branch names are truncated to the panel width', function()
  local d = h.tmpdir('stack-view-cjk')
  h.git(d, 'init', '-q', '-b', 'main')
  h.write(d, 'base.txt', 'base\n')
  h.git(d, 'add', '-A')
  h.git(d, 'commit', '-q', '-m', 'base')
  h.git(d, 'checkout', '-q', '-b', 'feat/日本語日本語日本語日本語日本語日本語-long')
  h.write(d, 'a.txt', 'a\n')
  h.git(d, 'add', '-A')
  h.git(d, 'commit', '-q', '-m', 'a')
  h.git(d, 'checkout', '-q', '-b', 'feat/x.y/ünïcödé-ブランチ-with-a-really-really-long-name')
  h.write(d, 'src/ディレクトリ/とても長いファイル名のファイル.ts', 'b\n')
  h.git(d, 'add', '-A')
  h.git(d, 'commit', '-q', '-m', 'b')
  local s = open(d)
  h.ok(vim.wait(5000, function()
    return s.review.stack and s.review.stack.full_stats ~= nil
  end, 10))
  local width = vim.api.nvim_win_get_width(s.panel_win)
  local ns = vim.api.nvim_get_namespaces()['revuey.panel']
  local virt = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, 0, -1, { details = true })) do
    if m[4].virt_text then
      local w = 0
      for _, v in ipairs(m[4].virt_text) do
        w = w + vim.fn.strdisplaywidth(v[1])
      end
      virt[m[2] + 1] = w
    end
  end
  for i, line in ipairs(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)) do
    local w = vim.fn.strdisplaywidth(line) + (virt[i] and (virt[i] + 1) or 0)
    h.ok(w <= width, ('line %d is %d cells wide (panel %d): %s'):format(i, w, width, line))
  end
end)

h.test(':RevueyStackParent --clear reports when there is nothing to clear', function()
  local s = open(fx)
  h.eq('stack/cart', s.review.branch)
  local msgs, restore = h.capture_notify()
  vim.cmd('RevueyStackParent --clear')
  restore()
  h.ok(msgs[1].msg:find('no stack parent override to clear', 1, true), vim.inspect(msgs))
  msgs, restore = h.capture_notify()
  vim.cmd('RevueyStackParent main')
  idle(s)
  vim.cmd('RevueyStackParent --clear')
  idle(s)
  restore()
  h.ok(msgs[#msgs].msg:find('cleared the stack parent of stack/cart', 1, true), vim.inspect(msgs))
  h.eq(3, #s.review.stack.layers)
end)

h.test('the viewed layer disappearing is reported, not silently replaced', function()
  local d = stack_fixture('stack-view-gone')
  local s = open(d)
  keys(s, ']s')
  h.eq('stack/ui', s.review.branch)
  h.git(d, 'branch', '-D', 'stack/ui')
  local msgs, restore = h.capture_notify()
  view.refresh()
  idle(s)
  restore()
  h.eq('stack/cart', s.review.branch)
  h.ok(msgs[1] and msgs[1].msg:find('layer stack/ui is no longer in the stack; showing stack/cart', 1, true), vim.inspect(msgs))
end)

h.test('entering the diff notices branches moved elsewhere (no focus event needed)', function()
  local d = stack_fixture('stack-view-bufenter')
  local s = open(d)
  h.eq(3, #s.review.stack.layers)
  h.git(d, 'branch', 'stack/ui-copy', 'stack/ui')
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_set_current_win(s.diff_win)
  h.ok(vim.wait(5000, function()
    local l = s.review.stack.layers[3]
    return not s.refreshing and l.also ~= nil
  end, 10), 'stack not re-detected on BufEnter')
  h.eq({ 'stack/ui-copy' }, s.review.stack.layers[3].also)
end)

h.test('a landed (squash-merged) bottom layer is dimmed in the panel', function()
  local d = stack_fixture('stack-view-landed')
  h.git(d, 'checkout', '-q', 'main')
  h.git(d, 'merge', '-q', '--squash', 'stack/math')
  h.git(d, 'commit', '-q', '-m', 'squash math')
  h.git(d, 'checkout', '-q', 'stack/cart')
  local s = open(d)
  h.eq(true, s.review.stack.layers[1].landed)
  h.ok(panel_text(s):find('stack/math looks landed in main', 1, true), panel_text(s))
  local ns = vim.api.nvim_get_namespaces()['revuey.panel']
  local dim = false
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, { 1, 0 }, { 1, -1 }, { details = true })) do
    if m[4].hl_group == 'Comment' and vim.api.nvim_buf_get_lines(s.panel_buf, 1, 2, false)[1]:find('stack/math', 1, true) then
      dim = true
    end
  end
  h.ok(dim, 'stack/math row dimmed')
end)

h.test('long note lists are capped in the panel', function()
  local d = stack_fixture('stack-view-notes')
  for i = 1, 150 do
    h.git(d, 'branch', 'child/ünï-' .. i, 'stack/math')
  end
  local s = open(d)
  local text = panel_text(s)
  h.ok(text:find('and 147 more', 1, true), text)
  h.ok(#vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false) < 40, text)
end)

h.test('plain review (no stack) shows the rewritten-parent note', function()
  local src = h.tmpdir('stack-view-clone-src')
  h.git(src, 'init', '-q', '-b', 'main')
  h.write(src, 'base.txt', 'base\n')
  h.git(src, 'add', '-A')
  h.git(src, 'commit', '-q', '-m', 'base')
  h.git(src, 'checkout', '-q', '-b', 'a')
  h.write(src, 'a.txt', 'a\n')
  h.git(src, 'add', '-A')
  h.git(src, 'commit', '-q', '-m', 'a')
  h.git(src, 'checkout', '-q', '-b', 'b')
  h.write(src, 'b.txt', 'b\n')
  h.git(src, 'add', '-A')
  h.git(src, 'commit', '-q', '-m', 'b')
  h.git(src, 'checkout', '-q', 'a')
  h.write(src, 'a.txt', 'a amended\n')
  h.git(src, 'commit', '-q', '-a', '--amend', '-m', 'a amended')
  h.git(src, 'checkout', '-q', 'main')
  local d = h.tmpdir('stack-view-clone')
  vim.fn.delete(d, 'rf')
  h.git(vim.fs.dirname(d), 'clone', '-q', src, d)
  h.git(d, 'branch', '-q', 'a', 'origin/a')
  h.git(d, 'checkout', '-q', '-b', 'b', 'origin/b')
  local s = open(d)
  h.eq(nil, s.review.stack)
  local text = panel_text(s)
  h.ok(text:find('a has a rewritten copy of a commit on', 1, true) and text:find('old version of a', 1, true), text)
  h.ok(not text:find('Stack:', 1, true), text)
end)

h.test('parse_args', function()
  local p = require('revuey').parse_args
  h.eq({ scope = 'full' }, p({ '--stack' }))
  h.eq({ base = 'develop', mode = 'committed' }, p({ 'develop', '--committed' }))
  h.eq(nil, (p({ '--nope' })))
  h.eq(nil, (p({ 'a', 'b' })))
end)

view.close()
h.run()
