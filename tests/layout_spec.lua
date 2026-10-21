local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
local diff = require('revuey.diff')
local layout = require('revuey.layout')

local text = table.concat({
  'diff --git a/a.ts b/a.ts',
  'index ' .. string.rep('a', 40) .. '..' .. string.rep('b', 40) .. ' 100644',
  '--- a/a.ts',
  '+++ b/a.ts',
  '@@ -1,3 +1,3 @@',
  ' one',
  '-two',
  '+TWO',
  ' three',
  'diff --git a/b.bin b/b.bin',
  'index ' .. string.rep('a', 40) .. '..' .. string.rep('b', 40) .. ' 100644',
  'Binary files a/b.bin and b/b.bin differ',
  '',
}, '\n')

h.test('composes lines with side table', function()
  local files = diff.parse(text)
  local l = layout.compose(files)
  h.eq({ 'a.ts', '@@ -1,3 +1,3 @@', 'one', 'two', 'TWO', 'three', '', 'b.bin', 'Binary file not shown', '' }, l.lines)
  h.eq(#l.lines, #l.map)
  h.eq('file', l.map[1].meta)
  h.eq('hunk', l.map[2].meta)
  h.eq('a.ts#1', l.map[2].hunk_id)
  h.eq({ 'ctx', 1, 1 }, { l.map[3].kind, l.map[3].old_lnum, l.map[3].new_lnum })
  h.eq({ 'del', 2, nil }, { l.map[4].kind, l.map[4].old_lnum, l.map[4].new_lnum })
  h.eq(2, l.map[4].anchor_lnum, 'deleted line anchors to following new line')
  h.eq({ 'add', nil, 2 }, { l.map[5].kind, l.map[5].old_lnum, l.map[5].new_lnum })
  h.eq('a.ts#1', l.map[5].hunk_id)
  h.eq({ start_row = 1, end_row = 7, hunk_rows = { 2 } }, l.files[1])
  h.eq({ start_row = 8, end_row = 10, hunk_rows = {} }, l.files[2])
  h.eq({ { row = 2, file_idx = 1, first_change = 4 } }, l.hunks)
  h.eq(6, layout.find_new_row(l, files, 'a.ts', 3))
  h.eq(nil, layout.find_new_row(l, files, 'a.ts', 99))
end)

h.test('fold levels: file folds and long context runs', function()
  local lines = { 'diff --git a/x b/x', 'index ' .. string.rep('a', 40) .. '..' .. string.rep('b', 40), '--- a/x', '+++ b/x' }
  lines[#lines + 1] = '@@ -1,21 +1,21 @@'
  lines[#lines + 1] = '-old'
  lines[#lines + 1] = '+new'
  for i = 2, 21 do
    lines[#lines + 1] = ' ctx' .. i
  end
  local files = diff.parse(table.concat(lines, '\n') .. '\n')
  local l = layout.compose(files)
  local f = layout.fold_levels(l, 12, 3)
  h.eq('>1', f[1])
  h.eq('1', f[2])
  -- ctx rows are 5..24; the run touches the end of the file, so fold from row 5+3=8 to 24
  h.eq('1', f[7])
  h.eq('>2', f[8])
  h.eq('2', f[24])
  h.eq('1', f[25])
end)

h.run()
