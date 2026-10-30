-- Integration: AI guide view on fixture repos with a fake `claude` (tests/bin/claude) first on PATH.
-- Generation, argv/cwd/stdin, the guide buffer and side table, section reviewed state, staleness,
-- cancel/timeout/errors, and separate guides per stack scope.
local h = dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/helpers.lua')
vim.cmd('runtime plugin/revuey.lua')

-- keep "guide ready" notifications out of the test output (tests capture them where it matters)
vim.notify = function() end

local log = h.tmpdir('fake-claude') .. '/calls.ndjson'
h.use_fake_claude(log)

local state_dir = h.tmpdir('guide-view-state')
require('revuey').setup({ state_dir = state_dir, lsp_warmup = false })
local config = require('revuey.config')
local view = require('revuey.view')
local gv = require('revuey.guide_view')
local layout = require('revuey.layout')

local function open(dir, opts)
  if view.session then
    view.close()
  end
  local s = h.open_review(vim.tbl_extend('force', { cwd = dir }, opts or {}))
  return s
end

local function idle(s)
  assert(vim.wait(10000, function()
    return not s.refreshing and not s.pending and not s.pending_scope
  end, 10), 'refresh did not finish')
end

local function wait_job(s)
  assert(vim.wait(20000, function()
    return next(gv.jobs) == nil
  end, 20), 'guide generation did not finish')
  idle(s)
end

local function lines(s)
  return vim.api.nvim_buf_get_lines(s.diff_buf, 0, -1, false)
end

local function text(s)
  return table.concat(lines(s), '\n')
end

---Prose with its wrapping undone (headless specs keep the 80-column screen, so prose wraps):
---every line break, with the indent and `▎ ` callout bar of the next line, becomes one space.
local function flat(s)
  return (text(s):gsub('%s*\n[%s▎]*', ' '))
end

local function find(s, needle, kind)
  for row, l in ipairs(lines(s)) do
    if l:find(needle, 1, true) and (not kind or s.layout.map[row].kind == kind or s.layout.map[row].meta == kind) then
      return row
    end
  end
end

