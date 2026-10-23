-- Integration: folding. <Tab> on title lines (file headers, hunk headers, guide section headings and
-- guide hunk headers) toggles that block; elsewhere <Tab> stays <C-i> (jumplist forward). `mr`
-- folds every kind of file and section, including the last one.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
vim.notify = function() end

local log = h.tmpdir('fold-fake-claude') .. '/calls.ndjson'
h.use_fake_claude(log)

require('revuey').setup({ state_dir = h.tmpdir('fold-state'), lsp_warmup = false })
local view = require('revuey.view')
local review_mod = require('revuey.review')
local gv = require('revuey.guide_view')

local function numbered(prefix, n)
  local t = {}
  for i = 1, n do
    t[#t + 1] = prefix .. i
  end
  return table.concat(t, '\n') .. '\n'
end

-- every file kind: added (committed and untracked, the untracked one sorting last), deleted,
-- renamed, binary, and modified with two hunks
local long = numbered('line ', 40)
local long2 = long:gsub('line 3\n', 'line three\n'):gsub('line 35\n', 'line thirty-five\n')
-- the same edit twice in one file: two identical hunks
local dup = 'a\nb\nc\nd\nX\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\na\nb\nc\nd\nX\ne\nf\ng\nh\n'
local repo = h.repo('fold-kinds', {
  ['dup.txt'] = dup,
  ['m.txt'] = long,
  ['d.txt'] = 'gone\nfor good\n',
  ['old.txt'] = 'same\nsame2\nsame3\n',
  ['bin.dat'] = 'x\0y',
}, {
  ['m.txt'] = long2,
  ['dup.txt'] = (dup:gsub('X', 'Y')),
  ['d.txt'] = false,
  ['a.txt'] = 'new\nfile\nhere\n',
  ['bin.dat'] = 'x\0z',
})
h.git(repo, 'mv', 'old.txt', 'new.txt')
h.git(repo, 'commit', '-qm', 'rename')
h.write(repo, 'zz_new.txt', 'untracked\nadded\nfile\n')

local function idle(s)
  assert(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
  end, 10), 'refresh did not finish')
end

local function keys(s, k)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
  idle(s)
end

local function closed_at(s, row)
  return vim.api.nvim_win_call(s.diff_win, function()
    return vim.fn.foldclosed(row)
  end)
end

local function cursor(s)
  return vim.api.nvim_win_get_cursor(s.diff_win)[1]
end

local function file_idx(s, path)
  for fi, f in ipairs(s.review.files) do
    if f.path == path then
      return fi
    end
  end
  error('no file ' .. path)
end

local function open()
  if view.session then
    view.close()
  end
  return h.open_review({ cwd = repo })
end

local s = open()

