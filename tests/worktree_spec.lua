-- Working-tree mode: committed + staged + unstaged + untracked changes, mode toggle, auto-refresh.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
require('revuey').setup({ state_dir = h.tmpdir('wt-state'), lsp_warmup = false })
local view = require('revuey.view')
local review_mod = require('revuey.review')

---Fixture plus uncommitted work of every kind.
local function dirty_fixture()
  local d = h.fixture()
  local function append(path, line)
    local l = vim.fn.readfile(d .. '/' .. path)
    l[#l + 1] = line
    vim.fn.writefile(l, d .. '/' .. path)
  end
  append('src/math.ts', '// unstaged edit')
  append('src/format.ts', '// staged edit')
  h.git(d, 'add', 'src/format.ts')
  h.write(d, 'src/extra.ts', 'import { sum } from "./math";\nexport const total = sum([1, 2]);\n')
  vim.fn.delete(d .. '/README.md')
  return d
end

local fixture = dirty_fixture()
local s

local function by_path(sess)
  local t = {}
  for i, f in ipairs(sess.review.files) do
    t[f.path] = { f = f, i = i }
  end
  return t
end

local function row_of(sess, path, needle)
  for row, e in ipairs(sess.layout.map) do
    local f = sess.review.files[e.file_idx]
    if f and f.path == path and e.kind ~= 'meta' and sess.layout.lines[row]:find(needle, 1, true) then
      return row
    end
  end
end

local function wait_renders(sess, n)
  vim.wait(5000, function()
    return sess.render_count >= n and not sess.refreshing
  end, 10)
end

h.test('default review includes staged, unstaged, untracked and deleted-on-disk changes', function()
  s = h.open_review({ cwd = fixture })
  h.eq('worktree', s.review.mode)
  local f = by_path(s)
  h.eq('A', f['src/extra.ts'].f.status)
  h.eq('D', f['README.md'].f.status)
  h.ok(row_of(s, 'src/math.ts', '// unstaged edit'), 'unstaged line shown')
  h.ok(row_of(s, 'src/format.ts', '// staged edit'), 'staged line shown')
  h.ok(row_of(s, 'src/extra.ts', 'export const total'), 'untracked file shown')
  -- every new-side row equals the file on disk
  for row, e in ipairs(s.layout.map) do
    if e.kind == 'add' or e.kind == 'ctx' then
      local file = s.review.files[e.file_idx]
      h.eq(vim.fn.readfile(fixture .. '/' .. file.path)[e.new_lnum], s.layout.lines[row], file.path)
    end
  end
  for path, want in pairs({
    ['src/math.ts'] = true,
    ['src/format.ts'] = true,
    ['src/extra.ts'] = true,
    ['README.md'] = true,
    ['src/cart.ts'] = false,
  }) do
    h.eq(want, f[path].f.uncommitted == true, path)
  end
end)

h.test('panel shows mode header and ● markers; no "not shown" warning', function()
  local lines = vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
  local text = table.concat(lines, '\n')
  h.ok(text:find('working tree', 1, true), text)
  h.ok(not text:find('not shown', 1, true), text)
  local f = by_path(s)
  h.ok(lines[s.panel_rows[f['src/math.ts'].i]]:find('●', 1, true), lines[s.panel_rows[f['src/math.ts'].i]])
  h.ok(not lines[s.panel_rows[f['src/cart.ts'].i]]:find('●', 1, true))
end)

h.test('reviewed marks: shared with committed mode, invalidated by edits', function()
  local f = by_path(s)
  review_mod.toggle_reviewed(s.review, f['src/cart.ts'].f)
  review_mod.toggle_reviewed(s.review, f['src/math.ts'].f)
  local committed = assert(review_mod.load({ cwd = fixture, base = 'main', mode = 'committed' }))
  local cf = by_path({ review = committed })
  h.eq(true, review_mod.is_reviewed(committed, cf['src/cart.ts'].f), 'unchanged file: same key in both modes')
  h.eq(false, review_mod.is_reviewed(committed, cf['src/math.ts'].f), 'committed math.ts differs from disk')
  -- edit math.ts again on disk: its worktree mark no longer applies
  local l = vim.fn.readfile(fixture .. '/src/math.ts')
  l[#l + 1] = '// another edit'
  vim.fn.writefile(l, fixture .. '/src/math.ts')
  local again = assert(review_mod.load({ cwd = fixture, base = 'main' }))
  h.eq(false, review_mod.is_reviewed(again, by_path({ review = again })['src/math.ts'].f))
  h.eq(true, review_mod.is_reviewed(again, by_path({ review = again })['src/cart.ts'].f))
end)

h.test('gu toggles committed-only mode, keeping the cursor on the same line', function()
  vim.api.nvim_set_current_win(s.diff_win)
  local row = row_of(s, 'src/cart.ts', 'total(): number')
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 4 })
  local n = s.render_count
  view.toggle_mode()
  wait_renders(s, n + 1)
  h.eq('committed', s.review.mode)
  h.eq(nil, by_path(s)['src/extra.ts'])
  local text = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  h.ok(text:find('committed', 1, true), text)
  local cur = vim.api.nvim_win_get_cursor(s.diff_win)
  h.ok(s.layout.lines[cur[1]]:find('total(): number', 1, true), s.layout.lines[cur[1]])
  h.eq(4, cur[2])
  view.toggle_mode()
  wait_renders(s, n + 2)
  h.eq('worktree', s.review.mode)
  local maps = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(s.diff_buf, 'n')) do
    maps[m.lhs] = m.desc
  end
  h.ok(maps.gu, 'gu mapped')
