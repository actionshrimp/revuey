-- Folders in the file panel. Unit: grouping and order (folders.lua), the common prefix, fish-style
-- abbreviation. Integration: the panel's headers and file rows, the diff and ]f following the
-- panel's order, j/k over headers, <CR> on a header, the winbar hint on one, a common prefix, a
-- narrow panel, the dimmed all-reviewed folder, and `panel_folders = false`.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
vim.notify = function() end

local folders = require('revuey.folders')

local function paths(files)
  return vim.tbl_map(function(f)
    return f.path
  end, files)
end

local function of(list)
  return vim.tbl_map(function(p)
    return { path = p }
  end, list)
end

-- ---------------------------------------------------------------------------
-- Unit
-- ---------------------------------------------------------------------------

h.test('order: folders contiguous in tree order (root first, a folder before its subfolders), names sorted', function()
  -- git's path order: `api-client` sorts between `api/src` and `api/test` ('-' < '/')
  local git_order = {
    'Makefile', 'README.md', 'packages/api-client/index.ts', 'packages/api/src/routes/refunds.ts',
    'packages/api/src/routes/billing.ts', 'packages/api/src/server.ts', 'packages/api/test/billing.test.ts',
  }
  h.eq({
    'Makefile', 'README.md',
    'packages/api/src/server.ts',
    'packages/api/src/routes/billing.ts', 'packages/api/src/routes/refunds.ts',
    'packages/api/test/billing.test.ts',
    'packages/api-client/index.ts',
  }, paths(folders.order(of(git_order))))
  -- a new list; the input is untouched
  local input = of({ 'b/x', 'a' })
  local out = folders.order(input)
  h.eq({ 'b/x', 'a' }, paths(input))
  h.eq({ 'a', 'b/x' }, paths(out))
  h.eq({}, folders.order({}))
  -- dots and unicode: plain component comparison
  h.eq({ '.github/ci.yml', 'docs/日本語/a.md', 'src/v1.2/x.ts', 'src/v1.2/y.ts' },
    paths(folders.order(of({ 'src/v1.2/y.ts', 'docs/日本語/a.md', '.github/ci.yml', 'src/v1.2/x.ts' }))))
end)

h.test('groups: runs of one folder, root as ""', function()
  h.eq({
    { dir = '', first = 1, last = 2 },
    { dir = 'a', first = 3, last = 3 },
    { dir = 'a/b', first = 4, last = 5 },
  }, folders.groups(of({ 'x', 'y', 'a/z', 'a/b/1', 'a/b/2' })))
  h.eq({ { dir = 'only/here', first = 1, last = 1 } }, folders.groups(of({ 'only/here/f.ts' })))
  h.eq({}, folders.groups({}))
end)

h.test('common_prefix: what every folder shares, keeping a component of each; none for one folder or root files', function()
  h.eq('src', folders.common_prefix({ 'src/app', 'src/lib' }))
  h.eq('packages/api', folders.common_prefix({ 'packages/api/src', 'packages/api/src/routes', 'packages/api/test' }))
  -- `src` itself is a folder: it keeps its name
  h.eq('', folders.common_prefix({ 'src', 'src/components' }))
  h.eq('src', folders.common_prefix({ 'src/a', 'src/a/b' }))
  h.eq('', folders.common_prefix({ '', 'src/a' }))
  h.eq('', folders.common_prefix({ 'a/x', 'b/x' }))
  -- one folder: dropping its prefix would only add a line
  h.eq('', folders.common_prefix({ 'deep/single/folder' }))
  h.eq('', folders.common_prefix({}))
  -- components, not characters
  h.eq('', folders.common_prefix({ 'src-old/a', 'src/b' }))
  h.eq('a/日本', folders.common_prefix({ 'a/日本/x', 'a/日本/y' }))
end)

