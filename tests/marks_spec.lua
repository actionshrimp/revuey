-- Integration: nested reviewed marks shared by the diff and guide views (units.lua). `mr` on a
-- hunk, a file, a guide section and a visual selection; folding and cursor movement after a mark
-- (the user's own <Tab> folds and the last item included); propagation between the views; an
-- edit resetting one hunk; the working-tree refresh; layer vs full-stack scope; old state files.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')
vim.notify = function() end

local log = h.tmpdir('marks-fake-claude') .. '/calls.ndjson'
h.use_fake_claude(log)

local state_dir = h.tmpdir('marks-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local view = require('revuey.view')
local review_mod = require('revuey.review')
local units = require('revuey.units')
local state = require('revuey.state')
local gv = require('revuey.guide_view')

local function numbered(n)
  local t = {}
  for i = 1, n do
    t[#t + 1] = 'line ' .. i
  end
  return table.concat(t, '\n') .. '\n'
end

local function edit(text, map)
  for from, to in pairs(map) do
    text = text:gsub('line ' .. from .. '\n', to .. '\n')
  end
  return text
end

-- a.txt: added (one hunk); m.txt: three hunks; z.txt (the last file): two hunks
local long = numbered(40)
local repo = h.repo('marks', { ['m.txt'] = long, ['z.txt'] = long }, {
  ['a.txt'] = 'new\nfile\n',
  ['m.txt'] = edit(long, { [3] = 'three', [20] = 'twenty', [35] = 'thirty-five' }),
  ['z.txt'] = edit(long, { [5] = 'five', [30] = 'thirty' }),
})

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

local function fidx(s, path)
  for fi, f in ipairs(s.review.files) do
    if f.path == path then
      return fi
    end
  end
  error('no file ' .. path)
end

local function rows(s, path)
  return s.layout.files[fidx(s, path)]
end

local function progress(s, path)
  return { review_mod.file_progress(s.review, fidx(s, path)) }
end

---End-of-line virtual text on `row`, all extmarks concatenated.
local function virt(s, row)
  local ns = vim.api.nvim_get_namespaces()['revuey.diff']
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, c in ipairs(m[4].virt_text or {}) do
      out[#out + 1] = c[1]
    end
  end
  return table.concat(out)
end

local function panel_line(s, path)
  return vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)[s.panel_rows[fidx(s, path)]]
end

local function unmark_all(s)
  local U = review_mod.units(s.review)
  assert(units.set(s.review.state, U, U.list, false))
  view.rerender(s)
end

local function open(dir, opts)
  if view.session then
    view.close()
  end
  return h.open_review(vim.tbl_extend('force', { cwd = dir }, opts or {}))
end

local s = open(repo)

h.test('fixture: a.txt one hunk, m.txt three, z.txt two', function()
  h.eq({ 'a.txt', 'm.txt', 'z.txt' }, vim.tbl_map(function(f)
    return f.path
  end, s.review.files))
  h.eq({ 1, 3, 2 }, vim.tbl_map(function(f)
    return #f.hunks
  end, s.review.files))
end)

h.test('diff: mr inside a hunk marks that hunk only, folds it, moves to the next unreviewed hunk', function()
  local r = rows(s, 'm.txt')
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[1] + 2, 0 })
  keys(s, 'mr')
  h.eq({ 1, 3 }, progress(s, 'm.txt'))
  h.eq(false, review_mod.is_reviewed(s.review, s.review.files[fidx(s, 'm.txt')]))
  h.eq(r.hunk_rows[1], closed_at(s, r.hunk_rows[1]), 'the hunk folds')
  h.eq(-1, closed_at(s, r.start_row), 'its file stays open')
  h.eq(r.hunk_rows[2], cursor(s), 'on to the next hunk')
  h.ok(virt(s, r.start_row):find('◐ 1/3', 1, true), virt(s, r.start_row))
  h.ok(virt(s, r.hunk_rows[1]):find('✓ reviewed', 1, true), virt(s, r.hunk_rows[1]))
  h.eq(nil, virt(s, r.hunk_rows[2]):find('reviewed', 1, true))
  h.ok(panel_line(s, 'm.txt'):find('◐', 1, true), panel_line(s, 'm.txt'))
  -- the panel's counts show the units: "1/3 +3 −3" (virtual text)
  local pns = vim.api.nvim_get_namespaces()['revuey.panel']
  local prow = s.panel_rows[fidx(s, 'm.txt')]
  local pv = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, pns, { prow - 1, 0 }, { prow - 1, -1 }, { details = true })) do
    for _, c in ipairs(m[4].virt_text or {}) do
      pv[#pv + 1] = c[1]
    end
  end
  h.ok(table.concat(pv):find('1/3 ', 1, true), table.concat(pv))
  -- the winbar too, once the file is at the top
  vim.api.nvim_win_call(s.diff_win, function()
    vim.fn.winrestview({ topline = r.start_row })
  end)
  local wb = vim.api.nvim_win_call(s.diff_win, function()
    vim.g.statusline_winid = s.diff_win
    return view.winbar()
  end)
  h.ok(wb:find('◐ 1/3', 1, true), wb)
end)

