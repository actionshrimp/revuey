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
  h.eq({ { start_row = 2, end_row = 6 } }, l.blocks, 'one fold block per hunk')
  h.eq(6, layout.find_new_row(l, files, 'a.ts', 3))
  h.eq(nil, layout.find_new_row(l, files, 'a.ts', 99))
end)

h.test('fold levels: file folds, hunk folds and long context runs', function()
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
  -- the hunk (header row 2, lines 3..24) is a level-2 fold
  h.eq('>2', f[2])
  h.eq('2', f[3])
  -- ctx rows are 5..24; the run touches the end of the file, so fold from row 5+3=8 to 24
  h.eq('2', f[7])
  h.eq('>3', f[8])
  h.eq('3', f[24])
  h.eq('1', f[25])
end)

h.test('head rows (the PR description) come first; files, hunks and folds follow them', function()
  local files = diff.parse(text)
  local plain = layout.compose(files)
  local block = { url = 'u', number = 1, title = 't', start_row = 1, end_row = 6, fold = { 3, 5 } }
  local head = { rows = {}, blocks = { block } }
  for i, t in ipairs({ 'PR #1 · t', '  a', '  b', '  c', '  d', '' }) do
    head.rows[i] = { text = t, entry = { kind = 'prose', role = 'description', desc = block } }
  end
  local l = layout.compose(files, head)
  h.eq(6 + #plain.lines, #l.lines)
  h.eq(#l.lines, #l.map)
  h.eq('PR #1 · t', l.lines[1])
  h.eq(plain.lines, vim.list_slice(l.lines, 7))
  h.eq({ start_row = 1, end_row = 6, blocks = { block } }, l.description)
  h.eq({ start_row = 7, end_row = 13, hunk_rows = { 8 } }, l.files[1])
  h.eq({ { row = 8, file_idx = 1, first_change = 10 } }, l.hunks)
  h.eq({ { start_row = 8, end_row = 12 } }, l.blocks)
  h.eq(12, layout.find_new_row(l, files, 'a.ts', 3))
  h.eq(nil, plain.description)
  -- the description's fold (rows 3-5) is level 1 on its own; its other rows are not folded
  local f = layout.fold_levels(l, 12, 3)
  h.eq({ nil, nil, '>1', '1', '1', nil, '>1', '>2' }, { f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8] })
  -- an empty head is no head
  h.eq(nil, layout.compose(files, { rows = {}, blocks = {} }).description)
end)

h.test('replace_head: the same layout as composing with the new head, rows shifted by the delta', function()
  local files = diff.parse(text)
  local function head(n)
    local block = { url = 'u', number = 1, title = 't', start_row = 1, end_row = n }
    local h0 = { rows = {}, blocks = { block } }
    for i = 1, n do
      h0.rows[i] = { text = 'row ' .. i, entry = { kind = 'prose', role = 'description', desc = block } }
    end
    return n > 0 and h0 or nil
  end
  for _, case in ipairs({ { 0, 4 }, { 4, 7 }, { 7, 2 }, { 3, 0 }, { 0, 0 } }) do
    local from, to = case[1], case[2]
    local l, d, old_n = layout.replace_head(layout.compose(files, head(from)), head(to))
    h.eq(layout.compose(files, head(to)), l, from .. ' -> ' .. to)
    h.eq({ to - from, from }, { d, old_n })
  end
  -- rows appended after compose (the empty review's notes) are kept
  local empty = layout.compose({}, head(2))
  empty.lines[#empty.lines + 1] = 'No changes'
  empty.map[#empty.map + 1] = { kind = 'meta', meta = 'note', file_idx = 0, path = '' }
  local l = layout.replace_head(empty, head(5))
  h.eq({ 'row 1', 'row 2', 'row 3', 'row 4', 'row 5', 'No changes' }, l.lines)
end)

h.run()
