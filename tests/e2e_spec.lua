-- End-to-end: open a review of the fixture repo headlessly and inspect buffers/extmarks.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
h.add_parsers_rtp()
vim.cmd('runtime plugin/revuey.lua')

local fixture = h.fixture()
require('revuey').setup({ state_dir = h.tmpdir('e2e-state'), lsp_warmup = false })

local function open()
  local session
  require('revuey').open({ cwd = fixture, base = 'main', on_ready = function(s)
    session = s
  end })
  vim.wait(5000, function()
    return session ~= nil
  end, 10)
  assert(session, 'review did not open')
  return session
end

local s = open()
local view = require('revuey.view')

local function lines()
  return vim.api.nvim_buf_get_lines(s.diff_buf, 0, -1, false)
end

h.test('diff buffer lists every changed file with headers', function()
  local l = lines()
  local headers = {}
  for row, e in ipairs(s.layout.map) do
    if e.meta == 'file' then
      headers[#headers + 1] = l[row]
    end
  end
  table.sort(headers)
  h.eq({
    'assets/logo.png',
    'src/cart.ts',
    'src/components/Total.tsx',
    'src/index.ts',
    'src/legacy.ts',
    'src/math.ts',
    'src/utils/strings.ts → src/text.ts',
  }, headers)
  h.eq(false, vim.bo[s.diff_buf].modifiable)
end)

h.test('buffer text equals source text for add/ctx/del lines', function()
  local git = require('revuey.git')
  local l = lines()
  local checked = 0
  for row, e in ipairs(s.layout.map) do
    local f = s.review.files[e.file_idx]
    if e.kind == 'add' or e.kind == 'ctx' then
      local src = vim.split(git.blob(f.new_blob, fixture), '\n', { plain = true })
      h.eq(src[e.new_lnum], l[row], f.path)
      checked = checked + 1
    elseif e.kind == 'del' then
      local src = vim.split(git.blob(f.old_blob, fixture), '\n', { plain = true })
      h.eq(src[e.old_lnum], l[row], f.path)
      checked = checked + 1
    end
  end
  h.ok(checked > 50, 'checked ' .. checked)
end)

h.test('diff background and word-diff extmarks exist', function()
  local ns = vim.api.nvim_get_namespaces()['revuey.diff']
  local marks = vim.api.nvim_buf_get_extmarks(s.diff_buf, ns, 0, -1, { details = true })
  local groups = {}
  for _, m in ipairs(marks) do
    local d = m[4]
    if d.line_hl_group then
      groups[d.line_hl_group] = (groups[d.line_hl_group] or 0) + 1
    end
    if d.hl_group then
      groups[d.hl_group] = (groups[d.hl_group] or 0) + 1
    end
  end
  h.ok((groups.RevueyAdd or 0) >= 50, vim.inspect(groups))
  h.ok((groups.RevueyDelete or 0) >= 15, vim.inspect(groups))
  h.ok((groups.RevueyFileHeader or 0) == 7, vim.inspect(groups))
  -- Regression (finding 4): word diff is computed lazily while drawing, not as extmarks for the
  -- whole review at render time.
  h.eq(nil, groups.RevueyAddText, vim.inspect(groups))
  h.eq(nil, groups.RevueyDeleteText, vim.inspect(groups))
end)

h.test('word diff spans are computed lazily per row', function()
  local found_add, found_del
  for row, e in ipairs(s.layout.map) do
    local spans = s.word_spans(row - 1)
    if spans then
      for _, sp in ipairs(spans) do
        if sp[3] == 'RevueyAddText' then
          found_add = s.layout.lines[row]:sub(sp[1] + 1, sp[2])
        elseif sp[3] == 'RevueyDeleteText' then
          found_del = s.layout.lines[row]:sub(sp[1] + 1, sp[2])
        end
      end
    end
  end
  h.ok(found_add and found_del, 'expected word spans')
end)

h.test('statuscolumn and winbar render', function()
  vim.g.statusline_winid = s.diff_win
  local add_row
  for row, e in ipairs(s.layout.map) do
    if e.kind == 'add' then
      add_row = row
      break
    end
  end
  vim.v.lnum = add_row -- luacheck: ignore
  local sc = view.statuscolumn()
  h.ok(sc:find('+', 1, true), sc)
  local wb = view.winbar()
  h.ok(wb:find('RevueyFilePath', 1, true), wb)
end)

h.test('projected tree-sitter highlights for ts, tsx and old side', function()
  local syntax = require('revuey.syntax')
  if not syntax.lang_for_path('a.ts') then
    h.skip('no typescript parser installed, or no typescript highlights query bundled with Neovim')
  end
  local found = {}
  for _, f in ipairs(s.review.files) do
    syntax.load_sync(s.review.root, f, 'new')
    syntax.load_sync(s.review.root, f, 'old')
  end
  for row, e in ipairs(s.layout.map) do
    local spans = syntax.spans_for_row(s, row - 1)
    if spans and #spans > 0 then
      local f = s.review.files[e.file_idx]
      found[f.path .. ':' .. e.kind] = true
      for _, sp in ipairs(spans) do
        h.ok(sp[2] <= #s.layout.lines[row], 'span within line')
      end
    end
  end
  h.ok(found['src/cart.ts:add'], vim.inspect(found))
  h.ok(found['src/legacy.ts:del'], vim.inspect(found))
  h.ok(found['src/math.ts:ctx'], vim.inspect(found))
  if syntax.lang_for_path('a.tsx') then
    h.ok(found['src/components/Total.tsx:add'], vim.inspect(found))
  end
  -- unknown languages degrade to no highlighting
  h.eq(nil, syntax.lang_for_path('assets/logo.png'))
end)

h.test('navigation: next hunk / next file', function()
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
  view.next_hunk(1)
  local row = vim.api.nvim_win_get_cursor(s.diff_win)[1]
  h.ok(s.layout.map[row].kind ~= 'ctx' and s.layout.map[row].kind ~= 'meta', 'lands on a change')
  local before = s.layout.map[row].file_idx
  view.next_file(1)
  row = vim.api.nvim_win_get_cursor(s.diff_win)[1]
  h.eq('file', s.layout.map[row].meta)
  h.eq(before + 1, s.layout.map[row].file_idx)
  view.next_file(-1)
  h.eq(before, s.layout.map[vim.api.nvim_win_get_cursor(s.diff_win)[1]].file_idx)
end)

h.test('toggle reviewed persists, folds file and updates panel', function()
  vim.api.nvim_set_current_win(s.diff_win)
  local fi = 2
  vim.api.nvim_win_set_cursor(s.diff_win, { s.layout.files[fi].start_row, 0 })
  view.toggle_reviewed()
  local f = s.review.files[fi]
  h.ok(require('revuey.review').is_reviewed(s.review, f))
  local start = s.layout.files[fi].start_row
  h.eq(start, vim.api.nvim_win_call(s.diff_win, function()
    return vim.fn.foldclosed(start)
  end))
  local panel_lines = vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
  h.ok(panel_lines[s.panel_rows[fi]]:find('✓', 1, true), panel_lines[s.panel_rows[fi]])
  h.ok(panel_lines[2]:find('✓ 1/7', 1, true), panel_lines[2])
  -- reopening the review restores the mark (and the fold)
  s = open()
  h.ok(require('revuey.review').is_reviewed(s.review, s.review.files[fi]))
  local start2 = s.layout.files[fi].start_row
  h.eq(start2, vim.api.nvim_win_call(s.diff_win, function()
    return vim.fn.foldclosed(start2)
  end))
end)

h.test('focus-panel key does not shadow <Tab>/<C-i>', function()
  local maps = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(s.diff_buf, 'n')) do
    maps[m.lhs] = true
  end
  h.eq(nil, maps['<Tab>'])
  h.ok(maps['gp'], vim.inspect(vim.tbl_keys(maps)))
end)

-- Regression (lower-confidence item): gd/K with no LSP for the filetype must fail fast.
h.test('gd without any LSP fails fast with a message', function()
  vim.api.nvim_set_current_win(s.diff_win)
  for row, e in ipairs(s.layout.map) do
    if e.kind == 'add' and s.review.files[e.file_idx].path == 'src/cart.ts' then
      vim.api.nvim_win_set_cursor(s.diff_win, { row, 2 })
      break
    end
  end
  local msgs, restore = h.capture_notify()
  local t0 = vim.uv.now()
  view.definition()
  vim.wait(4000, function()
    return #msgs > 0
  end, 20)
  restore()
  h.ok(#msgs > 0 and msgs[1].msg:find('LSP', 1, true), vim.inspect(msgs))
  h.ok(vim.uv.now() - t0 < 4000)
end)

local function session_autocmds()
  local ok, list = pcall(vim.api.nvim_get_autocmds, { group = 'revuey_session' })
  return ok and #list or 0
end

-- Regression (finding 9 + lower-confidence cleanup items).
h.test('close removes the tab, autocmds, hidden LSP buffers and syntax cache', function()
  local tabs = #vim.api.nvim_list_tabpages()
  h.ok(session_autocmds() > 0)
  require('revuey.lsp').file_buffer(fixture .. '/src/math.ts')
  view.close()
  h.eq(tabs - 1, #vim.api.nvim_list_tabpages())
  h.eq(nil, view.session)
  h.eq(0, session_autocmds())
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    h.ok(not (name:find(fixture, 1, true) and vim.api.nvim_buf_is_loaded(b)), 'still loaded: ' .. name)
  end
  h.eq(0, require('revuey.syntax').cache_size())
end)

h.test('wiping the review via :tabclose also cleans up', function()
  s = open()
  h.ok(session_autocmds() > 0)
  vim.cmd('tabclose')
  h.eq(nil, view.session)
  h.eq(0, session_autocmds())
end)

-- Regression (finding 5): an empty review shows a message and actions don't error.
h.test('empty review shows a friendly message and actions are safe', function()
  local es = h.open_review({ cwd = fixture, base = 'HEAD' })
  h.eq(0, #es.review.files)
  local text = table.concat(vim.api.nvim_buf_get_lines(es.diff_buf, 0, -1, false), '\n')
  h.ok(text:find('No changes between HEAD and the working tree', 1, true), text)
  vim.api.nvim_set_current_win(es.diff_win)
  local msgs, restore = h.capture_notify()
  for _, fn in ipairs({ 'open_file', 'definition', 'hover', 'toggle_reviewed', 'next_file', 'next_hunk' }) do
    local ok, err = pcall(view[fn], 1)
    h.ok(ok, fn .. ': ' .. tostring(err))
  end
  restore()
  h.ok(pcall(vim.api.nvim_eval, "v:lua.require'revuey.view'.winbar()"))
  view.close()
end)

-- Regression (finding 7 + no-EOL item): line-ending-only changes get a visible indicator.
h.test('EOL-only changes and missing final newline are annotated', function()
  local repo = h.repo('eol', { ['crlf.txt'] = 'a\nb\n', ['noeol.txt'] = 'x\ny\n' }, {
    ['crlf.txt'] = 'a\r\nb\r\n',
    ['noeol.txt'] = 'x\ny',
  })
  local es = h.open_review({ cwd = repo })
  local ns = vim.api.nvim_get_namespaces()['revuey.diff']
  local notes = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(es.diff_buf, ns, 0, -1, { details = true })) do
    local vt = m[4].virt_text
    if vt and vt[1][1]:find('⏎', 1, true) then
      notes[#notes + 1] = es.layout.lines[m[2] + 1] .. ' |' .. vt[1][1]
    end
  end
  table.sort(notes)
  h.eq({
    'a |  ⏎ line ending: LF → CRLF',
    'b |  ⏎ line ending: LF → CRLF',
    'y |  ⏎ line ending: LF → no newline at EOF',
  }, notes)
  view.close()
end)

-- Regression (review 2, high 2): definition targets map to the diff by position only.
local function dup_repo()
  local base = {}
  for i = 1, 60 do
    base[i] = (i == 5 or i == 50) and 'export function render() {' or ('const v' .. i .. ' = ' .. i .. ';')
  end
  local new = vim.deepcopy(base)
  new[52] = 'const changed = 1;'
  return h.repo('dups', { ['a.ts'] = table.concat(base, '\n') .. '\n' }, { ['a.ts'] = table.concat(new, '\n') .. '\n' })
end

h.test('clean tree: duplicate line outside the diff does not jump into the diff', function()
  local repo = dup_repo()
  local ds = h.open_review({ cwd = repo })
  h.eq(nil, view.diff_row_for_location(ds, repo .. '/a.ts', 5), 'line 5 is not shown; open the real file')
  local r = view.diff_row_for_location(ds, repo .. '/a.ts', 50)
  h.ok(r, 'line 50 is shown as context')
  h.eq(50, ds.layout.map[r].new_lnum)
  h.eq(nil, view.diff_row_for_location(ds, repo .. '/a.ts', 20), 'changed file, line outside the diff')
  view.close()
end)

h.test('dirty tree: working-tree lines map to HEAD lines by diff, not by text', function()
  local repo = dup_repo()
  local ds = h.open_review({ cwd = repo })
  local lines = vim.fn.readfile(repo .. '/a.ts')
  table.insert(lines, 1, '// b')
  table.insert(lines, 1, '// a')
  vim.fn.writefile(lines, repo .. '/a.ts')
  h.eq(nil, view.diff_row_for_location(ds, repo .. '/a.ts', 7), 'wt 7 = HEAD 5, not in the diff')
  local r = view.diff_row_for_location(ds, repo .. '/a.ts', 52)
  h.ok(r, 'wt 52 = HEAD 50, shown as context')
  h.eq(50, ds.layout.map[r].new_lnum)
  h.eq(nil, view.diff_row_for_location(ds, repo .. '/a.ts', 1), 'uncommitted line')
  -- forward direction (diff -> working tree) for LSP requests
  local lsp = require('revuey.lsp')
  local buf = lsp.file_buffer(repo .. '/a.ts')
  local head = require('revuey.git').blob(ds.review.files[1].new_blob, repo)
  h.eq(52, lsp.match_line(buf, 50, 'export function render() {', head))
  h.eq(7, lsp.match_line(buf, 5, 'export function render() {', head))
  view.close()
end)

h.test('R refresh picks up a new commit', function()
  local repo = h.repo('refresh', { ['a.txt'] = 'one\n' }, { ['a.txt'] = 'two\n' })
  local rs = h.open_review({ cwd = repo })
  h.eq(1, #rs.review.files)
  h.write(repo, 'b.txt', 'new file\n')
  h.git(repo, 'add', '-A')
  h.git(repo, 'commit', '-q', '-m', 'more')
  local msgs, restore = h.capture_notify()
  view.refresh()
  vim.wait(5000, function()
    return #rs.review.files == 2
  end, 10)
  restore()
  h.eq(2, #rs.review.files)
  h.ok(table.concat(vim.api.nvim_buf_get_lines(rs.diff_buf, 0, -1, false), '\n'):find('new file', 1, true))
  h.eq(rs, view.session)
  view.close()
end)

-- Regression (review 2): closing while a parse is in flight must not error or leak timers.
h.test('closing the review mid-parse is clean', function()
  local parts = {}
  for i = 1, 20000 do
    parts[#parts + 1] = ('local function f%d(a) return "x%d" end'):format(i, i)
  end
  local repo = h.repo('midparse', { ['x.lua'] = 'local x = 1\n' }, { ['big.lua'] = table.concat(parts, '\n') .. '\n' })
  local function active_timers()
    local set = {}
    vim.uv.walk(function(hd)
      if hd:get_type() == 'timer' and hd:is_active() then
        set[hd] = true
      end
    end)
    return set
  end
  local before = active_timers()
  local ms = h.open_review({ cwd = repo })
  local syntax = require('revuey.syntax')
  local big
  for _, f in ipairs(ms.review.files) do
    if f.path == 'big.lua' then
      big = f
    end
  end
  local errors = {}
  local orig = vim.notify
  vim.notify = function(m, l)
    if l == vim.log.levels.ERROR then
      errors[#errors + 1] = m
    end
  end
  vim.v.errmsg = ''
  syntax.get(ms.review.root, big, 'new')
  vim.wait(30) -- let the blob load start
  view.close()
  vim.wait(2000)
  vim.notify = orig
  h.eq({}, errors)
  h.eq('', vim.v.errmsg)
  h.eq(0, syntax.cache_size())
  h.eq(0, syntax.pending())
  -- No timer started during the test is still running (older timers may finish meanwhile).
  local leaked = 0
  for hd in pairs(active_timers()) do
    if not before[hd] then
      leaked = leaked + 1
    end
  end
  h.eq(0, leaked, 'timers started during the test are still active')
end)

h.test('origin/main and main share review state', function()
  h.git(fixture, 'remote', 'add', 'origin', fixture)
  h.git(fixture, 'fetch', '-q', 'origin')
  local r = require('revuey.review')
  local a = assert(r.load({ cwd = fixture, base = 'main' }))
  local b = assert(r.load({ cwd = fixture, base = 'origin/main' }))
  h.eq(a.state._path, b.state._path)
end)

h.run()