h.test('diff: the remaining hunks complete the file: it folds, gets a file mark, the cursor moves on', function()
  local r = rows(s, 'm.txt')
  keys(s, 'mr')
  h.eq(r.hunk_rows[3], cursor(s))
  keys(s, 'mr')
  h.eq({ 3, 3 }, progress(s, 'm.txt'))
  h.eq(r.start_row, closed_at(s, r.start_row), 'the complete file folds')
  h.eq(rows(s, 'z.txt').start_row, cursor(s), 'next unreviewed file')
  local f = s.review.files[fidx(s, 'm.txt')]
  h.eq(true, state.is_reviewed(s.review.state, f.path, state.content_key(f)), 'file-level mark stored')
  h.ok(virt(s, r.start_row):find('✓ reviewed', 1, true))
  h.ok(panel_line(s, 'm.txt'):find('✓', 1, true))
end)

h.test("diff: mr on a file header marks or unmarks all of it; the user's <Tab> folds are kept", function()
  local r = rows(s, 'm.txt')
  vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
  keys(s, 'mr') -- complete: unmark all
  h.eq({ 0, 3 }, progress(s, 'm.txt'))
  h.eq(-1, closed_at(s, r.start_row))
  for _, hr in ipairs(r.hunk_rows) do
    h.eq(-1, closed_at(s, hr), 'reviewed-folded hunks unfold')
  end
  -- the user collapses hunk 2, marks hunk 1, then marks the whole file from its header
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[2], 0 })
  keys(s, '<Tab>')
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[1], 0 })
  keys(s, 'mr')
  h.eq(r.hunk_rows[1], closed_at(s, r.hunk_rows[1]))
  vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
  keys(s, 'mr') -- partial: mark all
  h.eq({ 3, 3 }, progress(s, 'm.txt'))
  h.eq(r.start_row, closed_at(s, r.start_row))
  vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
  keys(s, 'mr') -- unmark all
  h.eq(-1, closed_at(s, r.start_row))
  h.eq(-1, closed_at(s, r.hunk_rows[1]), 'folded because reviewed: unfolds')
  h.eq(r.hunk_rows[2], closed_at(s, r.hunk_rows[2]), "the user's own fold stays")
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[2], 0 })
  keys(s, '<Tab>')
  h.eq(-1, closed_at(s, r.hunk_rows[2]))
end)

-- Regression for the last-item fold bug, at hunk level: marking the very last hunk must fold it
-- and leave the cursor on it, not reopen the fold by moving into it.
h.test('last item: the last hunk folds and keeps the cursor; completing the last file folds it', function()
  local r = rows(s, 'z.txt')
  local last = r.hunk_rows[2]
  vim.api.nvim_win_set_cursor(s.diff_win, { last + 1, 0 })
  keys(s, 'mr')
  h.eq(last, closed_at(s, last), 'last hunk folded')
  h.eq(last, cursor(s))
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[1] + 1, 0 })
  keys(s, 'mr')
  h.eq({ 2, 2 }, progress(s, 'z.txt'))
  h.eq(r.start_row, closed_at(s, r.start_row), 'last file folded')
  h.eq(r.start_row, cursor(s))
  -- unmark from the folded header, mark again: still folded
  keys(s, 'mr')
  h.eq(-1, closed_at(s, r.start_row))
  keys(s, 'mr')
  h.eq(r.start_row, closed_at(s, r.start_row))
  unmark_all(s)
