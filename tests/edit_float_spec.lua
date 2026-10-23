-- Integration: the edit float (`ge`) on fixture repos. Opening it from the diff and the guide,
-- editing and saving (refresh, cursor, LSP), refusals on other layers and modes, deleted lines,
-- the unsaved-close question, guide re-anchoring with the "edited since guide" marker, comments
-- following an edit, one buffer per file, and nothing leaking into the user's windows.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')

local log = h.tmpdir('edit-fake-claude') .. '/calls.ndjson'
h.use_fake_claude(log)

vim.o.columns, vim.o.lines = 160, 50
local state_dir = h.tmpdir('edit-float-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local view = require('revuey.view')
local ef = require('revuey.edit_float')
local edit = require('revuey.edit')
local lsp = require('revuey.lsp')
local gv = require('revuey.guide_view')
local units = require('revuey.units')
local review_mod = require('revuey.review')
local comments = require('revuey.comments')

local function make(name, flag)
  local d = h.tmpdir(name)
  vim.fn.delete(d, 'rf')
  local args = { h.root .. '/scripts/make-fixture.sh' }
  if flag then
    args[#args + 1] = flag
  end
  args[#args + 1] = d
  local res = vim.system(args, { text = true }):wait()
  assert(res.code == 0, res.stderr)
  return d
end

local function open(dir, opts)
  if ef.current then
    ef.close({ force = true })
  end
  if view.session then
    view.close()
  end
  return h.open_review(vim.tbl_extend('force', { cwd = dir }, opts or {}))
end

local function idle(s)
  assert(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
  end, 10), 'refresh did not finish')
end

---Wait until the review re-rendered after a save (BufWritePost refresh is debounced).
local function wait_render(s, n)
  assert(vim.wait(10000, function()
    return s.render_count > n and not s.refreshing and not s.pending
  end, 10), 'no refresh after the save')
end

local function row_of(s, path, needle, kind)
  for row, e in ipairs(s.layout.map) do
    local f = s.review.files[e.file_idx or 0]
    if f and f.path == path and (not kind or e.kind == kind or e.meta == kind) and s.layout.lines[row]:find(needle, 1, true) then
      return row
    end
  end
  error('no row: ' .. path .. ' ' .. needle)
end

---Press `k` in the diff window with the cursor on `row`; returns the messages shown.
local function press(s, row, k)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  local msgs, restore = h.capture_notify()
  vim.api.nvim_feedkeys(vim.keycode(k or 'ge'), 'mtx', false)
  restore()
  return msgs
end

local function msg_text(msgs)
  return table.concat(vim.tbl_map(function(m)
    return m.msg
  end, msgs), '\n')
end

---Buffers whose file is `abs` (by real path).
local function buffers_for(abs)
  local real = vim.uv.fs_realpath(abs)
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name ~= '' and (vim.uv.fs_realpath(name) or name) == real then
      out[#out + 1] = b
    end
  end
  return out
end

local function float_line()
  return vim.api.nvim_get_current_line()
end

local fixture = make('edit-fixture')
local math_abs = fixture .. '/src/math.ts'

h.test('ge on an added line opens the real file in a float, folded to the hunk', function()
  local s = open(fixture)
  local row = row_of(s, 'src/math.ts', 'export function sum', 'add')
  local diff_fm = vim.wo[s.diff_win].foldmethod
  local msgs = press(s, row)
  h.eq('', msg_text(msgs))
  local st = ef.current
  h.ok(st, 'float open')
  h.eq(st.win, vim.api.nvim_get_current_win())
  local cfg = vim.api.nvim_win_get_config(st.win)
  h.eq('win', cfg.relative)
  h.eq(' src/math.ts:3-25 ', cfg.title[1][1])
  -- the real file buffer: the one :edit gives, listed, editable, not revuey's hidden buffer
  h.eq(vim.uv.fs_realpath(math_abs), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(st.buf)))
  h.eq({ true, '', true, 'typescript' }, { vim.bo[st.buf].buflisted, vim.bo[st.buf].buftype, vim.bo[st.buf].modifiable, vim.bo[st.buf].filetype })
  h.eq(false, lsp.is_hidden(st.buf))
  h.eq(1, #buffers_for(math_abs), 'one buffer for the file')
  -- the cursor is on the same line of the file
  h.eq('export function sum(values: readonly number[]): number {', float_line())
  h.eq(s.layout.map[row].new_lnum, vim.api.nvim_win_get_cursor(st.win)[1])
  -- window-local manual folds around the hunk plus 3 lines of context; the diff window untouched
  h.eq('manual', vim.wo[st.win].foldmethod)
  local count = vim.api.nvim_buf_line_count(st.buf)
  h.eq(25, count)
  vim.api.nvim_win_call(st.win, function()
    h.eq(-1, vim.fn.foldclosed(1), 'the hunk starts at line 3: no fold above')
    h.eq(-1, vim.fn.foldclosed(25))
  end)
  h.eq(diff_fm, vim.wo[s.diff_win].foldmethod)
  -- q closes it and goes back to the review
  vim.api.nvim_feedkeys('q', 'mtx', false)
  vim.wait(500, function()
    return ef.current == nil
  end, 10)
  h.eq(nil, ef.current)
  h.eq(false, vim.api.nvim_win_is_valid(st.win))
  h.eq(s.diff_win, vim.api.nvim_get_current_win())
  h.eq('', vim.fn.reg_recording(), 'q did not start a recording')
end)

h.test('a hunk far into a file is folded around; context lines and hunk headers open too', function()
  local s = view.session
  -- src/index.ts: open from the hunk header
  local f, fi
  for i, x in ipairs(s.review.files) do
    if x.path == 'src/index.ts' then
      f, fi = x, i
    end
  end
  local header = s.layout.files[fi].hunk_rows[#s.layout.files[fi].hunk_rows]
  press(s, header)
  local st = assert(ef.current, 'float open from a hunk header')
  local h_last = f.hunks[#f.hunks]
  local lo, hi = edit.hunk_range(h_last)
  h.eq(lo, vim.api.nvim_win_get_cursor(st.win)[1])
  vim.api.nvim_win_call(st.win, function()
    if lo - 3 > 1 then
      h.eq(1, vim.fn.foldclosed(1), 'lines above the context are folded')
      h.eq(lo - 4, vim.fn.foldclosedend(1))
    end
    h.eq(-1, vim.fn.foldclosed(lo))
    h.eq(-1, vim.fn.foldclosed(hi))
  end)
  ef.close()
  -- a context line
  local ctx = row_of(s, 'src/math.ts', 'Multiply two numbers', 'ctx')
  press(s, ctx)
  h.eq('/** Multiply two numbers. */', float_line())
  ef.close()
end)

h.test('prose and meta rows say why; a deleted line opens at the nearest new-side line', function()
  local s = view.session
  local msgs = press(s, s.layout.files[1].start_row)
  h.eq(nil, ef.current)
  h.eq(edit.msg.row(), msg_text(msgs))
  local del = row_of(s, 'src/math.ts', 'let result = 0;', 'del')
  msgs = press(s, del)
  local st = assert(ef.current, 'float open at a deleted line')
  h.ok(msg_text(msgs):find("deleted lines can't be edited", 1, true), msg_text(msgs))
  h.eq(s.layout.map[del].anchor_lnum, vim.api.nvim_win_get_cursor(st.win)[1])
  h.eq('  return a * b;', float_line())
  ef.close()
  -- a deleted file
  msgs = press(s, row_of(s, 'src/legacy.ts', '', 'del'))
  h.eq(nil, ef.current)
  h.eq(edit.msg.deleted_file(), msg_text(msgs))
end)

h.test('edit and :w: the diff refreshes, the review cursor stays on the hunk; one buffer', function()
  local s = view.session
  local row = row_of(s, 'src/math.ts', 'return values.reduce', 'add')
  press(s, row)
  local st = assert(ef.current)
  -- type a new line below the cursor, as a user would
  vim.api.nvim_feedkeys('o  // edited in the float' .. vim.keycode('<Esc>'), 'mtx', false)
  h.eq(true, vim.bo[st.buf].modified)
  local n = s.render_count
  vim.cmd('silent write')
  wait_render(s, n)
  h.eq(false, vim.bo[st.buf].modified)
  local new = row_of(s, 'src/math.ts', '// edited in the float', 'add')
  h.eq(new, vim.api.nvim_win_get_cursor(s.diff_win)[1], 'review cursor on the edited line')
  h.eq(st.win, vim.api.nvim_get_current_win(), 'the float stays open and focused')
  -- <C-s> saves too, also from insert mode
  local lnum = vim.api.nvim_win_get_cursor(st.win)[1]
  vim.api.nvim_buf_set_lines(st.buf, lnum, lnum, false, { '  // and again' })
  n = s.render_count
  vim.api.nvim_feedkeys('A' .. vim.keycode('<C-s>'), 'mtx', false)
  vim.cmd('stopinsert')
  wait_render(s, n)
  h.eq(false, vim.bo[st.buf].modified)
  h.ok(row_of(s, 'src/math.ts', '// and again', 'add'))
  h.eq(1, #buffers_for(math_abs))
  ef.close()
  -- reopening after the edit maps through the new file: the same line, the new hunk range
  press(s, row_of(s, 'src/math.ts', '// and again', 'add'))
  h.eq('  // and again', float_line())
  ef.close()
end)

h.test('closing with unsaved changes: cancel keeps it open, discard reverts, save writes', function()
  local s = view.session
  local disk = vim.fn.readfile(math_abs)
  local row = row_of(s, 'src/math.ts', 'export function sum', 'add')
  local asked = {}
  local answers = {}
  ef.ask = function(msg)
    asked[#asked + 1] = msg
    return table.remove(answers, 1)
  end
  press(s, row)
  local st = assert(ef.current)
  vim.api.nvim_buf_set_lines(st.buf, 0, 0, false, { '// unsaved' })
  -- cancel (and <Esc> asks like q)
  answers = { 3 }
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'mtx', false)
  vim.wait(200, function()
    return #asked > 0
  end, 10)
  h.eq({ 'Save changes to src/math.ts?' }, asked)
  h.ok(vim.api.nvim_win_is_valid(st.win), 'still open')
  h.eq(true, vim.bo[st.buf].modified)
  -- discard: back to the file, buffer unmodified, nothing written
  answers = { 2 }
  vim.api.nvim_feedkeys('q', 'mtx', false)
  vim.wait(200, function()
    return ef.current == nil
  end, 10)
  h.eq(false, vim.api.nvim_win_is_valid(st.win))
  h.eq(false, vim.bo[st.buf].modified)
  h.eq(disk, vim.api.nvim_buf_get_lines(st.buf, 0, -1, false))
  h.eq(disk, vim.fn.readfile(math_abs))
  -- save: written, then closed; the review refreshes
  press(s, row)
  st = assert(ef.current)
  vim.api.nvim_buf_set_lines(st.buf, 0, 0, false, { '// saved on close' })
  answers = { 1 }
  local n = s.render_count
  vim.api.nvim_feedkeys('q', 'mtx', false)
  vim.wait(200, function()
    return ef.current == nil
  end, 10)
  h.eq('// saved on close', vim.fn.readfile(math_abs)[1])
  wait_render(s, n)
  h.ok(row_of(s, 'src/math.ts', '// saved on close', 'add'))
  ef.ask = function()
    error('unexpected question')
  end
end)

h.test('the file already open and modified elsewhere: the same buffer, its edits kept', function()
  local s = view.session
  local code = view.code_window(s)
  vim.api.nvim_set_current_win(code)
  vim.cmd('edit ' .. vim.fn.fnameescape(math_abs))
  local user_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(user_buf, 0, 0, false, { '// the user was here' })
  h.eq(true, vim.bo[user_buf].modified)
  local row = row_of(s, 'src/math.ts', 'export function sum', 'add')
  press(s, row)
  local st = assert(ef.current)
  h.eq(user_buf, st.buf, 'the same buffer, not a duplicate')
  h.eq(1, #buffers_for(math_abs))
  -- mapped through the unsaved line above: still the same code line
  h.eq('export function sum(values: readonly number[]): number {', float_line())
  vim.api.nvim_buf_set_lines(st.buf, 1, 1, false, { '// float edit' })
  ef.ask = function()
    return 2
  end
  ef.close()
  h.eq('// the user was here', vim.api.nvim_buf_get_lines(user_buf, 0, 1, false)[1], 'the earlier edit stays')
  h.eq(nil, vim.tbl_contains(vim.api.nvim_buf_get_lines(user_buf, 0, -1, false), '// float edit') or nil)
  h.eq(true, vim.bo[user_buf].modified)
  -- q in the user's own window is not the float's: it records a macro as usual
  vim.api.nvim_set_current_win(code)
  vim.api.nvim_feedkeys('qa', 'mtx', false)
  h.eq('a', vim.fn.reg_recording())
  vim.api.nvim_feedkeys('q', 'mtx', false)
  h.eq('', vim.fn.reg_recording())
  -- no folds or float options leaked into the user's window
  h.eq(false, vim.wo[code].number)
  vim.api.nvim_win_call(code, function()
    h.eq(0, vim.fn.foldlevel(1))
  end)
  vim.api.nvim_buf_call(user_buf, function()
    vim.cmd('silent edit!')
  end)
  vim.api.nvim_win_close(code, true)
  ef.ask = function()
    error('unexpected question')
  end
end)

h.test('options and folds of the float never reach the next window showing the file', function()
  local lines = {}
  for i = 1, 40 do
    lines[i] = 'line ' .. i
  end
  local base = table.concat(lines, '\n') .. '\n'
  lines[20] = 'line twenty'
  local repo = h.repo('edit-long', { ['long.txt'] = base }, { ['long.txt'] = table.concat(lines, '\n') .. '\n' })
  local s = open(repo)
  press(s, row_of(s, 'long.txt', 'line twenty', 'add'))
  local st = assert(ef.current)
  vim.api.nvim_win_call(st.win, function()
    h.eq({ 1, 13 }, { vim.fn.foldclosed(1), vim.fn.foldclosedend(1) })
    h.eq({ 27, 40 }, { vim.fn.foldclosed(40), vim.fn.foldclosedend(40) })
    h.eq(-1, vim.fn.foldclosed(14))
    h.eq(-1, vim.fn.foldclosed(26))
    -- the user can scroll out: open the folds as usual
    vim.cmd('normal! zR')
    h.eq(-1, vim.fn.foldclosed(1))
  end)
  h.eq(' long.txt:17-23 ', vim.api.nvim_win_get_config(st.win).title[1][1])
  vim.cmd('quit') -- :q in the float, not q
  h.eq(nil, ef.current)
  vim.cmd('tabnew')
  vim.cmd('buffer ' .. st.buf)
  h.eq(false, vim.wo.number)
  h.eq(0, vim.fn.foldlevel(1))
  h.eq(0, vim.fn.foldlevel(vim.fn.line('$')))
  h.eq('', vim.fn.maparg('q', 'n'), 'the close key is gone from the buffer')
  vim.cmd('tabclose')
end)

h.test('refusals: committed mode, a layer that is not checked out, a remote read-only layer', function()
  local s = open(fixture)
  view.toggle_mode()
  idle(s)
  h.eq('committed', s.review.mode)
  local msgs = press(s, row_of(s, 'src/math.ts', 'export function sum', 'add'))
  h.eq(nil, ef.current)
  h.eq('revuey: this is the committed-only view; switch to working-tree mode (gu) to edit', msg_text(msgs))
  view.toggle_mode()
  idle(s)

  local stack = make('edit-stack', '--stack')
  s = open(stack, { base = '' })
  h.eq('stack/cart', s.review.stack.layers[s.review.stack.current].name)
  -- the checked-out layer works
  press(s, s.layout.hunks[1].first_change)
  h.ok(ef.current, 'float on the @ layer')
  ef.close()
  -- the layer below
  view.set_scope({ kind = 'layer', index = 1 })
  idle(s)
  msgs = press(s, s.layout.hunks[1].first_change)
  h.eq(nil, ef.current)
  h.eq("revuey: stack/math isn't checked out; press gS to switch", msg_text(msgs))
  -- full stack with HEAD (stack/cart) below the top: committed-only
  view.toggle_full()
  idle(s)
  h.eq('full', s.scope.kind)
  msgs = press(s, s.layout.hunks[1].first_change)
  h.eq("revuey: stack/ui isn't checked out; press gS to switch", msg_text(msgs))

  local remote = make('edit-remote', '--remote-stack') .. '/review'
  s = open(remote, { base = '' })
  local st = s.review.stack
  h.ok(st.layers[1].remote, 'remote layers')
  view.set_scope({ kind = 'layer', index = 1 })
  idle(s)
  msgs = press(s, s.layout.hunks[1].first_change)
  h.eq(nil, ef.current)
  h.eq(("revuey: %s isn't checked out; press gS to switch"):format(st.layers[1].name), msg_text(msgs))
end)

h.test('full stack with HEAD at the top: its own hunks edit, lower layers refuse', function()
  local stack = make('edit-stack-top', '--stack')
  h.git(stack, 'checkout', '-q', 'stack/ui')
  local s = open(stack, { scope = 'full' })
  h.eq('full', s.scope.kind)
  h.ok(s.review.layer_labels, 'labels')
  local own, other
  for _, hk in ipairs(s.layout.hunks) do
    local e = s.layout.map[hk.row]
    local names = s.review.layer_labels[e.file_idx][edit.hunk_index(e)]
    if names and #names == 1 and names[1] == 'stack/ui' then
      own = own or hk.first_change
    elseif names and not vim.tbl_contains(names, 'stack/ui') then
      other = other or { hk.first_change, names[1] }
    end
  end
  h.ok(own and other, 'hunks of both kinds')
  press(s, own)
  h.ok(ef.current, 'the top layer is checked out')
  ef.close()
  local msgs = press(s, other[1])
  h.eq(nil, ef.current)
  h.ok(msg_text(msgs):find(other[2] .. ", which isn't checked out", 1, true), msg_text(msgs))
end)

h.test('guide: ge from a guide hunk; an edited hunk keeps its section, marked, mark reset', function()
  local d = make('edit-guide')
  local s = open(d)
  -- mark src/math.ts's hunk reviewed in the diff first
  local mrow = row_of(s, 'src/math.ts', 'export function sum', 'add')
  vim.api.nvim_win_set_cursor(s.diff_win, { mrow, 0 })
  view.toggle_reviewed()
  local fi
  for i, f in ipairs(s.review.files) do
    if f.path == 'src/math.ts' then
      fi = i
    end
  end
  h.eq({ 1, 1 }, { units.progress(s.review.state, units.of_hunk(review_mod.units(s.review), fi, 1)) })
  -- generate a guide with the fake claude
  vim.fn.delete(log)
  require('revuey.guide_view').errors = {}
  view.generate_guide()
  assert(vim.wait(20000, function()
    return next(gv.jobs) == nil
  end, 20), 'guide generation did not finish')
  idle(s)
  view.set_view('guide')
  h.eq('guide', s.view_mode)
  local res = s.guide.resolved
  h.eq(false, res.stale)
  local function section_of(path)
    for si, sec in ipairs(s.guide.resolved.sections) do
      for _, it in ipairs(sec.items) do
        if it.hunk.path == path then
          return si, sec.title, it
        end
      end
    end
  end
  local si, title = section_of('src/math.ts')
  -- ge on the hunk in the guide, change a line, save
  local grow = row_of(s, 'src/math.ts', 'return values.reduce', 'add')
  h.eq(si, s.layout.map[grow].section_idx)
  press(s, grow)
  local st = assert(ef.current, 'float from the guide')
  h.eq('  return values.reduce((acc, v) => add(acc, v), 0);', float_line())
  vim.api.nvim_set_current_line('  return values.reduce((acc, v) => acc + v, 0);')
  local n = s.render_count
  vim.cmd('silent write')
  wait_render(s, n)
  ef.close()
  local si2, title2, item = section_of('src/math.ts')
  h.eq({ si, title }, { si2, title2 }, 'still in its section')
  h.eq(true, item.edited)
  for _, sec in ipairs(s.guide.resolved.sections) do
    h.ok(sec.kind ~= 'new', 'no "Not in guide" section: ' .. sec.title)
  end
  -- the header shows the marker, the cursor is on the edited line in the guide
  local row = row_of(s, 'src/math.ts', 'acc + v', 'add')
  h.eq(row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  local header
  for r = row, 1, -1 do
    if s.layout.map[r].meta == 'hunk' then
      header = r
      break
    end
  end
  local ns = vim.api.nvim_get_namespaces()['revuey.diff']
  local virt = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, ns, { header - 1, 0 }, { header - 1, -1 }, { details = true })) do
    for _, ch in ipairs(m[4].virt_text or {}) do
      virt[#virt + 1] = ch[1]
    end
  end
  h.ok(table.concat(virt):find('edited since guide', 1, true), table.concat(virt))
  -- its reviewed mark reset (new content, new unit key)
  h.eq({ 0, 1 }, { units.progress(s.review.state, units.of_hunk(review_mod.units(s.review), fi, 1)) })
  -- the banner counts it
  h.ok(table.concat(vim.api.nvim_buf_get_lines(s.diff_buf, 0, -1, false), '\n'):find('1 hunk edited', 1, true))
end)

h.test('comments on edited lines re-anchor after the edit and the refresh', function()
  local d = make('edit-comments')
  local s = open(d)
  local editor = require('revuey.comment_editor')
  local row = row_of(s, 'src/math.ts', 'export const PI_ISH = Math.PI;', 'add')
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  vim.api.nvim_feedkeys('gc', 'mtx', false)
  local cst = assert(editor.current, 'comment editor')
  vim.api.nvim_buf_set_lines(cst.buf, 0, -1, false, { 'Why Math.PI?' })
  vim.api.nvim_feedkeys(vim.keycode('<C-s>'), 'mtx', false)
  local c
  for _, x in ipairs(comments.list(s.cm.store, {})) do
    if x.body == 'Why Math.PI?' then
      c = x
    end
  end
  assert(c, 'comment saved')
  local line0 = c.anchor.start_line
  -- insert two lines above it from the float, save
  press(s, row_of(s, 'src/math.ts', 'export function sum', 'add'))
  local st = assert(ef.current)
  vim.api.nvim_feedkeys('O// one' .. vim.keycode('<CR>') .. '// two' .. vim.keycode('<Esc>'), 'mtx', false)
  local n = s.render_count
  vim.cmd('silent write')
  wait_render(s, n)
  ef.close()
  local moved = comments.get(s.cm.store, c.id)
  h.eq(line0 + 2, moved.anchor.start_line, 'moved with its line')
  h.eq(false, moved.outdated)
  h.eq(line0 + 2, comments.read(s.cm.path).comments[c.id].anchor.start_line, 'persisted')
  -- now change the commented line itself: outdated (the existing rules)
  press(s, row_of(s, 'src/math.ts', 'export const PI_ISH = Math.PI;', 'add'))
  vim.api.nvim_set_current_line('export const PI_ISH = 3.14159;')
  n = s.render_count
  vim.cmd('silent write')
  wait_render(s, n)
  ef.close()
  h.eq(true, comments.get(s.cm.store, c.id).outdated)
end)

h.test('closing the review closes the float; the buffer keeps its unsaved changes', function()
  local s = open(fixture)
  press(s, row_of(s, 'src/math.ts', 'export function sum', 'add'))
  local st = assert(ef.current)
  vim.api.nvim_buf_set_lines(st.buf, 0, 0, false, { '// pending' })
  view.close()
  h.eq(nil, ef.current)
  h.eq(false, vim.api.nvim_win_is_valid(st.win))
  h.eq('// pending', vim.api.nvim_buf_get_lines(st.buf, 0, 1, false)[1])
  vim.api.nvim_buf_call(st.buf, function()
    vim.cmd('silent edit!')
  end)
end)

h.test('LSP works in the float, before and after a save (typescript-language-server)', function()
  if vim.fn.executable('typescript-language-server') ~= 1 then
    h.skip('typescript-language-server not on PATH')
  end
  vim.lsp.config('ts_ls', {
    cmd = { 'typescript-language-server', '--stdio' },
    filetypes = { 'typescript', 'typescriptreact' },
    root_markers = { 'tsconfig.json' },
  })
  -- Semantic tokens off: with them on, headless Neovim 0.12.4 on macOS crashes intermittently
  -- (SIGSEGV in augroup_del / aucmd_del_for_event_and_group) once a TypeScript buffer is shown
  -- in any window next to an open review, with or without the float. Not caused by the float;
  -- see the note in docs/TESTING.md.
  vim.lsp.semantic_tokens.enable(false)
  vim.lsp.enable('ts_ls')
  local d = make('edit-lsp')
  local s = open(d)
  press(s, row_of(s, 'src/math.ts', 'return values.reduce', 'add'))
  local st = assert(ef.current)
  local function hover_on(needle)
    local lnum = vim.fn.search(needle, 'nw')
    assert(lnum > 0, needle)
    local col = vim.fn.getline(lnum):find(needle, 1, true) - 1
    -- one async request at a time, polled from a single vim.wait (no nested event loops)
    local result, pending
    local deadline = vim.uv.now() + 20000
    while not result and vim.uv.now() < deadline do
      local client = vim.lsp.get_clients({ bufnr = st.buf, name = 'ts_ls' })[1]
      if client and client.initialized and not pending then
        pending = true
        client:request('textDocument/hover', {
          textDocument = { uri = vim.uri_from_bufnr(st.buf) },
          position = { line = lnum - 1, character = col },
        }, function(_, r)
          if r and r.contents then
            result = vim.inspect(r.contents)
          end
          pending = false
        end, st.buf)
      end
      vim.wait(300, function()
        return result ~= nil or not pending
      end, 20)
      if not result and not pending then
        vim.wait(300) -- the project is still loading: ask again shortly
      end
    end
    assert(result, 'no hover from ts_ls')
    return result
  end
  h.ok(hover_on('add(acc'):find('function add', 1, true))
  -- edit and save: the client stays attached and follows the new text
  vim.api.nvim_buf_set_lines(st.buf, 0, 0, false, { 'export const extra = 1;' })
  local n = s.render_count
  vim.cmd('silent write')
  wait_render(s, n)
  h.ok(hover_on('extra'):find('const extra', 1, true))
  ef.close()
  -- the server is left to Neovim's exit, as in lsp_spec.lua (force-stopping clients just before
  -- os.exit crashes Neovim 0.12)
end)

h.teardown(function()
  if ef.current then
    ef.close({ force = true })
  end
  if view.session then
    view.close()
  end
end)

h.run()