h.test('abbreviate: fish style from the root side, then first/…/last, …/last, the leaf cut', function()
  local p = 'packages/api/src/routes' -- 23 cells
  h.eq(p, folders.abbreviate(p, 40))
  h.eq(p, folders.abbreviate(p, 23))
  h.eq('packages/a/src/routes', folders.abbreviate(p, 22))
  h.eq('packages/a/s/routes', folders.abbreviate(p, 20))
  h.eq('packages/a/s/routes', folders.abbreviate(p, 19))
  h.eq('packages/…/routes', folders.abbreviate(p, 18))
  h.eq('…/routes', folders.abbreviate(p, 16))
  h.eq('…/routes', folders.abbreviate(p, 8))
  h.eq('…tes', folders.abbreviate(p, 4))
  h.eq('…', folders.abbreviate(p, 1))
  h.eq('', folders.abbreviate(p, 0))
  -- very deep: one component at a time, furthest from the leaf first
  local deep = 'alpha/bravo/charlie/delta/echo' -- 30
  h.eq('alpha/b/charlie/delta/echo', folders.abbreviate(deep, 29))
  h.eq('alpha/b/c/delta/echo', folders.abbreviate(deep, 25))
  h.eq('alpha/b/c/d/echo', folders.abbreviate(deep, 19))
  h.eq('alpha/…/echo', folders.abbreviate(deep, 15))
  -- dotted names keep the dot and a letter; dots inside a name are plain characters
  h.eq('a/.c/nvim/lua', folders.abbreviate('a/.config/nvim/lua', 17))
  h.eq('src/v/lib.d', folders.abbreviate('src/v1.2.3/lib.d', 12))
  -- unicode: by character and display width (CJK is two cells)
  local u = 'docs/日本語/ガイド/end' -- 22 cells
  h.eq('docs/日/ガイド/end', folders.abbreviate(u, 21))
  h.eq('docs/日/ガ/end', folders.abbreviate(u, 15))
  h.eq('docs/…/end', folders.abbreviate(u, 13))
  h.eq('…ド', folders.abbreviate('日本語/ガイド', 3))
  -- one or two components: nothing in the middle to shorten
  h.eq('…ryname', folders.abbreviate('verylongdirectoryname', 7))
  h.eq('…/defghij', folders.abbreviate('abc/defghij', 10))
  h.eq('…defghij', folders.abbreviate('abc/defghij', 8))
  -- whatever the width, the result fits
  for _, path in ipairs({ p, deep, u, '.github/workflows', 'a/b', 'x' }) do
    for w = 0, 32 do
      local a = folders.abbreviate(path, w)
      h.ok(vim.api.nvim_strwidth(a) <= w, ('%s at %d: %s'):format(path, w, a))
    end
  end
end)