end)

h.test('visual mr marks every hunk the selection touches', function()
  local r = rows(s, 'm.txt')
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[1] + 3, 0 })
  vim.api.nvim_feedkeys('V', 'nx', false)
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[2] + 1, 0 })
  keys(s, 'mr')
  h.eq('n', vim.api.nvim_get_mode().mode)
  local U = review_mod.units(s.review)
  h.eq({ true, true, false }, vim.tbl_map(function(u)
    return units.reviewed(s.review.state, u)
  end, U.by_file[fidx(s, 'm.txt')]))
  -- again: all touched units are reviewed, so they are unmarked
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[1], 0 })
  vim.api.nvim_feedkeys('V', 'nx', false)
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[2], 0 })
  keys(s, 'mr')
  h.eq({ 0, 3 }, progress(s, 'm.txt'))
  h.eq(-1, closed_at(s, r.hunk_rows[1]))
end)

local function tab_collapse(path)
  local r = rows(s, path)
  if closed_at(s, r.start_row) == -1 then
    vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
    keys(s, '<Tab>')
  end
end

local function tab_expand(path)
  local r = rows(s, path)
  if closed_at(s, r.start_row) ~= -1 then
    vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
    keys(s, '<Tab>')
  end
end

h.test('after a hunk mr the cursor skips hunks inside collapsed files', function()
  tab_collapse('z.txt')
  local r = rows(s, 'm.txt')
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[3] + 1, 0 })
  keys(s, 'mr')
  h.eq(r.hunk_rows[3], cursor(s), 'no visible unreviewed hunk after it: stays')
  h.eq(r.hunk_rows[3], closed_at(s, r.hunk_rows[3]))
  h.eq({ 0, 2 }, progress(s, 'z.txt'))
  h.eq(rows(s, 'z.txt').start_row, closed_at(s, rows(s, 'z.txt').start_row), 'z.txt stays collapsed')
  unmark_all(s)
  tab_expand('z.txt')
end)

h.test('visual mr over collapsed files marks all of them, the last one included', function()
  for _, p in ipairs({ 'a.txt', 'm.txt', 'z.txt' }) do
    tab_collapse(p)
  end
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_win_set_cursor(s.diff_win, { rows(s, 'a.txt').start_row, 0 })
  vim.api.nvim_feedkeys('Vjj', 'nx', false)
  keys(s, 'mr')
  h.eq({ { 1, 1 }, { 3, 3 }, { 2, 2 } }, { progress(s, 'a.txt'), progress(s, 'm.txt'), progress(s, 'z.txt') })
  unmark_all(s)
  for _, p in ipairs({ 'a.txt', 'm.txt', 'z.txt' }) do
    tab_expand(p)
  end
end)