h.test('fixture has every file kind, an untracked added file last', function()
  local kinds = {}
  for _, f in ipairs(s.review.files) do
    kinds[#kinds + 1] = f.status .. ' ' .. f.path .. (f.binary and ' (binary)' or '')
  end
  h.eq({ 'A a.txt', 'M bin.dat (binary)', 'D d.txt', 'M dup.txt', 'M m.txt', 'R new.txt', 'A zz_new.txt' }, kinds)
  h.eq(2, #s.review.files[file_idx(s, 'm.txt')].hunks)
  h.eq(2, #s.review.files[file_idx(s, 'dup.txt')].hunks)
end)

h.test('<Tab> on a file header folds and unfolds the file without marking it', function()
  local fi = file_idx(s, 'm.txt')
  local row = s.layout.files[fi].start_row
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, '<Tab>')
  h.eq(row, closed_at(s, row))
  h.eq(row, cursor(s))
  h.eq(false, review_mod.is_reviewed(s.review, s.review.files[fi]))
  keys(s, '<Tab>')
  h.eq(-1, closed_at(s, row))
  -- a file without hunks (binary, pure rename) folds too
  for _, p in ipairs({ 'bin.dat', 'new.txt', 'zz_new.txt' }) do
    local r = s.layout.files[file_idx(s, p)].start_row
    vim.api.nvim_win_set_cursor(s.diff_win, { r, 0 })
    keys(s, '<Tab>')
    h.eq(r, closed_at(s, r), p)
    keys(s, '<Tab>')
    h.eq(-1, closed_at(s, r), p)
  end
  for _, f in ipairs(s.review.files) do
    h.eq(false, review_mod.is_reviewed(s.review, f), f.path)
  end
end)

h.test('<Tab> on a hunk header folds only that hunk; foldtext keeps the header', function()
  local fi = file_idx(s, 'm.txt')
  local r = s.layout.files[fi]
  local h1, h2 = r.hunk_rows[1], r.hunk_rows[2]
  vim.api.nvim_win_set_cursor(s.diff_win, { h2, 0 })
  keys(s, '<Tab>')
  h.eq(h2, closed_at(s, h2), 'second hunk folded')
  h.eq(-1, closed_at(s, r.start_row), 'file stays open')
  h.eq(-1, closed_at(s, h1), 'first hunk stays open')
  h.eq(-1, closed_at(s, h1 + 1))
  local ft = vim.api.nvim_win_call(s.diff_win, function()
    return vim.fn.foldtextresult(h2)
  end)
  h.ok(ft:find(s.layout.lines[h2], 1, true), ft)
  h.ok(ft:find('lines folded', 1, true), ft)
  -- ]c skips a collapsed hunk, like a collapsed file
  vim.api.nvim_win_set_cursor(s.diff_win, { h1, 0 })
  keys(s, ']c')
  keys(s, ']c')
  h.ok(cursor(s) < h2 or cursor(s) > r.end_row, 'did not land in the folded hunk: ' .. cursor(s))
  vim.api.nvim_win_set_cursor(s.diff_win, { h2, 0 })
  keys(s, '<Tab>')
  h.eq(-1, closed_at(s, h2))
  -- folding the file and unfolding it keeps the hunk folds as they were
  keys(s, '<Tab>')
  vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
  keys(s, '<Tab>')
  h.eq(r.start_row, closed_at(s, r.start_row))
  keys(s, '<Tab>')
  h.eq(-1, closed_at(s, r.start_row))
  h.eq(h2, closed_at(s, h2), 'hunk fold kept')
  vim.api.nvim_win_set_cursor(s.diff_win, { h2, 0 })
  keys(s, '<Tab>')
  h.eq(-1, closed_at(s, h2))
  h.eq(false, review_mod.is_reviewed(s.review, s.review.files[fi]))
end)

h.test('hunk folds survive a re-render that moves them', function()
  local fi = file_idx(s, 'm.txt')
  local h2 = s.layout.files[fi].hunk_rows[2]
  vim.api.nvim_win_set_cursor(s.diff_win, { h2, 0 })
  keys(s, '<Tab>')
  -- a.txt (above m.txt) grows, so every m.txt row moves down
  h.write(repo, 'a.txt', 'new\nfile\nhere\nand\nmore\n')
  keys(s, 'R')
  local moved = s.layout.files[file_idx(s, 'm.txt')].hunk_rows[2]
  h.eq(h2 + 2, moved)
  h.eq(moved, closed_at(s, moved))
  h.eq(-1, closed_at(s, s.layout.files[file_idx(s, 'm.txt')].hunk_rows[1]))
  h.write(repo, 'a.txt', 'new\nfile\nhere\n')
  keys(s, 'R')
  h2 = s.layout.files[file_idx(s, 'm.txt')].hunk_rows[2]
  h.eq(h2, closed_at(s, h2))
  vim.api.nvim_win_set_cursor(s.diff_win, { h2, 0 })
  keys(s, '<Tab>')
  h.eq(-1, closed_at(s, h2))
end)

-- grow a.txt (above every other file) so all later rows move, and re-render
local function shift_and_refresh(lines)
  h.write(repo, 'a.txt', lines or 'new\nfile\nhere\nand\nmore\n')
  keys(s, 'R')
end

local function m_rows()
  return s.layout.files[file_idx(s, 'm.txt')]
end

h.test('a collapsed hunk inside a collapsed file stays collapsed across a refresh', function()
  for _, how in ipairs({ 'tab', 'stab', 'mr' }) do
    local r = m_rows()
    vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[2], 0 })
    keys(s, '<Tab>')
    vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
    keys(s, how == 'tab' and '<Tab>' or how == 'stab' and '<S-Tab>' or 'mr')
    h.eq(r.start_row, closed_at(s, r.start_row), how)
    shift_and_refresh(how == 'mr' and 'new\nfile\nhere\n' or (how == 'tab' and 'x\n' or 'y\ny\n'))
    r = m_rows()
    h.eq(r.start_row, closed_at(s, r.start_row), how .. ': file still collapsed')
    vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
    if how == 'stab' then
      keys(s, '<S-Tab>')
    elseif how == 'mr' then
      keys(s, 'mr')
      vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
    else
      keys(s, '<Tab>')
    end
    h.eq(-1, closed_at(s, r.start_row), how .. ': file expanded')
    h.eq(r.hunk_rows[2], closed_at(s, r.hunk_rows[2]), how .. ': hunk still collapsed')
    h.eq(-1, closed_at(s, r.hunk_rows[1]), how .. ': other hunk open')
    vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[2], 0 })
    keys(s, '<Tab>')
    h.eq(-1, closed_at(s, r.hunk_rows[2]))
  end
  shift_and_refresh('new\nfile\nhere\n')
  for _, f in ipairs(s.review.files) do
    h.eq(false, review_mod.is_reviewed(s.review, f), f.path)
  end
