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

local M = {}

local cleanup -- forward declaration

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

local function decorate(s)
  local buf, map = s.diff_buf, s.layout.map
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  s.header_marks = {}
  for row, e in ipairs(map) do
    local r0 = row - 1
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
    if e.kind ~= 'meta' then
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
    local hrow = s.layout.files[fi].hunk_rows[hi] -- 1-based header row; line k at hrow + k
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

local function goto_row(s, row, how, col)
  api.nvim_win_call(s.diff_win, function()
    local top, bot = vim.fn.line('w0'), vim.fn.line('w$')
    api.nvim_win_set_cursor(0, { row, col or 0 })
    if how ~= 'top' then
      vim.cmd('normal! zv')
    end
    if how == 'top' then
      vim.cmd('normal! zt')
    elseif row < top or row > bot then
      vim.cmd('normal! zz')
    end
  end)
end

local function in_closed_file_fold(s, row)
  return api.nvim_win_call(s.diff_win, function()
    local c = vim.fn.foldclosed(row)
    return c ~= -1 and s.layout.map[c] and s.layout.map[c].meta == 'file'
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
  local e, row = current(s)
  if not e then
    return
  end
  local f = s.review.files[e.file_idx]
  if f.status == 'D' then
    return vim.notify('revuey: file was deleted on this branch', vim.log.levels.INFO)
  end
  local lnum = e.new_lnum or e.anchor_lnum or 1
  local col = (e.kind == 'add' or e.kind == 'ctx') and api.nvim_win_get_cursor(s.diff_win)[2] or 0
  open_path(s, vim.fs.joinpath(s.review.root, f.path), lnum, col)
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
    goto_row(s, nxt and nxt.start_row or s.layout.files[fi].start_row, nxt and 'top' or nil)
  end
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
  local function jump(focus)
    local fi = file_under_cursor()
    if not fi then
      return
    end
    local row = s.layout.files[fi].start_row
    close_file_fold(s, fi, false)
    goto_row(s, row, 'top')
    panel.set_current(s, fi)
    if focus then
      api.nvim_set_current_win(s.diff_win)
    end
  end
  map(buf, { '<CR>', 'o', '<2-LeftMouse>' }, function()
    jump(true)
  end, 'open file in diff')
  map(buf, k.toggle_reviewed, function()
    local fi = file_under_cursor()
    if fi then
      M.toggle_reviewed(fi)
    end
  end, 'toggle file reviewed')
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
      if s.syncing then
        return
      end
      local fi = file_under_cursor()
      if fi and fi ~= s.current_file and api.nvim_win_is_valid(s.diff_win) then
        goto_row(s, s.layout.files[fi].start_row, 'top')
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
  local saved = { folds = {} }
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
  end)
  local e = s.layout.map[saved.row]
  local f = e and s.review.files[e.file_idx]
  if f then
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
  local row = find_saved_row(s, saved)
  api.nvim_win_call(s.diff_win, function()
    vim.fn.winrestview({ lnum = row, col = saved.col or 0, topline = math.max(1, row - (saved.offset or 0)) })
  end)
end

local function render(s, saved)
  s.render_count = (s.render_count or 0) + 1
  s.layout = layout_mod.compose(s.review.files)
  if #s.review.files == 0 then
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
  s.numw = compute_numw(s.review)
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
  for fi, f in ipairs(s.review.files) do
    local size = 0
    for _, h in ipairs(f.hunks) do
      size = size + #h.lines
    end
    local closed = review_mod.is_reviewed(s.review, f) or size > config.options.collapse_large_files
    if saved and saved.folds[f.path] ~= nil then
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
    foldlevel = 1,
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
      local fi = file_at_row(s, cursor_row(s))
      if fi ~= s.current_file then
        panel.set_current(s, fi)
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

---Open a review. opts: {cwd?, base?, standalone?, on_ready?}
function M.open(opts)
  opts = opts or {}
  git.async(function()
    local cache = {}
    local review, err = review_mod.load(vim.tbl_extend('force', opts, { cache = cache }))
    if not review then
      vim.notify('revuey: ' .. err, vim.log.levels.ERROR)
      return
    end
    local s = M.show(review, opts)
    s.load_cache = cache
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
    s.load_cache = s.load_cache or {}
    local review, err = review_mod.load(vim.tbl_extend('force', s.opts, {
      cwd = s.review.root,
      base = s.review.base,
      mode = mode,
      cache = s.load_cache,
    }))
    if M.session ~= s or s.cleaned then
      return finish()
    end
    if not review then
      vim.notify('revuey: ' .. err, vim.log.levels.ERROR)
      return finish()
    end
    if o.force or review.signature ~= s.review.signature then
      local saved = capture_view(s)
      s.review = review
      s.opts.mode = mode
      s.head_cache = nil
      render(s, saved)
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