-- The guide: section 1 = a.txt + m.txt's first hunk; section 2 = m.txt's other hunks + z.txt
-- (or `secs`: {title, pred} per section).
local function guide(secs)
  secs = secs or {
    { 'First', function(hk)
      return hk.path == 'a.txt' or (hk.path == 'm.txt' and hk.hunk_idx == 1)
    end },
    { 'Second', function(hk)
      return hk.path == 'z.txt' or (hk.path == 'm.txt' and hk.hunk_idx > 1)
    end },
  }
  local hs = review_mod.units(s.review).hunks
  local function ids(pred)
    local out = {}
    for _, hk in ipairs(hs) do
      if pred(hk) then
        out[#out + 1] = { id = hk.id }
      end
    end
    return out
  end
  local out = h.tmpdir('marks-guide') .. '/guide.json'
  local fd = assert(io.open(out, 'w'))
  fd:write(vim.json.encode({
    title = 'Marks guide',
    summary = 'Summary.',
    sections = vim.tbl_map(function(x)
      return { title = x[1], overview = x[3] or (x[1] .. '.'), hunks = ids(x[2]) }
    end, secs),
    unplaced = {},
  }))
  fd:close()
  vim.env.REVUEY_FAKE_CLAUDE_OUTPUT = out
  view.guide_command(true)
  assert(vim.wait(20000, function()
    return next(gv.jobs) == nil and s.guide.resolved ~= nil
  end, 20), 'guide generation did not finish')
  idle(s)
  h.eq('guide', s.view_mode)
end

local function guide_row(path, hi)
  for row, e in ipairs(s.layout.map) do
    if e.meta == 'hunk' and e.path == path and (e.hunk_idx or 0) == (hi or 0) then
      return row
    end
  end
  error('no guide hunk ' .. path .. '#' .. tostring(hi))
end

local function sec(i)
  return s.guide.resolved.sections[i]
end

h.test("guide: mr on a hunk marks that unit; the section shows partial progress; the diff sees it", function()
  guide()
  local row = guide_row('m.txt', 1)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, 'mr')
  h.eq({ 1, 2 }, { gv.section_progress(s, sec(1)) })
  h.eq(row, closed_at(s, row), 'the hunk folds in the guide')
  h.eq(-1, closed_at(s, s.layout.sections[1].start_row))
  h.ok(virt(s, row):find('✓ reviewed', 1, true), virt(s, row))
  local head = s.layout.sections[1].start_row
  h.ok(virt(s, head):find('◐ 1/2', 1, true), virt(s, head))
  h.eq(guide_row('m.txt', 2), cursor(s), 'on to the next unreviewed hunk (section 2)')
  local pl = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  h.ok(pl:find('◐ 1 First', 1, true), pl)
  h.ok(pl:find('◐  M  m.txt', 1, true) or pl:find('◐ M  m.txt', 1, true), pl)
  -- the diff view: m.txt at 1/3, its first hunk folded
  view.set_view('diff')
  local r = rows(s, 'm.txt')
  h.ok(virt(s, r.start_row):find('◐ 1/3', 1, true), virt(s, r.start_row))
  h.eq(r.hunk_rows[1], closed_at(s, r.hunk_rows[1]))
  h.eq(-1, closed_at(s, r.hunk_rows[2]))
end)

h.test('guide: mr on a section heading marks its units; files it covers are reviewed in the diff', function()
  view.set_view('guide')
  vim.api.nvim_win_set_cursor(s.diff_win, { s.layout.sections[1].start_row, 0 })
  keys(s, 'mr')
  h.eq(true, gv.section_reviewed(s, sec(1)))
  h.eq(s.layout.sections[1].start_row, closed_at(s, s.layout.sections[1].start_row))
  h.eq(guide_row('m.txt', 2), cursor(s), "on to section 2's first hunk")
  -- the guide's own meta line follows, in place (no re-render: the fold just closed stays)
  local text = table.concat(vim.api.nvim_buf_get_lines(s.diff_buf, 0, -1, false), '\n')
  h.ok(text:find('2 sections · 1/2 reviewed', 1, true), text:sub(1, 200))
  h.eq(s.layout.sections[1].start_row, closed_at(s, s.layout.sections[1].start_row))
  h.eq(true, review_mod.is_reviewed(s.review, s.review.files[fidx(s, 'a.txt')]), 'a.txt was all in section 1')
  h.eq({ 1, 3 }, progress(s, 'm.txt'))
  view.set_view('diff')
  h.eq(rows(s, 'a.txt').start_row, closed_at(s, rows(s, 'a.txt').start_row), 'complete file folds in the diff')
end)

h.test('diff: marking files ticks their units off in every guide section', function()
  vim.api.nvim_win_set_cursor(s.diff_win, { rows(s, 'z.txt').start_row, 0 })
  keys(s, 'mr')
  h.eq({ 2, 4 }, { gv.section_progress(s, sec(2)) })
  h.eq({ 2, 2 }, progress(s, 'z.txt'))
  vim.api.nvim_win_set_cursor(s.diff_win, { rows(s, 'm.txt').start_row, 0 })
  keys(s, 'mr')
  h.eq(true, gv.section_reviewed(s, sec(2)))
  view.set_view('guide')
  h.eq(s.layout.sections[2].start_row, closed_at(s, s.layout.sections[2].start_row), 'complete section folded')
  h.eq({ 2, 2 }, { gv.progress(s) })
  h.ok(virt(s, s.layout.sections[2].start_row):find('✓ reviewed', 1, true))
  view.set_view('diff')
end)

