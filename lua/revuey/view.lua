-- Review UI: composed diff buffer + file panel in a dedicated tabpage.
local api = vim.api
local config = require('revuey.config')
local git = require('revuey.git')
local diff = require('revuey.diff')
local layout_mod = require('revuey.layout')
local review_mod = require('revuey.review')
local syntax = require('revuey.syntax')
local highlights = require('revuey.highlights')
local panel = require('revuey.panel')
local lsp = require('revuey.lsp')
local linemap = require('revuey.linemap')
local stack_mod = require('revuey.stack')
local state_mod = require('revuey.state')
local guide_view = require('revuey.guide_view')

local M = {}

local cleanup -- forward declaration
local find_guide_anchor -- forward declaration

local ns = api.nvim_create_namespace('revuey.diff')
local WINBAR = "%!v:lua.require'revuey.view'.winbar()"

---@class revuey.Session
---@field review revuey.Review
---@field layout revuey.Layout
---@field opts table
---@field tab integer
---@field diff_buf integer
---@field diff_win integer
---@field panel_buf integer
---@field panel_win integer
---@field code_win? integer
---@field header_marks table<integer, integer>
---@field folds string[]
---@field numw integer
---@field current_file integer

---@type revuey.Session?
M.session = nil

local function session_for_buf(buf)
  local s = M.session
  if s and (s.diff_buf == buf or s.panel_buf == buf) then
    return s
  end
end

-- ---------------------------------------------------------------------------
-- Decoration
-- ---------------------------------------------------------------------------