end)

h.test('writing a file refreshes, preserving cursor, scroll and folds', function()
  vim.api.nvim_set_current_win(s.diff_win)
  local f = by_path(s)
  local cart_header = s.layout.files[f['src/cart.ts'].i].start_row
  vim.api.nvim_win_call(s.diff_win, function()
    vim.cmd(cart_header .. 'foldclose')
  end)
  local row = row_of(s, 'src/math.ts', 'export function sum')
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 7 })
  local view_before = vim.api.nvim_win_call(s.diff_win, vim.fn.winsaveview)
  local offset = row - view_before.topline
  local n = s.render_count
  -- edit and :write math.ts in a hidden buffer (fires BufWritePost)
  local buf = vim.fn.bufadd(fixture .. '/src/math.ts')
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '// written from nvim' })
  vim.api.nvim_buf_call(buf, function()
    vim.cmd('silent write')
  end)
  wait_renders(s, n + 1)
  h.eq(n + 1, s.render_count, 'one refresh')
  h.ok(row_of(s, 'src/math.ts', '// written from nvim'), 'new line shown')
  local cur = vim.api.nvim_win_get_cursor(s.diff_win)
  h.ok(s.layout.lines[cur[1]]:find('export function sum', 1, true), s.layout.lines[cur[1]])
  h.eq(7, cur[2])
  local view_after = vim.api.nvim_win_call(s.diff_win, vim.fn.winsaveview)
  h.eq(offset, cur[1] - view_after.topline, 'scroll offset kept')
  local cart_header2 = s.layout.files[by_path(s)['src/cart.ts'].i].start_row
  h.eq(cart_header2, vim.api.nvim_win_call(s.diff_win, function()
    return vim.fn.foldclosed(cart_header2)
  end), 'manually closed fold stays closed')
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

h.test('refresh requests are coalesced', function()
  local loads = 0
  local orig = review_mod.load
  review_mod.load = function(...)
    loads = loads + 1
    return orig(...)
  end
  local n = s.render_count
  for _ = 1, 5 do
    view.refresh()
  end
  vim.api.nvim_exec_autocmds('FocusGained', {})
  vim.wait(3000, function()
    return loads >= 1 and not s.refreshing
  end, 10)
  vim.wait(300)
  h.eq(n, s.render_count, 'unchanged content is not re-rendered')
  review_mod.load = orig
  h.eq(2, loads, 'first refresh + exactly one coalesced follow-up')
end)

h.test('FocusGained picks up edits made outside Neovim', function()
  h.write(fixture, 'src/outside.ts', 'export const outside = 1;\n')
  local n = s.render_count
  vim.api.nvim_exec_autocmds('FocusGained', {})
  wait_renders(s, n + 1)
  h.ok(by_path(s)['src/outside.ts'], 'new untracked file shown')
end)

h.test(':Revuey --committed opens committed-only mode', function()
  view.close()
  local done
  require('revuey').setup({ state_dir = h.tmpdir('wt-state2'), lsp_warmup = false })
  vim.cmd('cd ' .. vim.fn.fnameescape(fixture))
  vim.cmd('Revuey main --committed')
  vim.wait(5000, function()
    return view.session ~= nil
  end, 10)
  h.eq('committed', view.session.review.mode)
  h.eq('main', view.session.review.base)
  view.close()
end)

h.run()