h.test('an edit resets only that hunk; the working-tree refresh keeps the other marks', function()
  local f = s.review.files[fidx(s, 'm.txt')]
  local key = state.content_key(f)
  h.write(repo, 'm.txt', edit(long, { [3] = 'three', [20] = 'twenty (edited)', [35] = 'thirty-five' }))
  view.refresh()
  assert(vim.wait(10000, function()
    local nf = s.review.files[fidx(s, 'm.txt')]
    return state.content_key(nf) ~= key
  end, 10), 'refresh after the edit')
  idle(s)
  h.eq({ 2, 3 }, progress(s, 'm.txt'))
  local U = review_mod.units(s.review)
  h.eq({ true, false, true }, vim.tbl_map(function(u)
    return units.reviewed(s.review.state, u)
  end, U.by_file[fidx(s, 'm.txt')]))
  h.eq(true, review_mod.is_reviewed(s.review, s.review.files[fidx(s, 'a.txt')]))
  h.eq(true, review_mod.is_reviewed(s.review, s.review.files[fidx(s, 'z.txt')]))
  -- the edited file opens to show what is left; its reviewed hunks stay folded
  local r = rows(s, 'm.txt')
  h.eq(-1, closed_at(s, r.start_row))
  h.eq(r.hunk_rows[1], closed_at(s, r.hunk_rows[1]))
  h.eq(-1, closed_at(s, r.hunk_rows[2]))
  h.eq(r.hunk_rows[3], closed_at(s, r.hunk_rows[3]))
  h.ok(virt(s, r.start_row):find('◐ 2/3', 1, true))
  -- the guide: the edited hunk stays in section 2 (re-anchored by overlap, marked edited) and is
  -- not reviewed; the section's unchanged hunks still are
  view.set_view('guide')
  h.eq({ false, 1 }, { sec(2).outdated, sec(2).edited })
  h.eq(nil, sec(3), 'no "Not in guide" section')
  local edited
  for _, it in ipairs(sec(2).items) do
    if it.edited then
      edited = it.hunk
    end
  end
  h.eq({ 'm.txt', 2 }, { edited.path, edited.hunk_idx })
  local done, total = gv.section_progress(s, sec(2))
  h.eq(total - 1, done)
  h.eq(false, gv.section_reviewed(s, sec(2)))
  view.set_view('diff')
  h.write(repo, 'm.txt', edit(long, { [3] = 'three', [20] = 'twenty', [35] = 'thirty-five' }))
  view.refresh()
  idle(s)
end)