local function header_virt(s, fi)
  local f = s.review.files[fi]
  local virt = { { '  ' } }
  if f.binary then
    virt[#virt + 1] = { 'binary', 'Comment' }
  else
    virt[#virt + 1] = { '+' .. f.added, 'RevueyCountAdd' }
    virt[#virt + 1] = { ' −' .. f.removed, 'RevueyCountDelete' }
  end
  local label = ({ A = 'added', D = 'deleted', R = 'renamed', T = 'type changed' })[f.status]
  if label then
    virt[#virt + 1] = { '  ' .. label, panel.status_hl[f.status] }
  end
  if review_mod.is_reviewed(s.review, f) then
    virt[#virt + 1] = { '  ✓ reviewed', 'RevueyReviewed' }
  end
  return virt
end

local function set_header_mark(s, fi)
  local row = s.layout.files[fi].start_row - 1
  s.header_marks[fi] = api.nvim_buf_set_extmark(s.diff_buf, ns, row, 0, {
    id = s.header_marks[fi],
    line_hl_group = 'RevueyFileHeader',
    virt_text = header_virt(s, fi),
    virt_text_pos = 'eol',
    hl_mode = 'combine',
    priority = 20,
  })
end

---Guide section heading: checkbox (inline) and status chips (end of line).
local function set_section_mark(s, si)
  local sec = s.guide and s.guide.resolved and s.guide.resolved.sections[si]
  local range = s.layout.sections and s.layout.sections[si]
  if not sec or not range then
    return
  end
  local reviewed = guide_view.section_reviewed(s, sec)
  local virt = { { '  ' } }
  local n = #sec.items
  virt[#virt + 1] = { n .. (n == 1 and ' hunk' or ' hunks'), 'Comment' }
  if sec.outdated then
    virt[#virt + 1] = { '  outdated', 'RevueyGuideOutdated' }
  end
  if sec.kind == 'new' then
    virt[#virt + 1] = { '  not in guide', 'RevueyGuideOutdated' }
  end
  if reviewed then
    virt[#virt + 1] = { '  ✓ reviewed', 'RevueyReviewed' }
  end
  s.section_marks = s.section_marks or {}
  s.section_marks[si] = api.nvim_buf_set_extmark(s.diff_buf, ns, range.start_row - 1, 0, {
    id = s.section_marks[si],
    line_hl_group = 'RevueyGuideSection',
    virt_text = virt,
    virt_text_pos = 'eol',
    hl_mode = 'combine',
    priority = 20,
  })
  s.section_check_marks = s.section_check_marks or {}
  s.section_check_marks[si] = api.nvim_buf_set_extmark(s.diff_buf, ns, range.start_row - 1, 0, {
    id = s.section_check_marks[si],
    virt_text = { sec.id and { reviewed and '☑ ' or '☐ ', reviewed and 'RevueyReviewed' or 'Comment' } or { '  ' } },
    virt_text_pos = 'inline',
    priority = 20,
  })
end

---Guide hunk header: "path  @@ ... @@" with the hunk's counts and the file's reviewed mark.
local function guide_hunk_virt(s, e)
  local f = s.review.files[e.file_idx]
  local virt = { { '  ' } }
  local hk = e.hunk_idx and f.hunks[e.hunk_idx]
  if hk then
    local a, d = 0, 0
    for _, l in ipairs(hk.lines) do
      a = a + (l.kind == 'add' and 1 or 0)
      d = d + (l.kind == 'del' and 1 or 0)
    end
    virt[#virt + 1] = { '+' .. a, 'RevueyCountAdd' }
    virt[#virt + 1] = { ' −' .. d, 'RevueyCountDelete' }
  end
  local label = ({ A = 'added', D = 'deleted', R = 'renamed', T = 'type changed' })[f.status]
  if label then
    virt[#virt + 1] = { '  ' .. label, panel.status_hl[f.status] }
  end
  if review_mod.is_reviewed(s.review, f) then
    virt[#virt + 1] = { '  ✓ file reviewed', 'RevueyReviewed' }
  end
  return virt
end

local function decorate(s)
  local buf, map = s.diff_buf, s.layout.map
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  s.header_marks = {}
  s.section_marks, s.section_check_marks = {}, {}
  for row, e in ipairs(map) do
    local r0 = row - 1
    if e.kind == 'prose' then
      for _, hl in ipairs(e.hls or {}) do
        pcall(api.nvim_buf_set_extmark, buf, ns, r0, hl[1], { end_col = hl[2], hl_group = hl[3], priority = 20 })
      end
    elseif e.meta == 'section' then
      local len = #s.layout.lines[row]
      local dot = s.layout.lines[row]:find('. ', 1, true) or 0
      api.nvim_buf_set_extmark(buf, ns, r0, 0, { end_col = dot, hl_group = 'RevueyGuideSectionNumber', priority = 21 })
      api.nvim_buf_set_extmark(buf, ns, r0, 0, { end_col = len, hl_group = 'RevueyGuideBold', priority = 20 })
      set_section_mark(s, e.section_idx)
    elseif e.meta == 'hunk' and e.path_len then
      local len = #s.layout.lines[row]
      api.nvim_buf_set_extmark(buf, ns, r0, 0, {
        end_col = len,
        hl_group = 'RevueyHunkHeader',
        line_hl_group = 'RevueyHunkHeaderBg',
        virt_text = guide_hunk_virt(s, e),
        virt_text_pos = 'eol',
        hl_mode = 'combine',
        priority = 20,
      })
      api.nvim_buf_set_extmark(buf, ns, r0, 0, { end_col = math.min(e.path_len, len), hl_group = 'RevueyFilePath', priority = 21 })
    end
    -- Full-line background as a low-priority hl_group range with hl_eol (not line_hl_group, which
    -- would paint over the word-diff backgrounds); tree-sitter foregrounds combine on top.
    if e.kind == 'add' then
      api.nvim_buf_set_extmark(buf, ns, r0, 0, { end_row = r0 + 1, end_col = 0, hl_group = 'RevueyAdd', hl_eol = true, priority = 10 })
    elseif e.kind == 'del' then
      api.nvim_buf_set_extmark(buf, ns, r0, 0, { end_row = r0 + 1, end_col = 0, hl_group = 'RevueyDelete', hl_eol = true, priority = 10 })
    elseif e.meta == 'file' then
      local len = #s.layout.lines[row]
      api.nvim_buf_set_extmark(buf, ns, r0, 0, { end_col = len, hl_group = 'RevueyFilePath', priority = 20 })
      set_header_mark(s, e.file_idx)
    elseif e.meta == 'hunk' then
      local len = #s.layout.lines[row]
      api.nvim_buf_set_extmark(buf, ns, r0, 0, {
        end_col = len,
        hl_group = 'RevueyHunkHeader',
        line_hl_group = 'RevueyHunkHeaderBg',
        priority = 20,
      })
    elseif e.meta == 'note' then
      api.nvim_buf_set_extmark(buf, ns, r0, 0, { end_col = #s.layout.lines[row], hl_group = 'RevueyNote' })
    end
  end
  -- Line-ending indicators (cheap: only flagged lines). Otherwise identical -/+ pairs would be
  -- shown with no visible difference.
  for row, e in ipairs(map) do
    if e.kind ~= 'meta' and e.kind ~= 'prose' then
      local hk = s.review.files[e.file_idx].hunks[e.hunk_idx]
      if hk.has_eol_flags == nil then
        hk.has_eol_flags = false
        for _, x in ipairs(hk.lines) do
          if x.cr or x.no_eol then
            hk.has_eol_flags = true
            break
          end
        end
      end
      local l = hk.lines[e.line_idx]
      local note
      if e.kind == 'add' and hk.has_eol_flags then
        local partner = s.pair_of and s.pair_of(row)
        local d = partner and s.review.files[e.file_idx].hunks[e.hunk_idx].lines[map[partner].line_idx]
        note = d and diff.eol_change(d, l)
      end
      if not note and l.no_eol then
        note = 'no newline at end of file'
      end
      if note then
        api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
          virt_text = { { '  ⏎ ' .. note, 'RevueyNote' } },
          virt_text_pos = 'eol',
          hl_mode = 'combine',
        })
      end
    end
  end
end

---Lazy word diff: spans for a composed row (0-based), computed per hunk on first draw and cached.
---Skipped for files larger than `collapse_large_files` diff lines.
local function make_word_spans(s)
  local cache = {} -- [file_idx..':'..hunk_idx] = { [row0] = spans }
  local partner = {} -- [row1] = paired row1 (add <-> del)
  local function hunk_pairs(fi, hi)
    local key = fi .. ':' .. hi
    local c = cache[key]
    if c then
      return c
    end
    c = {}
    cache[key] = c
    local f = s.review.files[fi]
    local h = f.hunks[hi]
    local hrow = s.layout.hunk_base[fi][hi] -- line k of the hunk is at hrow + k
    for _, p in ipairs(diff.pair_changes(h.lines)) do
      local drow, arow = hrow + p[1], hrow + p[2]
      partner[drow], partner[arow] = arow, drow
      if config.options.word_diff and f.added + f.removed <= config.options.collapse_large_files then
        local dr, ar = diff.word_diff(h.lines[p[1]].text, h.lines[p[2]].text)
        if dr and ar then
          local ds, as = {}, {}
          for _, r in ipairs(dr) do
            ds[#ds + 1] = { r[1], r[2], 'RevueyDeleteText', 90 }
          end
          for _, r in ipairs(ar) do
            as[#as + 1] = { r[1], r[2], 'RevueyAddText', 90 }
          end
          c[drow - 1], c[arow - 1] = ds, as
        end
      end
    end
    return c
  end
  s.word_spans = function(row0)
    local e = s.layout.map[row0 + 1]
    if not e or (e.kind ~= 'add' and e.kind ~= 'del') then
      return nil
    end
    return hunk_pairs(e.file_idx, e.hunk_idx)[row0]
  end
  s.pair_of = function(row1)
    local e = s.layout.map[row1]
    if not e or not e.hunk_idx then
      return nil
    end
    hunk_pairs(e.file_idx, e.hunk_idx)
    return partner[row1]
  end
end

-- ---------------------------------------------------------------------------
-- Window-option callbacks (statuscolumn, folds, winbar)
-- ---------------------------------------------------------------------------

local function pad(n, w)
  local str = n and tostring(n) or ''
  return string.rep(' ', w - #str) .. str
end

function M.statuscolumn()
  local win = vim.g.statusline_winid
  if not win or not api.nvim_win_is_valid(win) then
    return ''
  end
  local s = session_for_buf(api.nvim_win_get_buf(win))
  if not s then
    return ''
  end
  local w = s.numw
  local blank = string.rep(' ', 2 * w + 4)
  if vim.v.virtnum ~= 0 then
    return blank
  end
  local e = s.layout.map[vim.v.lnum]
  if not e then
    return blank
  end
  if e.kind == 'add' then
    return '%#RevueyLineNr#' .. pad(nil, w) .. ' %#RevueyAddLineNr#' .. pad(e.new_lnum, w) .. '%#RevueyAddSign# + '
  elseif e.kind == 'del' then
    return '%#RevueyDeleteLineNr#' .. pad(e.old_lnum, w) .. ' ' .. pad(nil, w) .. '%#RevueyDeleteSign# - '
  elseif e.kind == 'ctx' then
    return '%#RevueyLineNr#' .. pad(e.old_lnum, w) .. ' ' .. pad(e.new_lnum, w) .. '   '
  elseif e.meta == 'file' then
    local f = s.review.files[e.file_idx]
    local hl = panel.status_hl[f.status] or 'Normal'
    local lnum = vim.v.lnum
    local folded = api.nvim_win_call(win, function()
      return vim.fn.foldclosed(lnum) ~= -1
    end)
    return '%#' .. hl .. '#' .. pad(f.status, w) .. ' ' .. pad(nil, w) .. ' ' .. (folded and '▸' or '▾') .. ' '
  elseif e.meta == 'section' then
    local lnum = vim.v.lnum
    local folded = api.nvim_win_call(win, function()
      return vim.fn.foldclosed(lnum) ~= -1
    end)
    return '%#RevueyGuideSectionNumber#' .. string.rep(' ', 2 * w + 1) .. (folded and '▸' or '▾') .. ' '
  elseif e.meta == 'hunk' and e.path_len then
    local f = s.review.files[e.file_idx]
    return '%#' .. (panel.status_hl[f.status] or 'Normal') .. '#' .. pad(f.status, w) .. ' ' .. pad(nil, w) .. '   '
  end
  return blank
end

function M.foldexpr()
  local s = session_for_buf(api.nvim_get_current_buf())
  if not s then
    return '0'
  end
  return s.folds[vim.v.lnum] or '0'
end

function M.foldtext()
  local s = session_for_buf(api.nvim_get_current_buf())
  local fs, fe = vim.v.foldstart, vim.v.foldend
  if not s then
    return vim.fn.foldtext()
  end
  local e = s.layout.map[fs]
  if e and e.meta == 'file' then
    local f = s.review.files[e.file_idx]
    local chunks = { { s.layout.lines[fs], 'RevueyFilePath' } }
    vim.list_extend(chunks, header_virt(s, e.file_idx))
    local hidden = 0
    for _, h in ipairs(f.hunks) do
      hidden = hidden + #h.lines
    end
    chunks[#chunks + 1] = { '  (' .. hidden .. ' lines folded)', 'Comment' }
    return chunks
  end
  if e and e.meta == 'section' then
    local sec = s.guide and s.guide.resolved and s.guide.resolved.sections[e.section_idx]
    local reviewed = sec and guide_view.section_reviewed(s, sec)
    local chunks = {
      { (sec and sec.id) and (reviewed and '☑ ' or '☐ ') or '  ', reviewed and 'RevueyReviewed' or 'Comment' },
      { s.layout.lines[fs], 'RevueyGuideBold' },
    }
    if sec then
      chunks[#chunks + 1] = { '  ' .. #sec.items .. (#sec.items == 1 and ' hunk' or ' hunks'), 'Comment' }
      if sec.outdated then
        chunks[#chunks + 1] = { '  outdated', 'RevueyGuideOutdated' }
      end
      if reviewed then
        chunks[#chunks + 1] = { '  ✓ reviewed', 'RevueyReviewed' }
      end
    end
    chunks[#chunks + 1] = { '  (' .. (fe - fs) .. ' lines folded)', 'Comment' }
    return chunks
  end
  if e and e.meta == 'hunk' then
    local text = s.layout.lines[fs]
    local chunks
    if e.path_len then
      chunks = { { text:sub(1, e.path_len), 'RevueyFilePath' }, { text:sub(e.path_len + 1), 'RevueyHunkHeader' } }
      vim.list_extend(chunks, guide_hunk_virt(s, e))
    else
      chunks = { { text, 'RevueyHunkHeader' } }
    end
    chunks[#chunks + 1] = { '  (' .. (fe - fs) .. ' lines folded)', 'Comment' }
    return chunks
  end
  return { { '⋯ ' .. (fe - fs + 1) .. ' unchanged lines', 'RevueyFold' } }
end

local function file_at_row(s, row)
  local e = s.layout.map[row]
  return e and e.file_idx or 1
end

function M.winbar()
  local win = vim.g.statusline_winid
  if not win or not api.nvim_win_is_valid(win) then
    return ''
  end
  local s = session_for_buf(api.nvim_win_get_buf(win))
  if s and s.view_mode == 'guide' then
    return M.guide_winbar(s, win)
  end
  if not s or #s.review.files == 0 then
    return ''
  end
  local top = vim.fn.line('w0', win)
  local fi = file_at_row(s, top)
  local f = s.review.files[fi]
  local esc = function(str)
    return (str:gsub('%%', '%%%%'))
  end
  local parts = {
    ' %#' .. (panel.status_hl[f.status] or 'Normal') .. '#' .. f.status .. ' ',
    '%#RevueyFilePath#' .. esc(layout_mod.file_title(f)) .. ' ',
    f.binary and '%#Comment#binary' or ('%#RevueyCountAdd#+' .. f.added .. ' %#RevueyCountDelete#−' .. f.removed),
  }
  if review_mod.is_reviewed(s.review, f) then
    parts[#parts + 1] = '  %#RevueyReviewed#✓ reviewed'
  end
  parts[#parts + 1] = '%*%=' .. fi .. '/' .. #s.review.files .. ' '
  return table.concat(parts)
end

---Section containing (or following) a row of the guide layout.
local function section_at_row(s, row)
  local secs = s.layout.sections or {}
  for i = #secs, 1, -1 do
    if secs[i].start_row <= row then
      return i
    end
  end
  return nil
end

function M.guide_winbar(s, win)
  local esc = function(str)
    return (str:gsub('%%', '%%%%'))
  end
  local res = s.guide and s.guide.resolved
  local scope = guide_view.scope_title(s.review)
  local parts = { ' %#RevueyGuideSectionNumber#Guide' .. (scope and esc(' · ' .. scope) or '') .. ' ' }
  if res then
    local top = vim.fn.line('w0', win)
    local si = section_at_row(s, top)
    local sec = si and res.sections[si]
    parts[#parts + 1] = '%#RevueyWinbar#' .. esc(sec and (si .. '. ' .. sec.title) or res.title)
    local done, total = guide_view.progress(s)
    parts[#parts + 1] = '%*%=' .. (si and ('§' .. si .. '/' .. #res.sections .. '  ') or '')
    parts[#parts + 1] = ((total > 0 and done == total) and '%#RevueyReviewed#' or '%#Comment#') .. '✓ ' .. done .. '/' .. total .. ' '
  else
    parts[#parts + 1] = guide_view.job(s) and '%#RevueyGuideSpinner#generating…' or '%#Comment#no guide yet'
  end
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Navigation & actions
-- ---------------------------------------------------------------------------

local function cursor_row(s)
  return api.nvim_win_get_cursor(s.diff_win)[1]
end

---Session + side-table entry under the cursor, or nil (no review, or empty review).
local function current(s)
  if not s or #s.review.files == 0 or not api.nvim_win_is_valid(s.diff_win) then
    return nil
  end
  local row = cursor_row(s)
  local e = s.layout.map[row]
  if not e then
    return nil
  end
  return e, row
end

---Move the diff window's cursor to `row`. `how`: 'top' scrolls it to the top; 'nofold' leaves
---folds alone (default: open folds at the cursor, like `zv`).
local function goto_row(s, row, how, col)
  api.nvim_win_call(s.diff_win, function()
    local top, bot = vim.fn.line('w0'), vim.fn.line('w$')
    api.nvim_win_set_cursor(0, { row, col or 0 })
    if how ~= 'top' and how ~= 'nofold' then
      vim.cmd('normal! zv')
    end
    if how == 'top' then
      vim.cmd('normal! zt')
    elseif row < top or row > bot then
      vim.cmd('normal! zz')
    end
  end)
end

---Is `row` inside a collapsed file, section or hunk (not just a folded context run)?
local function in_closed_file_fold(s, row)
  return api.nvim_win_call(s.diff_win, function()
    local c = vim.fn.foldclosed(row)
    local m = c ~= -1 and s.layout.map[c] and s.layout.map[c].meta
    return m == 'file' or m == 'section' or m == 'hunk'
  end)
end

function M.next_hunk(dir)
  local s = M.session
  if not current(s) then
    return
  end
  local row = cursor_row(s)
  for _ = 1, vim.v.count1 do
    local target
    local hunks = s.layout.hunks
    if dir > 0 then
      for _, h in ipairs(hunks) do
        if h.first_change > row and not in_closed_file_fold(s, h.first_change) then
          target = h.first_change
          break
        end
      end
    else
      for i = #hunks, 1, -1 do
        local h = hunks[i]
        if h.first_change < row and not in_closed_file_fold(s, h.first_change) then
          target = h.first_change
          break
        end
      end
    end
    if not target then
      break
    end
    row = target
  end
  api.nvim_win_call(s.diff_win, function()
    vim.cmd("normal! m'")
  end)
  goto_row(s, row)
  api.nvim_win_call(s.diff_win, function()
    vim.cmd('normal! zv')
  end)
end

function M.next_file(dir)
  local s = M.session
  if s and s.view_mode == 'guide' then
    return M.next_section(dir)
  end
  if not current(s) then
    return
  end
  local row = cursor_row(s)
  for _ = 1, vim.v.count1 do
    local target
    if dir > 0 then
      for _, r in ipairs(s.layout.files) do
        if r.start_row > row then
          target = r.start_row
          break
        end
      end
    else
      for i = #s.layout.files, 1, -1 do
        if s.layout.files[i].start_row < row then
          target = s.layout.files[i].start_row
          break
        end
      end
    end
    if not target then
      break
    end
    row = target
  end
  goto_row(s, row, 'top')
end

---Window used for real files (opened below the diff window and reused).
local function code_window(s)
  if s.code_win and api.nvim_win_is_valid(s.code_win) and api.nvim_win_get_tabpage(s.code_win) == s.tab then
    return s.code_win
  end
  api.nvim_set_current_win(s.diff_win)
  vim.cmd('belowright split')
  s.code_win = api.nvim_get_current_win()
  api.nvim_win_set_height(s.code_win, math.floor(vim.o.lines * 0.45))
  return s.code_win
end
M.code_window = code_window

local function open_path(s, abs, lnum, col)
  if not vim.uv.fs_stat(abs) then
    return vim.notify('revuey: not in working tree: ' .. abs, vim.log.levels.WARN)
  end
  local win = code_window(s)
  api.nvim_set_current_win(win)
  vim.cmd('edit ' .. vim.fn.fnameescape(abs))
  local count = api.nvim_buf_line_count(0)
  pcall(api.nvim_win_set_cursor, win, { math.min(math.max(lnum, 1), count), col or 0 })
  vim.cmd('normal! zvzz')
end

function M.open_file()
  local s = M.session
  local e = current(s)
  if not e then
    return
  end
  local f = e.file_idx and s.review.files[e.file_idx]
  if not f then
    if e.meta == 'section' then
      return M.toggle_section_fold(e.section_idx)
    end
    return
  end
  if f.status == 'D' then
    return vim.notify('revuey: file was deleted on this branch', vim.log.levels.INFO)
  end
  local lnum = e.new_lnum or e.anchor_lnum or 1
  local col = (e.kind == 'add' or e.kind == 'ctx') and api.nvim_win_get_cursor(s.diff_win)[2] or 0
  local abs = vim.fs.joinpath(s.review.root, f.path)
  if not f.worktree then
    -- committed side (committed mode, or a layer that isn't HEAD): the file on disk may differ,
    -- so map the line through a diff of the reviewed text against it
    lnum = M.map_to_disk(M.head_text(s, f), git.read_file(abs), lnum)
  end
  open_path(s, abs, lnum, col)
end

---Map a line of `text` (the reviewed new side) to the same line in `disk` (the working-tree
---file); a changed line maps to the nearest unchanged line above it, shifted.
function M.map_to_disk(text, disk, lnum)
  if not text or not disk or text == disk then
    return lnum
  end
  local fwd = linemap.new(text, disk)
  for d = 0, 500 do
    local m = lnum - d >= 1 and fwd(lnum - d)
    if m then
      return m + d
    end
  end
  return lnum
end

---HEAD content of a file in the review (cached per session).
function M.head_text(s, f)
  if not f.new_blob then
    return nil
  end
  s.head_cache = s.head_cache or {}
  local t = s.head_cache[f.new_blob]
  if t == nil then
    if f.worktree then
      -- working-tree mode: the reviewed new side is the file on disk
      t = f.new_text or git.read_file(vim.fs.joinpath(s.review.root, f.path)) or false
    else
      t = git.blob(f.new_blob, s.review.root) or false
    end
    s.head_cache[f.new_blob] = t
  end
  return t or nil
end

---Map a working-tree location (fname, lnum), e.g. an LSP definition, to the composed add/ctx
---row showing that line, or nil (then the real file is opened instead).
---Working-tree lines are mapped to HEAD lines through a diff of the buffer against the HEAD blob
---(identity on a clean tree), then looked up exactly. Text is never searched for, so duplicated
---lines elsewhere in the file cannot be picked.
function M.diff_row_for_location(s, fname, lnum)
  fname = vim.uv.fs_realpath(fname) or fname
  local root = (vim.uv.fs_realpath(s.review.root) or s.review.root) .. '/'
  if fname:sub(1, #root) ~= root then
    return nil
  end
  local rel = fname:sub(#root + 1)
  local f
  for _, x in ipairs(s.review.files) do
    if x.path == rel then
      f = x
    end
  end
  local head = f and M.head_text(s, f)
  if not head then
    return nil
  end
  local buf = lsp.file_buffer(vim.fs.joinpath(s.review.root, rel))
  if not buf then
    return nil
  end
  local buf_text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
  -- same diff direction (HEAD -> working tree) as lsp.match_line, so round trips agree
  local _, wt_to_head = linemap.both(head, buf_text)
  local head_lnum = wt_to_head(lnum)
  if not head_lnum then
    return nil -- uncommitted line: no HEAD counterpart
  end
  return layout_mod.find_new_row(s.layout, s.review.files, rel, head_lnum)
end

local function lsp_target(s)
  if not current(s) then
    return nil
  end
  local row, col = unpack(api.nvim_win_get_cursor(s.diff_win))
  local e = s.layout.map[row]
  if not e or (e.kind ~= 'add' and e.kind ~= 'ctx') then
    vim.notify('revuey: LSP is available on added and context lines only', vim.log.levels.INFO)
    return nil
  end
  local f = s.review.files[e.file_idx]
  return {
    abs = vim.fs.joinpath(s.review.root, f.path),
    lnum = e.new_lnum,
    col = col,
    text = s.layout.lines[row],
    head = M.head_text(s, f),
  }
end

function M.definition()
  local s = M.session
  if not s then
    return
  end
  local target = lsp_target(s)
  if not target then
    return
  end
  lsp.request(target, 'textDocument/definition', function(err, result, client)
    if err then
      return vim.notify('revuey: definition failed: ' .. tostring(err.message or err), vim.log.levels.WARN)
    end
    local locs = lsp.locations(result)
    if #locs == 0 or not client then
      return vim.notify('revuey: no definition found', vim.log.levels.INFO)
    end
    if M.session ~= s then
      return
    end
    if #locs == 1 then
      local loc = locs[1]
      local fname = vim.uri_to_fname(loc.uri)
      local lnum = loc.range.start.line + 1
      -- Prefer jumping inside the review when the definition is shown in the diff. The location is
      -- in working-tree coordinates (the file may have uncommitted edits), so map it back by text.
      local row = M.diff_row_for_location(s, fname, lnum)
      if row then
        api.nvim_set_current_win(s.diff_win)
        vim.cmd("normal! m'")
        local line = s.layout.lines[row]
        local col = vim.str_byteindex(line, client.offset_encoding, loc.range.start.character, false)
        goto_row(s, row, nil, col)
        return
      end
      local win = code_window(s)
      api.nvim_set_current_win(win)
      vim.lsp.util.show_document({ uri = loc.uri, range = loc.range }, client.offset_encoding, { focus = true })
      vim.cmd('normal! zvzz')
    else
      local items = vim.lsp.util.locations_to_items(result, client.offset_encoding)
      vim.fn.setqflist({}, ' ', { title = 'revuey: definitions', items = items })
      api.nvim_set_current_win(code_window(s))
      vim.cmd('cfirst')
      vim.cmd('botright copen')
    end
  end)
end

function M.hover()
  local s = M.session
  if not s then
    return
  end
  local target = lsp_target(s)
  if not target then
    return
  end
  local win = api.nvim_get_current_win()
  lsp.request(target, 'textDocument/hover', function(err, result)
    if err or not result or not result.contents or result.contents == '' then
      return vim.notify('revuey: no hover information', vim.log.levels.INFO)
    end
    if api.nvim_get_current_win() ~= win then
      return
    end
    local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
    if vim.tbl_isempty(lines) then
      return vim.notify('revuey: no hover information', vim.log.levels.INFO)
    end
    vim.lsp.util.open_floating_preview(lines, 'markdown', { border = 'rounded', focus_id = 'revuey_hover' })
  end, function(r)
    if type(r) ~= 'table' or r.contents == nil then
      return true
    end
    local c = r.contents
    return c == '' or (type(c) == 'table' and (c.value == '' or (c.value == nil and vim.tbl_isempty(c))))
  end)
end

local function close_file_fold(s, fi, close)
  local row = s.layout.files[fi].start_row
  api.nvim_win_call(s.diff_win, function()
    pcall(vim.cmd, row .. (close and 'foldclose' or 'foldopen'))
  end)
end

function M.toggle_reviewed(fi)
  local s = M.session
  if not s then
    return
  end
  if #s.review.files == 0 then
    return
  end
  if s.view_mode == 'guide' then
    if not fi then
      return M.toggle_section()
    end
    -- a file mark from the panel: shown on the guide's hunk headers
    local f = s.review.files[fi]
    if f then
      review_mod.toggle_reviewed(s.review, f)
      decorate(s)
      panel.render(s)
    end
    return
  end
  fi = fi or file_at_row(s, cursor_row(s))
  local f = s.review.files[fi]
  if not f then
    return
  end
  local now = review_mod.toggle_reviewed(s.review, f)
  set_header_mark(s, fi)
  panel.render(s)
  close_file_fold(s, fi, now)
  if now and api.nvim_get_current_win() == s.diff_win then
    -- move on to the next file, like GitHub's "Viewed" checkbox
    local nxt = s.layout.files[fi + 1]
    -- the last file: stay on its header without reopening the fold just closed
    goto_row(s, nxt and nxt.start_row or s.layout.files[fi].start_row, nxt and 'top' or 'nofold')
  end
end

-- ---------------------------------------------------------------------------
-- Guide view: sections
-- ---------------------------------------------------------------------------

local function section_fold(s, si, close)
  local r = s.layout.sections and s.layout.sections[si]
  if not r then
    return
  end
  api.nvim_win_call(s.diff_win, function()
    pcall(vim.cmd, r.start_row .. (close and 'foldclose' or 'foldopen'))
  end)
end

function M.toggle_section_fold(si)
  local s = M.session
  local r = s and s.layout.sections and s.layout.sections[si]
  if not r then
    return
  end
  local closed = api.nvim_win_call(s.diff_win, function()
    return vim.fn.foldclosed(r.start_row) ~= -1
  end)
  section_fold(s, si, not closed)
end

---]] / [[ in the guide: next/previous section heading (takes a count).
function M.next_section(dir)
  local s = M.session
  if not s or not current(s) then
    return
  end
  if s.view_mode ~= 'guide' then
    return M.next_file(dir)
  end
  local secs = s.layout.sections or {}
  if #secs == 0 then
    return
  end
  local row = cursor_row(s)
  local target
  for _ = 1, vim.v.count1 do
    local t
    if dir > 0 then
      for _, r in ipairs(secs) do
        if r.start_row > row then
          t = r.start_row
          break
        end
      end
    else
      for i = #secs, 1, -1 do
        if secs[i].start_row < row then
          t = secs[i].start_row
          break
        end
      end
    end
    if not t then
      break
    end
    row, target = t, t
  end
  if target then
    api.nvim_win_call(s.diff_win, function()
      vim.cmd("normal! m'")
    end)
    goto_row(s, target, 'top')
  end
end

---`mr` in the guide: toggle the reviewed state of the section under the cursor (or `si`); a newly
---reviewed section folds and the cursor moves to the next section.
function M.toggle_section(si)
  local s = M.session
  if not s or s.view_mode ~= 'guide' or not s.guide or not s.guide.resolved then
    return
  end
  si = si or section_at_row(s, cursor_row(s))
  local sec = si and s.guide.resolved.sections[si]
  if not sec then
    return vim.notify('revuey: move to a section to mark it reviewed', vim.log.levels.INFO)
  end
  if not sec.id then
    return vim.notify('revuey: this section shows no hunks', vim.log.levels.INFO)
  end
  local now, err = state_mod.toggle_section(s.review.state, sec.id)
  if err then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
  set_section_mark(s, si)
  panel.render(s)
  section_fold(s, si, now)
  if now and api.nvim_get_current_win() == s.diff_win then
    local nxt = s.layout.sections[si + 1]
    goto_row(s, nxt and nxt.start_row or s.layout.sections[si].start_row, nxt and 'top' or 'nofold')
  end
  return now
end

-- ---------------------------------------------------------------------------
-- Folding: <Tab> on title lines, <S-Tab> for every file / section
-- ---------------------------------------------------------------------------

---Identities of the layout's hunk blocks (cached on the layout), for keeping a collapsed hunk
---collapsed across re-renders: a hash of the path and the hunk's lines (so it survives line
---shifts), or the path for a file without hunks. Identical blocks get `@old_start,new_start`
---appended, like the guide's hunk hashes, so one never takes another's fold.
local function block_keys(s)
  local L = s.layout
  if L.block_keys then
    return L.block_keys
  end
  local keys, hunks, count = {}, {}, {}
  for i, b in ipairs(L.blocks or {}) do
    local e = L.map[b.start_row]
    local f = e and e.file_idx and s.review.files[e.file_idx]
    if f then
      local hi = e.hunk_id and tonumber(e.hunk_id:match('#(%d+)$'))
      local hk = hi and f.hunks[hi]
      local k = f.path
      if hk then
        local parts = { f.path }
        for _, l in ipairs(hk.lines) do
          parts[#parts + 1] = l.kind .. l.text
        end
        k = vim.fn.sha256(table.concat(parts, '\n'))
      end
      keys[i], hunks[i] = k, hk
      count[k] = (count[k] or 0) + 1
    end
  end
  for i in pairs(keys) do
    if count[keys[i]] > 1 then
      local hk = hunks[i]
      keys[i] = keys[i] .. '@' .. (hk and (hk.old_start .. ',' .. hk.new_start) or i)
    end
  end
  L.block_keys = keys
  return keys
end

local function block_key_at(s, row)
  for i, b in ipairs(s.layout.blocks or {}) do
    if b.start_row == row then
      return block_keys(s)[i]
    end
  end
end

---Collapsed hunk blocks for the current view mode (a set of block keys). Kept in the session
---rather than read back from the window, because a hunk inside a collapsed file or section can't
---be seen to be collapsed.
local function hunk_folds(s)
  s.hunk_folds = s.hunk_folds or {}
  local mode = s.view_mode == 'guide' and 'guide' or 'diff'
  s.hunk_folds[mode] = s.hunk_folds[mode] or {}
  return s.hunk_folds[mode]
end

---Update the set from the window wherever a hunk's own state is visible (it was toggled with
---`za`, `zc`, `zR`...); hunks inside a collapsed parent keep what the set says.
local function sync_hunk_folds(s)
  if not api.nvim_win_is_valid(s.diff_win) then
    return
  end
  local set, keys = hunk_folds(s), block_keys(s)
  api.nvim_win_call(s.diff_win, function()
    for i, b in ipairs(s.layout.blocks or {}) do
      local k = keys[i]
      if k then
        local c = vim.fn.foldclosed(b.start_row)
        if c == -1 then
          set[k] = nil
        elseif c == b.start_row then
          set[k] = true
        end
      end
    end
  end)
end

---Re-collapse the hunks in the set after a re-render (before any file/section fold is closed).
local function restore_hunk_folds(s)
  local set = hunk_folds(s)
  if next(set) == nil then
    return
  end
  local keys = block_keys(s)
  api.nvim_win_call(s.diff_win, function()
    for i, b in ipairs(s.layout.blocks or {}) do
      if keys[i] and set[keys[i]] then
        pcall(vim.cmd, b.start_row .. 'foldclose')
      end
    end
  end)
end

---Title rows: file headers, hunk headers (diff and guide) and guide section headings.
local fold_titles = { file = true, hunk = true, section = true }

---Expr mapping for `toggle_fold` (<Tab>): `za` on a title line (or a fold closed at one), else
---<C-i>, so jumplist-forward is untouched everywhere else (<Tab> is <C-i> in most terminals). A
---count always means the jumplist (the typed count still applies to the returned <C-i>).
---Returned keys are not remapped.
function M.fold_key()
  local s = M.session
  if vim.v.count == 0 and s and api.nvim_get_current_buf() == s.diff_buf and #s.review.files > 0 then
    local row = api.nvim_win_get_cursor(0)[1]
    local c = vim.fn.foldclosed(row)
    local top = c ~= -1 and c or row
    local e = s.layout.map[top]
    if e and fold_titles[e.meta] then
      if e.meta == 'hunk' then
        local k = block_key_at(s, top)
        if k then
          hunk_folds(s)[k] = (c ~= top) or nil -- `za` is about to flip it
        end
      end
      return 'za'
    end
  end
  return '<C-i>'
end

---`toggle_all_folds` (<S-Tab>): collapse every file (guide: every section), or expand them all when
---they are all collapsed. Does not mark anything reviewed.
function M.toggle_all_folds()
  local s = M.session
  if not current(s) then
    return
  end
  local ranges = s.view_mode == 'guide' and (s.layout.sections or {}) or s.layout.files
  api.nvim_win_call(s.diff_win, function()
    local any_open = false
    for _, r in ipairs(ranges) do
      if vim.fn.foldclosed(r.start_row) == -1 then
        any_open = true
        break
      end
    end
    for _, r in ipairs(ranges) do
      local closed = vim.fn.foldclosed(r.start_row) ~= -1
      if any_open and not closed then
        pcall(vim.cmd, r.start_row .. 'foldclose')
      elseif not any_open and closed then
        pcall(vim.cmd, r.start_row .. 'foldopen')
      end
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local function map(buf, lhs, fn, desc)
  if not lhs or lhs == false then
    return
  end
  for _, l in ipairs(type(lhs) == 'table' and lhs or { lhs }) do
    vim.keymap.set('n', l, fn, { buffer = buf, nowait = true, silent = true, desc = 'revuey: ' .. desc })
  end
end

local function stack_keymaps(buf)
  local k = config.options.keymaps
  map(buf, k.next_layer, function()
    M.next_layer(1)
  end, 'next stack layer')
  map(buf, k.prev_layer, function()
    M.next_layer(-1)
  end, 'previous stack layer')
  map(buf, k.toggle_stack, M.toggle_full, 'toggle full stack / layer scope')
end

local function guide_keymaps(buf)
  local k = config.options.keymaps
  map(buf, k.toggle_guide, function()
    M.guide_command(false)
  end, 'toggle AI guide view')
  map(buf, k.regenerate_guide, function()
    M.regenerate_guide()
  end, 'generate a new AI guide')
end

local function diff_keymaps(s)
  local k = config.options.keymaps
  local buf = s.diff_buf
  map(buf, k.next_hunk, function()
    M.next_hunk(1)
  end, 'next hunk')
  map(buf, k.prev_hunk, function()
    M.next_hunk(-1)
  end, 'previous hunk')
  map(buf, k.next_file, function()
    M.next_file(1)
  end, 'next file')
  map(buf, k.prev_file, function()
    M.next_file(-1)
  end, 'previous file')
  map(buf, k.open_file, M.open_file, 'open file at line')
  map(buf, k.definition, M.definition, 'LSP definition')
  map(buf, k.hover, M.hover, 'LSP hover')
  map(buf, k.toggle_reviewed, function()
    M.toggle_reviewed()
  end, 'toggle file reviewed')
  map(buf, k.refresh, function()
    M.refresh({ force = true, notify = true })
  end, 'refresh review')
  map(buf, k.toggle_mode, M.toggle_mode, 'toggle working tree / committed only')
  map(buf, k.close, M.close, 'close review')
  stack_keymaps(buf)
  guide_keymaps(buf)
  map(buf, k.next_section, function()
    M.next_section(1)
  end, 'next guide section (diff: next file)')
  map(buf, k.prev_section, function()
    M.next_section(-1)
  end, 'previous guide section (diff: previous file)')
  if k.toggle_fold then
    for _, l in ipairs(type(k.toggle_fold) == 'table' and k.toggle_fold or { k.toggle_fold }) do
      vim.keymap.set('n', l, M.fold_key, { buffer = buf, expr = true, nowait = true, silent = true, desc = 'revuey: toggle fold on a title line (else <C-i>)' })
    end
  end
  map(buf, k.toggle_all_folds, M.toggle_all_folds, 'collapse / expand every file (guide: section)')
  map(buf, k.focus_panel, function()
    if api.nvim_win_is_valid(s.panel_win) then
      api.nvim_set_current_win(s.panel_win)
    end
  end, 'focus file panel')
end

local function panel_keymaps(s)
  local k = config.options.keymaps
  local buf = s.panel_buf
  local function file_under_cursor()
    return s.panel_files[api.nvim_win_get_cursor(0)[1]]
  end
  local function section_under_cursor()
    return s.panel_sections and s.panel_sections[api.nvim_win_get_cursor(0)[1]]
  end
  local function jump_section(si, focus)
    local r = s.layout.sections and s.layout.sections[si]
    if not r then
      return
    end
    section_fold(s, si, false)
    goto_row(s, r.start_row, 'top')
    panel.set_current_section(s, si)
    if focus then
      api.nvim_set_current_win(s.diff_win)
    end
  end
  local function jump(focus)
    local fi = file_under_cursor()
    if not fi then
      return
    end
    local row
    if s.view_mode == 'guide' then
      row = s.layout.file_rows and s.layout.file_rows[fi]
      if not row then
        return
      end
    else
      row = s.layout.files[fi].start_row
      close_file_fold(s, fi, false)
    end
    goto_row(s, row, 'top')
    panel.set_current(s, fi)
    if focus then
      api.nvim_set_current_win(s.diff_win)
    end
  end
  map(buf, { '<CR>', 'o', '<2-LeftMouse>' }, function()
    local layer = s.panel_layers and s.panel_layers[api.nvim_win_get_cursor(0)[1]]
    if layer then
      return M.set_scope(layer == 'full' and { kind = 'full' } or { kind = 'layer', index = layer })
    end
    local si = section_under_cursor()
    if si then
      return jump_section(si, true)
    end
    jump(true)
  end, 'open file in diff / select stack layer / guide section')
  stack_keymaps(buf)
  guide_keymaps(buf)
  map(buf, k.toggle_reviewed, function()
    local si = section_under_cursor()
    if si then
      return M.toggle_section(si)
    end
    local fi = file_under_cursor()
    if fi then
      M.toggle_reviewed(fi)
    end
  end, 'toggle file / guide section reviewed')
  map(buf, k.refresh, function()
    M.refresh({ force = true, notify = true })
  end, 'refresh review')
  map(buf, k.toggle_mode, M.toggle_mode, 'toggle working tree / committed only')
  map(buf, k.close, M.close, 'close review')
  map(buf, k.focus_panel, function()
    api.nvim_set_current_win(s.diff_win)
  end, 'focus diff')
  api.nvim_create_autocmd('CursorMoved', {
    group = s.augroup,
    buffer = buf,
    callback = function()
      if s.syncing or not api.nvim_win_is_valid(s.diff_win) then
        return
      end
      local si = section_under_cursor()
      if si then
        if si ~= s.current_section then
          jump_section(si, false)
        end
        return
      end
      local fi = file_under_cursor()
      if fi and fi ~= s.current_file then
        if s.view_mode == 'guide' then
          local row = s.layout.file_rows and s.layout.file_rows[fi]
          if row then
            goto_row(s, row, 'top')
          end
        else
          goto_row(s, s.layout.files[fi].start_row, 'top')
        end
        panel.set_current(s, fi)
      end
    end,
  })
end

local function set_win_opts(win, opts)
  -- scope=local: like :setlocal, so splits/new windows don't inherit review options
  for k, v in pairs(opts) do
    api.nvim_set_option_value(k, v, { scope = 'local', win = win })
  end
end

local function compute_numw(review)
  local maxl = 1
  for _, f in ipairs(review.files) do
    for _, h in ipairs(f.hunks) do
      maxl = math.max(maxl, h.old_start + h.old_count, h.new_start + h.new_count)
    end
  end
  return math.max(3, #tostring(maxl))
end

---Fill the diff buffer for the session's review.
---Snapshot of what the user is looking at, to restore after a re-render.
local function capture_view(s)
  if s.view_mode == 'guide' then
    return M.capture_guide(s)
  end
  local saved = { folds = {}, mode = 'diff' }
  if not api.nvim_win_is_valid(s.diff_win) then
    return saved
  end
  api.nvim_win_call(s.diff_win, function()
    local v = vim.fn.winsaveview()
    saved.offset = v.lnum - v.topline
    saved.col = v.col
    saved.row = v.lnum
    for fi, f in ipairs(s.review.files) do
      local r = s.layout.files[fi]
      if r then
        saved.folds[f.path] = vim.fn.foldclosed(r.start_row) ~= -1
      end
    end
    sync_hunk_folds(s)
  end)
  local e = s.layout.map[saved.row]
  local f = e and s.review.files[e.file_idx]
  if f then
    if e.meta == 'hunk' then
      saved.block = block_key_at(s, saved.row) -- keep the cursor on this hunk's header
    end
    saved.path, saved.kind = f.path, e.kind
    saved.new_lnum, saved.old_lnum = e.new_lnum or e.anchor_lnum, e.old_lnum
    saved.text = M.head_text(s, f) -- new-side text the cursor's line numbers refer to
    -- neighbours, to land somewhere sensible if this file disappears
    saved.next_paths, saved.prev_paths = {}, {}
    for i = e.file_idx + 1, #s.review.files do
      saved.next_paths[#saved.next_paths + 1] = s.review.files[i].path
    end
    for i = e.file_idx - 1, 1, -1 do
      saved.prev_paths[#saved.prev_paths + 1] = s.review.files[i].path
    end
  end
  return saved
end

---Row in the current layout closest to a captured position: same file, same line if still
---shown, else the nearest shown line of that file, else the file header.
local function find_saved_row(s, saved)
  if not saved.path then
    return math.min(saved.row or 1, #s.layout.lines)
  end
  if saved.block then
    for i, k in pairs(block_keys(s)) do
      if k == saved.block then
        return s.layout.blocks[i].start_row
      end
    end
  end
  local index = {}
  for fi, f in ipairs(s.review.files) do
    index[f.path] = fi
  end
  for fi, f in ipairs(s.review.files) do
    if f.path == saved.path then
      -- map the old new-side line through the content change (lines inserted/removed above)
      if saved.text and saved.new_lnum and saved.kind ~= 'del' then
        local new_text = M.head_text(s, f)
        if new_text and new_text ~= saved.text then
          local fwd = linemap.new(saved.text, new_text)
          local mapped
          for d = 0, 200 do
            mapped = fwd(saved.new_lnum - d)
            if mapped then
              mapped = mapped + d
              break
            end
          end
          saved.new_lnum = mapped or saved.new_lnum
        end
      end
      local r = s.layout.files[fi]
      local best, best_d = r.start_row, math.huge
      for row = r.start_row, r.end_row do
        local e = s.layout.map[row]
        local d
        if saved.kind == 'del' and e.kind == 'del' and saved.old_lnum then
          d = math.abs(e.old_lnum - saved.old_lnum)
        elseif saved.kind ~= 'del' and (e.kind == 'add' or e.kind == 'ctx') and saved.new_lnum then
          d = math.abs(e.new_lnum - saved.new_lnum)
        elseif e.kind ~= 'meta' and saved.new_lnum and (e.new_lnum or e.anchor_lnum) then
          d = math.abs((e.new_lnum or e.anchor_lnum) - saved.new_lnum) + 0.5
        end
        if d and d < best_d then
          best, best_d = row, d
        end
      end
      if saved.kind == 'meta' then
        return r.start_row
      end
      return best
    end
  end
  -- the file is gone: nearest surviving file, preferring the next one
  for _, list in ipairs({ saved.next_paths or {}, saved.prev_paths or {} }) do
    for _, p in ipairs(list) do
      if index[p] then
        saved.offset = 0
        saved.col = 0
        return s.layout.files[index[p]].start_row
      end
    end
  end
  return math.min(saved.row or 1, #s.layout.lines)
end

local function restore_view(s, saved)
  if not saved.row or not api.nvim_win_is_valid(s.diff_win) then
    return
  end
  if (saved.mode or 'diff') ~= (s.view_mode or 'diff') then
    return
  end
  local row
  if saved.mode == 'guide' then
    -- the same hunk line or the same place in the same paragraph; else the same offset into the
    -- same section
    local col
    row, col = find_guide_anchor(s, saved.anchor)
    if row then
      saved = vim.tbl_extend('force', saved, { col = col or saved.col })
    else
      local r = saved.section_idx and s.layout.sections and s.layout.sections[saved.section_idx]
      row = r and math.min(r.start_row + saved.rel, r.end_row) or math.min(saved.row, #s.layout.lines)
    end
  else
    row = find_saved_row(s, saved)
  end
  api.nvim_win_call(s.diff_win, function()
    vim.fn.winrestview({ lnum = row, col = saved.col or 0, topline = math.max(1, row - (saved.offset or 0)) })
  end)
end

---Guide view snapshot: section + offset into it, scroll offset, and closed section folds.
function M.capture_guide(s)
  local saved = { mode = 'guide', section_folds = {} }
  if not api.nvim_win_is_valid(s.diff_win) then
    return saved
  end
  api.nvim_win_call(s.diff_win, function()
    local v = vim.fn.winsaveview()
    saved.offset, saved.col, saved.row = v.lnum - v.topline, v.col, v.lnum
    for si, r in ipairs(s.layout.sections or {}) do
      local sec = s.guide and s.guide.resolved and s.guide.resolved.sections[si]
      if sec then
        saved.section_folds[sec.id or ('#' .. si)] = vim.fn.foldclosed(r.start_row) ~= -1
      end
    end
    sync_hunk_folds(s)
  end)
  saved.section_idx = section_at_row(s, saved.row)
  local r = saved.section_idx and s.layout.sections[saved.section_idx]
  saved.rel = r and (saved.row - r.start_row) or 0
  -- what the cursor is on, independent of row numbers (re-wrapping moves rows)
  local e = s.layout.map[saved.row]
  if e and e.hunk_id then
    saved.anchor = { hunk_id = e.hunk_id, line_idx = e.line_idx, note = e.note }
  elseif e and e.kind == 'prose' and e.block then
    saved.anchor = { block = e.block, para = e.para, pos = e.off + math.max((saved.col or 0) - (e.pre or 0), 0) }
  elseif e and e.meta == 'section' then
    saved.anchor = { section_idx = e.section_idx }
  end
  return saved
end

---Row (and column) in the current guide layout for a captured anchor, or nil.
find_guide_anchor = function(s, a)
  if not a then
    return nil
  end
  local best, best_off
  for row, e in ipairs(s.layout.map) do
    if a.hunk_id then
      if e.hunk_id == a.hunk_id and e.line_idx == a.line_idx and (e.note or nil) == (a.note or nil) then
        return row
      end
    elseif a.block then
      if e.block == a.block and e.para == a.para and e.off and e.off <= a.pos and (not best_off or e.off > best_off) then
        best, best_off = row, e.off
      end
    elseif a.section_idx and e.meta == 'section' and e.section_idx == a.section_idx then
      return row
    end
  end
  if best then
    local e = s.layout.map[best]
    return best, (e.pre or 0) + (a.pos - e.off)
  end
end

---Prose wrap width for the guide: the diff window minus the line-number columns, capped.
local function prose_width(s)
  local w = api.nvim_win_is_valid(s.diff_win) and api.nvim_win_get_width(s.diff_win) or 100
  return math.max(30, math.min(w - (2 * (s.numw or 3) + 4) - 2, 100))
end

---Name the diff buffer after what it shows (revuey://<branch>..<base>); renaming leaves an
---unlisted buffer holding the old name behind, which is wiped.
local function set_diff_name(s)
  local name = 'revuey://' .. s.review.branch .. '..' .. s.review.base
  local old = api.nvim_buf_get_name(s.diff_buf)
  if old:sub(-#name) == name then
    return
  end
  if pcall(api.nvim_buf_set_name, s.diff_buf, name) and old ~= '' then
    local alt = vim.fn.bufnr(old)
    if alt > 0 and alt ~= s.diff_buf and not vim.bo[alt].buflisted and api.nvim_buf_line_count(alt) <= 1 then
      pcall(api.nvim_buf_delete, alt, { force = true })
    end
  end
end

local function render(s, saved)
  s.render_count = (s.render_count or 0) + 1
  set_diff_name(s)
  s.numw = compute_numw(s.review)
  guide_view.prepare(s)
  if s.view_mode == 'guide' then
    s.prose_width = prose_width(s)
    s.layout = layout_mod.compose_guide(s.review.files, guide_view.doc(s, s.prose_width))
  else
    s.layout = layout_mod.compose(s.review.files)
  end
  if s.view_mode ~= 'guide' and #s.review.files == 0 then
    local r = s.review
    local msg = r.mode == 'worktree'
        and {
          'No changes between ' .. r.base .. ' and the working tree.',
          '',
          'Edit files or commit on this branch; the review refreshes automatically.',
        }
      or {
        'No committed changes between ' .. r.base .. ' and ' .. r.branch .. '.',
        '',
        r.dirty and 'The working tree has uncommitted changes: press gu to include them.'
          or 'Commit some work on this branch, then press R to refresh.',
      }
    for _, text in ipairs(msg) do
      s.layout.lines[#s.layout.lines + 1] = text
      s.layout.map[#s.layout.map + 1] = { kind = 'meta', meta = 'note', file_idx = 0, path = '' }
    end
  end
  s.folds = layout_mod.fold_levels(s.layout, config.options.fold_context_threshold, 3)
  local buf = s.diff_buf
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, s.layout.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  make_word_spans(s)
  syntax.attach(buf, s)
  decorate(s)
  api.nvim_win_call(s.diff_win, function()
    vim.cmd('normal! zx')
  end)
  -- collapsed hunks first: closing a hunk inside an already collapsed file would not work
  restore_hunk_folds(s)
  if s.view_mode == 'guide' then
    -- reviewed sections start folded; otherwise keep the user's fold state
    for si, sec in ipairs(s.guide.resolved and s.guide.resolved.sections or {}) do
      local closed = guide_view.section_reviewed(s, sec)
      local key = sec.id or ('#' .. si)
      if saved and saved.section_folds and saved.section_folds[key] ~= nil then
        closed = saved.section_folds[key]
      end
      if closed then
        section_fold(s, si, true)
      end
    end
  end
  for fi, f in ipairs(s.view_mode ~= 'guide' and s.review.files or {}) do
    local size = 0
    for _, h in ipairs(f.hunks) do
      size = size + #h.lines
    end
    local closed = review_mod.is_reviewed(s.review, f) or size > config.options.collapse_large_files
    if saved and saved.folds and saved.folds[f.path] ~= nil then
      closed = saved.folds[f.path] -- keep the user's fold state across refreshes
    end
    if closed then
      close_file_fold(s, fi, true)
    end
  end
  if saved then
    restore_view(s, saved)
  end
  s.stat_sig = M.stat_signature(s)
  panel.render(s)
  guide_view.draw_status(s)
  M.load_stats(s)
end

---Re-render in place, keeping the view (used when a guide finishes or the window is resized).
function M.rerender(s)
  s = s or M.session
  if s and not s.cleaned and api.nvim_buf_is_valid(s.diff_buf) then
    render(s, capture_view(s))
  end
end

---Cheap fingerprint of the working tree as far as this review is concerned: size+mtime of every
---file shown plus the index. Used on entering the diff window to decide whether to refresh.
function M.stat_signature(s)
  local parts = {}
  local function add(path)
    local st = vim.uv.fs_stat(path)
    parts[#parts + 1] = st and (st.size .. ':' .. st.mtime.sec .. '.' .. st.mtime.nsec) or '-'
  end
  for _, f in ipairs(s.review.files) do
    add(vim.fs.joinpath(s.review.root, f.path))
  end
  if s.review.index_path then
    add(s.review.index_path)
  end
  return table.concat(parts, ',')
end

local function warmup_lsp(s)
  if not config.options.lsp_warmup then
    return
  end
  local seen_ft = {}
  for _, f in ipairs(s.review.files) do
    if f.status ~= 'D' and not f.binary then
      local ft = vim.filetype.match({ filename = f.path })
      if ft and not seen_ft[ft] then
        seen_ft[ft] = true
        lsp.warmup(vim.fs.joinpath(s.review.root, f.path))
      end
    end
  end
end

---Release everything a session owns: autocmds, decoration hook, syntax cache, hidden LSP buffers.
cleanup = function(s)
  if s.cleaned then
    return
  end
  s.cleaned = true
  if M.session == s then
    M.session = nil
  end
  if s.augroup then
    pcall(api.nvim_del_augroup_by_id, s.augroup)
  end
  if s.debounce then
    s.debounce:stop()
    s.debounce:close()
    s.debounce = nil
  end
  syntax.detach(s.diff_buf)
  syntax.clear_cache()
  lsp.cleanup()
end

---@param review revuey.Review
---@param opts table
function M.show(review, opts)
  highlights.setup()
  if M.session then
    M.close({ keep_nvim = true })
  end
  vim.cmd('tabnew')
  if opts.standalone then
    -- launched by bin/revuey: the review is the whole session, drop the startup tab (dashboard etc.)
    pcall(vim.cmd, 'tabonly')
  end
  local s = { review = review, opts = opts, tab = api.nvim_get_current_tabpage(), header_marks = {} } ---@type revuey.Session
  -- the user's mode preference; a committed-only layer must not overwrite it
  s.target_mode = opts.mode or (config.options.uncommitted and 'worktree' or 'committed')
  local scratch = api.nvim_get_current_buf()
  s.diff_win = api.nvim_get_current_win()
  s.diff_buf = api.nvim_create_buf(false, true)
  pcall(api.nvim_buf_set_name, s.diff_buf, 'revuey://' .. review.branch .. '..' .. review.base)
  vim.bo[s.diff_buf].filetype = 'revuey'
  vim.bo[s.diff_buf].bufhidden = 'wipe'
  vim.bo[s.diff_buf].swapfile = false
  api.nvim_win_set_buf(s.diff_win, s.diff_buf)
  if api.nvim_buf_is_valid(scratch) and scratch ~= s.diff_buf and api.nvim_buf_get_name(scratch) == '' then
    pcall(api.nvim_buf_delete, scratch, {})
  end
  set_win_opts(s.diff_win, {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    statuscolumn = "%!v:lua.require'revuey.view'.statuscolumn()",
    foldmethod = 'expr',
    foldexpr = "v:lua.require'revuey.view'.foldexpr()",
    foldtext = "v:lua.require'revuey.view'.foldtext()",
    foldlevel = 2, -- hunk folds (level 2) start open, long context runs (level 3) closed
    foldenable = true,
    foldminlines = 0,
    winbar = WINBAR,
    wrap = false,
    list = false,
    spell = false,
    cursorline = true,
    conceallevel = 0,
  })
  set_win_opts(s.diff_win, { fillchars = 'fold: ,eob: ' })

  s.panel_buf = api.nvim_create_buf(false, true)
  pcall(api.nvim_buf_set_name, s.panel_buf, 'revuey://files')
  vim.bo[s.panel_buf].filetype = 'revuey-files'
  vim.bo[s.panel_buf].bufhidden = 'wipe'
  vim.cmd('topleft vsplit')
  s.panel_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(s.panel_win, s.panel_buf)
  api.nvim_win_set_width(s.panel_win, config.options.panel_width)
  set_win_opts(s.panel_win, {
    number = false,
    relativenumber = false,
    signcolumn = 'no',
    foldcolumn = '0',
    statuscolumn = '',
    wrap = false,
    cursorline = true,
    winfixwidth = true,
    spell = false,
    list = false,
  })
  set_win_opts(s.panel_win, { winbar = ' Files' })

  M.session = s
  render(s)
  -- One augroup per session, deleted on close/wipeout so nothing outlives the review.
  local group = api.nvim_create_augroup('revuey_session', { clear = true })
  s.augroup = group
  diff_keymaps(s)
  panel_keymaps(s)
  api.nvim_set_current_win(s.diff_win)
  goto_row(s, 1, 'top')

  api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = s.diff_buf,
    callback = function()
      local row = cursor_row(s)
      if s.view_mode == 'guide' then
        local si = section_at_row(s, row)
        if si ~= s.current_section then
          panel.set_current_section(s, si)
        end
        return
      end
      local fi = file_at_row(s, row)
      if fi ~= s.current_file then
        panel.set_current(s, fi)
      end
    end,
  })
  -- the guide's prose is wrapped to the window: re-wrap when it is resized
  api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      if M.session ~= s or s.view_mode ~= 'guide' or not api.nvim_win_is_valid(s.diff_win) then
        return
      end
      if prose_width(s) ~= s.prose_width then
        M.rerender(s)
      end
    end,
  })
  -- Winbar plugins (barbecue, dropbar, lualine...) may overwrite our winbar; put it back.
  local function guard_winbar()
    for _, w in ipairs({ s.diff_win, s.panel_win }) do
      if api.nvim_win_is_valid(w) then
        local want = w == s.diff_win and WINBAR or ' Files'
        if vim.wo[w].winbar ~= want then
          set_win_opts(w, { winbar = want })
        end
      end
    end
  end
  api.nvim_create_autocmd({ 'OptionSet' }, {
    group = group,
    pattern = 'winbar',
    callback = function()
      vim.schedule(function()
        if M.session == s then
          guard_winbar()
        end
      end)
    end,
  })
  api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter', 'LspAttach' }, {
    group = group,
    callback = function()
      vim.schedule(function()
        if M.session == s then
          guard_winbar()
        end
      end)
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = s.diff_buf,
    callback = function()
      local was_current = M.session == s
      cleanup(s)
      if was_current and api.nvim_win_is_valid(s.panel_win) and #api.nvim_list_wins() > 1 then
        pcall(api.nvim_win_close, s.panel_win, true)
      end
    end,
  })
  -- Auto-refresh. Writes only matter in working-tree mode; focus/enter catch outside changes
  -- (other editors, git commands) in either mode. Unchanged content never re-renders.
  local root_prefix = (vim.uv.fs_realpath(review.root) or review.root) .. '/'
  api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(ev)
      if s.review.mode ~= 'worktree' then
        return
      end
      local file = vim.uv.fs_realpath(ev.match) or ev.match
      if file:sub(1, #root_prefix) == root_prefix then
        M.schedule_refresh(s, 200)
      end
    end,
  })
  api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function()
      M.refresh()
    end,
  })
  api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = s.diff_buf,
    callback = function()
      if M.stat_signature(s) ~= s.stat_sig then
        return M.refresh()
      end
      M.check_refs(s)
      if s.review.mode ~= 'worktree' or s.refreshing then
        return
      end
      -- new untracked files don't change any stat we track; `git ls-files --others` is cheap
      git.async(function()
        local list = table.concat(git.untracked(s.review.root), '\0')
        if M.session == s and list ~= s.review.untracked_list then
          M.refresh()
        end
      end, function() end)
    end,
  })
  vim.defer_fn(function()
    if M.session == s then
      warmup_lsp(s)
    end
  end, 100)
  return s
end

-- ---------------------------------------------------------------------------
-- Guide view: switching and generation
-- ---------------------------------------------------------------------------

---Switch the main window between the diff view and the guide view (same buffer, same panel).
---@param mode? 'diff'|'guide' default: the other one
function M.set_view(mode)
  local s = M.session
  if not s then
    return
  end
  mode = mode or (s.view_mode == 'guide' and 'diff' or 'guide')
  if (s.view_mode or 'diff') == mode then
    return
  end
  s.mode_views = s.mode_views or {}
  s.mode_views[s.view_mode or 'diff'] = capture_view(s)
  s.view_mode = mode
  local saved = s.mode_views[mode]
  render(s, saved)
  if not saved then
    goto_row(s, 1, 'top')
  end
  s.mode_views[mode] = nil
end

---Re-render whichever review is open when a guide job changes (the review may have been closed
---and reopened while the job ran; jobs are keyed by review, not by session).
local function on_guide_change()
  local cur = M.session
  if cur and not cur.cleaned then
    if cur.guide then
      cur.guide.reload = true
    end
    M.rerender(cur)
  end
end

---Start a generation for the current review and show the guide view.
function M.generate_guide()
  local s = M.session
  if not s then
    return vim.notify('revuey: no review open', vim.log.levels.WARN)
  end
  if s.view_mode ~= 'guide' then
    M.set_view('guide')
  end
  guide_view.generate(s, on_guide_change)
end

---Regenerate (asks first when a guide exists, since it runs the model again).
function M.regenerate_guide()
  local s = M.session
  if not s then
    return
  end
  local g = guide_view.prepare(s)
  if guide_view.jobs[g.ks] then
    return vim.notify('revuey: a guide is already being generated (:RevueyGuide cancel stops it)', vim.log.levels.INFO)
  end
  if not g.record then
    return M.generate_guide()
  end
  vim.ui.select({ 'Generate a new guide', 'Cancel' }, { prompt = 'Regenerate the AI guide (runs claude)?' }, function(choice)
    if choice == 'Generate a new guide' then
      M.generate_guide()
    end
  end)
end

---`:RevueyGuide[!] [cancel]` and `gG`: toggle the guide view; with no guide (and no run), offer to
---generate one. `!` regenerates without asking. `cancel` stops a run.
function M.guide_command(bang, arg)
  local s = M.session
  if not s then
    return vim.notify('revuey: no review open (:Revuey first)', vim.log.levels.WARN)
  end
  if arg == 'cancel' then
    if not guide_view.cancel(s) then
      vim.notify('revuey: no guide is being generated for this review', vim.log.levels.INFO)
    end
    return
  elseif arg and arg ~= '' then
    return vim.notify('revuey: unknown argument ' .. arg .. ' (use :RevueyGuide, :RevueyGuide! or :RevueyGuide cancel)', vim.log.levels.ERROR)
  end
  if bang then
    return M.generate_guide()
  end
  if s.view_mode == 'guide' then
    return M.set_view('diff')
  end
  local g = guide_view.prepare(s)
  if g.record or guide_view.jobs[g.ks] or #g.hunks == 0 then
    return M.set_view('guide')
  end
  vim.ui.select({ 'Generate a guide', 'Cancel' }, {
    prompt = 'No AI guide for this review yet. Generate one with claude?',
  }, function(choice)
    if choice == 'Generate a guide' then
      M.generate_guide()
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Stacks
-- ---------------------------------------------------------------------------

---Should this review look for a stack? Yes unless an explicit base was given without --stack.
local function wants_stack(opts)
  return opts.scope == 'full' or not opts.base or opts.base == ''
end

---Detect the stack for a review (inside git.async). Returns stack (or nil) and the trunk.
local function stack_trunk(root, opts)
  local trunk = (opts.base ~= '' and opts.base) or config.options.default_branch or git.default_branch(root)
  if trunk and git.rev_parse(trunk, root) then
    return trunk
  end
end

---@return revuey.Stack?, string[]? notes for a plain review when there is no stack
local function detect_stack(root, opts, cache)
  local trunk = stack_trunk(root, opts)
  if not trunk then
    return nil
  end
  return stack_mod.detect(root, trunk, cache)
end

---BufEnter: refresh when branches/overrides changed elsewhere (another terminal, no focus event).
function M.check_refs(s)
  if not wants_stack(s.opts) or s.refreshing then
    return
  end
  git.async(function()
    local trunk = stack_trunk(s.review.root, s.opts)
    local key = trunk and stack_mod.fingerprint(s.review.root, trunk)
    if M.session == s and key and s.stack_cache and key ~= s.stack_cache.key then
      M.refresh()
    end
  end, function() end)
end

---Keep the scope on the same layer (by name) when the stack is re-detected.
local function rescope(old_stack, new_stack, scope)
  if not new_stack then
    return nil
  end
  if not scope then
    return { kind = 'layer', index = new_stack.current }
  end
  if scope.kind == 'full' then
    return scope
  end
  local name = old_stack and old_stack.layers[scope.index] and old_stack.layers[scope.index].name
  for i, l in ipairs(new_stack.layers) do
    if l.name == name then
      return { kind = 'layer', index = i }
    end
  end
  if name then
    vim.notify(
      ('revuey: layer %s is no longer in the stack; showing %s'):format(name, new_stack.layers[new_stack.current].name),
      vim.log.levels.WARN
    )
  end
  return { kind = 'layer', index = new_stack.current }
end

---Review load options for the session's current stack/scope.
local function load_opts(base_opts, stack, scope)
  local o = vim.tbl_extend('force', {}, base_opts)
  if stack and scope then
    o.target = stack_mod.target(stack, scope)
  end
  return o
end

---Per-layer stats (commits, files, reviewed) for the stack section, computed in the background
---from committed history (`git diff --raw`, no patch parsing). The layer being reviewed shows
---live numbers from the loaded review instead.
function M.load_stats(s)
  local stack = s.review.stack
  if not stack then
    return
  end
  local root = s.review.root
  local dir = s.opts.state_dir or config.options.state_dir or state_mod.default_dir()
  s.stats_gen = (s.stats_gen or 0) + 1
  local gen = s.stats_gen
  git.async(function()
    local scopes = {}
    for i in ipairs(stack.layers) do
      scopes[#scopes + 1] = { kind = 'layer', index = i }
    end
    scopes[#scopes + 1] = { kind = 'full' }
    local fns = {}
    for i, sc in ipairs(scopes) do
      fns[i] = function()
        local t = stack_mod.target(stack, sc)
        local tip = t.to or git.rev_parse('HEAD', root)
        local mb = tip and review_mod.merge_base_for(root, t, tip)
        if not mb then
          return nil
        end
        local count = tonumber(vim.trim(git.git({ 'rev-list', '--count', mb .. '..' .. tip }, root) or ''))
        local keys = review_mod.raw_keys(root, mb, tip, t.key_old) or {}
        local st = state_mod.load(dir, t.state_repo or root, t.state_branch, t.state_base)
        local files, reviewed = 0, 0
        for path, key in pairs(keys) do
          files = files + 1
          if state_mod.is_reviewed(st, path, key) then
            reviewed = reviewed + 1
          end
        end
        return { commits = count, files = files, reviewed = reviewed }
      end
    end
    local results = git.all(fns)
    if M.session ~= s or s.review.stack ~= stack or s.stats_gen ~= gen then
      return
    end
    for i, r in ipairs(results) do
      local stats = r[1] and r[2] or nil
      if i <= #stack.layers then
        stack.layers[i].stats = stats
      else
        stack.full_stats = stats
      end
    end
    panel.render(s)
    if s.on_stats then
      s.on_stats(s)
    end
  end, function() end)
end

---Switch the review to a scope: {kind='layer', index=i} or {kind='full'}.
function M.set_scope(scope)
  local s = M.session
  if not s or not s.review.stack then
    return vim.notify('revuey: no stack detected for this branch', vim.log.levels.INFO)
  end
  local cur = s.pending_scope or s.scope
  if cur and cur.kind == scope.kind and cur.index == scope.index then
    return
  end
  if scope.kind == 'layer' then
    s.last_layer = scope.index
  end
  s.pending_scope = scope
  M.refresh({ scope = scope, force = true })
end

---Move to the next/previous layer (from full scope: the bottom / top layer).
function M.next_layer(dir)
  local s = M.session
  local stack = s and s.review.stack
  if not stack then
    return vim.notify('revuey: no stack detected for this branch', vim.log.levels.INFO)
  end
  local cur = s.pending_scope or s.scope
  local idx
  if cur.kind == 'full' then
    idx = dir > 0 and 1 or #stack.layers
  else
    idx = cur.index + dir * vim.v.count1
  end
  if idx < 1 or idx > #stack.layers then
    return vim.notify('revuey: no layer ' .. (dir > 0 and 'above' or 'below'), vim.log.levels.INFO)
  end
  M.set_scope({ kind = 'layer', index = idx })
end

---Toggle between full-stack scope and the last layer scope.
function M.toggle_full()
  local s = M.session
  local stack = s and s.review.stack
  if not stack then
    return vim.notify('revuey: no stack detected for this branch', vim.log.levels.INFO)
  end
  local cur = s.pending_scope or s.scope
  if cur.kind == 'full' then
    M.set_scope({ kind = 'layer', index = math.min(s.last_layer or stack.current, #stack.layers) })
  else
    M.set_scope({ kind = 'full' })
  end
end

---`:RevueyStackParent [branch]`: record an explicit stack parent (git config
---`branch.<name>.revueyParent`) for the layer being reviewed, or else the current branch.
---`parent = ''` clears it; nil picks from a list (vim.ui.select). Runs git synchronously (tiny).
function M.stack_parent(parent)
  local s = M.session
  local root, branch, trunk
  local stack = s and s.review.stack
  if stack and stack.kind == 'local' and s.scope and s.scope.kind == 'layer' then
    root, branch, trunk = s.review.root, stack.layers[s.scope.index].name, stack.trunk
  else
    root = git.root(vim.fn.getcwd())
    branch = root and git.current_branch(root)
    trunk = root and (config.options.default_branch or git.default_branch(root))
  end
  if not branch then
    return vim.notify('revuey: no branch to set a stack parent for (detached HEAD or not in a repo?)', vim.log.levels.ERROR)
  end
  local key = 'branch.' .. branch .. '.revueyParent'
  local function apply(p)
    if p == '' or p == '--clear' then
      local res = git.system({ 'git', 'config', '--unset', key }, { cwd = root, text = true })
      if res.code == 5 then
        return vim.notify('revuey: ' .. branch .. ' has no stack parent override to clear', vim.log.levels.WARN)
      elseif res.code ~= 0 then
        return vim.notify('revuey: could not clear the override: ' .. vim.trim(res.stderr or ''), vim.log.levels.ERROR)
      end
      vim.notify('revuey: cleared the stack parent of ' .. branch, vim.log.levels.INFO)
    else
      if p == branch then
        return vim.notify('revuey: a branch cannot be its own parent', vim.log.levels.ERROR)
      end
      if p ~= trunk and not git.rev_parse('refs/heads/' .. p, root) then
        return vim.notify('revuey: no local branch ' .. p, vim.log.levels.ERROR)
      end
      local _, err = git.git({ 'config', key, p }, root)
      if err then
        return vim.notify('revuey: ' .. err, vim.log.levels.ERROR)
      end
      vim.notify(('revuey: stack parent of %s set to %s'):format(branch, p), vim.log.levels.INFO)
    end
    if M.session then
      M.refresh({ force = true })
    end
  end
  if parent then
    return apply(parent)
  end
  local out = git.git({ 'for-each-ref', '--sort=-committerdate', '--format=%(refname:short)', 'refs/heads' }, root) or ''
  local items = {}
  if trunk then
    items[#items + 1] = { label = trunk .. '  (trunk)', value = trunk }
  end
  for b in out:gmatch('[^\n]+') do
    if b ~= branch and b ~= trunk then
      items[#items + 1] = { label = b, value = b }
    end
  end
  items[#items + 1] = { label = '(clear override: detect automatically)', value = '' }
  vim.ui.select(items, {
    prompt = 'Stack parent of ' .. branch .. ':',
    format_item = function(it)
      return it.label
    end,
  }, function(choice)
    if choice then
      apply(choice.value)
    end
  end)
end

---Open a review. opts: {cwd?, base?, scope?:'full', mode?, standalone?, on_ready?}
---Without a base (or with scope='full') the local stack around HEAD is detected first; with no
---stack the review is the plain single-branch one.
function M.open(opts)
  opts = opts or {}
  git.async(function()
    local cache, stack_cache = {}, {}
    local stack, scope, root, notes
    if wants_stack(opts) then
      root = git.root(opts.cwd or vim.fn.getcwd())
      if root then
        stack, notes = detect_stack(root, opts, stack_cache)
      end
      if stack then
        scope = opts.scope == 'full' and { kind = 'full' } or { kind = 'layer', index = stack.current }
      end
    end
    local lo = load_opts(vim.tbl_extend('force', opts, { cache = cache }), stack, scope)
    local review, err = review_mod.load(lo)
    if not review then
      vim.notify('revuey: ' .. err, vim.log.levels.ERROR)
      return
    end
    review.stack, review.scope = stack, scope
    review.notes = not stack and notes or nil
    local s = M.show(review, opts)
    s.load_cache = cache
    s.stack_cache = stack_cache
    s.scope = scope
    s.last_layer = stack and (scope.kind == 'layer' and scope.index or stack.current) or nil
    if opts.on_ready then
      opts.on_ready(s)
    end
  end)
end

---Reload the review and re-render in place, keeping cursor, scroll, folds and reviewed state.
---Requests made while a refresh is in flight are coalesced into one follow-up refresh. Nothing is
---re-rendered when the review content is unchanged (no flicker).
---@param o? {mode?:'worktree'|'committed', force?:boolean, notify?:boolean}
function M.refresh(o)
  local s = M.session
  if not s then
    return
  end
  o = o or {}
  if s.refreshing then
    s.pending = vim.tbl_extend('force', s.pending or {}, o)
    return
  end
  s.refreshing = true
  s.target_mode = o.mode or s.target_mode or s.review.mode
  if o.scope then
    s.pending_scope = nil
  end
  local function finish()
    s.refreshing = false
    local pending = s.pending
    s.pending = nil
    if pending and M.session == s then
      vim.schedule(function()
        M.refresh(pending)
      end)
    end
  end
  git.async(function()
    local mode = s.target_mode
    local old_stack, stack, scope, notes = s.review.stack, nil, nil, nil
    if wants_stack(s.opts) then
      -- cheap when refs are unchanged (fingerprint cache)
      s.stack_cache = s.stack_cache or {}
      stack, notes = detect_stack(s.review.root, s.opts, s.stack_cache)
      scope = rescope(old_stack, stack, o.scope or s.scope)
      if old_stack and not stack then
        vim.notify('revuey: no stack detected any more; showing the plain branch review', vim.log.levels.WARN)
      end
    end
    local scope_changed = not vim.deep_equal(scope, s.scope) or stack ~= old_stack
    if scope_changed then
      s.load_cache = {} -- different diff entirely
    end
    s.load_cache = s.load_cache or {}
    local review, err = review_mod.load(load_opts(vim.tbl_extend('force', s.opts, {
      cwd = s.review.root,
      base = not stack and (s.opts.base or (not s.review.target and s.review.base)) or nil,
      mode = mode,
      cache = s.load_cache,
    }), stack, scope))
    if M.session ~= s or s.cleaned then
      return finish()
    end
    if not review then
      vim.notify('revuey: ' .. err, vim.log.levels.ERROR)
      return finish()
    end
    review.stack, review.scope = stack, scope
    review.notes = not stack and notes or nil
    if o.force or scope_changed or review.signature ~= s.review.signature then
      local saved
      if scope and s.scope and not vim.deep_equal(scope, s.scope) and old_stack then
        -- switching scope: remember where we were, and return to where we left the new one
        s.scope_views = s.scope_views or {}
        local vm = s.view_mode or 'diff'
        s.scope_views[stack_mod.scope_key(old_stack, s.scope) .. '\0' .. vm] = capture_view(s)
        saved = s.scope_views[stack_mod.scope_key(stack, scope) .. '\0' .. vm]
      elseif not (scope and not vim.deep_equal(scope, s.scope)) then
        saved = capture_view(s)
      end
      s.review = review
      s.scope = scope
      s.opts.mode = mode
      s.head_cache = nil
      render(s, saved)
      if not saved then
        goto_row(s, 1, 'top')
        panel.set_current(s, 1)
      end
      lsp.checktime() -- hidden LSP buffers follow the files on disk
    else
      s.stat_sig = M.stat_signature(s)
    end
    if o.notify then
      vim.notify('revuey: refreshed (' .. #review.files .. ' files)', vim.log.levels.INFO)
    end
    finish()
  end, function(e)
    vim.schedule(function()
      vim.notify('revuey: ' .. tostring(e), vim.log.levels.ERROR)
    end)
    finish()
  end)
end

---Switch between working-tree and committed-only review.
function M.toggle_mode()
  local s = M.session
  if not s then
    return
  end
  if s.review.mode_locked then
    return vim.notify('revuey: this scope is committed-only (working-tree changes belong to the HEAD layer)', vim.log.levels.INFO)
  end
  -- toggle relative to where we're heading (a pending or in-flight switch), not the shown mode
  local current = (s.pending and s.pending.mode) or s.target_mode or s.review.mode
  local mode = current == 'worktree' and 'committed' or 'worktree'
  M.refresh({ mode = mode, force = true })
end

---Debounced refresh (BufWritePost bursts, e.g. :wa).
function M.schedule_refresh(s, ms)
  if not s.debounce then
    s.debounce = vim.uv.new_timer()
  end
  s.debounce:stop()
  s.debounce:start(ms, 0, vim.schedule_wrap(function()
    if M.session == s then
      M.refresh()
    end
  end))
end

function M.close(o)
  local s = M.session
  if not s then
    return
  end
  if s.opts.standalone and not (o and o.keep_nvim) then
    vim.cmd('confirm qall')
    return
  end
  cleanup(s)
  if api.nvim_tabpage_is_valid(s.tab) then
    if #api.nvim_list_tabpages() > 1 then
      local nr = api.nvim_tabpage_get_number(s.tab)
      pcall(vim.cmd, 'tabclose ' .. nr)
    else
      vim.cmd('tabnew')
      pcall(vim.cmd, 'tabclose ' .. api.nvim_tabpage_get_number(s.tab))
    end
  end
  for _, b in ipairs({ s.diff_buf, s.panel_buf }) do
    if api.nvim_buf_is_valid(b) then
      pcall(api.nvim_buf_delete, b, { force = true })
    end
  end
end

return M