h.test('order and groups stay fast: 3000 files in 330 folders', function()
  local list = {}
  for i = 1, 3000 do
    list[#list + 1] = ('pkg%d/sub%d/file%d.ts'):format(i % 30, i % 11, i)
  end
  local t = vim.uv.hrtime()
  local g = folders.groups(folders.order(of(list)))
  local ms = (vim.uv.hrtime() - t) / 1e6
  h.eq(330, #g)
  h.ok(ms < 500, ('took %.1fms'):format(ms))
end)

-- ---------------------------------------------------------------------------
-- Integration
-- ---------------------------------------------------------------------------

local state_dir = h.tmpdir('folders-state')
local function setup(extra)
  require('revuey').setup(vim.tbl_extend('force', { state_dir = state_dir, lsp_warmup = false, forge = { enabled = false } }, extra or {}))
end
setup()
local view = require('revuey.view')
local panel = require('revuey.panel')
local key_help = require('revuey.key_help')
local review_mod = require('revuey.review')

local mono = h.repo('folders-mono', {
  ['README.md'] = 'r\n',
  ['packages/api/src/server.ts'] = 's\n',
  ['packages/api/src/routes/billing.ts'] = 'b\n',
  ['packages/api/test/billing.test.ts'] = 't\n',
}, {
  ['README.md'] = 'r2\n',
  ['Makefile'] = 'all:\n',
  ['packages/api/src/server.ts'] = 's2\n',
  ['packages/api/src/routes/billing.ts'] = 'b2\n',
  ['packages/api/src/routes/refunds.ts'] = 'new\n',
  ['packages/api/test/billing.test.ts'] = 't2\n',
  ['packages/api-client/index.ts'] = 'c\n',
})

local under_src = h.repo('folders-src', {
  ['src/app/a.ts'] = 'a\n',
}, {
  ['src/app/a.ts'] = 'a2\n',
  ['src/app/b.ts'] = 'b\n',
  ['src/lib/c.ts'] = 'c\n',
})

local function open(dir, opts)
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

local function lines(s)
  return vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
end

---The file list: from the first header or file row to the last file row.
local function file_list(s)
  local first, last = math.huge, 0
  for row in pairs(s.panel_files) do
    first, last = math.min(first, row), math.max(last, row)
  end
  for row in pairs(s.panel_dirs) do
    first = math.min(first, row)
  end
  return vim.list_slice(lines(s), first, last)
end

---The file list as shown: each row with its right-aligned virtual text at the window's edge.
local function shown(s)
  local ns = vim.api.nvim_get_namespaces()['revuey.panel']
  local first = math.huge
  for row in pairs(s.panel_dirs) do
    first = math.min(first, row)
  end
  local out = {}
  for i, l in ipairs(file_list(s)) do
    local row = first + i - 1
    local virt = ''
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      for _, c in ipairs(m[4].virt_text or {}) do
        virt = virt .. c[1]
      end
    end
    local gap = vim.api.nvim_win_get_width(s.panel_win) - vim.api.nvim_strwidth(l) - vim.api.nvim_strwidth(virt)
    out[i] = virt == '' and l or (l .. string.rep(' ', gap) .. virt)
  end
  return out
end

local function header_row(s, dir)
  for row, g in pairs(s.panel_dirs) do
    if g.dir == dir then
      return row
    end
  end
  error('no header for ' .. dir)
end

---In the panel, go to `row` (CursorMoved runs, as it would for the user), then type `k`.
local function panel_keys(s, row, k)
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_win_set_cursor(s.panel_win, { row, 0 })
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.panel_buf })
  if k then
    vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
    idle(s)
  end
end

---Type a motion in the panel; CursorMoved runs.
local function move(s, k)
  vim.api.nvim_feedkeys(k, 'mtx', false)
  vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.panel_buf })
end

local function hl_at(s, row, col)
  local ns = vim.api.nvim_get_namespaces()['revuey.panel']
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    if m[3] == col and m[4].hl_group then
      return m[4].hl_group
    end
  end
end

local ORDER = {
  'Makefile', 'README.md', 'packages/api/src/server.ts', 'packages/api/src/routes/billing.ts',
  'packages/api/src/routes/refunds.ts', 'packages/api/test/billing.test.ts', 'packages/api-client/index.ts',
}

h.test('panel: a header per folder, its files indented under it with name, status and counts', function()
  local s = open(mono)
  h.eq(ORDER, paths(s.review.files))
  h.eq({
    ' ./',
    '     A  Makefile                   +1 −0',
    '     M  README.md                  +1 −1',
    ' packages/api/src:',
    '     M  server.ts                  +1 −1',
    ' packages/api/src/routes:',
    '     M  billing.ts                 +1 −1',
    '     A  refunds.ts                 +1 −0',
    ' packages/api/test:',
    '     M  billing.test.ts            +1 −1',
    ' packages/api-client:',
    '     A  index.ts                   +1 −0',
  }, shown(s))
  -- headers are labels: not files
  h.eq(nil, s.panel_files[header_row(s, 'packages/api/src')])
  h.eq('RevueyPanelFolder', hl_at(s, header_row(s, 'packages/api/src'), 1))
end)

