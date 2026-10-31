-- LSP projection against typescript-language-server (skipped when it cannot start here; CI fails).
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
h.need_ts_ls_spec()
vim.cmd('runtime plugin/revuey.lua')

local fixture = h.fixture()
require('revuey').setup({ state_dir = h.tmpdir('lsp-state') })
local view = require('revuey.view')
local s
require('revuey').open({ cwd = fixture, base = 'main', on_ready = function(x)
  s = x
end })
vim.wait(5000, function()
  return s ~= nil
end, 10)
assert(s, 'review did not open')

local function find_row(path, needle)
  for row, e in ipairs(s.layout.map) do
    local f = s.review.files[e.file_idx or 0]
    if f and f.path == path and (e.kind == 'add' or e.kind == 'ctx') then
      local col = s.layout.lines[row]:find(needle, 1, true)
      if col then
        return row, col - 1
      end
    end
  end
  error('not found: ' .. needle)
end

local function wait_cursor_change(win, buf_before, row_before)
  vim.wait(20000, function()
    local w = vim.api.nvim_get_current_win()
    return w ~= win or vim.api.nvim_win_get_cursor(w)[1] ~= row_before
  end, 50)
end

h.test('gd on a call jumps to a definition shown in the diff', function()
  vim.api.nvim_set_current_win(s.diff_win)
  local row, col = find_row('src/cart.ts', 'sum(this')
  vim.api.nvim_win_set_cursor(s.diff_win, { row, col })
  view.definition()
  wait_cursor_change(s.diff_win, s.diff_buf, row)
  h.eq(s.diff_win, vim.api.nvim_get_current_win())
  local r = vim.api.nvim_win_get_cursor(s.diff_win)[1]
  local e = s.layout.map[r]
  h.eq('src/math.ts', s.review.files[e.file_idx].path)
  h.ok(s.layout.lines[r]:find('export function sum', 1, true), s.layout.lines[r])
end)

h.test('gd, <C-o>, then <Tab> on a code line jumps forward again (<Tab> is <C-i>)', function()
  vim.api.nvim_set_current_win(s.diff_win)
  local row, col = find_row('src/cart.ts', 'sum(this')
  vim.api.nvim_win_set_cursor(s.diff_win, { row, col })
  vim.cmd('clearjumps')
  vim.api.nvim_feedkeys('gd', 'mtx', false)
  wait_cursor_change(s.diff_win, s.diff_buf, row)
  local target = vim.api.nvim_win_get_cursor(s.diff_win)[1]
  h.ok(target ~= row, 'gd moved')
  vim.api.nvim_feedkeys(vim.keycode('<C-o>'), 'mtx', false)
  h.eq(row, vim.api.nvim_win_get_cursor(s.diff_win)[1], '<C-o> back')
  h.eq('add', s.layout.map[row].kind)
  vim.api.nvim_feedkeys(vim.keycode('<Tab>'), 'mtx', false)
  h.eq(s.diff_win, vim.api.nvim_get_current_win())
  h.eq(target, vim.api.nvim_win_get_cursor(s.diff_win)[1], '<Tab> forward')
  h.eq(-1, vim.fn.foldclosed(s.layout.files[s.layout.map[row].file_idx].start_row), 'no fold toggled')
end)

h.test('gd to an unchanged file opens it in the code window', function()
  vim.api.nvim_set_current_win(s.diff_win)
  local row, col = find_row('src/cart.ts', 'formatCurrency(this')
  vim.api.nvim_win_set_cursor(s.diff_win, { row, col })
  view.definition()
  wait_cursor_change(s.diff_win, s.diff_buf, row)
  local buf = vim.api.nvim_get_current_buf()
  h.ok(vim.api.nvim_buf_get_name(buf):match('src/format%.ts$'), vim.api.nvim_buf_get_name(buf))
  local line = vim.api.nvim_get_current_line()
  h.ok(line:find('export function formatCurrency', 1, true), line)
  h.eq(s.code_win, vim.api.nvim_get_current_win())
end)

h.test('K shows hover for a context line', function()
  vim.api.nvim_set_current_win(s.diff_win)
  local row, col = find_row('src/math.ts', 'multiply(PI_ISH')
  vim.api.nvim_win_set_cursor(s.diff_win, { row, col })
  view.hover()
  local float
  vim.wait(10000, function()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then
        float = w
        return true
      end
    end
  end, 50)
  h.ok(float, 'hover float opened')
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), '\n')
  h.ok(text:find('multiply', 1, true), text)
end)

h.test('lines that differ in the working tree are not mapped', function()
  local lsp = require('revuey.lsp')
  local buf = lsp.file_buffer(fixture .. '/src/cart.ts')
  h.eq(nil, lsp.match_line(buf, 3, 'this line does not exist'))
  h.eq(3, lsp.match_line(buf, 3, 'import { capitalize } from "./text";'))
  -- no nearest-identical-line guessing: a different line number is not a match
  h.eq(nil, lsp.match_line(buf, 9, 'import { capitalize } from "./text";'))
end)