end)

h.test('identical hunks in one file fold independently across a refresh', function()
  local r = s.layout.files[file_idx(s, 'dup.txt')]
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[1], 0 })
  keys(s, '<Tab>')
  shift_and_refresh()
  r = s.layout.files[file_idx(s, 'dup.txt')]
  h.eq(r.hunk_rows[1], closed_at(s, r.hunk_rows[1]), 'first stays collapsed')
  h.eq(-1, closed_at(s, r.hunk_rows[2]), 'second stays open')
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[1], 0 })
  keys(s, '<Tab>')
  shift_and_refresh('new\nfile\nhere\n')
end)

h.test('the cursor stays on a hunk header across a refresh', function()
  local r = m_rows()
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[2], 0 })
  keys(s, '<Tab>')
  shift_and_refresh()
  r = m_rows()
  h.eq(r.hunk_rows[2], cursor(s))
  h.eq(r.hunk_rows[2], closed_at(s, r.hunk_rows[2]))
  keys(s, '<Tab>')
  -- an open hunk header too
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[2], 0 })
  shift_and_refresh('new\nfile\nhere\n')
  h.eq(m_rows().hunk_rows[2], cursor(s))
end)

h.test('a count makes <Tab> jumplist-forward even on a title line', function()
  local r = m_rows()
  vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
  keys(s, '3<Tab>')
  h.eq(-1, closed_at(s, r.start_row), 'file not folded')
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[1], 0 })
  keys(s, '1<Tab>')
  h.eq(-1, closed_at(s, r.hunk_rows[1]), 'hunk not folded')
end)