h.test('old state files: file marks and guide section marks keep working and are converted', function()
  unmark_all(s)
  local fa, fz = s.review.files[fidx(s, 'a.txt')], s.review.files[fidx(s, 'z.txt')]
  local path = s.review.state._path
  view.set_view('guide')
  local sec_id = sec(1).id
  view.set_view('diff')
  view.close()
  local fd = assert(io.open(path, 'w'))
  fd:write(vim.json.encode({
    version = 1, repo = s.review.state.repo, branch = 'feat', base = 'main',
    files = {
      [fa.path] = { key = state.content_key(fa), reviewed_at = 1 },
      [fz.path] = { key = state.content_key(fz), reviewed_at = 1 },
    },
    sections = { [sec_id] = { reviewed_at = 1 } },
  }))
  fd:close()
  s = open(repo)
  h.eq(true, review_mod.is_reviewed(s.review, s.review.files[fidx(s, 'z.txt')]))
  h.eq(rows(s, 'z.txt').start_row, closed_at(s, rows(s, 'z.txt').start_row))
  -- the section mark (a.txt + m.txt's first hunk) became unit marks
  h.eq({ 1, 3 }, progress(s, 'm.txt'))
  local raw = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  h.eq(2, raw.version)
  h.eq(nil, raw.sections)
  local U = review_mod.units(s.review)
  for _, u in ipairs(U.by_file[fidx(s, 'z.txt')]) do
    h.ok(raw.units[u.key], 'converted: ' .. u.key)
  end
  view.set_view('guide')
  h.eq(true, gv.section_reviewed(s, sec(1)))
  view.set_view('diff')
end)

-- Stack: unit marks belong to the scope (layer key vs full-stack key), like file marks.
h.test('layer and full scope keep separate unit marks, even for identical hunks', function()
  local d = h.tmpdir('marks-stack')
  vim.fn.delete(d, 'rf')
  assert(h.make_fixture('--stack', d).code == 0)
  view.close()
  require('revuey').open({ cwd = d, on_ready = function(x)
    s = x
  end })
  assert(vim.wait(10000, function()
    return view.session and s == view.session and s.review.stack ~= nil
  end, 10), 'stack review did not open')
  h.eq('stack/cart', s.review.branch)
  local fi = fidx(s, 'src/index.ts')
  local r = s.layout.files[fi]
  vim.api.nvim_win_set_cursor(s.diff_win, { r.hunk_rows[1] + 1, 0 })
  keys(s, 'mr')
  local layer_key = review_mod.units(s.review).by_file[fi][1].key
  h.ok(s.review.state.units[layer_key], 'unit mark in the layer state')
  h.eq(state.file_for(state_dir, s.review.root, 'stack/cart', 'stack/math'), s.review.state._path)
  keys(s, 'gs')
  h.eq('full', s.scope.kind)
  local U = review_mod.units(s.review)
  local full = U.by_file[fidx(s, 'src/index.ts')]
  h.eq(layer_key, full[1].key, 'the same hunk content: the same unit key')
  h.eq(false, units.reviewed(s.review.state, full[1]), 'but the full scope has its own marks')
  h.ok(s.review.state._path ~= state.file_for(state_dir, s.review.root, 'stack/cart', 'stack/math'))
  keys(s, 'gs')
  h.eq('stack/cart', s.review.branch)
  h.eq(true, units.reviewed(s.review.state, review_mod.units(s.review).by_file[fidx(s, 'src/index.ts')][1]))
  -- the layer row counts fully reviewed files (index.ts has one hunk; cart.ts none reviewed)
  local row
  for r, l in pairs(s.panel_layers) do
    if l == 2 then
      row = r
    end
  end
  local pns = vim.api.nvim_get_namespaces()['revuey.panel']
  local pv = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf, pns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, c in ipairs(m[4].virt_text or {}) do
      pv[#pv + 1] = c[1]
    end
  end
  h.ok(table.concat(pv):find('✓1/2', 1, true), table.concat(pv))
end)

-- Pre-tests the planned hunk splitting: with two units per hunk (lines 1-3 and the rest), the view
-- marks one piece from a code line, shows the hunk's progress, moves to the other piece, and
-- folds the hunk once both are reviewed; the header still toggles the whole hunk.
h.test('split units: mr on each piece of a hunk, progress, folding', function()
  review_mod.split = function(_, hk)
    if #hk.lines < 4 then
      return nil
    end
    return { { first = 1, last = 3 }, { first = 4, last = #hk.lines } }
  end
  local d = h.repo('marks-split', { ['m.txt'] = long }, { ['m.txt'] = edit(long, { [3] = 'three', [20] = 'twenty' }) })
  s = open(d)
  local ok, err = pcall(function()
    local r = rows(s, 'm.txt')
    local U = review_mod.units(s.review)
    h.eq(4, #U.by_file[1], 'two hunks, two pieces each')
    local hr = r.hunk_rows[1]
    vim.api.nvim_win_set_cursor(s.diff_win, { hr + 1, 0 }) -- line 1: the first piece
    keys(s, 'mr')
    h.eq({ 1, 4 }, progress(s, 'm.txt'))
    h.ok(virt(s, hr):find('◐ 1/2', 1, true), virt(s, hr))
    h.eq(-1, closed_at(s, hr), 'a partly reviewed hunk stays open')
    local base = s.layout.hunk_base[1][1]
    h.eq(base + 4, cursor(s), 'on to the other piece')
    keys(s, 'mr')
    h.eq({ 2, 4 }, progress(s, 'm.txt'))
    h.eq(hr, closed_at(s, hr), 'both pieces: the hunk folds')
    h.ok(virt(s, hr):find('✓ reviewed', 1, true))
    h.ok(s.review.state.units[U.by_file[1][1].hunk], 'the parent hunk key is stored')
    h.eq(r.hunk_rows[2], cursor(s), 'then the next hunk')
    -- the header toggles the whole hunk
    keys(s, 'mr')
    h.eq({ 4, 4 }, progress(s, 'm.txt'))
    vim.api.nvim_win_set_cursor(s.diff_win, { r.start_row, 0 })
    keys(s, 'mr')
    h.eq({ 0, 4 }, progress(s, 'm.txt'))
  end)
  review_mod.split = nil
  assert(ok, err)
end)

-- Moving on in the guide: section 1 = a.txt + m.txt's first hunk; 2 = m.txt's others, with a
-- longer overview; 3 = z.txt.
local function three_sections(bullets)
  guide({
    { 'Start', function(hk)
      return hk.path == 'a.txt' or (hk.path == 'm.txt' and hk.hunk_idx == 1)
    end },
    { 'Middle', function(hk)
      return hk.path == 'm.txt' and hk.hunk_idx > 1
    end, bullets and table.concat(vim.tbl_map(function(i)
      return '- point ' .. i
    end, vim.fn.range(1, bullets)), '\n') or nil },
    { 'End', function(hk)
      return hk.path == 'z.txt'
    end },
  })
end

-- unmark everything and open every fold (unmarking behind the view's back leaves folds as they are)
local function reset()
  unmark_all(s)
  vim.api.nvim_win_call(s.diff_win, function()
    vim.cmd('normal! zR')
  end)
end

local function mr_at(row)
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 0 })
  keys(s, 'mr')
end

local function view_top()
  return vim.api.nvim_win_call(s.diff_win, function()
    return vim.fn.line('w0')
  end)
end

---Make the diff window `n` text rows high (its winbar not counted); growing 'cmdheight' takes up
---the rest, as only vertical splits share the screen.
local function text_height(n)
  vim.api.nvim_win_set_height(s.diff_win, n + 1)
  h.eq(n, vim.fn.winheight(s.diff_win), 'text rows')
  h.ok(vim.wo[s.diff_win].winbar ~= '', 'the guide window has a winbar')
end

local function restore_height()
  vim.o.cmdheight = 1
  vim.api.nvim_win_set_height(s.diff_win, 999)
end

h.test("guide: completing a section moves to the next section's first unreviewed hunk", function()
  s = open(repo)
  unmark_all(s)
  three_sections()
  -- section 2's first hunk already reviewed: completing section 1 lands on its second
  mr_at(guide_row('m.txt', 2))
  mr_at(guide_row('a.txt', 1))
  h.eq(guide_row('m.txt', 1), cursor(s), 'section 1 not complete yet: its next hunk')
  mr_at(guide_row('m.txt', 1))
  h.eq(true, gv.section_reviewed(s, sec(1)))
  h.eq(guide_row('m.txt', 3), cursor(s), "section 2's first unreviewed hunk")
  h.eq(-1, closed_at(s, cursor(s)), 'the hunk is open')
  mr_at(guide_row('m.txt', 3))
  h.eq(guide_row('z.txt', 1), cursor(s), "completing section 2: section 3's first hunk")
  -- a fully reviewed next section is skipped
  reset()
  mr_at(guide_row('m.txt', 2))
  mr_at(guide_row('m.txt', 3))
  h.eq(true, gv.section_reviewed(s, sec(2)))
  mr_at(guide_row('a.txt', 1))
  mr_at(guide_row('m.txt', 1))
  h.eq(guide_row('z.txt', 1), cursor(s), 'section 2 is reviewed: skipped')
  -- a section mr on a heading lands on a hunk too
  reset()
  mr_at(s.layout.sections[1].start_row)
  h.eq(guide_row('m.txt', 2), cursor(s))
  -- a collapsed next section: its heading, still collapsed
  reset()
  view.toggle_section_fold(2)
  mr_at(s.layout.sections[1].start_row)
  h.eq(s.layout.sections[2].start_row, cursor(s))
  h.eq(s.layout.sections[2].start_row, closed_at(s, s.layout.sections[2].start_row))
  -- a collapsed unreviewed hunk is skipped for the next open one
  reset()
  vim.api.nvim_win_set_cursor(s.diff_win, { guide_row('m.txt', 2), 0 })
  keys(s, '<Tab>')
  h.eq(guide_row('m.txt', 2), closed_at(s, guide_row('m.txt', 2)))
  mr_at(s.layout.sections[1].start_row)
  h.eq(guide_row('m.txt', 3), cursor(s))
  -- the last section: its heading, folded
  reset()
  mr_at(s.layout.sections[1].start_row)
  mr_at(s.layout.sections[3].start_row)
  mr_at(s.layout.sections[2].start_row)
  h.eq(s.layout.sections[2].start_row, cursor(s), 'the rest is reviewed: stays on the heading')
  h.eq(s.layout.sections[2].start_row, closed_at(s, s.layout.sections[2].start_row))
  reset()
end)

h.test('guide: moving on keeps the next section heading in view; winbar and scrolloff', function()
  three_sections(7)
  local head = s.layout.sections[2].start_row
  local function land()
    reset()
    mr_at(s.layout.sections[1].start_row)
    h.eq(guide_row('m.txt', 2), cursor(s))
  end
  land()
  -- screen rows from the heading down to the hunk header (prose, blank lines)
  local above = vim.api.nvim_win_text_height(s.diff_win, { start_row = head - 1, end_row = cursor(s) - 2 }).all
  h.eq(9, above, 'the overview fits the cases below (20 text rows at most)')
  local ok, err = pcall(function()
    -- exactly room for the heading over a centred hunk: centred, heading on the top row
    text_height(2 * above + 1)
    land()
    h.eq(head, view_top(), 'zz keeps the heading')
    -- one row less: centring would hide the heading, so the heading goes to the top
    text_height(2 * above)
    land()
    h.eq(head, view_top(), 'heading at the top')
    -- 'scrolloff' 8 still leaves room for it
    vim.wo[s.diff_win].scrolloff = 8
    text_height(above + 9)
    land()
    h.eq(head, view_top(), "heading at the top with 'scrolloff'")
    -- a 'scrolloff' that always centres: centred, the hunk in view
    vim.wo[s.diff_win].scrolloff = 999
    land()
    h.ok(view_top() > head and view_top() < cursor(s), 'centred')
    vim.wo[s.diff_win].scrolloff = 0
    -- no room for the prose and the start of the hunk: the hunk centred, the prose above it
    text_height(above + 3)
    land()
    h.ok(view_top() > head and view_top() < cursor(s), 'long prose: centred')
  end)
  vim.wo[s.diff_win].scrolloff = 0
  restore_height()
  reset()
  assert(ok, err)
end)

h.test('guide: a section left with no hunks is skipped', function()
  guide({
    { 'Start', function(hk)
      return hk.path == 'a.txt' or (hk.path == 'm.txt' and hk.hunk_idx == 1)
    end },
    { 'Gone', function(hk)
      return hk.path == 'z.txt'
    end },
    { 'Rest', function(hk)
      return hk.path == 'm.txt' and hk.hunk_idx > 1
    end },
  })
  -- z.txt changed back: section 2 shows no hunks any more
  h.write(repo, 'z.txt', long)
  view.refresh()
  assert(vim.wait(10000, function()
    return s.guide.resolved and sec(2) and #sec(2).items == 0
  end, 10), 'section 2 emptied')
  idle(s)
  local ok, err = pcall(function()
    reset()
    h.eq('Gone', sec(2).title)
    mr_at(guide_row('a.txt', 1))
    mr_at(guide_row('m.txt', 1))
    h.eq(true, gv.section_reviewed(s, sec(1)))
    h.eq(guide_row('m.txt', 2), cursor(s), 'past the empty section to the next hunk')
  end)
  h.write(repo, 'z.txt', edit(long, { [5] = 'five', [30] = 'thirty' }))
  view.refresh()
  idle(s)
  assert(ok, err)
end)

h.run()