-- Regression (finding 2): with uncommitted edits above the definition, the LSP's working-tree
-- line must be mapped back to the right diff row (by text), not treated as a HEAD line number.
h.test('gd with a dirty working tree lands on the right diff row', function()
  require('revuey.view').close()
  local dirty = h.tmpdir('dirty-fixture')
  vim.fn.delete(dirty, 'rf')
  assert(h.make_fixture(dirty).code == 0)
  local path = dirty .. '/src/math.ts'
  local lines = vim.fn.readfile(path)
  table.insert(lines, 1, '// uncommitted 1')
  table.insert(lines, 1, '// uncommitted 2')
  table.insert(lines, 1, '// uncommitted 3')
  vim.fn.writefile(lines, path)
  s = h.open_review({ cwd = dirty })
  local row, col = find_row('src/cart.ts', 'sum(this')
  -- a cold server under load may answer from cart.ts's own import before its project has
  -- loaded; what matters is where `gd` lands once it has, so retry (bounded) until math.ts
  local r
  local deadline = vim.uv.now() + 30000
  repeat
    vim.api.nvim_set_current_win(s.diff_win)
    vim.api.nvim_win_set_cursor(s.diff_win, { row, col })
    view.definition()
    wait_cursor_change(s.diff_win, s.diff_buf, row)
    h.eq(s.diff_win, vim.api.nvim_get_current_win())
    r = vim.api.nvim_win_get_cursor(s.diff_win)[1]
    local e = s.layout.map[r]
    local landed = e and e.file_idx and s.review.files[e.file_idx].path == 'src/math.ts'
    if not landed then
      vim.wait(500)
    end
  until landed or vim.uv.now() > deadline
  h.ok(s.layout.lines[r]:find('export function sum', 1, true), s.layout.lines[r])
end)


-- Working-tree mode (default): gd from lines that only exist on disk, and from a buffer with
-- unsaved edits above the definition.
h.test('gd on an uncommitted (untracked) line, and with unsaved buffer edits', function()
  require('revuey.view').close()
  local d = h.tmpdir('wt-lsp-fixture')
  vim.fn.delete(d, 'rf')
  assert(h.make_fixture(d).code == 0)
  h.write(d, 'src/extra.ts', 'import { sum } from "./math";\nexport const total = sum([1, 2]);\n')
  s = h.open_review({ cwd = d })
  h.eq('worktree', s.review.mode)
  vim.api.nvim_set_current_win(s.diff_win)
  local row, col = find_row('src/extra.ts', 'sum([1')
  vim.api.nvim_win_set_cursor(s.diff_win, { row, col })
  view.definition()
  wait_cursor_change(s.diff_win, s.diff_buf, row)
  local r = vim.api.nvim_win_get_cursor(s.diff_win)[1]
  h.ok(s.layout.lines[r]:find('export function sum', 1, true), s.layout.lines[r])

  -- unsaved edits in math.ts shift the LSP's coordinates; mapping goes through the buffer text
  local mbuf = require('revuey.lsp').file_buffer(d .. '/src/math.ts')
  vim.api.nvim_buf_set_lines(mbuf, 0, 0, false, { '// unsaved 1', '// unsaved 2' })
  vim.wait(600) -- the LSP client debounces didChange (150ms) before the server sees the edit
  vim.api.nvim_set_current_win(s.diff_win)
  row, col = find_row('src/cart.ts', 'sum(this')
  vim.api.nvim_win_set_cursor(s.diff_win, { row, col })
  view.definition()
  wait_cursor_change(s.diff_win, s.diff_buf, row)
  r = vim.api.nvim_win_get_cursor(s.diff_win)[1]
  h.ok(s.layout.lines[r]:find('export function sum', 1, true), s.layout.lines[r])
  vim.api.nvim_buf_set_lines(mbuf, 0, 2, false, {})
  vim.bo[mbuf].modified = false
end)

h.test('gd inside the guide view jumps to a definition shown in the guide', function()
  h.use_fake_claude(h.tmpdir('lsp-fake-claude') .. '/calls.ndjson')
  local _, restore_notify = h.capture_notify()
  view.guide_command(true)
  assert(vim.wait(20000, function()
    return next(require('revuey.guide_view').jobs) == nil and s.guide.resolved ~= nil
  end, 20), 'guide generated')
  restore_notify()
  h.eq('guide', s.view_mode)
  vim.api.nvim_set_current_win(s.diff_win)
  local row, col = find_row('src/cart.ts', 'sum(this')
  h.eq('guide', s.layout.kind)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, col })
  view.definition()
  wait_cursor_change(s.diff_win, s.diff_buf, row)
  h.eq(s.diff_win, vim.api.nvim_get_current_win())
  local r = vim.api.nvim_win_get_cursor(s.diff_win)[1]
  local e = s.layout.map[r]
  h.eq('src/math.ts', s.review.files[e.file_idx].path)
  h.ok(s.layout.lines[r]:find('export function sum', 1, true), s.layout.lines[r])
  h.ok(e.section_idx, 'landed inside a guide section')
  -- K on a prose line is refused politely, never an error
  local msgs, restore = h.capture_notify()
  vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
  view.hover()
  restore()
  h.ok(msgs[1] and msgs[1].msg:find('added and context lines only', 1, true))
end)

h.run()