h.test('<Tab> on a code line is <C-i>: jumplist forward, with a count', function()
  local a = s.layout.files[file_idx(s, 'a.txt')].start_row + 2 -- a code line
  h.eq('add', s.layout.map[a].kind)
  vim.api.nvim_win_set_cursor(s.diff_win, { a, 0 })
  vim.cmd('clearjumps')
  keys(s, ']c')
  local r2 = cursor(s)
  keys(s, ']c')
  local r3 = cursor(s)
  h.ok(r2 ~= a and r3 ~= r2, 'two jumps')
  keys(s, '<C-o>')
  h.eq(r2, cursor(s))
  keys(s, '<C-o>')
  h.eq(a, cursor(s))
  keys(s, '<Tab>')
  h.eq(r2, cursor(s), '<Tab> jumps forward')
  keys(s, '<C-o>')
  h.eq(a, cursor(s))
  keys(s, '2<Tab>')
  h.eq(r3, cursor(s), '2<Tab> jumps two forward')
  h.eq(-1, closed_at(s, s.layout.files[file_idx(s, 'm.txt')].start_row), 'no fold toggled')
end)

h.test('<S-Tab> folds every file, then unfolds every file', function()
  vim.api.nvim_win_set_cursor(s.diff_win, { s.layout.files[2].start_row + 1, 0 })
  keys(s, '<S-Tab>')
  for fi, r in ipairs(s.layout.files) do
    h.eq(r.start_row, closed_at(s, r.start_row), s.review.files[fi].path)
  end
  keys(s, '<S-Tab>')
  for fi, r in ipairs(s.layout.files) do
    h.eq(-1, closed_at(s, r.start_row), s.review.files[fi].path)
  end
  for _, f in ipairs(s.review.files) do
    h.eq(false, review_mod.is_reviewed(s.review, f), f.path)
  end
end)

h.test('mr folds every file kind, including the last file', function()
  for fi, f in ipairs(s.review.files) do
    local r = s.layout.files[fi]
    -- on the file header: the whole file (inside a hunk `mr` marks that hunk, see below)
    vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
    keys(s, 'mr')
    h.eq(true, review_mod.is_reviewed(s.review, f), f.path)
    h.eq(r.start_row, closed_at(s, r.start_row), f.status .. ' ' .. f.path .. ' folded')
  end
  for fi, f in ipairs(s.review.files) do
    local r = s.layout.files[fi]
    h.eq(r.start_row, closed_at(s, r.start_row), f.path .. ' still folded')
  end
  -- unmarking the last file unfolds it
  local last = #s.review.files
  vim.api.nvim_win_set_cursor(s.diff_win, { s.layout.files[last].start_row, 0 })
  keys(s, 'mr')
  h.eq(-1, closed_at(s, s.layout.files[last].start_row))
  keys(s, 'mr')
  h.eq(s.layout.files[last].start_row, closed_at(s, s.layout.files[last].start_row))
  -- unmark all for the guide tests
  for fi in ipairs(s.review.files) do
    review_mod.toggle_reviewed(s.review, s.review.files[fi])
  end
end)