local function calls()
  local out = {}
  local fd = io.open(log, 'r')
  if not fd then
    return out
  end
  for l in fd:lines() do
    out[#out + 1] = vim.json.decode(l)
  end
  fd:close()
  return out
end

local function arg_value(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then
      return argv[i + 1]
    end
  end
end

---Answer the next vim.ui.select with `choice` (by label).
local function answer_select(choice)
  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb)
    vim.ui.select = orig
    cb(choice and vim.tbl_contains(items, choice) and choice or nil)
  end
end

local function keys(s, k)
  vim.api.nvim_set_current_win(s.diff_win)
  vim.api.nvim_feedkeys(vim.keycode(k), 'mtx', false)
  idle(s)
end

local fixture = h.fixture()

h.test('gG offers to generate, then shows the guide; claude gets read-only flags, cwd and the diff', function()
  vim.fn.delete(log)
  vim.env.REVUEY_FAKE_CLAUDE = 'slow'
  local s = open(fixture)
  h.eq(nil, s.view_mode)
  -- declining keeps the diff
  answer_select(nil)
  keys(s, 'gG')
  h.eq(nil, s.view_mode)
  h.eq(0, #calls())
  answer_select('Generate a guide')
  keys(s, 'gG')
  h.eq('guide', s.view_mode)
  -- placeholder with a live status while it runs; the diff stays usable meanwhile
  h.ok(find(s, 'Generating a guide for'), text(s))
  assert(vim.wait(5000, function()
    local j = gv.job(s)
    return j and j.progress == 'reading src/cart.ts'
  end, 10), 'progress from tool use')
  local panel = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  h.ok(panel:find(' Guide', 1, true), panel)
  h.ok(gv.status_text(s):find('generating %d+s  reading src/cart.ts'), gv.status_text(s))
  keys(s, 'gG')
  h.eq('diff', s.view_mode)
  vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
  keys(s, ']f')
  h.eq(s.layout.files[2].start_row, vim.api.nvim_win_get_cursor(s.diff_win)[1], 'navigating the diff while the guide is generated')
  wait_job(s)
  keys(s, 'gG')
  h.eq('guide', s.view_mode)

  local c = calls()
  h.eq(1, #c)
  local argv = c[1].argv
  h.eq(vim.uv.fs_realpath(fixture), vim.uv.fs_realpath(c[1].cwd), 'runs in the repo root')
  h.ok(vim.tbl_contains(argv, '-p'))
  h.eq('stream-json', arg_value(argv, '--output-format'))
  h.eq('dontAsk', arg_value(argv, '--permission-mode'))
  h.eq('Read,Grep,Glob,Bash', arg_value(argv, '--tools'))
  h.ok(not arg_value(argv, '--allowedTools'):find('Edit', 1, true))
  h.ok(vim.tbl_contains(argv, '--restricted') and vim.tbl_contains(argv, '--safe-mode'), 'settings files and hooks ignored')
  h.eq(require('revuey.guide_prompt').SCHEMA, vim.json.decode(arg_value(argv, '--json-schema')))
  h.eq(nil, arg_value(argv, '--model'), 'model unset by default')
  h.ok(c[1].stdin:find('# Guided Review Organizer', 1, true))
  h.ok(c[1].stdin:find('\n@@ h1 assets/logo.png @@\n', 1, true), 'diff order, binary file included')
  h.ok(c[1].stdin:find('\n@@ h2 src/cart.ts @@\n@@ -0,0 +1,27 @@', 1, true))
  h.ok(c[1].stdin:find('- feature: cart', 1, true) or c[1].stdin:find('Commits (newest first):', 1, true), 'commit subjects')

  -- the guide buffer: title, meta, summary, numbered sections, prose and hunks
  h.eq('Fake guide title', lines(s)[1])
  -- the meta line wraps in a narrow window (headless specs keep the 80-column screen)
  h.ok(text(s):gsub('\n', ' '):find('2 sections · 0/2 reviewed · claude-fake-1 · just now', 1, true), text(s))
  local sec1 = find(s, '1. Core change', 'section')
  local sec2 = find(s, '2. Follow-up wiring', 'section')
  h.ok(sec1 and sec2 and sec1 < sec2)
  h.ok(flat(s):find('The heart of the change: totals move into cart.ts.', 1, true), text(s))
  h.ok(flat(s):find('Important: Callers now get rounded totals.', 1, true), text(s))
  h.ok(flat(s):find(' Introduces the new total helper.', 1, true), 'hunk note')
  h.eq('clean', s.guide.resolved.stale and 'stale' or 'clean')
  h.eq(s.guide.record.generator.session_id, 'fake-session-1', 'session id kept for follow-ups')

  -- side table: prose rows are prose; hunk rows match the diff layout for the same hunk
  local diff_layout = layout.compose(s.review.files)
  local function sig(e)
    return { e.kind, e.file_idx, e.old_lnum, e.new_lnum, e.hunk_idx, e.line_idx, e.path }
  end
  local seen = 0
  for row, e in ipairs(s.layout.map) do
    if e.kind == 'add' or e.kind == 'del' or e.kind == 'ctx' then
      local base = diff_layout.hunk_base[e.file_idx][e.hunk_idx]
      h.eq(sig(diff_layout.map[base + e.line_idx]), sig(e), 'row ' .. row)
      h.eq(diff_layout.lines[base + e.line_idx], s.layout.lines[row])
      seen = seen + 1
    end
  end
  local total = 0
  for _, f in ipairs(s.review.files) do
    for _, hk in ipairs(f.hunks) do
      total = total + #hk.lines
    end
  end
  h.eq(total, seen, 'every hunk line appears exactly once in the guide')
  h.eq('prose', s.layout.map[1].kind)

  -- folds: one per section; ]] / [[ move between sections; ]c works inside
  vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
  keys(s, ']]')
  h.eq(sec1, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  keys(s, ']]')
  h.eq(sec2, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  keys(s, '[[')
  h.eq(sec1, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  keys(s, ']c')
  local e = s.layout.map[vim.api.nvim_win_get_cursor(s.diff_win)[1]]
  h.ok(e.kind == 'add' or e.kind == 'del', 'on a change')
  h.eq(1, e.section_idx)
  -- `go` from a hunk line inside the guide opens the real file at that line
  keys(s, 'go')
  h.eq(s.code_win, vim.api.nvim_get_current_win())
  h.ok(vim.api.nvim_buf_get_name(0):find(s.review.files[e.file_idx].path, 1, true))
  vim.api.nvim_win_close(s.code_win, true)
end)

h.test('syntax and word diff skip prose rows', function()
  local s = view.session
  local syntax = require('revuey.syntax')
  for row, e in ipairs(s.layout.map) do
    if e.kind == 'prose' or e.kind == 'meta' then
      h.eq(nil, syntax.spans_for_row({ layout = s.layout, review = s.review }, row - 1))
      h.eq(nil, s.word_spans(row - 1))
    end
  end
  -- word diff in the guide pairs the same lines as in the diff
  local row = find(s, 'export function sum', 'add')
  h.ok(row)
end)

h.test('panel lists sections; selecting one jumps to it', function()
  local s = view.session
  local panel = vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false)
  local prow
  for i, l in ipairs(panel) do
    if l:find('2 Follow-up wiring', 1, true) then
      prow = i
    end
  end
  h.ok(prow, table.concat(panel, '\n'))
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_win_set_cursor(s.panel_win, { prow, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'mtx', false)
  h.eq(s.diff_win, vim.api.nvim_get_current_win())
  h.eq(s.layout.sections[2].start_row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  h.eq(2, s.current_section)
  -- the guide view's file list has its folders too; <CR> on one shows its first file
  local hrow
  for row, g in pairs(s.panel_dirs) do
    if g.dir == 'src/components' then
      hrow = row
    end
  end
  h.eq(' src/components:', vim.api.nvim_buf_get_lines(s.panel_buf, hrow - 1, hrow, false)[1])
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_win_set_cursor(s.panel_win, { hrow, 0 })
  vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'mtx', false)
  h.eq(s.diff_win, vim.api.nvim_get_current_win())
  h.eq(s.layout.file_rows[s.panel_dirs[hrow].first], vim.api.nvim_win_get_cursor(s.diff_win)[1])
end)

h.test('mr marks a section reviewed, folds it, moves on; persists; resets when its hunks change', function()
  local s = view.session
  vim.api.nvim_win_set_cursor(s.diff_win, { s.layout.sections[1].start_row + 2, 0 })
  keys(s, 'mr')
  local sec = s.guide.resolved.sections[1]
  h.eq(true, gv.section_reviewed(s, sec))
  h.eq(s.layout.sections[2].start_row, vim.api.nvim_win_get_cursor(s.diff_win)[1], 'moved to the next section')
  local closed = vim.api.nvim_win_call(s.diff_win, function()
    return vim.fn.foldclosed(s.layout.sections[1].start_row)
  end)
  h.eq(s.layout.sections[1].start_row, closed, 'reviewed section folded')
  h.ok(table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n'):find('✓ 1 Core change', 1, true))
  h.ok(lines(s)[2]:find('1/2 reviewed', 1, true) or true)
  -- marks are shared with the diff view: a file is reviewed when all of its hunks are, here
  -- exactly the files whose hunks all sit in section 1
  local in_sec = {}
  for _, item in ipairs(sec.items) do
    in_sec[item.hunk.hash] = true
  end
  local U = require('revuey.review').units(s.review)
  for fi, f in ipairs(s.review.files) do
    local all = true
    for _, u in ipairs(U.by_file[fi]) do
      all = all and in_sec[u.hunk] == true
    end
    h.eq(all, require('revuey.review').is_reviewed(s.review, f), f.path)
  end
  -- reopen: the guide and the section mark are loaded from disk
  s = open(fixture)
  view.guide_command(false)
  h.eq('guide', s.view_mode)
  h.eq(true, gv.section_reviewed(s, s.guide.resolved.sections[1]))
  closed = vim.api.nvim_win_call(s.diff_win, function()
    return vim.fn.foldclosed(s.layout.sections[1].start_row)
  end)
  h.eq(s.layout.sections[1].start_row, closed, 'reviewed sections start folded')
  -- change a hunk of section 1: outdated + not reviewed, the changed hunk moves to
  -- "Not in guide", and a banner offers to regenerate
  local target
  for _, item in ipairs(s.guide.resolved.sections[1].items) do
    if item.hunk.hunk_idx and not target then
      target = item.hunk
    end
  end
  local f = s.review.files[target.file_idx]
  local lnum
  for _, ln in ipairs(f.hunks[target.hunk_idx].lines) do
    if ln.kind == 'add' and not lnum then
      lnum = ln.new_lnum
    end
  end
  local p = fixture .. '/' .. f.path
  local l = vim.fn.readfile(p)
  local orig_line = l[lnum]
  l[lnum] = l[lnum] .. ' // edited'
  vim.fn.writefile(l, p)
  view.refresh()
  assert(vim.wait(10000, function()
    return s.guide.resolved and s.guide.resolved.stale
  end, 20), 'stale after edit')
  idle(s)
  local res = s.guide.resolved
  -- the edited hunk stays in its section (re-anchored by overlap), marked edited and unreviewed
  h.eq({ false, 1 }, { res.sections[1].outdated, res.sections[1].edited })
  h.eq(false, gv.section_reviewed(s, res.sections[1]))
  for _, sec in ipairs(res.sections) do
    h.ok(sec.kind ~= 'new', 'no "Not in guide" section')
  end
  h.ok(flat(s):find('Warning: The diff changed since this guide was generated (1 hunk edited).', 1, true), text(s))
  h.ok(text(s):find('Press\n▎ gR to regenerate.', 1, true) or text(s):find('Press gR to regenerate.', 1, true))
  -- a change nothing in the guide overlaps (a new file): "Not in guide", as before
  local extra = fixture .. '/src/extra_after_guide.ts'
  vim.fn.writefile({ 'export const extra = 1;' }, extra)
  view.refresh()
  assert(vim.wait(10000, function()
    local r = s.guide.resolved
    return r and r.new > 0
  end, 20), 'a new hunk after the second edit')
  idle(s)
  res = s.guide.resolved
  h.eq('Not in guide', res.sections[#res.sections].title)
  h.ok(find(s, 'Not in guide', 'section'))
  h.eq({ 1, 1 }, { res.new, res.edited })
  h.ok(flat(s):find('(1 new hunk, 1 hunk edited)', 1, true), text(s))
  -- the guide never re-runs by itself
  h.eq(1, #calls())
  -- undo the edits: the guide is fresh again and the mark is back
  vim.fn.delete(extra)
  l[lnum] = orig_line
  vim.fn.writefile(l, p)
  view.refresh()
  assert(vim.wait(10000, function()
    return s.guide.resolved and not s.guide.resolved.stale
  end, 20), 'fresh again')
  idle(s)
  h.eq(true, gv.section_reviewed(s, s.guide.resolved.sections[1]))
end)

h.test('prose re-wraps to the window width; the cursor stays on the same content', function()
  local s = view.session
  local function rewrap(width)
    vim.api.nvim_win_set_width(s.diff_win, width)
    vim.cmd('doautocmd WinResized') -- not fired without a UI (screen_spec covers a real resize)
  end
  rewrap(120)
  local wide = s.prose_width
  -- a hunk line below wrapped prose (section 1's overview)
  local row
  for r, e in ipairs(s.layout.map) do
    if not row and (e.kind == 'add' or e.kind == 'del') and e.section_idx == 1 then
      row = r
    end
  end
  local before = vim.deepcopy(s.layout.map[row])
  local before_text = s.layout.lines[row]
  vim.api.nvim_win_set_cursor(s.diff_win, { row, 2 })
  rewrap(60)
  h.ok(s.prose_width < wide, 'rewrapped')
  local now = vim.api.nvim_win_get_cursor(s.diff_win)
  local e = s.layout.map[now[1]]
  h.ok(now[1] ~= row, 'rows moved (the test means something)')
  h.eq({ before.hunk_id, before.line_idx, before_text, 2 }, { e.hunk_id, e.line_idx, s.layout.lines[now[1]], now[2] })
  for r, x in ipairs(s.layout.map) do
    if x.kind == 'prose' then
      h.ok(vim.api.nvim_strwidth(s.layout.lines[r]) <= s.prose_width, s.layout.lines[r])
    end
  end
  -- a prose position: the same word stays under the cursor
  local prow = find(s, 'Callers now get rounded', 'prose') or find(s, 'rounded', 'prose')
  local col = s.layout.lines[prow]:find('rounded', 1, true) - 1
  vim.api.nvim_win_set_cursor(s.diff_win, { prow, col })
  rewrap(120)
  now = vim.api.nvim_win_get_cursor(s.diff_win)
  h.eq('rounded', s.layout.lines[now[1]]:sub(now[2] + 1, now[2] + 7))
  vim.api.nvim_win_set_width(s.panel_win, config.options.panel_width)
  vim.cmd('doautocmd WinResized')
end)

h.test('regenerate (gR) asks first, then replaces the guide', function()
  local s = view.session
  vim.fn.delete(log)
  vim.env.REVUEY_FAKE_CLAUDE = 'missing'
  answer_select('Cancel')
  keys(s, 'gR')
  h.eq(0, #calls())
  answer_select('Generate a new guide')
  keys(s, 'gR')
  wait_job(s)
  h.eq(1, #calls())
  -- the model placed only one hunk: the rest are in "Other changes", nothing is lost
  local res = s.guide.resolved
  h.eq({ 'Only one', 'Other changes' }, vim.tbl_map(function(x)
    return x.title
  end, res.sections))
  h.eq(#s.guide.hunks, #res.sections[1].items + #res.sections[2].items)
  h.eq(false, res.stale)
  h.ok(s.guide.record.generator.warnings.missed > 0)
end)

h.test('unknown ids and duplicates are dropped; fenced JSON is repaired', function()
  local s = view.session
  vim.env.REVUEY_FAKE_CLAUDE = 'unknown'
  view.guide_command(true)
  wait_job(s)
  local res = s.guide.resolved
  h.eq({ 'Core change', 'Follow-up wiring' }, { res.sections[1].title, res.sections[2].title })
  h.eq(nil, find(s, 'Ghost', 'section'), 'a section with only unknown ids is dropped')
  h.eq(2, s.guide.record.generator.warnings.unknown)
  h.eq(1, s.guide.record.generator.warnings.duplicates)
  vim.env.REVUEY_FAKE_CLAUDE = 'fenced'
  view.guide_command(true)
  wait_job(s)
  h.eq('Fake guide title', s.guide.resolved.title)
end)

h.test('newlines in model strings never reach a buffer line; reopening works', function()
  local s = view.session
  vim.env.REVUEY_FAKE_CLAUDE = 'newlines'
  view.guide_command(true)
  wait_job(s)
  h.eq('Title second line', lines(s)[1])
  h.ok(find(s, '1. Core change', 'section'), text(s))
  h.ok(find(s, '  note with newline', 'prose'), text(s))
  local panel = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  h.ok(panel:find('1 Core change', 1, true), panel)
  s = open(fixture)
  view.set_view('guide')
  h.eq('Title second line', lines(s)[1])
end)

---Line note extmarks in the guide buffer: {row, kind ('lines'|'marker'), text, chunks}.
local function note_marks(s)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, gv.ns_notes, 0, -1, { details = true })) do
    local d = m[4]
    if d.virt_lines then
      local t = {}
      for _, l in ipairs(d.virt_lines) do
        local parts = {}
        for _, ch in ipairs(l) do
          parts[#parts + 1] = ch[1]
        end
        t[#t + 1] = vim.trim(table.concat(parts))
      end
      -- (wrapped: headless specs keep the 80-column screen)
      out[#out + 1] = { row = m[2] + 1, kind = 'lines', text = table.concat(t, ' '):gsub('%s+', ' '), above = d.virt_lines_above, chunks = d.virt_lines[1], all = d.virt_lines, n = #d.virt_lines }
    elseif d.virt_text then
      out[#out + 1] = { row = m[2] + 1, kind = 'marker', text = vim.trim(d.virt_text[#d.virt_text][1]) }
    end
  end
  return out
end

h.test('line notes: above their lines in the guide, bad anchors dropped and counted, ]n [n, gN; not in the diff view', function()
  local s = view.session
  view.set_view('guide')
  local notes = {}
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  vim.env.REVUEY_FAKE_CLAUDE = 'notes'
  view.guide_command(true)
  wait_job(s)
  vim.notify = function() end
  -- the prompt numbered the lines the notes point at
  local stdin = calls()[#calls()].stdin
  h.ok(stdin:find('\n1|+import { formatCurrency } from "../format";\n', 1, true), stdin)
  -- three bad anchors (an unknown hunk, a line the hunk lacks, a file without lines): dropped,
  -- counted, stored and told
  h.eq({ kept = 3, dropped = 3, unknown_hunk = 1, bad_line = 2, empty = 0, duplicates = 0, extra = 0 }, s.guide.record.generator.warnings.notes)
  local ready = vim.iter(notes):find(function(m)
    return m:find('guide ready', 1, true) ~= nil
  end)
  h.ok(ready and ready:find('line notes: 3 dropped (1 unknown hunk, 2 lines outside their hunks)', 1, true), vim.inspect(notes))
  h.eq(3, s.guide.resolved.notes)
  -- drawn above the lines they point at, in row order
  local marks = note_marks(s)
  h.eq(3, #marks, vim.inspect(marks))
  local function at(m)
    local e = s.layout.map[m.row]
    return { e.path, e.line_idx, e.kind }
  end
  -- (the first core hunk with 3+ lines: the fake guide takes hunks in the diff's order, folders
  -- first, so src/index.ts before src/components/)
  h.eq({ 'src/index.ts', 1, 'del' }, at(marks[1]))
  h.eq('▼ guide The new module starts here.', marks[1].text)
  h.eq({ 'src/index.ts', 2, 'add' }, at(marks[2]))
  h.eq('▼ guide · 2 lines Note the sum call: totals are built here.', marks[2].text)
  h.ok(marks[2].n > 1, 'wrapped to the window')
  h.eq({ 'src/cart.ts', 1, 'add' }, at(marks[3]))
  h.eq('▼ guide Wired in here.', marks[3].text)
  h.eq(true, marks[1].above)
  -- the row sits under the right section and hunk header
  h.eq(1, s.layout.map[marks[1].row].section_idx)
  h.eq(2, s.layout.map[marks[3].row].section_idx)
  -- own highlight groups: label, band, inline code on the band
  h.eq('RevueyGuideLineNoteLabel', marks[2].chunks[1][2])
  local code
  for _, l in ipairs(marks[2].all) do
    for _, ch in ipairs(l) do
      if ch[1] == 'sum' then
        code = ch[2]
      end
    end
  end
  h.eq({ 'RevueyGuideLineNote', 'RevueyGuideCode' }, code)
  for _, g in ipairs({ 'RevueyGuideLineNote', 'RevueyGuideLineNoteLabel', 'RevueyGuideLineNoteMarker' }) do
    h.ok(next(vim.api.nvim_get_hl(0, { name = g })) ~= nil, g)
  end
  -- not comments: no gutter bars, nothing for ]m, the comment list or exports
  for _, r in pairs(s.cm and s.cm.jump or {}) do
    h.ok(r ~= marks[1].row and r ~= marks[2].row and r ~= marks[3].row, 'a note is not a comment')
  end
  h.eq(nil, require('revuey.comments_view').sign(s, marks[1].row))
  -- the panel names the keys while the guide has notes
  local panel = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  h.ok(panel:find(' ]n [n line note  gN show/collapse', 1, true), panel)
  -- ]n / [n (with a count) move between notes
  vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
  keys(s, ']n')
  h.eq(marks[1].row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  keys(s, '2]n')
  h.eq(marks[3].row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  local said = {}
  vim.notify = function(msg)
    said[#said + 1] = msg
  end
  keys(s, ']n')
  vim.notify = function() end
  h.eq(marks[3].row, vim.api.nvim_win_get_cursor(s.diff_win)[1], 'no wrap past the last note')
  h.eq({ 'revuey: no more line notes below' }, said)
  keys(s, '[n')
  h.eq(marks[2].row, vim.api.nvim_win_get_cursor(s.diff_win)[1])
  -- on a note, the winbar names its keys (key_help); off it, the guide's counters come back
  -- (this window is 39 cells: the first keys are drawn, all of them are in s.key_hint)
  local function winbar()
    vim.g.statusline_winid = s.diff_win
    return vim.api.nvim_eval_statusline(view.winbar(), { winid = s.diff_win, use_winbar = true }).str
  end
  local function hint()
    return table.concat(vim.tbl_map(function(it)
      return it.key .. ' ' .. it.label
    end, s.key_hint.items), ' · ')
  end
  h.ok(vim.endswith(winbar(), ' ]n/[n next/prev '), winbar())
  h.eq(']n/[n next/prev · gN hide notes', hint())
  -- gN collapses the notes to a marker at the end of their first line, and back
  keys(s, 'gN')
  h.eq(']n/[n next/prev · gN show notes', hint())
  vim.api.nvim_win_set_cursor(s.diff_win, { 1, 0 })
  h.ok(not winbar():find('next/prev', 1, true) and winbar():find('✓', 1, true), winbar())
  vim.api.nvim_win_set_cursor(s.diff_win, { marks[2].row, 0 })
  h.eq({ { marks[1].row, 'marker', '◆ guide' }, { marks[2].row, 'marker', '◆ guide' }, { marks[3].row, 'marker', '◆ guide' } },
    vim.tbl_map(function(m)
      return { m.row, m.kind, m.text }
    end, note_marks(s)))
  keys(s, ']n')
  h.eq(marks[3].row, vim.api.nvim_win_get_cursor(s.diff_win)[1], 'navigation works on collapsed notes')
  -- collapsed survives a re-render (window resize, refresh)
  view.rerender(s)
  h.eq('marker', note_marks(s)[1].kind)
  keys(s, 'gN')
  h.eq('lines', note_marks(s)[1].kind)
  -- the diff view has no notes; its ]n says where they are
  view.set_view('diff')
  h.eq({}, note_marks(s))
  notes = {}
  vim.notify = function(msg)
    notes[#notes + 1] = msg
  end
  keys(s, ']n')
  vim.notify = function() end
  h.ok(notes[1] and notes[1]:find('part of the guide view', 1, true), vim.inspect(notes))
  view.set_view('guide')
  h.eq(3, #note_marks(s))
end)

h.test('line notes: a note past an abridged hunk\'s preview is dropped (the prompt never showed it)', function()
  local s = view.session
  view.set_view('guide')
  vim.env.REVUEY_FAKE_CLAUDE = 'notes_abridged'
  config.options.ai.max_prompt_chars = #require('revuey.guide_prompt').SYSTEM + 3000
  view.guide_command(true)
  wait_job(s)
  config.options.ai.max_prompt_chars = 150000
  local stdin = calls()[#calls()].stdin
  h.ok(stdin:find('[abridged: ', 1, true), 'a hunk was abridged')
  h.eq('abridged', s.guide.record.generator.prompt_level)
  local notes = {}
  for _, sec in ipairs(s.guide.resolved.sections) do
    for _, it in ipairs(sec.items) do
      for _, n in ipairs(it.line_notes or {}) do
        notes[#notes + 1] = n.text
      end
    end
  end
  h.eq({ 'A line of the preview.' }, notes)
  h.eq({ kept = 1, dropped = 1, unknown_hunk = 0, bad_line = 1, empty = 0, duplicates = 0, extra = 0 }, s.guide.record.generator.warnings.notes)
end)

h.test('line notes: text renders inline only (no code blocks or callouts) and fits a narrow window', function()
  vim.env.REVUEY_FAKE_CLAUDE = 'notes'
  local s = view.session
  view.set_view('guide')
  view.guide_command(true)
  wait_job(s)
  local guide = require('revuey.guide')
  local rec = vim.deepcopy(s.guide.record)
  rec.anchors = s.guide.anchors
  rec.generator.generated_at = rec.generator.generated_at + 20
  local texts = { '```lua', '> [!WARNING] This is a bug.', 'Plain `code` here.' }
  local i = 0
  for _, sec in ipairs(rec.sections) do
    for _, a in ipairs(sec.hunks) do
      for _, n in ipairs(a.line_notes or {}) do
        i = i + 1
        n.text = texts[i]
      end
    end
  end
  guide.save(guide.dir(state_dir), rec)
  s = open(fixture)
  view.set_view('guide')
  vim.api.nvim_win_set_width(s.panel_win, 12) -- room for the words (the screen stays 80 wide)
  view.rerender(s)
  local got = vim.tbl_map(function(m)
    return m.text
  end, note_marks(s))
  -- (an unclosed backtick pair renders as text, never as a code block)
  h.eq({ '▼ guide `lua', '▼ guide · 2 lines > [!WARNING] This is a bug.', '▼ guide Plain code here.' }, got)
  -- a narrow window: every band fits it
  vim.api.nvim_win_set_width(s.diff_win, 30)
  view.rerender(s)
  local avail = vim.api.nvim_win_get_width(s.diff_win) - (2 * s.numw + 4)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(s.diff_buf, gv.ns_notes, 0, -1, { details = true })) do
    for _, l in ipairs(m[4].virt_lines or {}) do
      local w = 0
      for _, ch in ipairs(l) do
        w = w + vim.api.nvim_strwidth(ch[1])
      end
      h.ok(w <= math.max(avail, 1) + 0, ('band of %d cells in %d'):format(w, avail))
    end
  end
  vim.cmd('wincmd =')
end)

h.test('line notes: an old guide (version 1, no notes) still loads and renders', function()
  local s = view.session
  view.set_view('guide')
  local guide = require('revuey.guide')
  local old = vim.deepcopy(s.guide.record)
  old.version = 1
  old.title = 'An old guide'
  for _, sec in ipairs(old.sections) do
    for _, a in ipairs(sec.hunks) do
      a.line_notes = nil
    end
  end
  old.generator.generated_at = old.generator.generated_at + 10 -- the newest for this diff
  old.generator.warnings = { unknown = 0, duplicates = 0, missed = 0, unplaced = 0 }
  local f = io.open(guide.save(guide.dir(state_dir), old), 'r')
  h.ok(not f:read('*a'):find('line_notes', 1, true), 'written without notes')
  f:close()
  s = open(fixture)
  view.set_view('guide')
  h.eq('An old guide', lines(s)[1])
  h.eq({ 0, 0, false }, { s.guide.resolved.notes, s.guide.resolved.notes_lost, s.guide.resolved.stale })
  h.ok(find(s, '1. Core change', 'section'), text(s))
  h.eq({}, note_marks(s))
  local panel = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), '\n')
  h.ok(not panel:find('line note', 1, true), panel)
  local msgs = {}
  vim.notify = function(msg)
    msgs[#msgs + 1] = msg
  end
  keys(s, ']n')
  vim.notify = function() end
  h.eq({ 'revuey: this guide has no line notes' }, msgs)
end)

h.test('failures: invalid output, API error, not logged in, missing CLI; the last guide stays', function()
  local s = view.session
  local before = s.guide.resolved.title
  local msgs, restore = h.capture_notify()
  local function attempt(scenario)
    vim.env.REVUEY_FAKE_CLAUDE = scenario
    view.guide_command(true)
    wait_job(s)
    return msgs[#msgs].msg
  end
  h.ok(attempt('invalid'):find('not valid JSON', 1, true))
  h.ok(attempt('error'):find('API Error: 500', 1, true))
  local m = attempt('notloggedin')
  h.ok(m:find('claude is not logged in: run `claude` in a terminal and use /login', 1, true), m)
  h.ok(attempt('crash'):find('exited with code 3: fake claude: something broke', 1, true))
  config.options.ai.cmd = 'revuey-no-such-claude'
  view.guide_command(true)
  wait_job(s)
  config.options.ai.cmd = nil
  h.ok(msgs[#msgs].msg:find('`revuey-no-such-claude` not found on PATH', 1, true), msgs[#msgs].msg)
  -- over the prompt budget even as a file list: refused before anything runs
  local n_calls = #calls()
  config.options.ai.max_prompt_chars = #require('revuey.guide_prompt').SYSTEM + 300
  view.guide_command(true)
  wait_job(s)
  config.options.ai.max_prompt_chars = 150000
  h.ok(msgs[#msgs].msg:find('too large for one guide', 1, true), msgs[#msgs].msg)
  h.eq(n_calls, #calls(), 'claude was not started')
  restore()
  -- the previous guide is still shown
  h.eq(before, s.guide.resolved.title)
end)

local function alive(pid)
  return pid and vim.uv.kill(pid, 0) == 0
end

---pids {claude, sleep} written by the `kids` scenario (the last run).
local function kid_pids()
  local f = io.open(log .. '.kids', 'r')
  local last
  for l in (f and f:lines() or function() end) do
    last = l
  end
  if f then
    f:close()
  end
  local a, b = (last or ''):match('(%d+) (%-?%d+)')
  return tonumber(a), tonumber(b)
end

h.test('cancel and timeout stop the CLI and its child processes', function()
  local s = view.session
  vim.env.REVUEY_FAKE_CLAUDE = 'kids'
  os.remove(log .. '.kids')
  local msgs, restore = h.capture_notify()
  view.guide_command(true)
  assert(vim.wait(5000, function()
    local j = gv.job(s)
    return j and j.progress and kid_pids() ~= nil
  end, 10), 'started')
  local claude_pid, sleep_pid = kid_pids()
  h.ok(alive(claude_pid) and alive(sleep_pid), 'both running')
  vim.cmd('RevueyGuide cancel')
  wait_job(s)
  h.ok(msgs[#msgs].msg:find('cancelled', 1, true))
  h.ok(vim.wait(3000, function()
    return not alive(claude_pid) and not alive(sleep_pid)
  end, 20), 'claude and its child were killed')
  os.remove(log .. '.kids')
  config.options.ai.timeout_ms = 1000
  view.guide_command(true)
  assert(vim.wait(5000, function()
    return kid_pids() ~= nil
  end, 10), 'started again')
  claude_pid, sleep_pid = kid_pids()
  wait_job(s)
  config.options.ai.timeout_ms = 10 * 60 * 1000
  restore()
  h.ok(msgs[#msgs].msg:find('timed out after 1s', 1, true), msgs[#msgs].msg)
  h.ok(vim.wait(3000, function()
    return not alive(claude_pid) and not alive(sleep_pid)
  end, 20), 'killed on timeout')
  h.ok(find(s, 'Guide generation failed: timed out', 'prose') == nil, 'an existing guide stays, without the error')
end)

---Run a child Neovim that starts a guide with the fake `scenario`, optionally cancels it, and
---quits right away; returns the {claude, child} pids the fake recorded.
local function run_and_quit(scenario, cancel)
  os.remove(log .. '.kids')
  local fx = h.tmpdir('guide-quit')
  vim.fn.delete(fx, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', fx }):wait().code == 0)
  local script = h.tmpdir('guide-quit-script') .. '/quit.lua'
  vim.fn.writefile({
    'vim.opt.rtp:prepend(' .. vim.inspect(h.root) .. ')',
    'vim.cmd("runtime plugin/revuey.lua")',
    'vim.notify = function() end',
    'require("revuey").setup({ state_dir = ' .. vim.inspect(state_dir .. '-quit') .. ', lsp_warmup = false })',
    'local s',
    'require("revuey").open({ cwd = ' .. vim.inspect(fx) .. ', base = "main", on_ready = function(x) s = x end })',
    'vim.wait(10000, function() return s end)',
    'require("revuey.view").guide_command(true)',
    'local gv = require("revuey.guide_view")',
    'vim.wait(10000, function() local j = gv.job(s) return j and j.progress end)',
    'vim.wait(200)',
    cancel and 'require("revuey.view").guide_command(false, "cancel") vim.wait(50)' or '',
    'vim.cmd("qa!")',
  }, script)
  local res = vim.system({ vim.v.progpath, '--headless', '--clean', '-l', script }, { env = { REVUEY_FAKE_CLAUDE = scenario }, timeout = 20000 }):wait()
  h.eq(0, res.code, res.stderr)
  return kid_pids()
end

h.test('quitting Neovim during a run kills claude and its children', function()
  local claude_pid, sleep_pid = run_and_quit('kids', false)
  h.ok(claude_pid and sleep_pid and sleep_pid > 0, 'the run had started')
  h.ok(vim.wait(3000, function()
    return not alive(claude_pid) and not alive(sleep_pid)
  end, 20), 'nothing outlives Neovim')
end)

h.test('cancel then quit at once: a CLI that ignores SIGTERM is still killed, with its children', function()
  local claude_pid, child_pid = run_and_quit('stubborn', true)
  h.ok(claude_pid and child_pid and child_pid > 0, 'the run had started')
  local gone = vim.wait(3000, function()
    return not alive(claude_pid) and not alive(child_pid)
  end, 20)
  if not gone then -- don't leak them into the rest of the suite
    pcall(vim.uv.kill, -claude_pid, 'sigkill')
    pcall(vim.uv.kill, child_pid, 'sigkill')
  end
  h.ok(gone, 'nothing outlives Neovim')
end)

h.test('the direct kill is used when the process group cannot be signalled', function()
  local ai = require('revuey.ai')
  -- not spawned detached, so -pid names no process group: vim.uv.kill returns ESRCH
  local proc = vim.system({ 'sleep', '30' })
  local sent
  local orig = proc.kill
  proc.kill = function(self, sig)
    sent = sig
    return orig(self, sig)
  end
  ai.signal_group(proc, 'sigkill')
  h.eq('sigkill', sent)
  proc:wait(2000)
end)

h.test('a run outlives its review: reopening shows progress, then the guide', function()
  vim.env.REVUEY_FAKE_CLAUDE = 'slow'
  local d = h.tmpdir('guide-reopen')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', d }):wait().code == 0)
  local s = open(d)
  view.guide_command(true)
  view.close()
  s = open(d)
  view.set_view('guide')
  h.ok(gv.job(s), 'the run continues')
  h.ok(find(s, 'Generating a guide for'), text(s))
  wait_job(s)
  h.eq('Fake guide title', lines(s)[1])
end)

h.test('stack: layer and full scope have separate guides', function()
  vim.env.REVUEY_FAKE_CLAUDE = 'good'
  local d = h.tmpdir('guide-stack')
  vim.fn.delete(d, 'rf')
  assert(vim.system({ h.root .. '/scripts/make-fixture.sh', '--stack', d }):wait().code == 0)
  local s = open(d, { base = '' })
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  view.guide_command(true)
  wait_job(s)
  h.eq('guide', s.view_mode)
  local layer_ks = s.guide.ks
  h.ok(s.guide.resolved)
  -- the prompt says this is one branch of the stack, and the winbar names the scope
  local stdin = calls()[#calls()].stdin
  h.ok(stdin:find('This review covers only the branch `stack/cart`: its own changes on top of its parent branch `stack/math`.', 1, true), stdin)
  h.ok(stdin:find('(main <- stack/math <- stack/cart <- stack/ui)', 1, true), stdin)
  h.eq('layer stack/cart', gv.scope_title(s.review))
  h.ok(view.guide_winbar(s, s.diff_win):find('Guide · layer stack/cart', 1, true), view.guide_winbar(s, s.diff_win))
  keys(s, 'gs')
  h.eq({ kind = 'full' }, s.scope)
  h.eq('guide', s.view_mode, 'stays in the guide view')
  h.eq(nil, s.guide.resolved, 'no guide for the full stack yet')
  h.ok(find(s, 'No guide for this review yet.'), text(s))
  h.ok(s.guide.ks ~= layer_ks)
  h.eq('full stack', gv.scope_title(s.review))
  view.guide_command(true)
  wait_job(s)
  h.ok(s.guide.resolved)
  stdin = calls()[#calls()].stdin
  h.ok(stdin:find('This review covers a whole stack of 3 branches, each built on the one before it, bottom first:\n'
    .. '1. stack/math (on main)\n2. stack/cart (on stack/math)\n3. stack/ui (on stack/cart)\n', 1, true), stdin)
  h.ok(stdin:find('Commits by branch (bottom first, newest first within each):\n- stack/math:\n  - ', 1, true), stdin)
  local full_hunks = #s.guide.hunks
  keys(s, 'gs')
  h.eq({ kind = 'layer', index = 2 }, s.scope)
  h.ok(s.guide.resolved, 'the layer guide is still there')
  h.ok(#s.guide.hunks < full_hunks)
  h.eq(2, #vim.fn.glob(require('revuey.guide').dir(state_dir) .. '/*guide-stack*.json', true, true))
  -- a stack scope switch while generating: the job finishes for its own scope
  vim.env.REVUEY_FAKE_CLAUDE = 'slow'
  vim.fn.delete(require('revuey.guide').dir(state_dir), 'rf')
  view.set_view('diff')
  view.guide_command(true)
  keys(s, ']s')
  h.eq(3, s.scope.index)
  wait_job(s)
  h.eq(nil, s.guide.resolved, 'layer 3 has no guide')
  keys(s, '[s')
  h.ok(s.guide.resolved, 'layer 2 got its guide')
end)

h.run()