h.test('the diff and ]f follow the panel order', function()
  local s = view.session
  -- the diff draws the files in that order
  for fi = 2, #ORDER do
    h.ok(s.layout.files[fi].start_row > s.layout.files[fi - 1].start_row)
  end
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
  local function at_cursor()
    return s.review.files[s.layout.map[vim.api.nvim_win_get_cursor(s.diff_win)[1]].file_idx].path
  end
  local visited = { at_cursor() }
  for _ = 2, #ORDER do
    vim.api.nvim_feedkeys(']f', 'mtx', false)
    visited[#visited + 1] = at_cursor()
  end
  h.eq(ORDER, visited)
  -- the panel's rows go down in the same order
  for fi = 2, #ORDER do
    h.ok(s.panel_rows[fi] > s.panel_rows[fi - 1])
  end
end)

h.test('j/k land on a header harmlessly; <CR> there shows its first file; mr there does nothing', function()
  local s = view.session
  local routes = header_row(s, 'packages/api/src/routes')
  -- on server.ts (the row above the routes header), then j onto the header
  panel_keys(s, routes - 1)
  h.eq(3, s.current_file)
  move(s, 'j')
  h.eq(routes, vim.api.nvim_win_get_cursor(s.panel_win)[1])
  h.eq(3, s.current_file, 'the header previews nothing')
  move(s, 'j')
  h.eq(4, s.current_file, 'on to billing.ts')
  move(s, 'k')
  h.eq(routes, vim.api.nvim_win_get_cursor(s.panel_win)[1])
  h.eq(4, s.current_file)
  -- mr on the header: no marks
  vim.api.nvim_feedkeys('mr', 'mtx', false)
  idle(s)
  for fi = 1, #s.review.files do
    h.eq(0, (review_mod.file_progress(s.review, fi)))
  end
  -- <CR>: the folder's first file, in the diff
  panel_keys(s, header_row(s, 'packages/api/test'), '<CR>')
  h.eq(s.diff_win, vim.api.nvim_get_current_win())
  h.eq(6, s.current_file)
  h.eq(s.layout.files[6].start_row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
end)

h.test('hint: on a header the diff winbar names <CR> and the folder\'s full path', function()
  local s = view.session
  local function winbar()
    vim.g.statusline_winid = s.diff_win
    return vim.api.nvim_eval_statusline(view.winbar(), { winid = s.diff_win, use_winbar = true, maxwidth = 200 }).str
  end
  panel_keys(s, header_row(s, 'packages/api/src/routes'))
  h.eq({ { key = '<CR>', label = 'first file in packages/api/src/routes/' } }, key_help.current(s, s.diff_win))
  h.ok(winbar():find('<CR> first file in packages/api/src/routes/', 1, true), winbar())
  panel_keys(s, header_row(s, ''))
  h.eq({ { key = '<CR>', label = 'first file in ./' } }, key_help.current(s, s.diff_win))
  -- on a file row, and once the diff has focus: no folder hint
  panel_keys(s, s.panel_rows[1])
  h.eq({}, key_help.current(s, s.diff_win))
  panel_keys(s, header_row(s, ''))
  vim.api.nvim_set_current_win(s.diff_win)
  h.ok(not winbar():find('first file in', 1, true), winbar())
end)

h.test('a redraw keeps the panel cursor on its header', function()
  local s = view.session
  local row = header_row(s, 'packages/api-client')
  panel_keys(s, row)
  panel.render(s, { keep_view = true })
  h.eq(row, vim.api.nvim_win_get_cursor(s.panel_win)[1])
end)

h.test('a folder whose files are all reviewed is dimmed', function()
  local s = view.session
  local routes = header_row(s, 'packages/api/src/routes')
  h.eq('RevueyPanelFolder', hl_at(s, routes, 1))
  panel_keys(s, s.panel_rows[4], 'mr')
  h.eq('RevueyPanelFolder', hl_at(s, header_row(s, 'packages/api/src/routes'), 1), 'one of two')
  panel_keys(s, s.panel_rows[5], 'mr')
  h.eq('RevueyUnreviewed', hl_at(s, header_row(s, 'packages/api/src/routes'), 1))
  h.eq('RevueyPanelFolder', hl_at(s, header_row(s, 'packages/api/src'), 1), 'its parent is its own folder')
  panel_keys(s, s.panel_rows[5], 'mr')
  h.eq('RevueyPanelFolder', hl_at(s, header_row(s, 'packages/api/src/routes'), 1))
end)

h.test('narrow panel: headers abbreviated fish style; every line fits', function()
  local s = view.session
  vim.api.nvim_win_set_width(s.panel_win, 22)
  panel.render(s)
  local list = file_list(s)
  -- 20 cells for a header and its colon
  h.ok(vim.tbl_contains(list, ' packages/a/s/routes:'), table.concat(list, '\n'))
  h.ok(vim.tbl_contains(list, ' packages/api/src:'), table.concat(list, '\n'))
  h.ok(vim.tbl_contains(list, ' packages/api-client:'), table.concat(list, '\n'))
  vim.api.nvim_win_set_width(s.panel_win, 19)
  panel.render(s)
  list = file_list(s)
  h.ok(vim.tbl_contains(list, ' packages/…/routes:'), table.concat(list, '\n'))
  h.ok(vim.tbl_contains(list, ' packages/api/test:'), table.concat(list, '\n'))
  vim.api.nvim_win_set_width(s.panel_win, 18)
  panel.render(s)
  list = file_list(s)
  h.ok(vim.tbl_contains(list, ' packages/a/test:'), table.concat(list, '\n'))
  vim.api.nvim_win_set_width(s.panel_win, 14)
  panel.render(s)
  list = file_list(s)
  h.ok(vim.tbl_contains(list, ' …/routes:'), table.concat(list, '\n'))
  for _, l in ipairs(list) do
    h.ok(vim.api.nvim_strwidth(l) <= 14, l)
  end
  -- the hint still has the whole path
  panel_keys(s, header_row(s, 'packages/api/src/routes'))
  h.eq('first file in packages/api/src/routes/', key_help.current(s, s.diff_win)[1].label)
  vim.api.nvim_win_set_width(s.panel_win, 40)
end)

h.test('a leading folder every file shares is dropped from the headers and named once above them', function()
  local s = open(under_src)
  h.eq({ ' in src/', ' app:' }, vim.list_slice(lines(s), header_row(s, 'src/app') - 1, header_row(s, 'src/app')))
  h.eq(' lib:', lines(s)[header_row(s, 'src/lib')])
  panel_keys(s, header_row(s, 'src/lib'))
  h.eq('first file in src/lib/', key_help.current(s, s.diff_win)[1].label)
end)

h.test('a single file: its folder as the header, no prefix line', function()
  local one = h.repo('folders-one', { ['a/b/c.ts'] = '1\n' }, { ['a/b/c.ts'] = '2\n' })
  local s = open(one)
  local list = file_list(s)
  h.eq(' a/b:', list[1])
  h.eq(2, #list)
  h.ok(not table.concat(lines(s), '\n'):find(' in a', 1, true))
end)

h.test('a large review (400 files in 40 folders): a panel redraw stays fast, its headers cached', function()
  local changes = {}
  for i = 1, 400 do
    changes[('svc%d/layer%d/f%03d.ts'):format(i % 8, i % 5, i)] = ('export const v%d = %d;\n'):format(i, i)
  end
  local s = open(h.repo('folders-large', { ['keep.txt'] = 'k\n' }, changes))
  h.eq(400, #s.review.files)
  h.eq(40, vim.tbl_count(s.panel_dirs))
  local cache = s.panel_folder_cache
  local t = vim.uv.hrtime()
  for _ = 1, 10 do
    panel.render(s)
  end
  local ms = (vim.uv.hrtime() - t) / 1e6 / 10
  io.write(('    (panel redraw, 400 files: %.1fms)\n'):format(ms))
  h.ok(ms < 150, ('a redraw took %.1fms'):format(ms))
  h.ok(s.panel_folder_cache == cache, 'headers computed once per file list and width')
  view.close()
end)

h.test('panel_folders = false: one flat list in git order, folders after names, no headers', function()
  setup({ panel_folders = false })
  local s = open(mono)
  h.eq({
    'Makefile', 'README.md', 'packages/api-client/index.ts', 'packages/api/src/routes/billing.ts',
    'packages/api/src/routes/refunds.ts', 'packages/api/src/server.ts', 'packages/api/test/billing.test.ts',
  }, paths(s.review.files))
  h.eq({}, s.panel_dirs)
  local list = file_list(s)
  h.eq(7, #list)
  h.ok(vim.startswith(list[3], '   A  index.ts  ') and list[3]:find('api-client', 1, true), list[3])
  h.eq('RevueyPanelDir', hl_at(s, s.panel_rows[3], #'   A  index.ts'))
  -- the rows still map to files
  panel_keys(s, s.panel_rows[4], '<CR>')
  h.eq(4, s.current_file)
  setup()
  view.close()
end)

h.run()