-- Guide view: section 1 holds the modified/deleted/binary/renamed hunks, section 2 (the last) holds
-- only added files.
local function guide_view()
  local hunks = require('revuey.guide').hunks(s.review.files)
  local changed, added = {}, {}
  for _, hk in ipairs(hunks) do
    local f = s.review.files[hk.file_idx]
    table.insert(f.status == 'A' and added or changed, { id = hk.id })
  end
  local out = h.tmpdir('fold-guide') .. '/guide.json'
  local fd = assert(io.open(out, 'w'))
  fd:write(vim.json.encode({
    title = 'Fold guide',
    summary = 'Summary.',
    sections = {
      { title = 'Changes', overview = 'Edits.', hunks = changed },
      { title = 'New files', overview = 'Added files only.', hunks = added },
    },
    unplaced = {},
  }))
  fd:close()
  vim.env.REVUEY_FAKE_CLAUDE = nil
  vim.env.REVUEY_FAKE_CLAUDE_OUTPUT = out
  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb)
    vim.ui.select = orig
    cb('Generate a guide')
  end
  keys(s, 'gG')
  assert(vim.wait(20000, function()
    return next(gv.jobs) == nil
  end, 20), 'guide generation did not finish')
  idle(s)
  h.eq('guide', s.view_mode)
  h.eq(2, #s.layout.sections)
end

local function guide_hunk_row(path, first)
  for row, e in ipairs(s.layout.map) do
    if e.meta == 'hunk' and e.path == path then
      if first == nil or first == 0 then
        return row
      end
      first = first - 1
    end
  end
  error('no guide hunk for ' .. path)
end

h.test('guide: <Tab> on a section heading folds the section', function()
  guide_view()
  local r = s.layout.sections[1]
  vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
  keys(s, '<Tab>')
  h.eq(r.start_row, closed_at(s, r.start_row))
  h.eq(false, gv.section_reviewed(s, s.guide.resolved.sections[1]))
  keys(s, '<Tab>')
  h.eq(-1, closed_at(s, r.start_row))
end)

h.test('guide: <Tab> on a hunk header folds that hunk; also files without a text diff', function()
  for _, p in ipairs({ 'm.txt', 'bin.dat', 'new.txt', 'a.txt' }) do
    local row = guide_hunk_row(p)
    local si = s.layout.map[row].section_idx
    vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
    keys(s, '<Tab>')
    h.eq(row, closed_at(s, row), p)
    h.eq(-1, closed_at(s, s.layout.sections[si].start_row), p .. ': section stays open')
    keys(s, '<Tab>')
    h.eq(-1, closed_at(s, row), p)
  end
  -- the second hunk of m.txt folds on its own
  local h1, h2 = guide_hunk_row('m.txt'), guide_hunk_row('m.txt', 1)
  vim.api.nvim_win_set_cursor(s.diff_win, { h2, 0 })
  keys(s, '<Tab>')
  h.eq(h2, closed_at(s, h2))
  h.eq(-1, closed_at(s, h1))
  keys(s, '<Tab>')
  for _, sec in ipairs(s.guide.resolved.sections) do
    h.eq(false, gv.section_reviewed(s, sec))
  end
end)

h.test('guide: a collapsed hunk inside a collapsed section stays collapsed across a re-render', function()
  local row = guide_hunk_row('m.txt', 1)
  local si = s.layout.map[row].section_idx
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, '<Tab>')
  local sr = s.layout.sections[si].start_row
  vim.api.nvim_win_set_cursor(s.diff_win, { sr, 0 })
  keys(s, '<Tab>')
  h.eq(sr, closed_at(s, sr))
  view.rerender(s)
  sr, row = s.layout.sections[si].start_row, guide_hunk_row('m.txt', 1)
  h.eq(sr, closed_at(s, sr), 'section still collapsed')
  vim.api.nvim_win_set_cursor(s.diff_win, { sr, 0 })
  keys(s, '<Tab>')
  h.eq(-1, closed_at(s, sr))
  h.eq(row, closed_at(s, row), 'hunk still collapsed')
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, '<Tab>')
  h.eq(-1, closed_at(s, row))
end)

h.test('guide: <S-Tab> folds every section, then unfolds them', function()
  keys(s, '<S-Tab>')
  for _, r in ipairs(s.layout.sections) do
    h.eq(r.start_row, closed_at(s, r.start_row))
  end
  keys(s, '<S-Tab>')
  for _, r in ipairs(s.layout.sections) do
    h.eq(-1, closed_at(s, r.start_row))
  end
end)

h.test('guide: mr folds a section of added files, also when it is the last section', function()
  for si, r in ipairs(s.layout.sections) do
    vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row + 1, 0 })
    keys(s, 'mr')
    h.eq(true, gv.section_reviewed(s, s.guide.resolved.sections[si]), 'section ' .. si)
    h.eq(r.start_row, closed_at(s, r.start_row), 'section ' .. si .. ' folded')
  end
  for _, r in ipairs(s.layout.sections) do
    h.eq(r.start_row, closed_at(s, r.start_row))
  end
end)

h.run()
